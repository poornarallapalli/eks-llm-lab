# System design: a multi-cluster platform for LLM training and code-execution sandboxes

*Interview framing:* "Design the infrastructure that lets many research teams train LLMs at the same time on shared GPUs, and hands out isolated code-execution sandboxes for RL and evals within seconds, across many Kubernetes clusters. Include deployment and monitoring."

This is the full-scale version of what `PLATFORM-HUB-SPOKE.md` builds. Each section ends with what you built in the lab, so you can say "I've run this".

---

## 1. Clarify the requirements (first 5 minutes)

Ask, then write down the numbers. Example answers to design against:

| Question | Assumption |
|---|---|
| GPU fleet size, and where? | ~20k GPUs, 3 regions, mostly reserved capacity (Capacity Blocks / ODCRs / owned), some on-demand |
| Concurrent training jobs | 50–200, from 1 GPU to 4,096 GPUs |
| Teams and priorities | ~30 teams. Tiers: flagship pre-training > production fine-tunes > research > batch evals |
| Sandboxes: what kind? | **RL/eval code execution** (the model runs code it wrote; untrusted, short-lived) and **researcher dev sandboxes** (GPU notebooks; trusted users, long-lived) |
| Sandbox rate and latency | RL peak 200 claims/s, p99 time to Ready < 2 s; dev sandbox < 60 s |
| Isolation | Untrusted code must not reach the cloud API, other tenants, the cluster API, or the internet beyond an allow-list |
| Availability | Losing one cluster or AZ must not stop other teams. A control-plane outage must not kill running jobs |
| Observability | Global view across all clusters; ~13 months of downsampled history; per-team cost reporting |

**Non-goals to state:** model-serving traffic management (separate design), data pipelines.

## 2. Back-of-envelope numbers

