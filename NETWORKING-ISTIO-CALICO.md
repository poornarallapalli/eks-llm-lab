# Calico + Istio on the EKS LLM Lab

> **On platform v2, Calico and Istio are installed by Argo CD** (`calico`, `istio-base`, `istiod`, `istio-gateway` and `platform-baseline` add-ons), including the default-deny policies for `llm`, STRICT mTLS and access logging. Skip the Helm install steps and the `kubectl apply` of policies below. Use this guide for **how the layers work and the tests/drills** (test clients in `k8s/61-test-clients.yaml`, contexts `dev`/`staging`). The mesh routing manifests (Gateway, VirtualService canary, AuthorizationPolicy) from v1 are a good exercise to add to `apps/vllm/chart`.

This adds two layers of networking control to the cluster from `README.md`:

- **Calico** decides *which pods can open connections to which* (Layer 3/4: IPs, ports, namespaces). It enforces Kubernetes `NetworkPolicy` and adds its own richer policies.
- **Istio** decides *what happens on those connections* (Layer 7: HTTP). It adds mTLS with a cryptographic identity per workload, traffic routing (canaries, retries, timeouts), identity-based authorization, and per-request telemetry.

Use both and you get defense in depth. A request has to pass Calico (is this pod even allowed to reach that port?) and then Istio (is this workload identity allowed to call this HTTP method and path?).

```
 apps/llm-client ──(1) Calico: is apps → llm:8000 allowed? ──(2) Istio: mTLS + is SA llm-client allowed POST /v1/*? ──▶ vllm-qwen
                                                                    │
                          VirtualService: 90% vllm-qwen / 10% vllm-finetuned, timeout 300s, retry on connect failure
```

**How this works on EKS specifically:** EKS uses the AWS VPC CNI, which gives every pod a real VPC IP address. We keep that and install Calico in **policy-only mode**: VPC CNI still does networking and IP addresses, Calico only enforces policy. Replacing VPC CNI with Calico's own networking is possible but unusual on EKS, and the control plane can't reach overlay pod IPs, which breaks webhooks.

Versions used (checked November 2026): **Calico v3.33.1**, **Istio 1.32.0**, on EKS 1.35.

Files added to the repo:

| File | What it is |
|---|---|
| `k8s/50-calico-policies.yaml` | Default deny for `llm` plus an allow-list, and a Calico `GlobalNetworkPolicy` |
| `k8s/60-istio-mesh.yaml` | mTLS, ingress Gateway, canary VirtualService, DestinationRules, AuthorizationPolicy, access logs |
| `k8s/61-test-clients.yaml` | Three test clients that show each layer allowing or blocking traffic |
| `k8s/41-vllm-podmonitor-mesh.yaml` | Prometheus scraping that still works under strict mTLS |

---

## Step 1 — Open the webhook ports (Terraform)

Istio's sidecar injector and Calico's API server run as **admission webhooks / aggregated APIs inside pods**. The EKS control plane must be able to reach them on the nodes. The EKS module's default rules don't include these ports, so `terraform/main.tf` now adds:

- TCP **15017** from the control plane → nodes (Istio injection and validation webhooks)
- TCP **5443** from the control plane → nodes (Calico API server)

```bash
cd terraform && terraform apply && cd ..
```

**If you skip this:** `kubectl apply` of Istio resources hangs and fails with `failed calling webhook ... context deadline exceeded`, and new pods quietly start **without** sidecars. This is one of the most common real-world Istio-on-EKS problems, so it's worth remembering.

---

## Part A — Calico

### Step 2 — Install Calico (policy-only mode)

```bash
# Make sure VPC CNI's own network-policy engine is NOT also enabled (two enforcers = confusion)
kubectl -n kube-system get ds aws-node -o yaml | grep -A1 enable-network-policy   # expect "false" or nothing

helm repo add projectcalico https://docs.tigera.io/calico/charts
helm repo update

kubectl create namespace tigera-operator
helm install calico projectcalico/tigera-operator \
  --version v3.33.1 \
  --namespace tigera-operator \
  --set installation.kubernetesProvider=EKS \
  --set installation.cni.type=AmazonVPC \
  --set installation.cni.ipam.type=AmazonVPC
```

