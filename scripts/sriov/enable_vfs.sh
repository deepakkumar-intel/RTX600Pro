#!/bin/bash
# enable_vfs.sh — Enable SR-IOV Virtual Functions on RTX 600 Pro
# Usage: ./enable_vfs.sh <num_vfs>

set -euo pipefail

NUM_VFS=${1:-4}
CARD=${CARD:-card0}
SRIOV_PATH="/sys/class/drm/${CARD}/device/sriov_numvfs"
TOTAL_PATH="/sys/class/drm/${CARD}/device/sriov_totalvfs"

if [[ ! -f "$SRIOV_PATH" ]]; then
    echo "ERROR: SR-IOV not supported or driver not loaded for ${CARD}"
    exit 1
fi

TOTAL=$(cat "$TOTAL_PATH")
echo "GPU: ${CARD} | Max VFs supported: ${TOTAL}"

if (( NUM_VFS > TOTAL )); then
    echo "ERROR: Requested ${NUM_VFS} VFs but max is ${TOTAL}"
    exit 1
fi

echo "Enabling ${NUM_VFS} VFs on ${CARD}..."
echo "$NUM_VFS" | sudo tee "$SRIOV_PATH"

echo "Done. Active VFs:"
lspci | grep "Virtual Function"
