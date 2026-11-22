# Model rollout runbook: Llama 3.1 8B Instruct (dev → staging), production pattern

Every change is a reviewed PR. No human reads a secret, copies a model by hand, or runs `kubectl apply`.

```
                       infra/shared  (would be a security / shared-services account)
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │ KMS key (rotation on) ─▶ Secrets Manager llm-lab/hf-token   value set ONCE by the owner;   │
 │                          resource policy DENIES GetSecretValue to everyone except          │
 │                          llm-*-external-secrets roles (admins included)                    │
 │ Model registry s3://llm-lab-model-registry-<acct>/models/<name>/<revision>/                │
 │   versioned · deletes denied · only llm-*-model-ingest may write · TLS only                │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ token (dev only)                    ▲ publish (dev only)          ▲ read-only (every env)
 External Secrets ─▶ Secret hf-token ─▶ ingest Job (Argo CD, from      vLLM initContainer: refuses to
 (Pod Identity)       in llm (dev)       Git model catalog, pinned SHA)  start without _COMPLETE
```

| Rule | How it's enforced |
|---|---|
| Secret values never in Git, Terraform state, CI or terminals | Terraform creates the secret **container**; the owner sets the value once; gitleaks in CI + pre-commit |
| Least privilege | Separate role per job: ESO reads `llm-lab/*` only; ingest writes the registry only; serving reads only. Staging never gets the token |
| Defence in depth | IAM allow **and** resource-policy deny **and** KMS key policy; every secret access is in CloudTrail for audit |
| Immutable, pinned artifacts | 40-char commit SHA (chart rejects branches), SHA-256 manifest, S3-verified checksums, deletes denied |
| Promote the same artifact | Staging points at the exact registry path dev validated. Nothing is copied or re-downloaded |
| Everything by PR | 5 PRs below. CODEOWNERS review on staging, shared infra and modules |

**PRs in this rollout:** ① infra → ② platform → ③ publish model → ④ deploy to dev → ⑤ promote to staging.

---

## 0. Prerequisites (one-time)

**a) Hugging Face: a service identity, not your personal account**
1. Create an organisation on huggingface.co (e.g. `<you>-ml-platform`). Companies use an org-owned service/bot account so nothing breaks when a person leaves.
2. From that identity, open **meta-llama/Llama-3.1-8B-Instruct**, read and accept the **Llama 3.1 Community License**, and wait until the page says access is granted.
3. Create a **fine-grained** token scoped as narrowly as the UI allows: read access to contents of *this repo only* (or gated repos you can access), and set an expiry if offered. Copy it; it's shown once. Don't paste it anywhere yet.

**b) Clean up the earlier lab approach, if you ran it:**
```bash
aws secretsmanager delete-secret --secret-id llm-lab/hf-token --force-delete-without-recovery 2>/dev/null   # Terraform will own it now
kubectl --context dev -n llm delete job ingest-llama-3.1-8b-instruct --ignore-not-found   # the old hand-applied Job
```

**c) Local guardrail:** `pip install pre-commit && pre-commit install` in the repo, so gitleaks runs on every commit.

---

## ① Infrastructure PR: shared security layer + IAM

What changes:
- **New `infra/shared/`:** KMS key, the `llm-lab/hf-token` secret container plus its deny policy, and the model registry bucket.
- **`infra/modules/eks-spoke`:**
  - `llm/vllm` becomes read-only on the **registry**.
  - New `llm/model-ingest` role, created only where `model_ingest_enabled = true` (dev).
  - The External Secrets role can decrypt with the KMS key only through Secrets Manager.
- **`infra/envs/dev/main.tf`:** `model_ingest_enabled = true`.
- **`infra/hub/main.tf`:** the cluster-secret annotation `model_registry`, so the account ID never goes into Git.
- **CI and ownership:**
  - `infra/shared` is added to the validate matrix.
  - A gitleaks job scans the full history.
  - `.pre-commit-config.yaml` adds the local gitleaks hook.
  - `CODEOWNERS` gets the new paths.

```bash
git checkout main && git pull && git checkout -b infra-model-platform-security
# copy from the bundle: infra/shared/, infra/modules/eks-spoke/, infra/envs/*/, infra/hub/main.tf,
#                       .github/, .pre-commit-config.yaml
git add -A && git commit -m "infra: shared secrets/KMS/model registry; least-privilege model roles"
git push -u origin infra-model-platform-security && gh pr create --fill
```
In the PR, check that **secret-scan**, **terraform** (it runs `terraform validate` on every stack) and **gitops** are green. Then merge.