What this does: Helm installs the **Tigera operator**. The operator reads the `Installation` resource (from the values above) and deploys:
- `calico-node` DaemonSet: on every node, including the GPU nodes Karpenter launches later. It programs iptables/nftables rules for each pod's network interface.
- `calico-typha`: fans out policy updates so the Kubernetes API server isn't hammered by every node.
- `calico-kube-controllers`: syncs namespaces, service accounts, etc.
- `calico-apiserver`: serves the `projectcalico.org/v3` API so `kubectl` can manage Calico's own policy types.
- **Goldmane + Whisker**: flow-log aggregation and a web UI showing allowed and denied flows.

Verify:
```bash
kubectl get tigerastatus                       # all AVAILABLE=True (takes 1–3 min)
kubectl -n calico-system get pods -o wide      # calico-node on every node
kubectl api-resources | grep projectcalico.org # GlobalNetworkPolicy etc. available
```

### Step 3 — See the "before" state

With no policies, **every pod can reach every pod** (Kubernetes' default).
```bash
kubectl apply -f k8s/61-test-clients.yaml      # namespaces apps (mesh-labelled) and outsider
kubectl -n outsider rollout status deploy/curl
kubectl -n outsider exec deploy/curl -- curl -s -m 5 http://vllm-qwen.llm:8000/v1/models
# -> JSON listing the model. Any pod in the cluster can call your GPU server.
```
(The `apps` namespace is labelled for Istio injection, but Istio isn't installed yet, so nothing happens there.)

### Step 4 — Apply default deny plus an allow-list

```bash
kubectl apply -f k8s/50-calico-policies.yaml
kubectl -n llm get networkpolicy
kubectl get globalnetworkpolicy
```

Read `k8s/50-calico-policies.yaml` top to bottom. The pattern is the one used in production:

| Policy | Why it exists |
|---|---|
| `default-deny-all` | Selects every pod for Ingress and Egress, so anything not allowed below is dropped |
| `allow-dns` | Egress to CoreDNS on 53. Forgetting this is the #1 "everything broke" mistake |
| `allow-intra-namespace` | Pods in `llm` talk freely to each other: torchrun rendezvous (29500) and NCCL's dynamic ports |
| `allow-egress-https` | 443 to the internet for Hugging Face, pip and S3, but **not** to other VPC IPs |
| `allow-pod-identity-agent` | Egress to `169.254.170.23:80`, where EKS Pod Identity hands out AWS credentials. Without it the trainer's S3 upload fails |
| `allow-istiod` | Sidecars must reach istiod on 15012 for config and certificates (used in Part B) |
| `allow-ingress-to-vllm` | Only `istio-ingress`, `apps` and `monitoring` namespaces may connect to vLLM (8000) and sidecar metrics (15020/15090) |
| `deny-imds-llm` (Calico) | A Calico **Deny** with `order: 100`: blocks the EC2 metadata endpoint for `llm` pods, evaluated before any Kubernetes allow rule (Calico gives those order 1000) |

Now test again:
```bash
kubectl -n outsider exec deploy/curl -- curl -s -m 5 http://vllm-qwen.llm:8000/v1/models
# -> exits after 5s (timeout). Calico drops the SYN packet. Denied traffic times out; it doesn't get "refused".

kubectl -n apps exec deploy/llm-client -- curl -s -m 5 http://vllm-qwen.llm:8000/v1/models
# -> JSON. The apps namespace is on the allow-list.
```

Prove the egress rules work from inside `llm`:
```bash
kubectl -n llm exec deploy/vllm-qwen -c vllm -- python3 -c "import urllib.request;print(urllib.request.urlopen('https://huggingface.co',timeout=5).status)"   # 200
kubectl -n llm exec deploy/vllm-qwen -c vllm -- python3 -c "import urllib.request;urllib.request.urlopen('http://169.254.169.254/latest/meta-data/',timeout=5)"   # timeout: IMDS blocked
```

### Step 5 — Watch flows in Calico Whisker

```bash
kubectl -n calico-system port-forward svc/whisker 8081:8081
# open http://localhost:8081
```
Re-run the `outsider` curl and watch a **Denied** flow appear with source, destination and port, next to the **Allowed** flows from `apps`. When a policy "doesn't work", this is where you start debugging.

### Step 6 — Re-run training under default deny

```bash
kubectl -n llm delete job ddp-train --ignore-not-found
export BUCKET=$(terraform -chdir=terraform output -raw artifacts_bucket)
envsubst '${BUCKET}' < k8s/20-ddp-train.yaml | kubectl apply -f -
kubectl -n llm logs -f -l job-name=ddp-train,batch.kubernetes.io/job-completion-index=0
```
It should still work: DNS, pip/HF over 443, rank-to-rank NCCL inside the namespace, and the Pod Identity agent are all allowed. **Drill:** delete `allow-pod-identity-agent`, re-run, and watch the final S3 upload fail. Then delete `allow-intra-namespace` and watch rank 1 hang at rendezvous.

---

## Part B — Istio

### Step 7 — Install Istio (sidecar mode, with Helm)

Install the `istioctl` CLI for debugging. You'll use it for `analyze` and `proxy-status`, not for installing:
```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.32.0 sh -
export PATH="$PWD/istio-1.32.0/bin:$PATH"
istioctl version --remote=false
```

Install the control plane and an ingress gateway with Helm. Helm is the GitOps-friendly way to install, and it's what you'd put in ArgoCD:
```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 1. CRDs and cluster-wide resources
helm install istio-base istio/base -n istio-system --create-namespace --version 1.32.0 \
  --set defaultRevision=default

# 2. istiod: the control plane (config distribution via xDS, certificate authority, sidecar injector)
helm install istiod istio/istiod -n istio-system --version 1.32.0 --wait

# 3. An ingress gateway (a standalone Envoy deployment). ClusterIP so we don't create
#    an AWS load balancer for the lab; we'll port-forward to it.
kubectl create namespace istio-ingress
helm install istio-ingressgateway istio/gateway -n istio-ingress --version 1.32.0 \
  --set service.type=ClusterIP --wait
```

Verify:
```bash
kubectl -n istio-system get pods        # istiod Running
kubectl -n istio-ingress get pods       # istio-ingressgateway Running
istioctl analyze -A                     # config warnings, if any
```

### Step 8 — Put the model servers into the mesh

Sidecar injection is turned on per namespace with a label. The mutating webhook (port 15017, the one opened in step 1) adds an Envoy sidecar to every **new** pod, so existing pods need a restart:
```bash
kubectl label namespace llm istio-injection=enabled
kubectl -n llm rollout restart deploy/vllm-qwen deploy/vllm-finetuned
kubectl -n llm get pods                 # READY 2/2 = vllm + istio-proxy
```
The `apps` namespace was already labelled, so restart those clients too:
```bash
kubectl -n apps rollout restart deploy
```
(The vLLM pods re-download the model because it lives on an `emptyDir`, so give them a few minutes.)

**The training Job stays out of the mesh on purpose.** `k8s/20-ddp-train.yaml` has the annotation `sidecar.istio.io/inject: "false"`. NCCL pushes gigabytes of gradients per step over dynamic ports. Routing that through Envoy adds latency, CPU and failure modes for no benefit. Calico policy still applies to those pods. "Mesh for request/response services, not for collective communication" is a good answer to give in an interview.

Under the hood:
- An init step (`istio-init`) adds iptables rules **inside the pod's network namespace** that redirect all inbound and outbound TCP through Envoy (inbound → 15006, outbound → 15001).
- Istio 1.32 uses **Kubernetes native sidecars** (an init container with `restartPolicy: Always`) on supported clusters. The proxy starts before your app and doesn't block Jobs from completing, which was a classic sidecar problem.
- Each sidecar gets an X.509 certificate from istiod with a **SPIFFE identity**: `spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>`. That identity is what authorization uses, not the pod IP.

Check it:
```bash
istioctl proxy-status                                         # every sidecar SYNCED with istiod
istioctl proxy-config cluster deploy/vllm-qwen -n llm | head  # the upstreams this Envoy knows about
```

### Step 9 — Apply the mesh config: mTLS, routing, authorization

```bash
kubectl apply -f k8s/60-istio-mesh.yaml
```

The file has six resources:

1. **`PeerAuthentication` STRICT** in `llm`: sidecars accept only mutual-TLS connections.
2. **`Gateway`** on the ingress gateway, port 80, host `llm.example.local`.
3. **`VirtualService` `llm-api`**: bound to the gateway **and** `mesh` (internal callers of `vllm-qwen` get the same rules):
   - header `x-canary: true` → always `vllm-finetuned`
   - otherwise **90% `vllm-qwen` / 10% `vllm-finetuned`**. Both serve the model name `qwen`, so clients don't change.
   - `timeout: 300s`, because streamed LLM responses run long
   - retries only on connection failures, because retrying a slow generation doubles GPU cost
4. **`DestinationRule`s**: `LEAST_REQUEST` load balancing (LLM request lengths vary hugely, so round-robin overloads unlucky replicas) and **outlier detection** (a replica returning repeated 5xx, for example after a GPU XID error, is ejected for 60s).
5. **`AuthorizationPolicy`**: only `apps/llm-client` and the ingress gateway's identity may `GET`/`POST` `/v1/*` and `/health`.
6. **`Telemetry`**: Envoy access logs everywhere, so you can see which upstream served each request.

> The 90/10 split assumes `vllm-finetuned` is deployed (README step 6). If it isn't, 10% of requests get `503 no healthy upstream`. That's a good demonstration too; set the weights to 100/0 to fix it.

### Step 10 — See each layer in action

```bash
# Allowed: right namespace (Calico) and right identity (Istio)
kubectl -n apps exec deploy/llm-client -c curl -- \
  curl -s -w '\nHTTP %{http_code}\n' http://vllm-qwen.llm:8000/v1/models
# -> model list, HTTP 200

# Wrong identity: Calico allows the connection (apps namespace), Istio denies at L7
kubectl -n apps exec deploy/intruder -c curl -- \
  curl -s -w '\nHTTP %{http_code}\n' http://vllm-qwen.llm:8000/v1/models
# -> "RBAC: access denied", HTTP 403

# Not in the mesh and namespace not allowed: Calico drops it before Istio sees anything
kubectl -n outsider exec deploy/curl -- curl -s -m 5 -w '\nHTTP %{http_code}\n' http://vllm-qwen.llm:8000/v1/models
# -> timeout
```

**Exercise: isolate the mTLS layer.** Add `outsider` to the namespace list in `allow-ingress-to-vllm` and re-apply. Calico now lets the packet through, but the outsider pod has no sidecar and speaks plaintext, so STRICT mTLS rejects it and you get `connection reset by peer` instead of a timeout. Revert afterwards. Being able to say *"timeout means a network policy drop, reset means a TLS/mTLS rejection, 403 means L7 authorization"* shows you've actually debugged this.

### Step 11 — Call through the gateway and watch the canary

```bash
kubectl -n istio-ingress port-forward svc/istio-ingressgateway 8080:80 &

for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: llm.example.local' \
    localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"qwen","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
done

# Which backend served each request? Read the gateway's access log:
kubectl -n istio-ingress logs deploy/istio-ingressgateway | grep -o 'outbound|8000||vllm-[a-z]*' | sort | uniq -c
#   ~18 outbound|8000||vllm-qwen
#    ~2 outbound|8000||vllm-finetuned

# Force the canary with a header:
curl -s -H 'Host: llm.example.local' -H 'x-canary: true' localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"Give one GPU tip"}],"max_tokens":60}'
```

Then do a progressive rollout by editing the weights: 90/10 → 50/50 → 0/100, and `kubectl apply` each step. This is how model rollouts work behind an API: shift traffic gradually, watch error rate and latency per version, and roll back by changing a number.

### Step 12 — Metrics under strict mTLS

Prometheus isn't in the mesh, so its plaintext scrape of `:8000` is now rejected by STRICT mTLS. The fix is Istio **metrics merging**: the sidecar serves the app's own metrics (found through the `prometheus.io/*` annotations already on the vLLM pods) together with Envoy's `istio_*` metrics on `:15020/stats/prometheus`, outside mTLS.

```bash
kubectl delete -f k8s/40-vllm-podmonitor.yaml --ignore-not-found
kubectl apply -f k8s/41-vllm-podmonitor-mesh.yaml
```

Queries to try in Prometheus:
- `sum by (destination_workload, response_code) (rate(istio_requests_total{destination_workload_namespace="llm"}[1m]))`: request rate per model version and status code. This is your canary dashboard.
- `histogram_quantile(0.95, sum by (le, destination_workload) (rate(istio_request_duration_milliseconds_bucket{destination_workload_namespace="llm"}[5m])))`: p95 latency per version.
- `vllm:num_requests_waiting`: still there, merged from vLLM.

---

## Gotchas (these come up in interviews and incidents)

| Symptom | Cause | Fix |
|---|---|---|
| Istio `kubectl apply` hangs; pods start without sidecars | Control plane can't reach the webhook on 15017 | Security group rule (step 1) |
| Everything times out right after default deny | DNS egress not allowed | `allow-dns` policy |
| S3 `NoCredentialsError` under default deny | Pod Identity agent (169.254.170.23:80) blocked | `allow-pod-identity-agent` |
| Prometheus targets down after STRICT mTLS | Non-mesh scraper sending plaintext | Metrics merging on :15020, or PERMISSIVE on the metrics port only |
| Streamed LLM responses cut off | Proxy route or idle timeouts | `timeout` on the VirtualService route; for very long streams also check idle timeouts |
| NCCL slow or hanging with a sidecar | Envoy proxying collective traffic | Don't inject training pods (annotation), or exclude ports with `traffic.sidecar.istio.io/excludeOutboundPorts` |
| Policy "doesn't work" on a brand-new Karpenter GPU node | `calico-node` not ready yet when the first pod starts | Brief window at node startup; check `kubectl -n calico-system get pods -o wide` and Whisker |
| Unexpected drops with both enforcers enabled | VPC CNI network policy **and** Calico both on | Pick one. Here, Calico |
| Health probes fail after injection | Probe ports intercepted | Istio rewrites HTTP probes to the sidecar (:15021) by default; don't disable `rewriteAppHTTPProbe` |

---

## Optional — Istio ambient mode (no sidecars)

Ambient mode replaces per-pod sidecars with a per-node **ztunnel** (L4: mTLS and identity) and optional per-namespace **waypoint** proxies (L7: routing and authorization). It uses much less CPU and memory, and you don't need to restart pods to join the mesh. Try it on a **fresh cluster** or after uninstalling sidecar mode:

```bash
helm install istio-base istio/base -n istio-system --create-namespace --version 1.32.0
helm install istiod  istio/istiod  -n istio-system --version 1.32.0 --set profile=ambient --wait
helm install istio-cni istio/cni   -n istio-system --version 1.32.0 --set profile=ambient --wait
helm install ztunnel istio/ztunnel -n istio-system --version 1.32.0 --wait

kubectl label namespace llm istio.io/dataplane-mode=ambient   # no restart needed
istioctl waypoint apply -n llm --enroll-namespace             # only needed for L7 policy/routing
```

Differences to know:
- Mesh traffic between nodes is tunnelled over **HBONE on port 15008**, so your Calico ingress allow-lists must permit **15008** to the `llm` pods, not just 8000.
- L7 `AuthorizationPolicy` attaches to the **waypoint** (`targetRefs`), not to pods. L4-only policies (principals, namespaces) are enforced by ztunnel.
- For routing, Istio recommends **Gateway API `HTTPRoute`** attached to the waypoint over `VirtualService`.
- Interview angle: sidecar = strongest per-pod isolation but a proxy in every pod (resource overhead, upgrade churn). Ambient = shared node proxy for L4, opt-in L7, and big savings at fleet scale.

---

## Interview questions to practise with this setup

1. **"Walk me through a request from a client pod to vLLM."** DNS → client Envoy (outbound 15001) picks an endpoint using the VirtualService weights and DestinationRule LB → mTLS handshake with SPIFFE certificates → node routing on the VPC (Calico iptables checks the destination port and namespace) → server Envoy (15006) checks PeerAuthentication and AuthorizationPolicy → localhost:8000 vLLM.
2. **"NetworkPolicy vs AuthorizationPolicy: why both?"** L3/L4 vs L7. NetworkPolicy works without a mesh, covers non-HTTP traffic (NCCL, databases) and stops traffic before any proxy. AuthorizationPolicy uses cryptographic identity, not IPs (pod IPs are reused), and can look at methods, paths and JWT claims. A compromised sidecar-less pod is still contained by Calico.
3. **"How would you roll out a new model version safely?"** Deploy it alongside, send it shadow or header-only traffic, then weighted canary 1% → 10% → 50% → 100%, gated on per-version error rate, p95 TTFT and evaluation scores, with instant rollback by changing weights.
4. **"Would you put a service mesh on a training cluster?"** Not on the collective-communication path. Use network policy and node or security-group isolation there. A mesh is useful for the control services around training: experiment tracking, checkpoint services, inference endpoints for evals.
5. **"What does it cost?"** Sidecars add roughly tens of MB of memory and some CPU per pod, plus extra latency per hop. That matters for thousands of small pods and is negligible next to a GPU pod. Ambient mode reduces it.

## Teardown (Istio and Calico only)

```bash
kubectl delete -f k8s/60-istio-mesh.yaml -f k8s/61-test-clients.yaml --ignore-not-found
kubectl label namespace llm istio-injection-
kubectl -n llm rollout restart deploy
helm uninstall istio-ingressgateway -n istio-ingress
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl delete -f k8s/50-calico-policies.yaml --ignore-not-found
helm uninstall calico -n tigera-operator
```
If you're done with the whole lab, skip this and follow README step 10. Destroying the cluster removes everything.
