#!/usr/bin/env bash
# Install the EKS LLM Lab tools on Amazon Linux 2023 or Amazon Linux 2 (x86_64 or aarch64):
#   aws CLI v2, terraform, kubectl, helm v3, envsubst (gettext), python3, istioctl, plus git/unzip/jq
#
# Usage:  bash scripts/install-tools-amazon-linux.sh
# Safe to re-run: tools that are already installed are skipped or upgraded in place.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.35}"        # match your EKS version (kubectl supports +/-1 minor)
ISTIO_VERSION="${ISTIO_VERSION:-1.32.0}"

# ---- detect OS and CPU architecture -----------------------------------------------
. /etc/os-release
case "${VERSION_ID}" in
  2023*) PKG=dnf; AL=2023 ;;
  2)     PKG=yum; AL=2 ;;
  *)     echo "Unsupported OS: ${PRETTY_NAME}"; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64)  ARCH=amd64; AWS_ARCH=x86_64 ;;
  aarch64) ARCH=arm64; AWS_ARCH=aarch64 ;;
  *)       echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac
echo ">> ${PRETTY_NAME} (${ARCH})"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. base packages: envsubst (gettext), python3, git, unzip, jq, tar --------------
echo ">> base packages"
if [ "$AL" = 2023 ]; then
  # curl-minimal ships by default on AL2023 and is fine; don't swap it for full curl
  sudo dnf install -y gettext python3 python3-pip git unzip jq tar dnf-plugins-core
else
  sudo yum install -y gettext python3 python3-pip git unzip jq tar yum-utils
fi

# ---- 2. AWS CLI v2 ---------------------------------------------------------------------
# AL2023 ships AWS CLI v2. AL2 ships v1, which we replace with v2 from the official bundle.
if aws --version 2>/dev/null | grep -q 'aws-cli/2'; then
  echo ">> aws CLI v2 already present: $(aws --version)"
else
  echo ">> installing aws CLI v2"
  [ "$AL" = 2 ] && sudo yum remove -y awscli || true
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "$TMP/awscliv2.zip"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP"
  sudo "$TMP/aws/install" --update
  hash -r
fi

# ---- 3. Terraform (HashiCorp's official RPM repo) --------------------------------------
echo ">> terraform"
if [ "$AL" = 2023 ]; then
  sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo || true
  sudo dnf install -y terraform
else
  sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  sudo yum install -y terraform
fi

# ---- 4. kubectl (official binary, checksum-verified) ----------------------------------
echo ">> kubectl (${K8S_MINOR}.x)"
KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt")"
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o "$TMP/kubectl"
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256" -o "$TMP/kubectl.sha256"
echo "$(cat "$TMP/kubectl.sha256")  $TMP/kubectl" | sha256sum --check --quiet
sudo install -o root -g root -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl

# ---- 5. Helm v3 (official installer script; installs the latest 3.x release) ----------
echo ">> helm v3"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$TMP/get_helm.sh"
chmod 700 "$TMP/get_helm.sh"
HELM_INSTALL_DIR=/usr/local/bin "$TMP/get_helm.sh"

# ---- 6. istioctl (for the Calico + Istio guide) ----------------------------------------
echo ">> istioctl ${ISTIO_VERSION}"
curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-${ARCH}.tar.gz" \
  -o "$TMP/istioctl.tgz"
tar -xzf "$TMP/istioctl.tgz" -C "$TMP"
sudo install -m 0755 "$TMP/istioctl" /usr/local/bin/istioctl

# ---- 7. shell completion + short alias (optional but handy) ---------------------------
if ! grep -q 'kubectl completion bash' ~/.bashrc 2>/dev/null; then
  sudo "$PKG" install -y bash-completion >/dev/null 2>&1 || true
  cat >> ~/.bashrc <<'EOF'

# --- EKS LLM Lab ---
source <(kubectl completion bash)
source <(helm completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
complete -C "$(command -v aws_completer)" aws
EOF
fi

# ---- verify ------------------------------------------------------------------------------
echo
echo "================ installed versions ================"
aws --version
terraform -version | head -1
kubectl version --client | head -1
helm version --short
envsubst --version | head -1
python3 --version
istioctl version --remote=false
echo "===================================================="
echo "Next: run 'aws configure' (or 'aws configure sso'), then 'aws sts get-caller-identity'."
echo "Open a new shell (or 'source ~/.bashrc') for completion and the 'k' alias."
