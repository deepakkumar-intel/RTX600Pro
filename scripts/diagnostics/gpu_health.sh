#!/bin/bash
# gpu_health.sh — Basic GPU health and status check

set -euo pipefail

echo "=== GPU Health Check ==="
echo ""

echo "--- PCI Devices ---"
lspci | grep -i "VGA\|Display\|3D\|GPU"

echo ""
echo "--- DRM Cards ---"
ls /sys/class/drm/

echo ""
echo "--- SR-IOV Status ---"
for card in /sys/class/drm/card*/; do
    name=$(basename "$card")
    total=$(cat "${card}device/sriov_totalvfs" 2>/dev/null || echo "N/A")
    active=$(cat "${card}device/sriov_numvfs" 2>/dev/null || echo "N/A")
    echo "${name}: totalvfs=${total} | active vfs=${active}"
done

echo ""
echo "--- IOMMU Status ---"
dmesg | grep -i iommu | tail -5

echo ""
echo "--- Driver Info ---"
lsmod | grep -E "xe|i915|nvidia"
