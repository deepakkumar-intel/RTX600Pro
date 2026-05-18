# RTX 600 Pro — GPU Work Management

Repository for managing driver setup, CUDA stack, NCCL tests, and operational scripts for **RTX 600 Pro** GPU cards.

> **OS:** All instructions are written and tested for **Ubuntu 24.04.1 LTS (Noble Numbat)**.

> ⚠️ **Blackwell Architecture Notice:** RTX 600 Pro uses the NVIDIA Blackwell architecture (PCI ID `10de:2bb5`). Blackwell GPUs **require** the open kernel module variant of the driver. Installing the standard proprietary driver results in `RmInitAdapter failed (0x22:0x56:1017)` on every GPU and `nvidia-smi` will not detect any devices.

---

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

## 1️⃣ NVIDIA Driver Setup (Ubuntu 24.04.1)

### Verify GPU is detected

```bash
lspci | grep -i nvidia
# Expected output (8x RTX 600 Pro):
# 0000:18:00.0 3D controller: NVIDIA Corporation Device 2bb5 (rev a1)
# 0000:67:00.0 3D controller: NVIDIA Corporation Device 2bb5 (rev a1)
# ...
```

### Add NVIDIA CUDA Repository

Required to access the open kernel module packages:

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
```

### Install the Open Kernel Module Driver

> **Critical:** Install the `-server-open` variant. The standard `nvidia-driver-*-server` package installs the proprietary closed-source kernel module which does **not** support Blackwell GPUs.

```bash
# Install kernel headers first (required for DKMS to build the module)
sudo apt-get install -y linux-headers-$(uname -r)

# Install open kernel module driver
sudo apt-get install -y nvidia-driver-595-server-open

# Verify DKMS compiled the module (must show 'installed', not just 'added')
dkms status | grep nvidia
# Expected: nvidia/595.58.03, 6.8.0-xxx-generic, x86_64: installed
```

> **If DKMS shows `added` but not `installed`** (happens when headers were missing at install time):
> ```bash
> sudo dkms install nvidia/595.58.03 -k $(uname -r)
> dkms status | grep nvidia   # confirm 'installed'
> ```

```bash
sudo reboot
```

After reboot, verify:

```bash
nvidia-smi
# Expected: all 8 GPUs listed with driver 595.58.03

lsmod | grep nvidia
# Expected: nvidia, nvidia_modeset, nvidia_uvm modules loaded
```

---

## 2️⃣ CUDA Toolkit Setup (Ubuntu 24.04.1)

Using the NVIDIA CUDA repo configured in Step 1:

```bash
sudo apt-get install -y cuda-toolkit-13-2

# Set environment variables
echo 'export PATH=/usr/local/cuda-13.2/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-13.2/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
nvcc --version
# Expected: Cuda compilation tools, release 13.2
```

### Install cuDNN (optional)

```bash
sudo apt-get install -y cudnn9-cuda-13
```

---

## 3️⃣ Install NCCL (Ubuntu 24.04.1)

```bash
sudo apt-get install -y libnccl2 libnccl-dev

# Verify
dpkg -l | grep nccl
# Expected: libnccl2 and libnccl-dev, version 2.x+cuda13.2
```

---

## 4️⃣ Configure OFED MPI Environment

> **Important:** OFED installs its own OpenMPI at `/usr/mpi/gcc/openmpi-4.1.9a1/`. Ubuntu's system OpenMPI (`openmpi-bin`) conflicts with OFED's libraries and will crash (see Troubleshooting). Always use OFED's MPI for NCCL tests.

```bash
export MPI_HOME=/usr/mpi/gcc/openmpi-4.1.9a1
export LD_LIBRARY_PATH=$MPI_HOME/lib:/usr/local/cuda-13.2/lib64
export PATH=$MPI_HOME/bin:$PATH

# Add to ~/.bashrc for persistence
echo "export MPI_HOME=/usr/mpi/gcc/openmpi-4.1.9a1" >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=$MPI_HOME/lib:/usr/local/cuda-13.2/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
echo 'export PATH=$MPI_HOME/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Verify
mpirun --version
# Expected: mpirun (Open MPI) 4.1.9a1
```

---

## 5️⃣ Compile and Install NCCL Tests

### Install Build Dependencies

```bash
sudo apt-get install -y build-essential git
```

### Clone and Build nccl-tests

```bash
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests

# Build using OFED MPI + CUDA 13.2
make MPI=1 \
     MPI_HOME=$MPI_HOME \
     CUDA_HOME=/usr/local/cuda-13.2 \
     NCCL_HOME=/usr

# Verify binaries
ls build/
```

---

## 6️⃣ Run Collective Tests with MPI

All test binaries are in `nccl-tests/build/`.

### Single Node — All 8 GPUs

```bash
cd nccl-tests

# AllReduce across all 8 GPUs
mpirun --allow-run-as-root -np 8 ./build/all_reduce_perf \
    -b 1024 -e 256M -f 2 -g 1

# AllGather
mpirun --allow-run-as-root -np 8 ./build/all_gather_perf \
    -b 1024 -e 256M -f 2 -g 1

# ReduceScatter
mpirun --allow-run-as-root -np 8 ./build/reduce_scatter_perf \
    -b 1024 -e 256M -f 2 -g 1
```

### Multi-Node Test

Create a hostfile:
```
node1 slots=8
node2 slots=8
```

```bash
mpirun --allow-run-as-root -np 16 \
    --hostfile hostfile \
    --mca btl_tcp_if_include eth0 \
    -x NCCL_DEBUG=WARN \
    -x LD_LIBRARY_PATH \
    -x PATH \
    ./build/all_reduce_perf \
    -b 1024 -e 4G -f 2 -g 1
