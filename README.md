# EKS LLM Lab — train and serve LLMs on Kubernetes, hands-on

A small but production-shaped lab: Terraform builds an EKS cluster where **Karpenter launches GPU nodes on demand**, you **serve an LLM with vLLM**, run **multi-node distributed fine-tuning (PyTorch DDP over NCCL)**, push the result to S3 via **EKS Pod Identity**, then **serve your own fine-tuned model**, with Prometheus metrics on top.

It's built to give you real stories for infra interviews at OpenAI, Anthropic, xAI, Meta and similar labs: GPU scheduling, autoscaling, distributed training failure modes, inference performance, and cost.

```
                         ┌──────────────────────── VPC 10.0.0.0/16 (3 AZs) ────────────────────────┐
  you ── kubectl ──▶ EKS │  private subnets                                                        │
       (public API)      │  ┌──────────────── managed node group "system" (2× m6i.large) ───────┐  │
                         │  │ karpenter controller · coredns · prometheus/grafana               │  │
                         │  └───────────────────────────────────────────────────────────────────┘  │
                         │            │ watches Pending pods → calls EC2 Fleet                     │
                         │            ▼                                                            │
                         │  ┌── Karpenter NodePool "gpu" (g6/g5/g6e, spot→on-demand, taint) ───┐  │
                         │  │ vllm-qwen (1 GPU)   ddp-train-0 (1 GPU) ◀─NCCL─▶ ddp-train-1 (1 GPU)│ │
                         │  └──────────────────────────────────────────┬────────────────────────┘  │
                         │                     NAT GW → HuggingFace     │ Pod Identity              │
                         └──────────────────────────────────────────────┼───────────────────────────┘
                                                                        ▼
                                                              S3 bucket (checkpoints/models)
```

| Path | What it is |
|---|---|
| `terraform/` | VPC, EKS (module v21), Karpenter IAM/SQS + Helm chart, S3 bucket, Pod Identity role |
| `k8s/00-karpenter-nodepools.yaml` | CPU and GPU NodePools / EC2NodeClasses (Bottlerocket, NVIDIA drivers built in) |
| `k8s/10-vllm-serve.yaml` | vLLM serving Qwen2.5-1.5B-Instruct, OpenAI-compatible API |
| `k8s/20-ddp-train.yaml` + `training/train_ddp.py` | 2-node DDP fine-tune of Qwen2.5-0.5B on Dolly, uploads to S3 |
| `k8s/30-vllm-serve-finetuned.yaml` | Serves your fine-tuned model, pulled from S3 by an initContainer |
| `k8s/40-vllm-podmonitor.yaml` | Prometheus scraping of vLLM metrics |
| `scripts/load_test.py` | Concurrent streaming load test (TTFT p50/p95, tokens/s) |
| `INTERVIEW-NOTES.md` | Concepts and questions to practise talking through |
| `NETWORKING-ISTIO-CALICO.md` | Add-on guide: Calico network policy + Istio service mesh (mTLS, canary routing, L7 authz) |
| `k8s/50-*`, `k8s/60-*`, `k8s/61-*`, `k8s/41-*` | Manifests for the Calico/Istio guide |
| `PLATFORM-HUB-SPOKE.md` | Add-on guide: hub cluster with central Argo CD + Prometheus/Grafana managing spokes; sandboxes with warm pools; Kueue team queues |
| `platform/hub-terraform/`, `platform/gitops/`, `platform/examples/`, `platform/scripts/` | Code for the hub and spoke guide |
| `SYSTEM-DESIGN-SANDBOX-PLATFORM.md` | Interview system design: multi-cluster LLM training + code-execution sandboxes, GitOps, central monitoring |

---

## Cost and safety first

Rough on-demand prices in us-east-1 (check the AWS pricing pages; Spot is often 50–70% cheaper):

| Item | Approx. |
|---|---|
| EKS control plane | $0.10/hr |
| 2× m6i.large system nodes | ~$0.19/hr |
| NAT gateway | ~$0.045/hr + data |
| 1× g6.xlarge (NVIDIA L4 24 GB) | ~$0.80/hr on-demand |

Baseline is about **$0.35/hr with no GPU running**, and about **$2–3/hr during the training step** (2–3 GPUs). A 3–4 hour session costs roughly $5–10. **Always run the teardown (step 10) when you're done.** The GPU NodePool has a hard limit of 4 GPUs as a guardrail.

