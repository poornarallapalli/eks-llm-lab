"""
Minimal multi-node supervised fine-tuning with PyTorch DDP.

Launched by torchrun (see k8s/20-ddp-train.yaml), which sets RANK, WORLD_SIZE,
LOCAL_RANK, MASTER_ADDR, MASTER_PORT for each process.

Deliberately written as a plain training loop (no HF Trainer / Accelerate) so
every distributed concept is visible: process group init, DistributedSampler,
DDP gradient all-reduce, rank-0-only checkpointing, barriers.
"""

import os
import time

import torch
import torch.distributed as dist
from datasets import load_dataset
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader, DistributedSampler
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_ID = os.environ.get("MODEL_ID", "Qwen/Qwen2.5-0.5B")
DATASET = os.environ.get("DATASET", "databricks/databricks-dolly-15k")
NUM_SAMPLES = int(os.environ.get("NUM_SAMPLES", "4000"))
SEQ_LEN = int(os.environ.get("SEQ_LEN", "512"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "4"))  # per GPU
LR = float(os.environ.get("LR", "2e-5"))
MAX_STEPS = int(os.environ.get("MAX_STEPS", "200"))
OUT_DIR = os.environ.get("OUT_DIR", "/cache/output")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_PREFIX = os.environ.get("S3_PREFIX", "models/finetuned")


def log(rank, msg):
    if rank == 0:
        print(f"[rank0 {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_dataset(tok):
    ds = load_dataset(DATASET, split=f"train[:{NUM_SAMPLES}]")

    def fmt(ex):
        ctx = f"\n\n### Context:\n{ex['context']}" if ex["context"] else ""
        text = (
            f"### Instruction:\n{ex['instruction']}{ctx}\n\n"
            f"### Response:\n{ex['response']}{tok.eos_token}"
        )
        return tok(text, truncation=True, max_length=SEQ_LEN, padding="max_length")

    ds = ds.map(fmt, remove_columns=ds.column_names)
    ds.set_format("torch")
    return ds


def upload_dir_to_s3(local_dir, bucket, prefix):
    import boto3  # credentials come from EKS Pod Identity, not env vars

    s3 = boto3.client("s3")
    for root, _, files in os.walk(local_dir):
        for f in files:
            path = os.path.join(root, f)
            key = f"{prefix}/{os.path.relpath(path, local_dir)}"
            s3.upload_file(path, bucket, key)
            print(f"uploaded s3://{bucket}/{key}", flush=True)


def main():
    # 1. Join the process group. NCCL = GPU-to-GPU collectives (all-reduce of grads).
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)
    log(rank, f"world_size={world} gpu={torch.cuda.get_device_name(device)}")

    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    # 2. Each rank sees a disjoint shard of the data.
    ds = build_dataset(tok)
    sampler = DistributedSampler(ds, num_replicas=world, rank=rank, shuffle=True, seed=42)
    dl = DataLoader(ds, batch_size=BATCH_SIZE, sampler=sampler, drop_last=True, num_workers=2)

    # 3. Same model on every rank; DDP broadcasts rank 0's weights at wrap time and
    #    all-reduces gradients during backward().
    model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16).to(device)
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model = DDP(model, device_ids=[local_rank])

    opt = torch.optim.AdamW(model.parameters(), lr=LR, weight_decay=0.0)

    step, epoch = 0, 0
    model.train()
    t0 = time.time()
    tokens_seen = 0
    while step < MAX_STEPS:
        sampler.set_epoch(epoch)  # reshuffle differently each epoch
        for batch in dl:
            ids = batch["input_ids"].to(device, non_blocking=True)
            mask = batch["attention_mask"].to(device, non_blocking=True)
            labels = ids.clone()
            labels[mask == 0] = -100  # don't learn to predict padding

            loss = model(input_ids=ids, attention_mask=mask, labels=labels).loss
            loss.backward()  # <- gradient all-reduce across nodes happens here
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            opt.zero_grad(set_to_none=True)

            step += 1
            tokens_seen += int(mask.sum()) * world

            if step % 10 == 0:
                # Average the loss across ranks just for logging
                l = loss.detach().clone()
                dist.all_reduce(l, op=dist.ReduceOp.AVG)
                elapsed = time.time() - t0
                log(
                    rank,
                    f"step {step}/{MAX_STEPS} loss={l.item():.4f} "
                    f"tok/s={tokens_seen / elapsed:,.0f} "
                    f"mem={torch.cuda.max_memory_allocated(device) / 2**30:.1f}GiB",
                )
            if step >= MAX_STEPS:
                break
        epoch += 1

    # 4. Only rank 0 writes the checkpoint; everyone waits so nobody exits early.
    if rank == 0:
        os.makedirs(OUT_DIR, exist_ok=True)
        model.module.save_pretrained(OUT_DIR, safe_serialization=True)
        tok.save_pretrained(OUT_DIR)
        log(rank, f"saved to {OUT_DIR}")
        if S3_BUCKET:
            upload_dir_to_s3(OUT_DIR, S3_BUCKET, S3_PREFIX)
    dist.barrier()
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