**Apply in dependency order** (shared first, hub last):
```bash
git checkout main && git pull
export TF_STATE_BUCKET=<your state bucket>

# 1. shared (security account in real life)
cd infra/shared
terraform init -backend-config="bucket=$TF_STATE_BUCKET"
terraform plan -out tfplan
#   expect ~12 to add: kms key+alias, secret+policy, bucket (+versioning, ownership, public-access block, encryption, lifecycle, policy)
terraform apply tfplan && cd ../..

# 2. dev, then 3. staging (same module; dev adds the model-ingest role)
for E in dev staging; do
  (cd infra/envs/$E && terraform init -backend-config="bucket=$TF_STATE_BUCKET" -reconfigure >/dev/null \
     && terraform plan -out tfplan && terraform apply tfplan)
done
#   dev: vllm policy updated (registry), external-secrets policy updated (kms), +role/policy/association model-ingest
#   staging: same minus model-ingest

# 4. hub (adds the model_registry annotation to every Argo CD cluster secret)
(cd infra/hub && terraform plan -out tfplan && terraform apply tfplan)
```
Review every plan before applying. You want 0 to destroy (an in-place policy update is fine).

## ② Set the secret value: once, by the owner, through an audited path

The owner signs in with their own short-lived SSO/admin session (CloudTrail records who did it) and sets the value. Nobody else ever handles the token.
```bash
read -s -p "HF token: " T; echo
aws secretsmanager put-secret-value --secret-id llm-lab/hf-token --secret-string "$T"
unset T
```
**Prove the controls work** (good to screenshot for interviews):
```bash
aws secretsmanager describe-secret --secret-id llm-lab/hf-token \
  --query '{name:Name,kms:KmsKeyId,changed:LastChangedDate,tags:Tags}'      # metadata: allowed
aws secretsmanager get-secret-value --secret-id llm-lab/hf-token            # value: AccessDenied, even as admin
```
Both calls are recorded in CloudTrail (who, when, from where), which is your audit trail if you ever need it.

## ③ Platform PR: External Secrets, model catalog, chart support (no behaviour change)

What changes:
- **External Secrets add-on** (`externalSecrets: 2.15.0` in the env `addons.yaml`).
- **`secrets-config`:**
  - dev gets a `ClusterSecretStore` plus the `ExternalSecret` that creates `hf-token`;
  - staging (`values-staging.yaml`) gets **no** token.
- **New `apps/model-ingest`:** the chart and the dev catalog (empty for now), plus the `app-model-ingest` ApplicationSet.
- **vLLM chart:**
  - runs as service account `vllm`;
  - new `modelSource.path`, empty by default, so Qwen keeps loading as before;
  - `modelRegistry` is injected by Argo CD;
  - the loader init container runs as UID 1337 so it works with the Istio sidecar.
- **`scripts/gen_bootstrap.py`** plus the regenerated `gitops/bootstrap/`.

```bash
git checkout -b platform-external-secrets-model-catalog
# copy from the bundle: gitops/, apps/, scripts/gen_bootstrap.py
python3 scripts/gen_bootstrap.py && git diff --stat
git add -A && git commit -m "platform: External Secrets, model catalog/ingest, registry-backed vLLM chart"
git push -u origin platform-external-secrets-model-catalog && gh pr create --fill   # → merge
```
**Verify** (after the `platform-root` refresh):
```bash
for C in dev staging; do echo "== $C"
  kubectl --context $C -n external-secrets get pods
  kubectl --context $C get clustersecretstore aws-secrets-manager            # READY True
  kubectl --context $C -n llm get externalsecret,secret 2>/dev/null | grep -i hf-token || echo "no hf-token (expected on staging)"
done
kubectl --context dev -n llm get externalsecret hf-token                    # SecretSynced / True
kubectl --context dev -n argocd get applications | grep -E "model-ingest|vllm"   # Synced / Healthy
```
The vLLM pods restart once (new ServiceAccount) and are still Qwen.
**If `SecretSynced` fails:** run `kubectl --context dev -n llm describe externalsecret hf-token`.
- `AccessDenied … kms` → the dev apply in ① is missing.
- `AccessDenied … GetSecretValue` → the role name doesn't match `llm-*-external-secrets`.

## ④ Publish the model: catalog PR (Argo CD runs the ingest Job)

