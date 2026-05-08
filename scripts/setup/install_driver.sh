#!/bin/bash
# install_driver.sh — Driver setup for RTX 600 Pro
# Modify for your specific distro and driver version

set -euo pipefail

echo "=== RTX 600 Pro Driver Setup ==="

# Update system
sudo apt-get update -y

# Install kernel headers
sudo apt-get install -y linux-headers-$(uname -r)

echo "Driver setup complete. Please reboot."
