"""
Measure how fast sandboxes are handed out: create N SandboxClaims at once and time
each one until its Ready condition is True. Run it with the warm pool at 5, then at 0,
and compare (warm adoption vs cold pod start vs cold node start).

  python3 scripts/sandbox_claim_bench.py --context dev --count 5
  kubectl --context dev -n sandboxes patch sandboxwarmpool python-runtime \
      --type merge -p '{"spec":{"replicas":0}}'     # (or change it in Git: that's the GitOps way)
  python3 scripts/sandbox_claim_bench.py --context dev --count 5

Uses only kubectl + the Python standard library.
"""

import argparse
import datetime as dt
import json
import statistics
import subprocess
import time
import uuid


def kubectl(ctx, *args, stdin=None):
    cmd = ["kubectl", "--context", ctx, *args]
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=True).stdout


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--context", default="dev")
    p.add_argument("--namespace", default="sandboxes")
    p.add_argument("--warm-pool", default="python-runtime")
    p.add_argument("--count", type=int, default=5)
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--keep", action="store_true", help="don't delete the claims afterwards")
    a = p.parse_args()

    run_id = uuid.uuid4().hex[:6]
    expires = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    names = [f"bench-{run_id}-{i}" for i in range(a.count)]
    docs = []
    for n in names:
        docs.append({
            "apiVersion": "extensions.agents.x-k8s.io/v1beta1",
            "kind": "SandboxClaim",
            "metadata": {"name": n, "namespace": a.namespace, "labels": {"bench": run_id}},
            "spec": {
                "warmPoolRef": {"name": a.warm_pool},
                # every claim has a hard expiry: idle sandboxes must never leak
                "lifecycle": {"shutdownTime": expires, "shutdownPolicy": "Delete"},
            },
        })
    manifest = json.dumps({"apiVersion": "v1", "kind": "List", "items": docs})

    t0 = time.monotonic()
    kubectl(a.context, "create", "-f", "-", stdin=manifest)
    ready_at = {}

    while len(ready_at) < len(names) and time.monotonic() - t0 < a.timeout:
        out = kubectl(a.context, "-n", a.namespace, "get", "sandboxclaims", "-l", f"bench={run_id}", "-o", "json")
        for item in json.loads(out)["items"]:
            name = item["metadata"]["name"]
            if name in ready_at:
                continue
            for c in item.get("status", {}).get("conditions", []):
                if c.get("type") == "Ready" and c.get("status") == "True":
                    ready_at[name] = time.monotonic() - t0
        time.sleep(0.2)

    lat = sorted(ready_at.values())
    print(f"claims={a.count} ready={len(lat)} (kubectl polling adds ~0.2-0.5s to each number)")
    for n in names:
        v = ready_at.get(n)
        print(f"  {n}: {'%.2fs' % v if v is not None else 'NOT READY'}")
    if lat:
        print(f"p50={statistics.median(lat):.2f}s  max={lat[-1]:.2f}s")

    if not a.keep:
        kubectl(a.context, "-n", a.namespace, "delete", "sandboxclaims", "-l", f"bench={run_id}", "--wait=false")


if __name__ == "__main__":
    main()
