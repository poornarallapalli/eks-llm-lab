# Platform v2: hub + dev + staging, everything after Day 1 from Git

This rebuild applies the best practices from our discussion:

| Practice | How v2 does it |
|---|---|
| **Terraform only for Day 0–1** | VPCs, EKS, Day-1 add-ons (VPC CNI, CoreDNS, kube-proxy, Pod Identity agent, **Karpenter controller**), IAM, AMP, Argo CD. Nothing else |
| **Argo CD for every platform add-on** | Karpenter NodePools, **Calico** (policy-only), **Istio** (base → istiod → gateway), baseline network policy + mTLS, Prometheus agent, Kueue + queues, Agent Sandbox + warm pool, and the vLLM app |
| **Folder per environment, one `main` branch** | `gitops/envs/{dev,staging}/addons.yaml` (add-on versions), `values-<env>.yaml` (config), `apps/vllm/envs/<env>/values.yaml` (app) |
| **Promotion = PR** | Change a version or tag in the dev file → merge → only dev changes → validate → same change in the staging file |
| **Separate Terraform state per environment** | S3 backend, KMS-encrypted, versioned, native S3 locking (`use_lockfile`), one state key per env |
| **Managed central metrics** | Every cluster remote_writes to **Amazon Managed Prometheus** with SigV4 + Pod Identity; Grafana on the hub. No NLB, DNS or VPC peering |
| **No stored credentials** | Argo CD → spokes via IAM role chain + EKS Access Entries; Prometheus/Grafana → AMP via Pod Identity; trainer → S3 via Pod Identity |
| **Guardrails on Git** | `validate` workflow on every PR (Terraform fmt/validate, generated ApplicationSets up to date, every chart renders for every env), CODEOWNERS for staging |

```
                         GitHub: poornarallapalli/eks-llm-lab (main)
                gitops/envs/dev/addons.yaml   gitops/envs/staging/addons.yaml   apps/vllm/envs/*
                                       ▲ pull
   ┌────────────── platform-hub (10.100/16) ──────────────┐
   │ Argo CD ── ApplicationSets (matrix: env file × cluster label env=…)                 │
   │ Grafana ──query (SigV4)──▶  Amazon Managed Prometheus  ◀──remote_write (SigV4)── every cluster │
   └──────────┬─────────────────────────────┬─────────────┘
              │ IAM role chain + Access Entry │
   ┌──────────▼──────── llm-dev (10.10/16) ─┐ ┌──────────▼──── llm-staging (10.20/16) ─┐
   │ env=dev: newest versions first          │ │ env=staging: promoted versions          │
   │ Calico · Istio · Kueue · Agent Sandbox  │ │ same add-ons, staging values             │
   │ Karpenter pools (gpu ≤4, Spot ok)       │ │ (gpu ≤2, on-demand only, HA Prometheus)  │
   │ vLLM replicas: 1                        │ │ vLLM replicas: 0 until you test           │
   └─────────────────────────────────────────┘ └──────────────────────────────────────────┘
```

**Cost:** about **$0.30/hr per cluster** idle (control plane + 2 system nodes + NAT), so ~$0.90/hr for three, plus **~$0.30–0.80/hr for dev's GPU** while vLLM runs (set dev `replicas: 0` in Git when you're not using it), plus small AMP ingest charges.

---

## Part A — Tear down the current three clusters

Order matters: **hub first** (stop Argo CD and remove its load balancer), **then the spokes** (remove Karpenter nodes, then destroy). Do this **before** you replace the repo contents in Part B, because these steps use the old Terraform folders and their state.

> Where each one's Terraform state lives (from our session):
> - `platform-hub` → `~/project27/eks-llm-lab/platform/hub-terraform/` (default workspace)
> - `llm-lab` → `~/project27/eks-llm-lab-3/terraform/` (default workspace)
> - `llm-lab-2` → `~/project27/eks-llm-lab/terraform/` (workspace `spoke2`)

Refresh your AWS credentials first. Each destroy takes 10–15 minutes.

### A1. Stop Argo CD from re-creating anything
```bash
kubectl --context hub -n argocd delete application platform-root --cascade=orphan
kubectl --context hub -n argocd delete applicationsets --all
kubectl --context hub -n argocd get applications     # should become empty
```
(Generated Applications have no deletion finalizer, so this removes the Applications but leaves their resources in place. We remove those next.)

### A2. Remove the hub's NLB, then destroy the hub
```bash
kubectl --context hub -n monitoring delete svc prometheus-remote-write --wait=true
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'monitori')].LoadBalancerName"   # wait until []

cd ~/project27/eks-llm-lab/platform/hub-terraform
terraform state list | grep cluster_spoke    # shows which spokes the last apply registered
terraform destroy \
  -var gitops_repo_url=https://github.com/poornarallapalli/eks-llm-lab.git \
  -var 'spoke_clusters={"llm-lab"={labels={env="dev",gpu="true"}},"llm-lab-2"={labels={env="staging",gpu="true"}}}'
```
Use the **same** `spoke_clusters` value as your last hub apply. If `llm-lab-2` was never added to the hub, drop it from the map.

