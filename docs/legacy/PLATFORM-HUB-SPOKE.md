# Hub and spoke platform: central Argo CD + central Prometheus, sandboxes and team queues on spokes

This turns the single-cluster lab into a small version of how AI labs run fleets of clusters:

- A **hub (management) cluster** runs **Argo CD** (deploys software to every cluster from Git) and the **central Prometheus + Grafana** (every cluster's metrics in one place).
- **Spoke (workload) clusters**, starting with your existing `llm-lab`, run the workloads: GPU training under **Kueue** team quotas, and a **code-execution sandbox service** (Agent Sandbox with warm pools). They're configured entirely by Argo CD; you don't `kubectl apply` platform components on spokes any more.

```
                                   ┌──────────────── Git (your GitHub repo) ────────────────┐
                                   │ platform/gitops/bootstrap/*.yaml  (ApplicationSets)    │
                                   │ platform/gitops/hub/...   platform/gitops/spokes/...   │
                                   └───────────────▲────────────────────────────────────────┘
                                                   │ pull (every ~3 min, or webhook)
 ┌──────────── HUB: platform-hub (VPC 10.100.0.0/16) ───────────┐        ┌──────────── SPOKE: llm-lab (VPC 10.0.0.0/16) ────────────┐
 │ Argo CD ─── assumes IAM role per spoke (Pod Identity) ───────┼─ EKS ─▶│ kube-prometheus-stack (6h local, remote_write ──────┐)   │
 │   ApplicationSets × cluster secrets (labels+annotations)     │  API   │ Kueue: ClusterQueues team-a / team-b (cohort)       │    │
 │ AWS LB Controller · ExternalDNS · EBS CSI                    │        │ Agent Sandbox: template + warm pool + claims        │    │
 │ Prometheus (remote-write receiver, 15d on EBS) ◀── internal NLB ◀────┼─ VPC peering ── prometheus.platform.internal:9090 ◀┘    │
 │ Grafana (multi-cluster dashboards: "cluster" dropdown)      │        │ Karpenter: gpu / default / sandbox NodePools             │
 └──────────────────────────────────────────────────────────────┘        └───────────────────────────────────────────────────────────┘
                     Route 53 private zone platform.internal (associated with both VPCs)
```

**Why the design is split this way** (you'll explain this in the interview):

| Decision | Why |
|---|---|
| Argo CD on a separate hub | One place to change, audit and roll back every cluster. A spoke failing or being rebuilt doesn't take down your deployment tooling. New clusters get everything automatically |
| ApplicationSet **cluster generator** | One definition → N clusters. Adding a cluster = adding a cluster secret; nothing else changes |
| **GitOps Bridge** (Terraform writes cluster-secret annotations) | Terraform owns AWS facts (VPC ids, IAM roles, URLs); Argo CD owns in-cluster software. No copy-pasted IDs in Git |
| Argo CD auth via IAM + EKS Access Entries | No kubeconfigs or long-lived tokens stored anywhere. Revoking access = deleting one access entry |
| Local Prometheus on spokes + `remote_write` to the hub | Spokes keep scraping and buffering (write-ahead log) if the hub or the network is down; global queries happen on the hub |
| Private DNS + internal NLB + VPC peering | Metrics never cross the internet. Spokes find the hub by a stable name, not a load balancer hostname |

Versions used (checked November 2026): Argo CD chart 10.18.2 (Argo CD v3.6), argocd-apps 2.0.8, kube-prometheus-stack 93.4.1, AWS Load Balancer Controller 3.6.3, ExternalDNS chart 1.24.0, Kueue 0.20.6 (API `kueue.x-k8s.io/v1beta2`), Agent Sandbox v1.0.12 (API `extensions.agents.x-k8s.io/v1beta1`).

**Extra cost:** the hub is about **$0.45/hr** (control plane, 3× m6i.large, NAT, one NLB, EBS). The Kueue exercise in step 8 briefly runs up to 4 GPUs.

---

## Step 0 — Prerequisites

- The spoke `llm-lab` is up (README steps 1–3): Karpenter installed and the `default` + `gpu` NodePools applied. The sandbox NodePool reuses the `default` EC2NodeClass.
- The tools from `scripts/install-tools-amazon-linux.sh`, plus `git`.
- **Your own GitHub repo** with this lab in it. Argo CD pulls from Git, so it needs a URL it can reach.

## Step 1 — Put the lab in your Git repo

From the unzipped `eks-llm-lab` folder (the repo root must contain `platform/gitops/...`):
```bash
git init -b main
git add . && git commit -m "EKS LLM lab + platform"
# create an empty repo on GitHub first (public is simplest for a lab), then:
git remote add origin https://github.com/<you>/eks-llm-lab.git
git push -u origin main
```
**Private repo?** Create a GitHub fine-grained token with read-only *Contents* access to that repo and pass it as `-var gitops_repo_token=...` in step 3. Terraform stores it as an Argo CD repository secret.

If this is a work machine or work account, check that pushing this code to your personal GitHub is allowed.

## Step 2 — Prepare the spoke

```bash
# Name the kube contexts so every command says which cluster it targets
aws eks update-kubeconfig --region us-east-1 --name llm-lab --alias spoke

# If you installed kube-prometheus-stack by hand in README step 7, remove it:
# Argo CD will install the spoke version (same release name "kps") with remote_write.
helm --kube-context spoke uninstall kps -n monitoring || true
```

## Step 3 — Build the hub (≈20 min)

```bash
cd platform/hub-terraform
terraform init
terraform plan -out tfplan -var gitops_repo_url=https://github.com/<you>/eks-llm-lab.git
terraform apply tfplan
$(terraform output -raw configure_kubectl_hub)     # adds kube context "hub"
cd ../..
```

What Terraform creates, in order:
1. **Hub VPC (10.100.0.0/16) + EKS** with 3 fixed nodes and the EBS CSI driver.
2. **VPC peering** hub ↔ every spoke, with routes in both directions, and the **private Route 53 zone** `platform.internal` attached to both VPCs.
3. **IAM roles via Pod Identity** for the LB Controller and ExternalDNS (the hub add-ons that call AWS).
4. **The Argo CD identity chain:** management role (Argo CD pods) → assumes `platform-hub-argocd-llm-lab` → which has an **EKS Access Entry** on `llm-lab` with cluster-admin.
5. **Argo CD** (Helm), with the Git repo and Kueue's OCI chart registry pre-registered.
6. **Cluster secrets:** `cluster-platform-hub` (label `role=hub`) and `cluster-llm-lab` (label `role=spoke`). Their **annotations** hold the AWS facts (region, VPC id, remote-write URL, Git path).
7. **Root Application `platform-root`**: syncs `platform/gitops/bootstrap/`. From here on, Git is the source of truth.

## Step 4 — Watch Argo CD install the platform onto both clusters

Both clusters already exist: `llm-lab` from the original lab, `platform-hub` from step 3. Argo CD creates no clusters. It runs on the hub and installs software onto the hub itself (LB controller, ExternalDNS, central Prometheus + Grafana) and onto `llm-lab` (Prometheus forwarding to the hub, Kueue, Agent Sandbox).


```bash
kubectl --context hub -n argocd get applicationsets
kubectl --context hub -n argocd get applications -w
# aws-lbc-platform-hub, external-dns-platform-hub, platform-config-platform-hub, monitoring-platform-hub,
# monitoring-llm-lab, kueue-llm-lab, kueue-config-llm-lab, agent-sandbox-llm-lab, sandbox-platform-llm-lab
```
Several apps go **Healthy** only after others: the config apps wait for CRDs from Kueue, Agent Sandbox and Prometheus, and the remote-write Service waits for the LB controller. That's what the `retry` and `SkipDryRunOnMissingResource` settings handle. Expect 5–10 minutes until everything is Synced and Healthy.

Open the UI:
```bash
eval "$(cd platform/hub-terraform && terraform output -raw argocd_admin_password_cmd)"   # eval: the output contains a pipe
kubectl --context hub -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080  user: admin
# (on a remote dev desktop: ssh -L 8080:localhost:8080 <host> from your laptop)
```
In **Settings → Clusters** both clusters should show **Successful**. If `llm-lab` shows a connection error:
- Is the access entry there? `aws eks list-access-entries --cluster-name llm-lab`
- Did the Pod Identity associations exist **before** the Argo CD pods started? If not, restart them: `kubectl --context hub -n argocd rollout restart deploy,sts`

## Step 5 — Check central monitoring end to end

**a) The remote-write endpoint exists:**
```bash
kubectl --context hub -n monitoring get svc prometheus-remote-write     # EXTERNAL-IP = internal NLB hostname
aws route53 list-resource-record-sets \
  --hosted-zone-id $(aws route53 list-hosted-zones-by-name --dns-name platform.internal --query 'HostedZones[0].Id' --output text) \
  --query "ResourceRecordSets[?contains(Name,'prometheus')]"
```

**b) The spoke can resolve and reach it over peering:**
```bash
kubectl --context spoke run netcheck --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'nslookup prometheus.platform.internal && curl -s -o /dev/null -w "%{http_code}\n" http://prometheus.platform.internal:9090/-/ready'
# expect: an address in 10.100.x.x, then 200
```

