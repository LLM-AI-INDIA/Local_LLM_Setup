#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 00-install-tools.sh
#
# Install kubectl and Helm on Windows (Git Bash). Skips installation if the
# tool is already present and functional.
###############################################################################

KUBECTL_VERSION="v1.31.0"
HELM_VERSION="v3.16.3"
INSTALL_DIR="${HOME}/bin"

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No colour

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

mkdir -p "${INSTALL_DIR}"

# Ensure INSTALL_DIR is on PATH for this session
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
    export PATH="${INSTALL_DIR}:${PATH}"
fi

###############################################################################
# kubectl
###############################################################################
install_kubectl() {
    if command -v kubectl &>/dev/null; then
        info "kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
        return 0
    fi

    info "Downloading kubectl ${KUBECTL_VERSION} for windows/amd64 ..."
    local url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/windows/amd64/kubectl.exe"
    curl -fSL --progress-bar -o "${INSTALL_DIR}/kubectl.exe" "${url}" \
        || fail "Failed to download kubectl"

    chmod +x "${INSTALL_DIR}/kubectl.exe"
    info "kubectl installed to ${INSTALL_DIR}/kubectl.exe"
}

###############################################################################
# Helm
###############################################################################
install_helm() {
    if command -v helm &>/dev/null; then
        info "Helm is already installed: $(helm version --short 2>/dev/null)"
        return 0
    fi

    info "Downloading Helm ${HELM_VERSION} for windows/amd64 ..."
    local zip_file
    zip_file="$(mktemp -t helm-XXXXXX.zip)"
    local url="https://get.helm.sh/helm-${HELM_VERSION}-windows-amd64.zip"

    curl -fSL --progress-bar -o "${zip_file}" "${url}" \
        || fail "Failed to download Helm"

    info "Extracting Helm ..."
    local tmp_dir
    tmp_dir="$(mktemp -d -t helm-extract-XXXXXX)"

    # Use unzip if available, otherwise try PowerShell
    if command -v unzip &>/dev/null; then
        unzip -qo "${zip_file}" -d "${tmp_dir}"
    else
        powershell.exe -NoProfile -Command \
            "Expand-Archive -Path '$(cygpath -w "${zip_file}")' -DestinationPath '$(cygpath -w "${tmp_dir}")' -Force"
    fi

    cp "${tmp_dir}/windows-amd64/helm.exe" "${INSTALL_DIR}/helm.exe"
    chmod +x "${INSTALL_DIR}/helm.exe"

    # Clean up
    rm -rf "${zip_file}" "${tmp_dir}"
    info "Helm installed to ${INSTALL_DIR}/helm.exe"
}

###############################################################################
# Main
###############################################################################
info "Install directory: ${INSTALL_DIR}"
info "Ensure ${INSTALL_DIR} is in your PATH permanently (add to ~/.bashrc)."

install_kubectl
install_helm

echo ""
info "=== Verification ==="
echo -n "kubectl: " && kubectl version --client 2>/dev/null | head -1
echo -n "helm:    " && helm version --short 2>/dev/null
echo ""
info "Tool installation complete."