### A3. Each spoke: remove Karpenter nodes, remove GuardDuty's endpoint, destroy
GuardDuty Runtime Monitoring (enabled on your account) adds a **VPC endpoint and a security group** to every cluster VPC. Terraform doesn't know about them, so they block VPC deletion. Remove them before destroying.

```bash
destroy_prep() {   # usage: destroy_prep <kube-context> <cluster-name>
  local ctx=$1 name=$2
  kubectl --context $ctx delete nodepools --all --ignore-not-found
  echo "waiting for Karpenter nodes to terminate..."
  while [ "$(kubectl --context $ctx get nodeclaims -o name 2>/dev/null | wc -l)" -gt 0 ]; do sleep 10; done
  local vpc=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$name --query 'Vpcs[0].VpcId' --output text)
  echo "VPC $vpc"
  for ep in $(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$vpc --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    echo "deleting VPC endpoint $ep (GuardDuty-managed)"; aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ep >/dev/null
  done
}

# llm-lab
destroy_prep spoke llm-lab
cd ~/project27/eks-llm-lab-3/terraform && terraform workspace select default && terraform destroy

# llm-lab-2
aws eks update-kubeconfig --name llm-lab-2 --alias spoke2 >/dev/null 2>&1
destroy_prep spoke2 llm-lab-2
cd ~/project27/eks-llm-lab/terraform && terraform workspace select spoke2 \
  && terraform destroy -var cluster_name=llm-lab-2 -var vpc_cidr=10.1.0.0/16
```
**If a VPC destroy fails with `DependencyViolation`:** a GuardDuty security group (`GuardDutyManagedSecurityGroup-vpc-…`) or an orphaned ENI is still there. Delete it after its endpoint is gone (`aws ec2 describe-security-groups --filters Name=vpc-id,Values=<vpc> --query 'SecurityGroups[?GroupName!=\`default\`].[GroupId,GroupName]'`, then `aws ec2 delete-security-group --group-id …`) and re-run `terraform destroy`.

`llm-lab-2`'s state may be incomplete because its first apply was interrupted. If destroy reports nothing to remove for some resources, check the leftovers below.

### A4. Check that nothing is left (and still billing)
```bash
aws eks list-clusters
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value]' --output table
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,Tags[?Key==`Name`]|[0].Value]' --output table
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws route53 list-hosted-zones-by-name --dns-name platform.internal --query 'HostedZones[0].Name'
aws s3 ls | grep -E 'llm-lab|artifacts'
```
You want: no `llm-lab*` or `platform-hub` clusters, instances, VPCs, NAT gateways or load balancers. Anything left over: delete it in the console.

---

## Part B — Put v2 in your repo

```bash
cd ~/project27/eks-llm-lab
git pull
# remove the v1 layout (only after Part A is finished: v1 state folders are no longer needed)
git rm -r -q platform terraform k8s README.md PLATFORM-HUB-SPOKE.md
rm -rf platform terraform     # also removes local .terraform/ and the spoke2 workspace state (destroyed already)
# unzip the v2 bundle somewhere else, then copy its contents over the repo root:
unzip -q ~/Downloads/eks-llm-lab-v2.zip -d /tmp/v2 && cp -r /tmp/v2/eks-llm-lab/. .
git add -A
git status      # check: no .tfstate, .terraform/, tfplan or .tfvars files listed
git commit -m "Platform v2: env-promoted GitOps add-ons, AMP, per-env Terraform state"
git push
```
**Your push token needs one more permission.** v2 adds a GitHub Actions workflow (`.github/workflows/validate.yaml`), and GitHub refuses to let a token create workflow files without the **Workflows: Read and write** permission. Edit your fine-grained token, add it, and click Update. Otherwise the push fails with `refusing to allow a Personal Access Token to create or update workflow`.

**Recommended:** in the repo's **Settings → Rules → Rulesets**, add a rule for `main`: require a pull request, require the `validate` status checks, and require review from Code Owners. After that, every change follows the PR flow. (For a solo lab you can allow yourself to bypass reviews but keep the checks required.)

---

## Part C — Build it

Tools: same as before (`scripts/install-tools-amazon-linux.sh`). Terraform must be **≥ 1.10** (for S3-native locking): `terraform version`.

