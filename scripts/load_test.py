"""
Tiny concurrent load generator for an OpenAI-compatible endpoint (vLLM).
Stdlib only. Measures TTFT (time to first token) and output tokens/sec.

  kubectl -n llm port-forward svc/vllm-qwen 8000:8000 &
  python3 scripts/load_test.py --concurrency 16 --requests 64
"""

import argparse
import json
import statistics
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def one_request(url, model, max_tokens):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "Explain Kubernetes to a 10 year old in detail."}],
        "max_tokens": max_tokens,
        "stream": True,
    }).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    start = time.time()
    ttft = None
    chunks = 0
    with urllib.request.urlopen(req, timeout=300) as resp:
        for line in resp:
            line = line.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            delta = json.loads(line[5:])["choices"][0]["delta"].get("content")
            if delta:
                if ttft is None:
                    ttft = time.time() - start
                chunks += 1
    total = time.time() - start
    return ttft or total, chunks, total


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
    p.add_argument("--model", default="qwen")
    p.add_argument("--concurrency", type=int, default=8)
    p.add_argument("--requests", type=int, default=32)
    p.add_argument("--max-tokens", type=int, default=256)
    a = p.parse_args()

    t0 = time.time()
    with ThreadPoolExecutor(a.concurrency) as ex:
        results = list(ex.map(lambda _: one_request(a.url, a.model, a.max_tokens), range(a.requests)))
    wall = time.time() - t0

    ttfts = sorted(r[0] for r in results)
    toks = sum(r[1] for r in results)
    p50 = statistics.median(ttfts)
    p95 = ttfts[min(len(ttfts) - 1, int(0.95 * len(ttfts)))]
    print(f"requests={a.requests} concurrency={a.concurrency} wall={wall:.1f}s")
    print(f"TTFT p50={p50 * 1000:.0f}ms p95={p95 * 1000:.0f}ms")
    print(f"aggregate output throughput ~ {toks / wall:,.0f} tokens/s (stream chunks ~ tokens)")


if __name__ == "__main__":
    main()
