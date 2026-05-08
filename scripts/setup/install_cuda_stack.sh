#!/bin/bash
# install_cuda_stack.sh
# Full automated setup for Ubuntu 24.04.4 LTS:
#   - NVIDIA Driver 570
#   - CUDA Toolkit 12.8
#   - cuDNN 9
#   - NCCL
#   - OpenMPI
#   - nccl-tests (built with MPI support)
#
# Usage:
#   bash scripts/setup/install_cuda_stack.sh
#   bash scripts/setup/install_cuda_stack.sh --skip-driver   # skip driver install
#   bash scripts/setup/install_cuda_stack.sh --skip-reboot   # skip reboot prompt

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
CUDA_VERSION="12-8"
CUDA_PATH="/usr/local/cuda-12.8"
DRIVER_VERSION="570"
NCCL_TESTS_DIR="$HOME/nccl-tests"
SKIP_DRIVER=false
SKIP_REBOOT=false

# ── Argument parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --skip-driver) SKIP_DRIVER=true ;;
        --skip-reboot) SKIP_REBOOT=true ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }
section() { echo -e "\n\e[1;34m═══ $* ═══\e[0m"; }

# ── Preflight checks ─────────────────────────────────────────────────────────
section "Preflight Checks"

if [[ "$(id -u)" -eq 0 ]]; then
    error "Do not run as root. Run as a normal user with sudo access."
fi

# Verify Ubuntu 24.04
source /etc/os-release
if [[ "$VERSION_ID" != "24.04" ]]; then
    warn "This script targets Ubuntu 24.04. Detected: $PRETTY_NAME. Proceeding anyway..."
fi

# Verify NVIDIA GPU present
if ! lspci | grep -qi nvidia; then
    error "No NVIDIA GPU detected. Aborting."
fi

info "GPU detected:"
lspci | grep -i nvidia

# ── System update ────────────────────────────────────────────────────────────
section "System Update"
sudo apt-get update -y
sudo apt-get install -y \
    software-properties-common \
    build-essential \
    git \
    wget \
    curl \
    openmpi-bin \
    openmpi-common \
    libopenmpi-dev

# ── NVIDIA Driver ────────────────────────────────────────────────────────────
if [[ "$SKIP_DRIVER" == "false" ]]; then
    section "NVIDIA Driver ${DRIVER_VERSION}"

    if command -v nvidia-smi &>/dev/null; then
        CURRENT=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        info "NVIDIA driver already installed: $CURRENT"
        warn "Skipping driver install. Pass --skip-driver to suppress this check."
    else
        sudo apt-get install -y nvidia-driver-${DRIVER_VERSION}-server

        info "Driver installed. A reboot is required before continuing."
        if [[ "$SKIP_REBOOT" == "false" ]]; then
            read -rp "Reboot now? [y/N] " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                info "Rebooting... Re-run this script after reboot to continue setup."
                sudo reboot
            else
                warn "Skipping reboot. CUDA install may fail if driver is not yet active."
            fi
        fi
    fi
else
    info "Skipping driver install (--skip-driver)."
fi

# ── CUDA Repository ──────────────────────────────────────────────────────────
section "CUDA Repository (Ubuntu 24.04)"

KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
if [[ ! -f "/etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list" ]]; then
    wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/${KEYRING_DEB}"
    sudo dpkg -i "$KEYRING_DEB"
    rm -f "$KEYRING_DEB"
    sudo apt-get update -y
    info "NVIDIA CUDA repo added."
else
    info "NVIDIA CUDA repo already configured."
fi

# ── CUDA Toolkit ─────────────────────────────────────────────────────────────
section "CUDA Toolkit ${CUDA_VERSION//-/.}"

if command -v nvcc &>/dev/null; then
    info "CUDA already installed: $(nvcc --version | grep release)"
else
    sudo apt-get install -y cuda-toolkit-${CUDA_VERSION}
    info "CUDA Toolkit installed."
fi

# Set environment variables
BASHRC="$HOME/.bashrc"
if ! grep -q "cuda-${CUDA_VERSION//-/.}" "$BASHRC"; then
    echo "" >> "$BASHRC"
    echo "# CUDA ${CUDA_VERSION//-/.}" >> "$BASHRC"
    echo "export PATH=${CUDA_PATH}/bin:\$PATH" >> "$BASHRC"
    echo "export LD_LIBRARY_PATH=${CUDA_PATH}/lib64:\$LD_LIBRARY_PATH" >> "$BASHRC"
    info "CUDA environment variables added to ~/.bashrc"
fi

export PATH="${CUDA_PATH}/bin:$PATH"
export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:$LD_LIBRARY_PATH"

nvcc --version

# ── cuDNN ────────────────────────────────────────────────────────────────────
section "cuDNN 9"
sudo apt-get install -y cudnn9-cuda-12
info "cuDNN installed."

# ── NCCL ─────────────────────────────────────────────────────────────────────
section "NCCL"
sudo apt-get install -y libnccl2 libnccl-dev
info "NCCL installed: $(dpkg -l libnccl2 | tail -1 | awk '{print $3}')"

# ── nccl-tests ───────────────────────────────────────────────────────────────
section "nccl-tests"

# Find OpenMPI headers location
MPI_HOME=$(dirname "$(find /usr -name 'mpi.h' 2>/dev/null | grep openmpi | head -1)")
if [[ -z "$MPI_HOME" ]]; then
    error "Could not find OpenMPI headers. Ensure libopenmpi-dev is installed."
fi
info "MPI_HOME: $MPI_HOME"

if [[ -d "$NCCL_TESTS_DIR" ]]; then
    warn "nccl-tests directory already exists at $NCCL_TESTS_DIR. Pulling latest..."
    git -C "$NCCL_TESTS_DIR" pull
else
    git clone https://github.com/NVIDIA/nccl-tests.git "$NCCL_TESTS_DIR"
fi

cd "$NCCL_TESTS_DIR"
make -j"$(nproc)" \
    MPI=1 \
    MPI_HOME="$MPI_HOME" \
    CUDA_HOME="${CUDA_PATH}" \
    NCCL_HOME=/usr

info "nccl-tests built. Binaries in: $NCCL_TESTS_DIR/build/"
ls "$NCCL_TESTS_DIR/build/"

# ── Summary ──────────────────────────────────────────────────────────────────
section "Setup Complete"
info "NVIDIA Driver : $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
info "CUDA          : $(nvcc --version | grep -oP 'release \K[\d.]+')"
info "NCCL          : $(dpkg -l libnccl2 | tail -1 | awk '{print $3}')"
info "MPI           : $(mpirun --version | head -1)"
info "nccl-tests    : $NCCL_TESTS_DIR/build/"

echo ""
info "Quick test — AllReduce across all GPUs:"
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "  mpirun -np ${GPU_COUNT} ${NCCL_TESTS_DIR}/build/all_reduce_perf -b 8 -e 256M -f 2 -g 1"
echo ""
info "Done! Source your shell or open a new terminal for PATH changes to take effect:"
echo "  source ~/.bashrc"
