# Interview notes: AI infrastructure on Kubernetes

Use the lab to get real numbers and failure stories, then practise answering these out loud. Frontier-lab infra interviews reward reasoning from first principles (memory, bandwidth, failure probability, cost) over tool name-dropping.

## 1. GPU memory math (be able to do this on a whiteboard)

**Inference, weights:** params × bytes/param. 8B in bf16 = 16 GB. 70B in bf16 = 140 GB, so it needs ≥2× 80 GB GPUs with tensor parallelism; in FP8 it's ~70 GB.

**Inference, KV cache per token:**
`2 (K and V) × num_layers × num_kv_heads × head_dim × bytes`
Llama-3-8B: 2 × 32 × 8 × 128 × 2 B = **128 KB/token**. A 32k-token context is about 4 GB for one sequence. Fifty concurrent 8k-token requests is about 50 GB. This is why KV cache, not weights, usually caps concurrency, and why GQA, paged attention, prefix caching and KV quantization matter.

**Training (mixed precision + Adam), per parameter:** about 16 bytes = bf16 weights 2 + bf16 grads 2 + fp32 master weights 4 + Adam m 4 + Adam v 4. Plus activations. So 7B params ≈ 112 GB before activations. That doesn't fit on one 80 GB GPU, which is why you need FSDP/ZeRO sharding.

In this lab: Qwen2.5-0.5B with pure bf16 AdamW ≈ 0.5B × 8 B ≈ 4 GB + activations (reduced by gradient checkpointing). Check `mem=` in the rank-0 logs against your estimate.

## 2. Parallelism strategies

| Strategy | What's split | Communication | When |
|---|---|---|---|
| Data parallel (DDP) | Data; full model copy per GPU | All-reduce of grads every step | Model fits on one GPU |
| FSDP / ZeRO-3 | Params, grads, optimizer state | All-gather params fwd/bwd, reduce-scatter grads | Model doesn't fit; scales well |
| Tensor parallel | Individual matmuls across GPUs | All-reduce inside every layer, very chatty | Keep within a node (NVLink) |
| Pipeline parallel | Layers into stages | Point-to-point activations; bubble overhead | Across nodes for very deep models |
| Expert parallel | MoE experts | All-to-all token routing | MoE models |
| Context/sequence parallel | Sequence dimension | Ring attention passes | Very long contexts |

Typical 3D layout: TP inside a node (NVLink ~900 GB/s on H100), PP and DP across nodes (EFA 3.2 Tbps on p5).

**Ring all-reduce cost:** each GPU sends/receives about 2 × (N−1)/N × message size. It's bandwidth-bound, so per-step time grows with model size and inverse network bandwidth, not GPU count. That's why your 2-node g6 run over TCP scales sub-linearly.

## 3. Kubernetes for AI: the questions you'll get

**"How do GPUs get exposed to pods?"** The NVIDIA device plugin advertises `nvidia.com/gpu` as an extended resource via the kubelet device-plugin gRPC API. The scheduler treats it as an integer; the container runtime (nvidia-container-toolkit) mounts device files and driver libraries. On Bottlerocket NVIDIA AMIs all three ship in the OS. Elsewhere, the NVIDIA GPU Operator installs them. Newer: DRA (Dynamic Resource Allocation) for richer claims like specific GPU models, partitions, topology.

**"Why taint GPU nodes?"** So CPU-only pods don't land on $30/hr hardware and block GPU jobs. Pods opt in with a toleration.

**"How do you schedule a 512-GPU training job?"** Gang scheduling (Kueue, Volcano, or a custom scheduler): all-or-nothing admission, otherwise partial allocations deadlock. Topology-aware placement (same spine / UltraCluster / placement group) because all-reduce speed depends on the slowest link. Quotas and fair-share across teams, preemption priorities (prod training > research > batch eval).

**"A training job hangs at step 0 / mid-run. Debug it."** Check rendezvous: DNS of the master, port reachable, all ranks started (`kubectl get pods`), NetworkPolicies, security groups. Then NCCL: `NCCL_DEBUG=INFO`, transport selected, `NCCL_SOCKET_IFNAME` picking the wrong interface, EFA device present. Then a straggler or dead rank: one hung rank blocks every collective; `NCCL_TIMEOUT` / `TORCH_NCCL_ASYNC_ERROR_HANDLING` turn hangs into errors. Then hardware: XID errors in `dmesg`, ECC errors, a GPU fallen off the bus, thermal throttling (DCGM metrics). At scale you assume some node is always broken: health checks, automatic node cordon, and checkpoint-restart.