```

### Key Parameters

| Flag | Description |
|------|-------------|
| `-np <N>` | Number of MPI processes (= number of GPUs) |
| `-b <size>` | Minimum message size (e.g. `1024` bytes) |
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
export NCCL_P2P_DISABLE=1           # Disable NVLink/NVSwitch, force PCIe
export NCCL_IB_DISABLE=1            # Disable InfiniBand
```

### Expected Output

```
#                                                       out-of-place                       in-place
#       size         count    type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                             (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
        1024           256   float     sum      -1    45.2    0.02    0.04      0     44.8    0.02    0.04      0
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
| **OS** | Ubuntu 24.04.1 LTS |
| NVIDIA Driver | 595-server-**open** (open kernel module — required for Blackwell) |
| CUDA Toolkit | 13.2 |
| NCCL | 2.30.4+cuda13.2 |
| OpenMPI | 4.1.9a1 (OFED — **not** system `openmpi-bin`) |
| Linux Kernel | 6.8+ (HWE) |

---

## 🔧 Troubleshooting

### `nvidia-smi` reports no devices / `Failed to allocate NvKmsKapiDevice`

**Symptom:** After driver install and reboot, `nvidia-smi` returns no devices. `dmesg` shows:

```
[nvidia-drm] [GPU ID 0x00001800] Failed to allocate NvKmsKapiDevice
NVRM: The NVIDIA GPU ... requires use of the NVIDIA open kernel modules
RmInitAdapter failed! (0x22:0x56:1017)
```

**Root cause:** Blackwell GPUs mandate the open kernel module driver. The proprietary driver (installed by `nvidia-driver-595-server` without `-open`) does not support Blackwell architecture.

**Fix:**

```bash
# Remove proprietary driver
sudo apt-get purge 'nvidia-driver-*' 'nvidia-dkms-*'
sudo apt-get autoremove

# Ensure kernel headers are present
sudo apt-get install -y linux-headers-$(uname -r)

# Install open kernel module variant
sudo apt-get install -y nvidia-driver-595-server-open

# Verify DKMS built the module
dkms status | grep nvidia
# Must show 'installed' — if it shows 'added', run:
sudo dkms install nvidia/595.58.03 -k $(uname -r)

sudo reboot
```

---

### DKMS shows `added` but module not found after install

**Symptom:**

```
$ dkms status | grep nvidia
nvidia/595.58.03: added          ← should be 'installed'

$ modprobe nvidia
modprobe: FATAL: Module nvidia not found in directory /lib/modules/6.8.0-xxx-generic
```

**Root cause:** Linux kernel headers were not installed when the driver package was installed. DKMS registered the driver source but never compiled it into a kernel module.

**Fix:**

```bash
sudo apt-get install -y linux-headers-$(uname -r)
sudo dkms install nvidia/595.58.03 -k $(uname -r)

# Verify
dkms status | grep nvidia    # should show 'installed'
modprobe nvidia && echo "Module loaded OK"
nvidia-smi
```

---

### `mpirun` segfaults immediately — even for `/bin/echo`

**Symptom:** Any command under `mpirun` crashes instantly:

```
Signal: Segmentation fault (11)
Signal code: Address not mapped (1)
Failing at address: (nil)
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)
```

This happens even for trivial commands (`mpirun -np 1 /bin/echo hello`) and regardless of MCA flags.

**Root cause:** OFED installs OpenMPI 4.1.9a1 (alpha) at `/usr/mpi/gcc/openmpi-4.1.9a1/` and registers its shared libraries in the system linker cache (`/etc/ld.so.cache`). Ubuntu's system `mpirun` (`openmpi-bin` 4.1.6) loads at startup and picks up OFED's mismatched 4.1.9a1 libraries via ldconfig. The ABI mismatch causes a NULL function pointer dereference in an early constructor.

**Fix:** Always use OFED's own `mpirun` with its isolated library path — never the system `mpirun`:

```bash
export MPI_HOME=/usr/mpi/gcc/openmpi-4.1.9a1
export LD_LIBRARY_PATH=$MPI_HOME/lib:/usr/local/cuda-13.2/lib64
export PATH=$MPI_HOME/bin:$PATH

# Verify the right mpirun is active
which mpirun
# Expected: /usr/mpi/gcc/openmpi-4.1.9a1/bin/mpirun

# Confirm it works
mpirun --allow-run-as-root -np 1 /bin/echo hello
# Expected: hello
```

> **Note:** The system `openmpi-bin` package and OFED's `openmpi` package cannot coexist cleanly. Do **not** call `/usr/bin/mpirun` directly.

---

### nccl-tests segfault (non-MPI mode works, MPI mode crashes)

If `./build/all_reduce_perf` runs fine standalone but crashes under `mpirun`, this is almost always the MPI library conflict above. Resolve the `mpirun` issue first, then rebuild nccl-tests with OFED's MPI:

```bash
export MPI_HOME=/usr/mpi/gcc/openmpi-4.1.9a1
export LD_LIBRARY_PATH=$MPI_HOME/lib:/usr/local/cuda-13.2/lib64

cd nccl-tests
make clean
make MPI=1 \
     MPI_HOME=$MPI_HOME \
     CUDA_HOME=/usr/local/cuda-13.2 \
     NCCL_HOME=/usr
```

---

## 🔗 Resources

- [NVIDIA CUDA Downloads](https://developer.nvidia.com/cuda-downloads)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [nccl-tests GitHub](https://github.com/NVIDIA/nccl-tests)
- [OpenMPI Documentation](https://www.open-mpi.org/doc/)
- [Ubuntu 24.04 NVIDIA Driver Guide](https://ubuntu.com/server/docs/nvidia-drivers-installation)