- **Warm pool size (Little's law):** pods needed in the pool ≈ claim rate × time to replace one. 200 claims/s × ~10 s cold start = **~2,000 warm sandboxes**, plus burst headroom (say 1.5×) = ~3,000. At 0.25 vCPU each that's about 750 vCPU of always-on capacity. The pool is a latency vs cost trade-off you size from the p99 target.
- **Sandbox nodes:** 3,000 pods ÷ ~100 pods per node ≈ **30+ nodes** just for warm capacity, before active sandboxes. Pod churn of 200/s is heavy load on the API server and etcd, so **shard sandboxes across several clusters (cells)**.
- **Metrics:** 5,000 nodes × ~1.5k series (node + kubelet + DCGM) ≈ 7.5M series, plus applications ≈ **10–20M active series**. One Prometheus handles a few million series at most, so you need a horizontally scalable backend (Mimir, Thanos, VictoriaMetrics, or a managed service).
- **Training failure rate:** at 20k GPUs with roughly 1 failure per 1,000 GPUs per day, expect ~20 failed nodes a day, so automatic detection and replacement plus checkpoint/restart is mandatory.

## 3. Architecture

```
                          ┌──────────────────────── Git (platform + team repos) ───────────────────────┐
                          └──────────────▲──────────────────────────────────────────────────────────────┘
                                         │
 ┌───────────── MANAGEMENT PLANE (per region, HA, nothing user-facing runs here) ─────────────┐
 │ Argo CD (sharded app controllers) · ApplicationSets (cluster generator) · policy (Kyverno) │
 │ Platform API (jobs, sandboxes, quotas) · MultiKueue manager (dispatch jobs to clusters)    │
 │ Observability: Mimir/Thanos (S3) ← remote_write from every cluster · Grafana · Alerting    │
 │ Logs: Loki/OpenSearch/CloudWatch ← Fluent Bit · Traces: OTel collector → Tempo/X-Ray        │
 └──────────────┬───────────────────────────────┬─────────────────────────────────────────────┘
                │ GitOps + job dispatch          │ metrics / logs (private network)
   ┌────────────▼──────────────┐   ┌─────────────▼─────────────┐   ┌───────────────────────────┐
   │ TRAINING cells (per       │   │ SANDBOX cells (CPU,       │   │ DEV-SANDBOX / INTERACTIVE │
   │ capacity block / spine)   │   │ high churn)               │   │ cells (GPU notebooks)     │
   │ Kueue (gang, topology,    │   │ Agent Sandbox controller  │   │ Sandbox CRD + TTL/idle GC │
   │ fair share, preemption)   │   │ warm pools per template   │   │ MIG / time-slicing        │
   │ JobSet / Trainer, EFA     │   │ gVisor / Kata / microVM   │   │ warm GPU nodes            │
   │ FSx Lustre, NVMe ckpts    │   │ egress proxy, no creds    │   │ SSO, per-user volumes     │
   │ DCGM health → remediation │   │ Karpenter (fast, Spot ok) │   │ Karpenter                 │
   └───────────────────────────┘   └───────────────────────────┘   └───────────────────────────┘
```

**Why cells (many clusters):** blast radius (a bad upgrade or an overloaded etcd hits one cell), Kubernetes scale limits (API server/etcd churn, roughly 5k nodes per cluster), capacity reality (a GPU reservation lives in one AZ and spine), and independent upgrades. The management plane makes many clusters look like one platform.

## 4. Deployment: GitOps at fleet scale

- **Argo CD on the management plane**, one instance per region (keeps a regional failure contained, low latency to clusters). Users don't deploy *through* it to production by hand; Git is the interface.
- **ApplicationSets with the cluster generator:** every cluster is a cluster secret with **labels** (`role=training|sandbox|dev`, `region`, `gpu-type`, `env`) and **annotations** (VPC id, IAM role ARNs, endpoints) written by Terraform. That's the **GitOps Bridge**. One ApplicationSet means "Kueue on every training cell". A new cluster is fully configured within minutes of being registered.
- **Progressive rollout:** ApplicationSet progressive syncs or per-environment branches/overlays: canary cell → 10% of cells → all. Gate each stage on SLO checks (Argo Rollouts analysis, or a pipeline step). Platform changes roll out across the fleet the same way a model rollout shifts traffic.
- **Identity:** Argo CD authenticates to each cluster with IAM role chaining + EKS Access Entries. No static kubeconfigs, revocable per cluster, auditable in CloudTrail.
- **Scaling Argo CD:** shard the application controller across clusters, scale the repo-server horizontally (manifest rendering is CPU-heavy), cache Helm/OCI charts in-region, use Git webhooks instead of polling. For thousands of clusters, consider a pull model (an agent per cluster pulling its own config, for example the Argo CD Agent project) so the hub doesn't hold thousands of open watches.
- **What goes through GitOps vs an API:** platform components and team namespaces/quotas go through Git (reviewed, slow-changing). **Jobs and sandboxes don't.** They're high-volume runtime objects created through the platform API or the Kubernetes API directly. Putting 200 sandboxes per second through Git would be wrong.

*Lab:* `platform/hub-terraform` (identity chain, cluster secrets, root app) and `platform/gitops/bootstrap/*.yaml` (ApplicationSets).

## 5. Monitoring: central, multi-cluster

- **Per cluster:** a local Prometheus (or Prometheus Agent / OTel collector) scrapes node-exporter, kubelet/cAdvisor, kube-state-metrics, **DCGM exporter** (GPU health), Kueue, Karpenter, Agent Sandbox and application metrics. It attaches `cluster=<name>` as an external label and **remote_writes** to the central store. Its WAL buffers through network or hub outages. Local alerting can stay for the most critical alerts ("this cell's API server is down" shouldn't depend on the hub).
- **Central store:** Mimir/Thanos/Cortex on object storage (S3), or a managed service such as Amazon Managed Service for Prometheus. Horizontally scalable ingest, **multi-tenant** (a tenant per cluster or team, so one noisy cell can't overload ingest), **per-tenant limits** on series and ingest rate, **downsampling** for long retention.
- **Cardinality control is the hard part:** drop or relabel labels with unbounded values (pod UIDs, request IDs, sandbox names on high-churn metrics). With 200 new sandbox pods per second, per-pod series grow very quickly, so aggregate sandbox metrics by template and pool rather than per pod.
- **Meta-monitoring:** monitor the monitoring system: remote_write lag (`highest_timestamp - queue_highest_sent_timestamp`), failed samples, ingest rejections, and a dead man's switch alert that fires when alerts stop arriving.
- **The SLOs that matter here:** sandbox claim latency p50/p99, warm pool depth vs demand, job queue wait time per priority tier, GPU **goodput** (useful training time ÷ allocated GPU-hours), time to replace a failed node, checkpoint overhead.
- **Logs and traces:** Fluent Bit → central logs (logs from nodes Karpenter terminates are otherwise lost). OTel traces for the platform API and sandbox claim path.

*Lab:* spoke `kps` with `remoteWrite` + `externalLabels`, hub Prometheus `enableRemoteWriteReceiver` on EBS, internal NLB + ExternalDNS + VPC peering, Grafana multi-cluster dashboards.

## 6. Training: many LLMs at once on shared GPUs

- **Admission with Kueue:** a ClusterQueue per team with **nominal quota**, a **cohort** so idle quota can be **borrowed**, **preemption** to reclaim it, and **WorkloadPriorityClasses** for tiers. **Gang admission:** a whole job or nothing, so no idle partial allocations and no deadlocks.
- **Across clusters: MultiKueue.** A manager cluster holds the queues and dispatches each admitted job to a worker cluster that has capacity. Users get one queue regardless of which cluster runs the job.
- **Placement:** topology-aware scheduling (Kueue TAS or a scheduler plugin) keeps a job's ranks inside one EFA/NVLink network domain. One straggler slows the whole all-reduce.
- **Jobs:** JobSet or Kubeflow Trainer (the production form of the lab's Indexed Job + headless Service). EFA devices, `/dev/shm`, no service-mesh sidecars on the NCCL path.
- **Reliability:** health checks before admission (DCGM diagnostics, NCCL all-reduce test), continuous health monitoring (XID/ECC errors, NVLink, thermals) → automatic cordon and replace. Hot spare nodes inside reservations. Sharded async checkpoints to NVMe then S3, with automatic restart from the last checkpoint. Preemptible tiers must checkpoint on SIGTERM.
- **Capacity:** reserved blocks for steady load, Karpenter for elastic and Spot capacity (evals, fine-tunes that can be interrupted), quotas sized to reservations, cost reporting per team.

*Lab:* `gitops/spokes/kueue-config` (flavor, two ClusterQueues in a cohort, priorities) and `platform/examples/kueue-ddp-job.yaml` (borrowing and preemption in action).

## 7. Sandboxes: fast and isolated

**Claim flow:**
1. An RL worker or researcher calls the **platform API**: `POST /sandboxes {template: python-3.12, ttl: 15m}`. It checks authentication and quota, picks a **sandbox cell** (least loaded, same region as the caller), and creates a `SandboxClaim`.
2. The Agent Sandbox controller **adopts a pod from the warm pool**: already scheduled, image pulled, process running, Ready. Time to Ready is about 1 s. The pool immediately starts a replacement.
3. If the pool is empty, the fallback is a cold start (pod scheduling + image pull + readiness). If the node is also full, Karpenter adds a node (plus about a minute). Alert on pool exhaustion, because that's when p99 latency jumps.
4. The caller talks to the sandbox through a **router/gateway** (stable endpoint, authentication, connection draining), never directly to the pod IP.
5. **TTL and idle cleanup** delete the claim; the controller deletes the pod. Nothing is reused between tenants.

**What makes it fast:**
- Warm pools sized with Little's law, per template, with predictive scaling ahead of RL bursts.
- **Images:** small, standard base images. Pre-pull on sandbox nodes (DaemonSet, or bake into the AMI/EBS snapshot), lazy loading (SOCI), and a regional registry cache.
- **Readiness:** probe every 1 s, not 10 s (the lab's bench shows the difference). No slow init containers.
- **Spare node capacity:** low-priority placeholder pods or a Karpenter node pool with a minimum size, so a cold start doesn't also wait for a node.
- **Snapshot/restore** (checkpointed sandbox state, microVM snapshots) for heavy environments that take minutes to set up.

**What makes it safe** (defense in depth, because the code is hostile by assumption):

| Layer | Control |
|---|---|
| Kernel | gVisor or Kata Containers / Firecracker microVMs instead of plain runc. Dedicated, tainted sandbox nodes; recycle nodes regularly (`expireAfter`) |
| Pod | Non-root, read-only rootfs, drop all capabilities, seccomp, `restricted` Pod Security, no service-account token, resource limits, ephemeral storage limits |
| Network | Default deny. No VPC, metadata, Pod Identity, cluster API or other sandboxes. Egress only via an allow-listing proxy (package mirrors), or none for offline evals |
| Identity | No cloud credentials in the sandbox. Results go back through the router, not written to S3 directly |
| Quota | ResourceQuota per tenant namespace, claim rate limits in the API, max TTL |
| Audit | Log every claim (who, template, duration), keep egress logs |

*Lab:* `gitops/spokes/sandbox-platform` (tainted Karpenter NodePool, `restricted` Pod Security, SandboxTemplate with managed NetworkPolicy, no token, non-root, read-only rootfs, 5-pod warm pool, quota, controller metrics) and `platform/scripts/sandbox_claim_bench.py` (warm vs cold numbers).

## 8. Failure modes to bring up yourself

| Failure | Impact | Mitigation |
|---|---|---|
| Management plane / Argo CD down | No deploys | Running workloads are unaffected (clusters keep their state). Argo CD HA, regional instances. Break-glass access |
| Central metrics store down | No global dashboards | Spoke WAL buffers ~2h; local alerting for critical alerts; Mimir replication across AZs |
| Sandbox claim storm drains the pool | p99 spikes to cold-start times | Claim rate limits, predictive pool scaling, spare node capacity, spread across cells |
| A cell's API server/etcd overloaded by pod churn | Claims fail in that cell | Cell sharding, API Priority and Fairness, controller QPS limits, the router fails over to other cells |
| Sandbox escape attempt | Potential host compromise | gVisor/Kata, dedicated nodes, no credentials, node recycling, runtime detection (Falco/GuardDuty) |
| Bad platform change pushed | Fleet-wide breakage | Progressive rollout by cell with SLO gates; `git revert` |
| GPU node failure mid-training | Job crash | Health checks, auto-replace, checkpoint-restart, hot spares |
| Noisy team hogs GPUs | Others starve | Kueue quotas, fair sharing, preemption by priority |

## 9. Trade-offs to state out loud

- **Warm pool size vs cost:** idle pods cost money; size from the p99 target and demand data, and scale the pool on a schedule or predictively.
- **Isolation vs speed:** microVMs are the strongest and slowest to start; gVisor sits in the middle; runc is the fastest and weakest. Choose per template (an untrusted RL environment gets gVisor or a microVM; an internal tool gets runc).
- **One big cluster vs cells:** simpler operations vs smaller blast radius and room to scale. Use cells, and make the management plane hide the difference.
- **Push GitOps (hub reaches out) vs pull (agent per cluster):** push is simpler and gives one control point; pull scales further and doesn't need network access from the hub to every cluster.
- **Self-hosted Mimir/Thanos vs managed Prometheus:** control and cost at scale vs less to operate.

## 10. A 45-minute interview flow

1. **(5 min)** Requirements and numbers (section 1–2). Ask "which kind of sandbox?" early.
2. **(10 min)** Draw the architecture (section 3) and explain why cells and a management plane.
3. **(10 min)** Go deep on the sandbox claim path: warm pools with Little's law, the isolation layers, and how the cold-start fallback works.
4. **(8 min)** Training admission: Kueue quotas, borrowing, preemption, gang + topology, MultiKueue.
5. **(7 min)** Deployment and monitoring: GitOps Bridge, ApplicationSets, progressive rollout, remote_write to a central store, cardinality, SLOs.
6. **(5 min)** Failure modes and trade-offs (sections 8–9), ending with the numbers you measured in the lab: warm vs cold claim latency, preemption behaviour, remote_write lag during a hub outage.
