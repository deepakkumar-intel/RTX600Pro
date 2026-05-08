# RTX 600 Pro — GPU Work Management

Repository for managing driver setup, CUDA stack, NCCL tests, and operational scripts for **RTX 600 Pro** GPU cards.

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

## 1️⃣ NVIDIA CUDA Stack Setup

### Prerequisites

```bash
# Verify GPU is detected
lspci | grep -i nvidia

# Check OS version
cat /etc/os-release
```

### Install NVIDIA Driver

```bash
# Ubuntu — using the official NVIDIA repo
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:graphics-drivers/ppa
sudo apt-get update

# Install latest recommended driver (check nvidia-smi output for correct version)
sudo apt-get install -y nvidia-driver-570
sudo reboot
```

After reboot:
```bash
nvidia-smi   # should show driver version, CUDA version, and GPU info
```

### Install CUDA Toolkit

```bash
# Download CUDA keyring (adjust version as needed — example: CUDA 12.8)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update

# Install CUDA toolkit
sudo apt-get install -y cuda-toolkit-12-8

# Set environment variables
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc

# Verify
nvcc --version
```

### Install cuDNN (optional but recommended)

```bash
sudo apt-get install -y cudnn9-cuda-12
```

---

## 2️⃣ Install NCCL

```bash
# Install NCCL libraries from NVIDIA repo (already configured above)
sudo apt-get install -y libnccl2 libnccl-dev

# Verify
dpkg -l | grep nccl
```

---

## 3️⃣ Compile and Install NCCL Tests

### Install Build Dependencies

```bash
sudo apt-get install -y build-essential git openmpi-bin openmpi-common libopenmpi-dev
```

### Clone and Build nccl-tests

```bash
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests

# Build with MPI support
make MPI=1 \
     MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
     CUDA_HOME=/usr/local/cuda \
     NCCL_HOME=/usr

# Binaries are placed in ./build/
ls build/
```

> **Tip:** If NCCL or MPI are installed in non-default paths, adjust `NCCL_HOME` and `MPI_HOME` accordingly:
> ```bash
> # Find paths if needed
> find /usr -name "libnccl.so*" 2>/dev/null
> which mpirun
> ```

---

## 4️⃣ Run Collective Tests with MPI

All test binaries are in `nccl-tests/build/`. Run them with `mpirun` for multi-GPU or multi-node tests.

### Single Node — All GPUs

```bash
cd nccl-tests

# AllReduce — most common collective (adjust -np to number of GPUs)
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
```

### Key Parameters

| Flag | Description |
|------|-------------|
| `-np <N>` | Number of MPI processes (= number of GPUs) |
| `-b <size>` | Minimum message size (e.g. `8` bytes) |
| `-e <size>` | Maximum message size (e.g. `256M`) |
| `-f 2` | Step factor (doubles each step) |
| `-g 1` | Number of GPUs per MPI process |
| `-c 1` | Check correctness (disable with `-c 0` for perf) |
| `-w 5` | Number of warmup iterations |
| `-n 20` | Number of measured iterations |

### Multi-Node Test

Create a hostfile listing each node and GPU count:

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
    ./build/all_reduce_perf \
    -b 8 -e 4G -f 2 -g 1
```

### Useful NCCL Environment Variables

```bash
# Enable debug logging
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=ALL

# Force specific network interface (for multi-node)
export NCCL_SOCKET_IFNAME=eth0

# Disable NVLink (force PCIe) — for testing
export NCCL_P2P_DISABLE=1
```

### Expected Output

```
# nccl-tests output columns:
#                                                       out-of-place                       in-place
#       size         count    type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                             (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
         8             2   float     sum      -1    23.5    0.00    0.00      0     23.1    0.00    0.00      0
     ...
 268435456      67108864   float     sum      -1   5000.0   53.7   100.7      0   4980.0   53.9   101.1      0
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

| Component | Minimum Version |
|-----------|----------------|
| NVIDIA Driver | 570+ |
| CUDA Toolkit | 12.x |
| NCCL | 2.x |
| OpenMPI | 4.x |
| Linux Kernel | 6.8+ |

## 🔗 Resources

- [NVIDIA CUDA Downloads](https://developer.nvidia.com/cuda-downloads)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [nccl-tests GitHub](https://github.com/NVIDIA/nccl-tests)
- [OpenMPI Documentation](https://www.open-mpi.org/doc/)