**c) The spoke Prometheus is sending data without errors:**
```bash
kubectl --context spoke -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9091:9090 &
curl -s 'localhost:9091/api/v1/query' --data-urlencode \
  'query=rate(prometheus_remote_storage_samples_total[5m])'        # > 0: samples being sent
curl -s 'localhost:9091/api/v1/query' --data-urlencode \
  'query=rate(prometheus_remote_storage_samples_failed_total[5m])' # should be 0
```

**d) Query everything from the hub:**
```bash
kubectl --context hub -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
kubectl --context hub -n monitoring port-forward svc/kps-grafana 3000:80 &
```
In Prometheus (http://localhost:9090) run:
- `count by (cluster) (up)` → one row for `platform-hub`, one for `llm-lab`
- `sum by (cluster) (kube_node_info)` → nodes per cluster
- `sum by (cluster, nodepool) (karpenter_nodes_created_total)`, if Karpenter's metrics are scraped

In Grafana (admin / admin123), open **Dashboards → Kubernetes / Compute Resources / Cluster** and switch the new **cluster** dropdown between hub and spoke.

## Step 6 — Change things the GitOps way

The rule now: **change Git, not the cluster.**

1. **Drift is reverted automatically.** Try a manual change:
   ```bash
   kubectl --context spoke -n sandboxes patch sandboxwarmpool python-runtime --type merge -p '{"spec":{"replicas":1}}'
   kubectl --context spoke -n sandboxes get sandboxwarmpool python-runtime -w
   ```
   Within seconds Argo CD sets it back to 5 (`selfHeal: true`). The Argo CD UI shows the app briefly *OutOfSync*.
2. **Change it in Git instead.** Edit `platform/gitops/spokes/sandbox-platform/sandbox-platform.yaml` and set `replicas: 10`, then `git commit` and `git push`. Argo CD polls about every 3 minutes (click **Refresh** to sync now). Every spoke gets the change.
3. **Roll back** with `git revert HEAD && git push`. That is the whole rollback procedure, and it's audited.

## Step 7 — Sandboxes: warm vs cold

```bash
kubectl --context spoke -n sandboxes get sandboxtemplates,sandboxwarmpools
kubectl --context spoke -n sandboxes get pods -o wide        # 5 warm pods on a "sandbox" NodePool node
kubectl --context spoke get nodes -l workload=sandbox         # Karpenter launched it for the pool
```
If no pods appear, check `kubectl --context spoke -n sandboxes get events`. The namespace enforces the `restricted` Pod Security Standard, so a pod spec that adds anything privileged gets rejected at admission. That's intended for untrusted code, but it's the first thing to check.

**Claim one by hand:**
```bash
cat <<EOF | kubectl --context spoke apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: demo
  namespace: sandboxes
spec:
  warmPoolRef:
    name: python-runtime
  lifecycle:
    shutdownTime: "$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)"
    shutdownPolicy: Delete
EOF
kubectl --context spoke -n sandboxes get sandboxclaim demo -o yaml | grep -A8 conditions
kubectl --context spoke -n sandboxes get sandboxwarmpool python-runtime   # pool refills back to 5
```
(On macOS use `date -u -v+30M ...`.)

**Check the isolation from inside the sandbox:**
```bash
POD=$(kubectl --context spoke -n sandboxes get pods -l app=python-sandbox -o name | head -1)
kubectl --context spoke -n sandboxes exec $POD -- python3 -c "import os;print(os.getuid())"                   # 65532, not root
kubectl --context spoke -n sandboxes exec $POD -- ls /var/run/secrets/kubernetes.io 2>&1 | head -1            # no SA token
kubectl --context spoke -n sandboxes exec $POD -- python3 -c \
  "import urllib.request;urllib.request.urlopen('http://169.254.169.254/latest/meta-data/',timeout=3)"        # times out (if Calico is installed)
kubectl --context spoke -n sandboxes exec $POD -- python3 -c \
  "import urllib.request;print(urllib.request.urlopen('https://pypi.org',timeout=5).status)"                 # 200 (443 egress allowed)
```
Managed NetworkPolicies only take effect if a policy engine is running, which is Calico from `NETWORKING-ISTIO-CALICO.md`. VPC CNI alone doesn't enforce them unless its network-policy feature is turned on.

**Benchmark warm vs cold:**
```bash
python3 platform/scripts/sandbox_claim_bench.py --context spoke --count 5    # warm: each ~1s
python3 platform/scripts/sandbox_claim_bench.py --context spoke --count 15   # 5 warm, 10 cold (pool exhausted)
```
Then set `replicas: 0` in Git, push, wait for the sync, and run `--count 5` again. Now every claim is cold: pod creation, image pull on a new node, readiness. If Karpenter has to add a node, you'll also see node launch time. Write down the three numbers you get: **warm**, **cold pod** and **cold node**. They're the core of your sandbox design story.

Find the controller's metrics (names vary by version):
```bash
kubectl --context spoke -n agent-sandbox-system port-forward svc/agent-sandbox-controller 8085:8080 &
curl -s localhost:8085/metrics | grep -i -E "claim|warm|sandbox" | grep -v "^#" | head -20
```
They're also on the hub, with `cluster="llm-lab"`, through remote_write.

## Step 8 — Multi-team training with Kueue: quota, borrowing, preemption

The setup: team-a and team-b are each **guaranteed 2 GPUs** and may **borrow 2** from each other. The GPU NodePool allows at most 4 GPUs in total.

```bash
for t in team-a team-b; do
  kubectl --context spoke -n $t create configmap train-script --from-file=training/train_ddp.py
done
kubectl --context spoke get clusterqueues
```

**1. team-a fills its quota, then borrows:**
```bash
submit() { TEAM=$1 JOB=$2 PRIORITY=$3 envsubst '${TEAM} ${JOB} ${PRIORITY}' \
  < platform/examples/kueue-ddp-job.yaml | kubectl --context spoke apply -f - ; }

submit team-a exp-1 experiment     # uses team-a's 2 GPUs
submit team-a exp-2 experiment     # borrows team-b's idle 2 GPUs
kubectl --context spoke get workloads -A -w
kubectl --context spoke get clusterqueues   # team-a: 4 GPUs in use (2 nominal + 2 borrowed)
kubectl --context spoke get nodeclaims      # Karpenter adds GPU nodes only for ADMITTED jobs
```

**2. team-b reclaims its quota:**
```bash
submit team-b prod-1 production
kubectl --context spoke get workloads -A -w
kubectl --context spoke -n team-a describe workload $(kubectl --context spoke -n team-a get workloads -o name | grep exp-2 | cut -d/ -f2) | tail -15
```
Kueue **preempts** team-a's borrowing job (`exp-2` is suspended, its pods are deleted, and it goes back into the queue) and admits `prod-1` on team-b's own quota. Before anything was admitted, no GPU sat idle and no half-scheduled job held GPUs: Kueue admits a whole job or none of it.

**3. Look at it on the hub:** Kueue exposes metrics such as `kueue_pending_workloads` and `kueue_admitted_workloads_total` if you enable its metrics. Scraping them is a good extension (`enablePrometheus` in the Kueue chart values; the metrics endpoint uses TLS, so the ServiceMonitor needs a `tlsConfig`).

**Clean up the GPUs:**
```bash
for j in team-a/exp-1 team-a/exp-2 team-b/prod-1; do
  kubectl --context spoke -n ${j%/*} delete job ${j#*/} --ignore-not-found
done
```

## Step 9 (optional) — Add a second spoke, and see that nothing else changes

```bash
cd terraform
terraform workspace new spoke2
terraform apply -var cluster_name=llm-lab-2 -var vpc_cidr=10.1.0.0/16
aws eks update-kubeconfig --region us-east-1 --name llm-lab-2 --alias spoke2
CLUSTER_NAME=llm-lab-2 envsubst '${CLUSTER_NAME}' < ../k8s/00-karpenter-nodepools.yaml | kubectl --context spoke2 apply -f -
cd ../platform/hub-terraform
terraform apply -var gitops_repo_url=https://github.com/<you>/eks-llm-lab.git \
  -var 'spoke_clusters={"llm-lab"={labels={env="dev",gpu="true"}},"llm-lab-2"={labels={env="dev",gpu="true"}}}'
```
Argo CD generates five new Applications for `llm-lab-2` and installs monitoring, Kueue and sandboxes on it, and the hub's Grafana shows a third cluster in the dropdown. **You didn't write any new YAML.** That's the point of ApplicationSets.

## Step 10 — Break/fix drills

| Break it | What you should see and be able to explain |
|---|---|
| Scale the hub Prometheus to 0 for 10 min (`kubectl --context hub -n monitoring patch prometheus kps-kube-prometheus-stack-prometheus --type merge -p '{"spec":{"replicas":0}}'`), then revert the patch | On the spoke, `prometheus_remote_storage_samples_pending` grows (WAL buffering) and then drains. The hub graphs fill the gap, within the WAL's ~2h window. Argo CD self-heal reverts your patch anyway, which is GitOps working against your drill |
| Delete the spoke access entry (`aws eks delete-access-entry --cluster-name llm-lab --principal-arn <argocd spoke role>`) | Argo CD → cluster `llm-lab` shows **Unauthorized**, apps go Unknown. Restore it with `terraform apply` |
| Push a broken YAML (typo in a kind) | Only that app goes *SyncFailed*; everything else keeps running. Fix with `git revert` |
| Remove `10.0.0.0/8` from `loadBalancerSourceRanges` in Git | The spoke's remote_write fails (`samples_failed_total` rises, timeouts). The NLB's security group now drops traffic from the spoke |
| Drain the sandbox node while the warm pool is full | Warm pods are recreated; claims during that window are slow. Discuss PDBs for warm pools and over-provisioning |
| Submit a 6-GPU job to team-a | Never admitted: it's bigger than nominal + borrowing limit. `kubectl describe workload` explains why. A quota error, not a scheduling error |

## Step 11 — Teardown (order matters)

```bash
# 1. Delete the NLB through Kubernetes first, otherwise the LB controller's NLB and security groups block VPC deletion
kubectl --context hub -n argocd delete application platform-root --cascade=orphan
kubectl --context hub -n argocd delete applicationset hub-platform-config
kubectl --context hub -n monitoring delete svc prometheus-remote-write --wait=true
# 2. Remove the hub (peering, routes, access entries, zone, cluster)
cd platform/hub-terraform && terraform destroy -var gitops_repo_url=https://github.com/<you>/eks-llm-lab.git && cd ../..
# 3. Then the spoke(s): README step 10 (delete NodePools incl. "sandbox", wait for nodeclaims=0, terraform destroy)
kubectl --context spoke delete nodepool sandbox --ignore-not-found
```
Destroy the hub **before** the spokes. Hub Terraform reads the spoke VPCs and clusters as data sources, so it fails if they're already gone.

See `SYSTEM-DESIGN-SANDBOX-PLATFORM.md` for how to present the large-scale version of this in an interview.