### C1. State bucket (once, ~1 min)
```bash
cd infra/bootstrap-state
terraform init && terraform apply
export TF_STATE_BUCKET=$(terraform output -raw state_bucket)
cd ../..
```
This one stack keeps its own state locally (it's what creates the bucket). Everything else stores state in that bucket.

### C2. Dev and staging clusters (~20 min each, can run in parallel)
Long applies are where credentials expired last time, so **refresh credentials before each apply**.
```bash
# terminal 1
cd infra/envs/dev
terraform init -backend-config="bucket=$TF_STATE_BUCKET"
terraform plan -out tfplan && terraform apply tfplan
$(terraform output -raw configure_kubectl)          # kube context "dev"

# terminal 2 (export TF_STATE_BUCKET there too)
cd infra/envs/staging
terraform init -backend-config="bucket=$TF_STATE_BUCKET"
terraform plan -out tfplan && terraform apply tfplan
$(terraform output -raw configure_kubectl)          # kube context "staging"
```
Check: `kubectl --context dev get nodes` (2 system nodes) and `kubectl --context dev -n kube-system get pods -l app.kubernetes.io/name=karpenter` (2 Running). No NodePools yet; Argo CD adds them.

### C3. Hub (~20 min)
```bash
cd infra/hub
terraform init -backend-config="bucket=$TF_STATE_BUCKET"
terraform plan -out tfplan && terraform apply tfplan
$(terraform output -raw configure_kubectl)          # kube context "hub"
cd ../..
```
The hub reads both spokes (they must exist first) and creates: the AMP workspace, the Prometheus/Grafana roles **and their Pod Identity associations on all three clusters**, the Argo CD identity chain with an Access Entry on each spoke, Argo CD itself, the three cluster secrets (labels `role`, `env`, `gpu`; annotations with the AMP URLs), and the root app.

### C4. Watch Argo CD install everything
```bash
kubectl --context hub -n argocd get applicationsets      # 13
kubectl --context hub -n argocd get applications -w
```
Expected: **26 Applications** = `platform-root` + `hub-monitoring-platform-hub` + 12 per spoke (`karpenter-nodepools`, `calico`, `istio-base`, `istiod`, `istio-gateway`, `platform-baseline`, `monitoring`, `kueue`, `kueue-config`, `agent-sandbox`, `sandbox-platform`, `vllm`) × 2. Allow 10–15 minutes. Apps that depend on others' CRDs (baseline, kueue-config, sandbox-platform, vllm) retry until those exist.

UI (from your laptop: `ssh -N -L 8080:localhost:8080 -L 3000:localhost:3000 clouddesk`):
```bash
kubectl --context hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl --context hub -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 &
```
Filter the UI by label `env=dev` or `env=staging` to see one environment at a time.

### C5. Verify each layer on a spoke
```bash
C=dev   # then repeat with C=staging
kubectl --context $C get nodepools,ec2nodeclasses                # default, gpu, sandbox
kubectl --context $C get tigerastatus                            # Calico: all AVAILABLE
kubectl --context $C -n istio-system get pods                    # istiod
kubectl --context $C -n istio-ingress get pods                   # gateway
kubectl --context $C get ns llm apps --show-labels               # istio-injection=enabled
kubectl --context $C -n llm get networkpolicy,peerauthentication
kubectl --context $C get clusterqueues                           # team-a, team-b
kubectl --context $C -n agent-sandbox-system get pods
kubectl --context $C -n sandboxes get sandboxwarmpool,pods       # 5 warm pods on dev, 2 on staging
kubectl --context $C -n llm get pods                             # dev: vllm-qwen 2/2 (vllm + istio-proxy); staging: none (replicas 0)
kubectl --context $C get nodeclaims                              # dev: a GPU node for vLLM, a sandbox node
```

### C6. Central metrics in Grafana
```bash
kubectl --context hub -n monitoring port-forward svc/kps-grafana 3000:80 >/dev/null 2>&1 &
# http://localhost:3000   admin / admin123
```
- **Connections → Data sources → Amazon Managed Prometheus → Save & test** should succeed (SigV4 through Pod Identity).
- **Explore**, query `count by (cluster, env) (up)` → three rows: `platform-hub`/hub, `llm-dev`/dev, `llm-staging`/staging.
- `sum by (cluster) (rate(vllm:generation_tokens_total[5m]))` once you send vLLM traffic in dev.
- **Dashboards → Kubernetes / Compute Resources / Cluster** → switch the **cluster** dropdown.

If a cluster is missing, check that cluster's Prometheus: `kubectl --context dev -n monitoring logs prometheus-kps-kube-prometheus-stack-prometheus-0 -c prometheus | grep -i -E "remote|error" | tail`. `403` means the Pod Identity association or IAM policy is wrong; `no such host` means the URL annotation is wrong.

---

## Part D — Practise promotion (the point of the rebuild)

### D1. App: a new vLLM image, dev → staging
```bash
git checkout -b vllm-dev-bump
# apps/vllm/envs/dev/values.yaml: image.tag: <new tag>
git commit -am "vllm: <new tag> to dev" && git push -u origin vllm-dev-bump
gh pr create --fill        # the validate workflow runs; merge when green
```
After the merge, **only `vllm-llm-dev`** goes OutOfSync → syncs → rolling update (`maxUnavailable: 0`). `vllm-llm-staging` stays Synced. Validate in dev (`scripts/load_test.py` through a port-forward), then open a PR changing `apps/vllm/envs/staging/values.yaml`: the same tag, plus `replicas: 1` to actually run it (CODEOWNERS review applies). Set staging back to `replicas: 0` afterwards to save the GPU.

Pick a real tag from the vLLM releases page. If a new tag fails to start (for example a CUDA/driver mismatch), you've just tested rollback: `git revert` the merge commit.

### D2. Platform add-on: upgrade an add-on in dev first
Edit `gitops/envs/dev/addons.yaml` and bump one version (for example `kueue` to a newer patch release, checked on its releases page), then PR → merge. Argo CD re-renders only the **dev** cluster's `kueue-llm-dev` Application at the new chart version. Staging keeps the old version until a second PR changes `gitops/envs/staging/addons.yaml`. That's an environment-by-environment add-on rollout, the same mechanism you'd use for Istio or Calico upgrades.

For **Istio** specifically, production teams go further with **revision-based upgrades** (two istiod revisions side by side, namespaces moved with revision tags). That's a good next exercise once the in-place flow is familiar.

### D3. Config difference without a version change
`gitops/charts/kueue-config/values-staging.yaml` gives staging smaller quotas, and `gitops/charts/sandbox-platform/values-staging.yaml` a smaller warm pool. Try changing the warm pool size in the chart's `values.yaml`: that's the **shared default**, so dev changes *and* so would staging, except staging overrides it in its own file. Deciding where a value belongs (shared default or per-environment file) is part of the design, and a review question in every PR.

### D4. Infrastructure: per-env Terraform
Make an infra change (for example the SQS queue from our earlier discussion) in `infra/envs/dev` first: plan, review, apply. Then the same block in `infra/envs/staging`. Each environment has its own state key, so a mistake in dev can't touch staging. In a real team, a pipeline runs `plan` on the PR and `apply` on merge through OIDC.

---

## Part E — Earlier exercises on v2

| Exercise | Where now |
|---|---|
| vLLM load test (TTFT vs throughput) | `kubectl --context dev -n llm port-forward svc/vllm-qwen 8000:8000` + `scripts/load_test.py` |
| 2-node DDP training + S3 | `kubectl --context dev -n llm create configmap train-script --from-file=training/train_ddp.py`; `export BUCKET=$(terraform -chdir=infra/envs/dev output -raw artifacts_bucket)`; `envsubst '${BUCKET}' < k8s/20-ddp-train.yaml \| kubectl --context dev apply -f -` |
| Serve the fine-tuned model | `envsubst '${BUCKET}' < k8s/30-vllm-serve-finetuned.yaml \| kubectl --context dev apply -f -` |
| Calico + Istio security layers | `k8s/61-test-clients.yaml` and the test steps in `NETWORKING-ISTIO-CALICO.md` (installation is now done by Argo CD; skip its install steps) |
| Kueue borrowing + preemption | `k8s/70-kueue-ddp-job.yaml` on `--context dev` |
| Sandbox warm vs cold | `python3 scripts/sandbox_claim_bench.py --context dev --count 5` |

Manually applied objects in `k8s/` are deliberately **not** in Git: they're runtime work (jobs, experiments), not platform state.

---

## Part F — Teardown of v2

```bash
kubectl --context hub -n argocd delete application platform-root --cascade=orphan
kubectl --context hub -n argocd delete applicationsets --all
for C in dev staging; do
  kubectl --context $C delete nodepools --all
  while [ "$(kubectl --context $C get nodeclaims -o name | wc -l)" -gt 0 ]; do sleep 10; done
done
# GuardDuty VPC endpoints: same loop as Part A3 for VPCs llm-dev, llm-staging, platform-hub
(cd infra/hub && terraform destroy)
(cd infra/envs/staging && terraform destroy)
(cd infra/envs/dev && terraform destroy)
(cd infra/bootstrap-state && terraform destroy)   # last: it holds everyone's state
```
Hub first (it reads both spokes), state bucket last.

---

### Versions (checked November 2026)
Terraform ≥ 1.10, AWS provider ~> 6.0, terraform-aws-modules/eks ~> 21.0 and vpc ~> 6.0, EKS 1.35, Karpenter 1.15.2, Argo CD chart 10.18.2 (v3.6), Calico v3.33.1, Istio 1.32.0, kube-prometheus-stack 93.4.1, Kueue 0.20.6, Agent Sandbox v1.0.12, vLLM v0.34.0. Bump them through the per-environment files, never all at once.