Set a billing alarm before starting: Billing → Budgets → create a $50/month cost budget with email alerts.

---

## Step 0 — Prerequisites

1. **Tools on your laptop:** `aws` CLI v2, `terraform` ≥ 1.5.7, `kubectl`, `helm` v3, `envsubst` (in `gettext`; `brew install gettext` on macOS), `python3`. On **Amazon Linux 2023 / 2**, run `bash scripts/install-tools-amazon-linux.sh` to install all of them (plus `istioctl`).
2. **AWS credentials** with admin rights on a sandbox account: `aws sts get-caller-identity` should work.
3. **GPU quota (do this first, approval can take hours to a day).** New accounts often have **0 vCPUs** for GPU instances. In the console: Service Quotas → Amazon EC2 → request:
   - `Running On-Demand G and VT instances` → **16** vCPUs
   - `All G and VT Spot Instance Requests` → **16** vCPUs

   A g6.xlarge is 4 vCPUs, so 16 gives you room for 3–4 GPU nodes. Check from the CLI:
   ```bash
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region us-east-1   # On-Demand G/VT
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-3819A6DF --region us-east-1   # Spot G/VT
   ```
4. **Spot service-linked role** (one-time per account; errors if it already exists, which is fine):
   ```bash
   aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
   ```

---

## Step 1 — Build the infrastructure (≈15–20 min)

```bash
cd terraform
terraform init
terraform plan -out tfplan        # read it: VPC, EKS, IAM roles, SQS queue, EventBridge rules, S3, Helm release
terraform apply tfplan
```

**What to understand while it runs (interview gold):**
- **Why Karpenter instead of Cluster Autoscaler?** CA scales pre-defined node groups; Karpenter looks at Pending pods' actual requirements (GPU count, arch, zone, capacity type) and calls EC2 Fleet directly for the best-fit instance, usually in under a minute. It also consolidates and handles Spot interruptions via the SQS queue Terraform created.
- **Why is the controller pinned to the managed node group?** If Karpenter ran on a node it manages, it could consolidate away its own node.
- **Pod Identity vs IRSA:** both give pods AWS creds without static keys. Pod Identity needs no OIDC provider trust policy per cluster and uses `aws_eks_pod_identity_association` (see `main.tf`).
- **Subnet sizing:** VPC CNI gives every pod a real VPC IP, which is why the private subnets are /20s.

## Step 2 — Connect and verify

```bash
$(terraform output -raw configure_kubectl)
cd ..
kubectl get nodes -o wide                       # 2 system nodes, Bottlerocket
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -f   # leave this open in a second terminal
```

## Step 3 — Create the Karpenter NodePools

```bash
CLUSTER_NAME=llm-lab envsubst '${CLUSTER_NAME}' < k8s/00-karpenter-nodepools.yaml | kubectl apply -f -
kubectl get nodepools,ec2nodeclasses
```

No GPU nodes exist yet. That's intended: Karpenter creates them only when a pod asks for `nvidia.com/gpu`.

## Step 4 — Serve an LLM with vLLM

```bash
kubectl apply -f k8s/10-vllm-serve.yaml
kubectl -n llm get pods -w                       # Pending → (Karpenter launches a node) → ContainerCreating → Running
```

In another terminal, watch Karpenter do its job:
```bash
kubectl get nodeclaims -w                        # a NodeClaim appears, picks e.g. g6.xlarge spot
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,workload
```

Expect ~1 min for the node, ~2–4 min to pull the ~10 GB image, ~1–2 min for model download and CUDA graph capture. Then:

```bash
kubectl -n llm logs deploy/vllm-qwen -f          # look for KV cache size / "maximum concurrency" lines
kubectl -n llm port-forward svc/vllm-qwen 8000:8000 &

curl -s localhost:8000/v1/models | python3 -m json.tool
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen",
  "messages": [{"role":"user","content":"In two sentences, what is a KV cache?"}],
  "max_tokens": 120
}' | python3 -m json.tool
```

Check the GPU from inside the pod:
```bash
kubectl -n llm exec deploy/vllm-qwen -- nvidia-smi
```
Memory shows ~90% used even when idle. That's `--gpu-memory-utilization=0.90`: vLLM pre-allocates the KV cache up front (PagedAttention blocks).

