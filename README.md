# RTX 600 Pro — GPU Work Management

Repository for managing driver setup, CUDA stack, NCCL tests, and operational scripts for **RTX 600 Pro** GPU cards.

> **OS:** All instructions are written and tested for **Ubuntu 24.04.4 LTS (Noble Numbat)**.

## 📁 Folder Structure

```
RTX600Pro/
├── scripts/
│   ├── setup/          # Installation and initial setup scripts
│   ├── diagnostics/    # Health checks, logging, and debug tools
│   └── sriov/          # PF/VF enablement and management scripts
├── configs/
│   ├── driver/         # Driver configuration files
│   ├── sriov/          # SR-IOV and virtualization configs
│   └── profiles/       # GPU performance and power profiles
└── docs/               # Documentation, guides, and notes
```

---

## 1️⃣ NVIDIA Driver Setup (Ubuntu 24.04.4)

### Verify GPU is detected

```bash
lspci | grep -i nvidia
ubuntu-drivers devices      # shows recommended driver
```

### Install NVIDIA Driver

```bash
sudo apt-get update
sudo apt-get install -y software-properties-common

# Option A: Auto-install recommended driver
sudo ubuntu-drivers autoinstall

# Option B: Pin a specific driver version
sudo apt-get install -y nvidia-driver-570-server
sudo reboot
```

After reboot, verify:
```bash
nvidia-smi
# Expected: driver version 570.x, CUDA Version 12.x shown in top-right
```

---

## 2️⃣ CUDA Toolkit Setup (Ubuntu 24.04.4)

### Add NVIDIA CUDA Repository

```bash
# Install CUDA keyring for Ubuntu 24.04
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
```

### Install CUDA Toolkit 12.8

```bash
sudo apt-get install -y cuda-toolkit-12-8

# Set environment variables permanently
echo 'export PATH=/usr/local/cuda-12.8/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc
```

Verify:
```bash
nvcc --version
# Expected: Cuda compilation tools, release 12.8
```

### Install cuDNN (optional)

```bash
sudo apt-get install -y cudnn9-cuda-12
```

---

## 3️⃣ Install NCCL (Ubuntu 24.04.4)

NCCL is available from the same NVIDIA repo configured above.

```bash
sudo apt-get install -y libnccl2 libnccl-dev

# Verify
dpkg -l | grep nccl
```

---

## 4️⃣ Compile and Install NCCL Tests (Ubuntu 24.04.4)

### Install Build Dependencies

```bash
sudo apt-get install -y \
    build-essential \
    git \
    openmpi-bin \
    openmpi-common \
    libopenmpi-dev
```

### Clone and Build nccl-tests

```bash
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests

# Build with MPI support (Ubuntu 24.04 MPI path)
make MPI=1 \
     MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
     CUDA_HOME=/usr/local/cuda-12.8 \
     NCCL_HOME=/usr

# Binaries land in ./build/
ls build/
```

> **Tip:** If the MPI path differs, find it with:
> ```bash
> dirname $(find /usr -name "mpi.h" 2>/dev/null | head -1)
> ```

### Quick Automated Install

```bash
# Full automated setup (driver + CUDA + NCCL + nccl-tests)
bash scripts/setup/install_cuda_stack.sh
```

---

## 5️⃣ Run Collective Tests with MPI

All test binaries are in `nccl-tests/build/`. Each binary maps to an NCCL collective operation.

### Single Node — All GPUs

```bash
cd nccl-tests

# AllReduce (most common — tests ring/tree reduce across all GPUs)
mpirun -np 4 ./build/all_reduce_perf \
    -b 8 -e 256M -f 2 -g 1

# AllGather
mpirun -np 4 ./build/all_gather_perf \
    -b 8 -e 256M -f 2 -g 1

# ReduceScatter
mpirun -np 4 ./build/reduce_scatter_perf \
    -b 8 -e 256M -f 2 -g 1

# Broadcast
mpirun -np 4 ./build/broadcast_perf \
    -b 8 -e 256M -f 2 -g 1

# AllToAll
mpirun -np 4 ./build/alltoall_perf \
    -b 8 -e 256M -f 2 -g 1
```

### Multi-Node Test

Create a hostfile:
```
# hostfile
node1 slots=4
node2 slots=4
```

```bash
mpirun -np 8 \
    --hostfile hostfile \
    --mca btl_tcp_if_include eth0 \
    -x NCCL_DEBUG=INFO \
    -x LD_LIBRARY_PATH \
    -x PATH \
    ./build/all_reduce_perf \
    -b 8 -e 4G -f 2 -g 1
```

### Key Parameters

| Flag | Description |
|------|-------------|
| `-np <N>` | Number of MPI processes (= number of GPUs) |
| `-b <size>` | Minimum message size (e.g. `8` bytes) |
| `-e <size>` | Maximum message size (e.g. `256M`, `4G`) |
| `-f 2` | Step factor (doubles each step) |
| `-g 1` | Number of GPUs per MPI process |
| `-c 1` | Enable correctness check (`-c 0` for pure perf) |
| `-w 5` | Warmup iterations |
| `-n 20` | Measured iterations |

### Useful NCCL Environment Variables

```bash
export NCCL_DEBUG=INFO              # Verbose NCCL logging
export NCCL_DEBUG_SUBSYS=ALL        # Log all subsystems
export NCCL_SOCKET_IFNAME=eth0      # Force network interface (multi-node)
export NCCL_P2P_DISABLE=1           # Disable NVLink, force PCIe (for testing)
export NCCL_IB_DISABLE=1            # Disable InfiniBand
```

### Expected Output

```
#                                                       out-of-place                       in-place
#       size         count    type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                             (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
           8             2   float     sum      -1    23.5    0.00    0.00      0     23.1    0.00    0.00      0
   268435456      67108864   float     sum      -1  5000.0   53.7  100.7       0   4980.0   53.9  101.1       0
# Out of bounds values: 0 OK
# Avg bus bandwidth    : 100.7 GB/s
```

---

## 🛠️ SR-IOV Quick Reference

```bash
# Enable 4 VFs
bash scripts/sriov/enable_vfs.sh 4

# Disable all VFs
bash scripts/sriov/disable_vfs.sh

# Run GPU health check
bash scripts/diagnostics/gpu_health.sh
```

---

## 📋 Requirements

| Component | Version |
|-----------|---------|
| **OS** | Ubuntu 24.04.4 LTS |
| NVIDIA Driver | 570+ |
| CUDA Toolkit | 12.8 |
| NCCL | 2.x |
| OpenMPI | 4.x |
| Linux Kernel | 6.8+ (HWE) |

## 🔗 Resources

- [NVIDIA CUDA Downloads](https://developer.nvidia.com/cuda-downloads)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [nccl-tests GitHub](https://github.com/NVIDIA/nccl-tests)
- [OpenMPI Documentation](https://www.open-mpi.org/doc/)
- [Ubuntu 24.04 NVIDIA Driver Guide](https://ubuntu.com/server/docs/nvidia-drivers-installation)