**"How often should you checkpoint?"** Trade checkpoint cost against expected lost work. If cluster MTBF is M and a checkpoint takes C, the Young/Daly optimum interval is about √(2·C·M). With 10,000 GPUs, failures happen hourly or more often, so you want fast async/sharded checkpoints to local NVMe then to S3, and fast restart (warm pools, cached images and weights).

**"How do you autoscale LLM inference?"** Not on CPU. On queue depth (`num_requests_waiting`), KV cache utilization, or TTFT SLO burn. Scaling is slow (GPU node 1–2 min + 10 GB image + model load), so keep headroom, pre-pull images, cache weights on fast storage, and scale ahead with predictive policies. Karpenter handles nodes; KEDA/HPA handles replicas.

**"Spot for GPUs?"** Fine for stateless inference replicas behind a load balancer and for checkpointed, restartable training. Use capacity-type fallback, diversify instance types and AZs, handle the 2-minute interruption (Karpenter's SQS queue cordons and drains). Big training runs usually use reserved capacity (ODCRs / Capacity Blocks for ML).

## 4. Inference serving concepts

- **Prefill vs decode:** prefill processes the prompt in parallel (compute-bound, sets TTFT). Decode generates one token at a time per sequence (memory-bandwidth-bound, sets inter-token latency).
- **Continuous batching:** new requests join the running batch at token granularity, so the GPU stays busy. That's what your load test showed: throughput up, per-request latency up.
- **PagedAttention:** KV cache in fixed-size blocks, like virtual memory pages, which removes fragmentation so more concurrent sequences fit.
- **Prefix caching:** shared system prompts reuse KV blocks. Route requests with the same prefix to the same replica (KV-aware routing).
- **Disaggregated prefill/decode:** separate pools with different hardware profiles, KV transferred between them (llm-d, Dynamo, vLLM's disaggregation work).
- **Speculative decoding:** a small draft model proposes tokens and the big model verifies several per forward pass.
- **Quantization:** FP8 / INT4 weights cut memory and bandwidth; check the quality regression.
- **Metrics that matter:** TTFT, time per output token (TPOT), throughput (tokens/s), goodput under an SLO, cost per million tokens.

## 5. Networking and storage at scale

- **EFA** (Elastic Fabric Adapter): OS-bypass RDMA-like networking via libfabric. NCCL uses it through the aws-ofi-nccl plugin. On EKS you need the EFA device plugin, security groups allowing all traffic to self, and huge pages.
- **NVLink/NVSwitch** within a node vs **EFA/InfiniBand** across nodes: the bandwidth gap is why TP stays in-node.
- **Storage:** training data streaming (S3 with high-throughput readers, or FSx for Lustre linked to S3); checkpoints (local NVMe → async to S3); model weights for serving (S3 → node cache; avoid N replicas each pulling from Hugging Face).
- **VPC CNI IP exhaustion** with big nodes and many pods: prefix delegation, custom networking, or secondary CIDRs.

## 6. Story bank: turn your lab into STAR answers

Write these down with your actual numbers after doing the lab:
1. "I measured vLLM throughput going from X tok/s at concurrency 1 to Y at 32, with p95 TTFT going from A to B ms. Here's how I'd pick the operating point for a latency SLO."
2. "I killed a DDP rank and saw the job hang until the NCCL timeout. Here's how I'd design fault tolerance for a 1,000-GPU run."
3. "My 2-node run got Z× the throughput of 1 node over TCP. Here's the all-reduce math explaining it and what EFA would change."
4. "Cold start was N minutes, broken down into node launch / image pull / weight download / CUDA graph capture. Here's how I cut it."
5. Tie it to your day job: how you'd bring Karpenter, Kyverno, ArgoCD and IAM patterns you already run at AWS to a GPU fleet.

## 7. Questions to ask your interviewers

- How is GPU capacity shared between research and production inference, and who decides preemption?
- What's your mean time between failures at your largest training scale, and how fast is checkpoint restart?
- Is the scheduler Kubernetes-native (Kueue/Volcano), Slurm, or custom, and why?
- What's the biggest source of lost GPU-hours today: hardware failures, stragglers, scheduling fragmentation, or idle reservations?