**1. Resolve the immutable revision.** Model metadata is public, so no token is needed:
```bash
curl -s https://huggingface.co/api/models/meta-llama/Llama-3.1-8B-Instruct/revision/main | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"])'
```
(If that returns an auth error, open the model's **Files and versions → History** page and copy the full 40-character commit SHA.)

**2. Add it to the catalog.** Edit `apps/model-ingest/envs/dev/values.yaml`:
```yaml
models:
  - name: llama-3.1-8b-instruct
    repo: meta-llama/Llama-3.1-8B-Instruct
    revision: <40-char SHA from step 1>
```
```bash
git checkout -b publish-llama-3.1-8b-instruct
git commit -am "models: publish meta-llama/Llama-3.1-8B-Instruct@<sha8>" && git push -u origin HEAD && gh pr create --fill
```
The PR is the approval record: who asked for which model, at which exact revision, and who approved it. The chart refuses anything that isn't a 40-character SHA. Merge.

**3. Watch Argo CD run it** (~10–15 min, on a CPU node):
```bash
kubectl --context dev -n llm get jobs -l app.kubernetes.io/name=model-ingest -w
kubectl --context dev -n llm logs -f -l app.kubernetes.io/name=model-ingest
#   meta-llama/Llama-3.1-8B-Instruct@<sha>: N files -> s3://llm-lab-model-registry-<acct>/models/llama-3.1-8b-instruct/<sha>/
#   model-00001-of-00004.safetensors  4.98 GB  sha256=…
#   PUBLISHED s3://…
```
**4. Verify the artifact and its protections:**
```bash
REG=$(terraform -chdir=infra/shared output -raw model_registry_bucket); P=models/llama-3.1-8b-instruct/<sha>
aws s3 ls s3://$REG/$P/                                     # safetensors, config, tokenizer, MANIFEST.json, _COMPLETE
aws s3 cp s3://$REG/$P/MANIFEST.json - | head -20
aws s3 rm s3://$REG/$P/config.json                          # AccessDenied: published artifacts are immutable
```
**If the Job fails:** `kubectl --context dev -n llm describe job -l app.kubernetes.io/name=model-ingest`.
- `401/403 gated` → the license isn't accepted, or the token's scope is too narrow.
- `AccessDenied PutObject` → the dev apply in ① is missing, or the role name doesn't match `llm-*-model-ingest`.

To retry, delete the failed Job; Argo CD recreates it. It's idempotent and skips the model if it's already published.

## ⑤ Deploy to dev: values PR

`apps/vllm/envs/dev/values.yaml`. Keep your image tag; this replaces the Qwen-specific lines:
```yaml
# What DEV runs. Every line here is reviewed; Argo CD applies it.
image:
  tag: v0.34.0
replicas: 1

# Llama 3.1 8B Instruct from the shared model registry (immutable, pinned, published by PR ③)
model: meta-llama/Llama-3.1-8B-Instruct            # informational
modelSource:
  path: models/llama-3.1-8b-instruct/<40-char SHA>
servedModelName: llama-3.1-8b
maxModelLen: 16384             # KV ≈ 128 KB/token (32 layers × 8 KV heads × 128 dim × 2 (K,V) × 2 B)
gpuMemoryUtilization: "0.92"
resources:
  cpu: "4"
  memory: 24Gi                 # → Karpenter picks g6.2xlarge (L4 24 GB, 32 GiB RAM)
  memoryLimit: 28Gi
  gpu: 1
extraArgs:
  - --enable-auto-tool-choice
  - --tool-call-parser=llama3_json
  - --chat-template=/vllm-workspace/examples/tool_chat_template_llama3.1_json.jinja
```
Remove `--tool-call-parser=hermes` / `--reasoning-parser=qwen3`. The registry bucket name is **not** in this file; Argo CD injects it.
```bash
git checkout -b vllm-dev-llama31
helm template t apps/vllm/chart -f apps/vllm/envs/dev/values.yaml --set modelRegistry=x | grep -E "fetch-model|--model|served|max-model|chat-template"
git commit -am "vllm(dev): Llama 3.1 8B Instruct @ <sha8>" && git push -u origin HEAD && gh pr create --fill   # → merge
```
**Watch:**
```bash
kubectl --context dev get nodeclaims -w                                  # g6.2xlarge
kubectl --context dev -n llm get pods -l app=vllm-qwen -w                # Init:0/1 → PodInitializing → 2/2 Running
kubectl --context dev -n llm logs -f deploy/vllm-qwen -c fetch-model
kubectl --context dev -n llm logs -f deploy/vllm-qwen -c vllm | grep -iE "loading|KV cache|concurrency|Uvicorn"
```
Rolling update with `maxUnavailable: 0`: Qwen serves until Llama is Ready.
**Release gate:** all of these must pass before you open the staging PR:
- [ ] `/v1/models` lists `llama-3.1-8b`.
- [ ] Open WebUI (dev): new chat with **llama-3.1-8b**; a few real prompts and one tool-calling prompt.
- [ ] Load test:
  ```bash
  python3 scripts/load_test.py --url http://localhost:8000/v1/chat/completions --model llama-3.1-8b --concurrency 8 --requests 32
  ```
  Record TTFT p50/p95 and tokens/s in the PR.
- [ ] Grafana: no error-rate increase; KV-cache usage under load; note cold-start time (pod created → Ready).

## ⑥ Promote to staging: values PR only

Nothing is copied: staging reads the **same immutable registry path** that dev validated.
```bash
git checkout main && git pull && git checkout -b vllm-staging-llama31
# apps/vllm/envs/staging/values.yaml: the same model block as dev (same modelSource.path), staging's replicas
#   (staging = on-demand GPUs, max 2; keep pdb.enabled: true)
git commit -am "vllm(staging): promote Llama 3.1 8B @ <sha8> (dev validation: <PR link + numbers>)"
git push -u origin HEAD && gh pr create --fill
```
CODEOWNERS approval is required. Staging rolls one pod at a time with a PDB, so there's no downtime. Repeat the release gate on staging.

## ⑦ Rollback

`git revert <merge commit of ⑤ or ⑥>` → PR → merge. The previous model's artifact is still in the registry, because nothing can delete it, so rollback is just a values change.

## ⑧ Operating it

**Rotate the Hugging Face token** (every 90 days, on leaver events, or immediately on suspected exposure):
1. Create a new token for the service identity.
2. Owner runs `put-secret-value` (same as ②).
3. Force External Secrets to pick it up:
   ```bash
   kubectl --context dev -n llm annotate externalsecret hf-token force-sync=$(date +%s) --overwrite
   ```
4. Revoke the old token on Hugging Face.

No deploys and no Git changes are involved. Serving is unaffected because it never used the token.

**Leak response:** revoke on Hugging Face first, then rotate as above. Check CloudTrail `GetSecretValue` events for the secret (Event history) to see which principals read it.

**Cost:** set `replicas: 0` (PR) when idle and Karpenter removes the GPU nodes. Old registry objects are kept for rollback. To tear down the registry in this lab, apply `infra/shared` with `-var allow_force_destroy=true`, then destroy.

---

## Where this still differs from a large lab's production

| Here | At scale |
|---|---|
| One account, separate stacks | Separate AWS accounts: security (KMS, secrets), shared services (registry), and one per environment. Cross-account resource policies; SCPs enforce the denies org-wide |
| `python:3.12-slim` + pinned `pip install` at runtime; `aws-cli:latest` loader | Prebuilt, scanned images in your own ECR, pinned **by digest**, signed and verified at admission (Kyverno/cosign) |
| Ingest = Argo CD Job from a catalog PR | A model-release pipeline: ingest → licence/safety review → **automated eval suite** (quality, safety, latency) → publish → promote with eval results attached |
| Replace the model in place | Run old and new side by side; **canary** traffic with Istio (90/10 → 50/50 → 100) gated on error rate, latency and eval scores |
| Initcontainer `aws s3 sync` (~16 GB) | Streaming/parallel loaders, node-local or FSx caches, pre-warmed nodes for fast scale-out |
| Hugging Face token in Secrets Manager | The same, or no third-party token at all: a mirrored internal model hub |

## Interview summary

*"Model releases go through the same change control as code. Secrets: Terraform owns the container, KMS key and a resource policy that denies reading the value to everyone except the sync role; the owner sets the value once through an audited session, and CloudTrail keeps the audit trail. Gitleaks in CI and pre-commit keeps credentials out of Git. A model is published by a catalog PR pinned to a commit SHA; Argo CD runs an idempotent ingest job, the only workload with the token, which writes to an immutable, versioned registry with a SHA-256 manifest and a completion marker. Serving pods have read-only access, never the token, and won't start on an incomplete artifact. Dev and staging point at the same registry path, so promotion is a reviewed values PR and rollback is a git revert."*