Load test it:
```bash
python3 scripts/load_test.py --concurrency 1  --requests 8
python3 scripts/load_test.py --concurrency 32 --requests 128
```
Compare: aggregate tokens/s goes **up a lot** with concurrency (continuous batching) while per-request TTFT gets worse. Being able to explain that throughput/latency tradeoff with your own numbers is one of the most valuable things in this lab.

## Step 5 — Multi-node distributed training (DDP)

```bash
kubectl -n llm create configmap train-script --from-file=training/train_ddp.py
export BUCKET=$(terraform -chdir=terraform output -raw artifacts_bucket)
envsubst '${BUCKET}' < k8s/20-ddp-train.yaml | kubectl apply -f -

kubectl get nodeclaims -w                        # 1–2 more GPU nodes (pod anti-affinity forces separate nodes)
kubectl -n llm get pods -l job-name=ddp-train -o wide
kubectl -n llm logs -f -l job-name=ddp-train,batch.kubernetes.io/job-completion-index=0   # rank 0: loss + tok/s
```

What's happening:
- The **Indexed Job** gives each pod `JOB_COMPLETION_INDEX` (0, 1), used as `--node_rank`.
- The **headless Service `ddp`** plus `subdomain: ddp` gives rank 0 a stable DNS name, `ddp-train-0.ddp`, used as `--master_addr`. torchrun rendezvous happens on port 29500.
- `NCCL_DEBUG=INFO` logs show the transport. On g6 you'll see `NET/Socket` (plain TCP). On p4d/p5 with EFA you'd see `NET/OFI` (libfabric), which is the step-change in multi-node bandwidth.
- `loss.backward()` triggers the **gradient all-reduce** across nodes; every rank ends each step with identical weights.
- Rank 0 saves the model and uploads it to S3 using **Pod Identity** credentials (no keys anywhere).

When the Job completes:
```bash
aws s3 ls s3://$BUCKET/models/qwen2.5-0.5b-dolly/
```
After about 5 minutes Karpenter removes the now-empty GPU nodes (`consolidationPolicy: WhenEmpty`). Watch it happen in the Karpenter logs.

**Experiments to run:**
1. Set `completions/parallelism` to 1 and `--nnodes=1`: compare tok/s against 2 nodes. Is scaling linear? Why not? (communication overhead without EFA)
2. Delete one training pod mid-run: `kubectl -n llm delete pod ddp-train-1-xxxxx`. Watch rank 0 hang, then fail with an NCCL timeout. This is exactly why large-scale training needs checkpointing and elastic or gang-aware restart.
3. Set `NodePool gpu` capacity type to Spot only and imagine a 2-minute interruption notice mid-epoch. What should the job do? (Checkpoint on SIGTERM, resume from S3.)

## Step 6 — Serve the model you just trained

```bash
envsubst '${BUCKET}' < k8s/30-vllm-serve-finetuned.yaml | kubectl apply -f -
kubectl -n llm get pods -l app=vllm-finetuned -w
kubectl -n llm port-forward svc/vllm-finetuned 8001:8000 &
curl -s localhost:8001/v1/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen-dolly",
  "prompt": "### Instruction:\nGive me three tips for running GPUs on Kubernetes.\n\n### Response:\n",
  "max_tokens": 150
}' | python3 -m json.tool
```

That's a complete loop: **data → distributed training → artifact store → inference**, all on one cluster.

## Step 7 — Observability

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin123
kubectl apply -f k8s/40-vllm-podmonitor.yaml

kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &      # http://localhost:3000  admin / admin123
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
```

Re-run the load test and query in Prometheus:
- `vllm:num_requests_running` / `vllm:num_requests_waiting` — queueing. Waiting > 0 means you're saturated.
- `vllm:gpu_cache_usage_perc` — KV cache pressure (at 100%, requests get preempted).
- `histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[1m])))` — p95 TTFT.
- `rate(vllm:generation_tokens_total[1m])` — output tokens/s.

(Metric names occasionally change between vLLM versions; `curl localhost:8000/metrics | grep vllm:` shows the current set.)

## Step 8 — Break/fix drills (do these, they're the best interview prep)

| Break it | What you should observe and explain |
|---|---|
| Remove the `tolerations` from the vLLM Deployment | Pod stays Pending; `kubectl describe pod` shows the untolerated `nvidia.com/gpu` taint. Karpenter logs say no NodePool matches. |
| Request `nvidia.com/gpu: 8` | Karpenter can't fit within the NodePool `limits` (4 GPUs) or the allowed instance sizes; read its error. |
| Set `--gpu-memory-utilization=0.30` | vLLM fails at startup, or reports a tiny KV cache and low max concurrency. Explain weights vs KV cache memory. |
| Set `--max-model-len=32768` on the L4 | KV cache can't fit a single max-length sequence; vLLM refuses to start. Do the KV-cache math (see notes). |
| Remove the `/dev/shm` volume from the training Job | NCCL/DataLoader shared-memory errors (bus error / `unable to write to file </torch_...>`). |
| Remove `publishNotReadyAddresses: true` from the `ddp` Service | Rank 1 can't resolve `ddp-train-0.ddp` until rank 0 is Ready, so rendezvous fails or stalls. |
| Remove `serviceAccountName: trainer` from the training Job | Pod gets no Pod Identity creds, so the S3 upload fails with `NoCredentialsError` / AccessDenied. Trace how creds reach the pod (`AWS_CONTAINER_CREDENTIALS_FULL_URI`). |
| `kubectl delete nodeclaim <gpu-node>` while vLLM runs | Graceful drain, pod reschedules, Karpenter replaces the node. Measure the downtime and say how you'd hide it (replicas > 1, PDB, warm pool, image pre-pull). |

## Step 9 — Level-ups (once the basics feel easy)

1. **Gang scheduling with Kueue.** If only one of the two training pods fits, the other sits Pending while one GPU idles, and with many jobs that can deadlock. Install Kueue and submit the Job through a `LocalQueue` so all pods are admitted together or not at all.
2. **Autoscale inference on the right signal.** CPU is meaningless for vLLM. Use KEDA with a Prometheus trigger on `vllm:num_requests_waiting`, and let Karpenter add GPU nodes underneath.
3. **Faster cold starts.** Model weights on emptyDir are re-downloaded every time. Try S3 + `aws s3 sync` (already in step 6), FSx for Lustre, or a node-local cache. Pre-pull the 10 GB image with a DaemonSet or Bottlerocket EBS snapshots. Measure start-to-ready time before and after.
4. **Bigger models / tensor parallelism.** On a `g6.12xlarge` (4× L4), run vLLM with `--tensor-parallel-size=4` and an 8B model. Then look at LeaderWorkerSet (LWS) for multi-node inference.
5. **Ray.** Install KubeRay and redo training with Ray Train and serving with Ray Serve; compare the operational model with the plain Job.
6. **FSDP.** Swap DDP for FSDP in `train_ddp.py` and fit a model that doesn't fit in one GPU's memory. Explain sharding of params, grads and optimizer state.
7. **Network security and service mesh.** Follow `NETWORKING-ISTIO-CALICO.md`: Calico default-deny for the `llm` namespace, then Istio mTLS, a 90/10 canary between the base and fine-tuned models, and identity-based authorization.
8. **Policy.** Add Kyverno policies: GPU pods must set memory limits, images must be pinned by digest, etc.
9. **GitOps and multi-cluster.** Follow `PLATFORM-HUB-SPOKE.md`: a hub cluster runs Argo CD and central Prometheus/Grafana and manages this cluster (and more spokes) from Git, including a sandbox service and Kueue team queues.

## Step 10 — Teardown (don't skip this)

Order matters: delete Karpenter-launched nodes **before** destroying Terraform, otherwise orphaned EC2 instances block VPC deletion and keep billing.

```bash
helm uninstall kps -n monitoring 2>/dev/null || true
kubectl delete ns llm monitoring --wait=true
kubectl delete nodepools --all
kubectl get nodeclaims                           # wait until this is empty
kubectl delete ec2nodeclasses --all

cd terraform
terraform destroy
```

Then confirm in the EC2 console (in your region) that no instances tagged `karpenter.sh/nodepool` remain, and that no load balancers or EBS volumes are left.

---

### Version notes (checked November 2026)
- terraform-aws-modules/eks `~> 21.0` (v21.30.x current), AWS provider `~> 6.0`
- EKS Kubernetes 1.35 (1.36 also available); Karpenter 1.15.2 (supports K8s up to 1.36)
- vLLM image `v0.34.0`. If the pod logs show `CUDA driver version is insufficient`, the Bottlerocket NVIDIA driver is older than the image's CUDA build; pin an older vLLM tag, or move the cluster to a newer K8s version (newer Bottlerocket variants ship newer drivers).
- Training image `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` with `transformers==4.46.3`, `datasets==3.1.0`.
