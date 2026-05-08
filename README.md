# RTX 600 Pro — GPU Work Management

Repository for managing driver setup, SR-IOV configuration, diagnostics, and operational scripts for **RTX 600 Pro** GPU cards.

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

## 🚀 Quick Start

### 1. Enable SR-IOV (PF/VF)
```bash
# Enable 4 Virtual Functions
bash scripts/sriov/enable_vfs.sh 4
```

### 2. Run Diagnostics
```bash
bash scripts/diagnostics/gpu_health.sh
```

### 3. Apply Driver Config
```bash
bash scripts/setup/install_driver.sh
```

## 📋 Requirements

- Linux kernel ≥ 6.8
- IOMMU enabled in BIOS (VT-d)
- SR-IOV enabled in BIOS

## 🔗 Resources

- [Intel GPU Documentation](https://dgpu-docs.intel.com)
- [Kernel xe Driver Docs](https://www.kernel.org/doc/html/latest/gpu/xe/)
