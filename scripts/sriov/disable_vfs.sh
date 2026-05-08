#!/bin/bash
# disable_vfs.sh — Disable all SR-IOV Virtual Functions

set -euo pipefail

CARD=${CARD:-card0}
SRIOV_PATH="/sys/class/drm/${CARD}/device/sriov_numvfs"

echo "Disabling all VFs on ${CARD}..."
echo 0 | sudo tee "$SRIOV_PATH"
echo "Done."
