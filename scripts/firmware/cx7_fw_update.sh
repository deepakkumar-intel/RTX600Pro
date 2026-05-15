#!/bin/bash
# =============================================================================
# cx7_fw_update.sh
#
# Discovers all ConnectX-7 NICs on this host, queries their current firmware
# version, and optionally flashes a user-supplied firmware image using Flint.
#
# Usage:
#   bash cx7_fw_update.sh [OPTIONS]
#
# Options:
#   --fw-file  <path>   Path to firmware .bin file to flash onto all CX7 NICs
#   --device   <pci>    Flash only the specified PCI device (e.g. 0000:1a:00.0)
#                       Can be repeated for multiple devices
#   --query-only        Query and display current FW versions only; do not flash
#   -y, --yes           Auto-confirm all prompts (non-interactive mode)
#   --no-color          Disable colour output
#   --log-dir  <dir>    Directory for log file  (default: ./cx7_fw_logs_<ts>)
#
# Examples:
#   # Query current FW versions on all CX7 NICs
#   bash cx7_fw_update.sh --query-only
#
#   # Flash a specific image to all CX7 NICs (with confirmation)
#   bash cx7_fw_update.sh --fw-file /path/to/fw-ConnectX7-rel.bin
#
#   # Flash a specific image to one NIC only
#   bash cx7_fw_update.sh --fw-file /path/to/fw.bin --device 0000:1a:00.0
#
#   # Non-interactive flash (e.g. in automation / ansible)
#   bash cx7_fw_update.sh --fw-file /path/to/fw.bin --yes
#
# Requirements (Ubuntu 24.04):
#   sudo apt-get install -y mstflint pciutils
#
# Notes:
#   • A COLD REBOOT is required after flashing for firmware to take effect.
#   • Running as root (or with sudo) is required — Flint needs PCIe access.
#   • flint is part of the mstflint package (Mellanox/NVIDIA MFT tools).
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
FW_FILE=""
QUERY_ONLY=false
AUTO_YES=false
COLOR=true
LOG_DIR="./cx7_fw_logs_$(date +%Y%m%d_%H%M%S)"
declare -a FILTER_DEVS=()   # PCI addresses from --device flags

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fw-file)    FW_FILE="$2";               shift ;;
        --device)     FILTER_DEVS+=("$2");         shift ;;
        --query-only) QUERY_ONLY=true ;;
        -y|--yes)     AUTO_YES=true ;;
        --no-color)   COLOR=false ;;
        --log-dir)    LOG_DIR="$2";                shift ;;
        -h|--help)
            sed -n '2,/^# ====/{ /^# ====/d; s/^# \?//; p }' "$0"
            exit 0 ;;
        *) echo "Unknown option: $1  (use --help for usage)"; exit 1 ;;
    esac
    shift
done

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ "$COLOR" == "true" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
hdr()   { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}"; }
sep()   { printf '%0.s─' {1..70}; echo; }

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/fw_update.log"
exec > >(tee -a "$LOG") 2>&1

echo ""
echo -e "${BOLD}  CX7 Firmware Update — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
[[ -n "$FW_FILE"           ]] && echo "  FW file    : $FW_FILE"
[[ "$QUERY_ONLY" == "true" ]] && echo "  Mode       : query only (no flash)"
[[ "$AUTO_YES"   == "true" ]] && echo "  Auto-yes   : enabled"
[[ ${#FILTER_DEVS[@]} -gt 0 ]] && echo "  Devices    : ${FILTER_DEVS[*]}"
echo "  Log        : $LOG"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (Flint needs PCIe device access).\n       Re-run with: sudo bash $0 $*"
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
hdr "Prerequisites"

for tool in flint lspci; do
    if command -v "$tool" &>/dev/null; then
        ver=""
        case "$tool" in
            flint) ver=$(flint --version 2>&1 | head -1 | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true) ;;
            lspci) ver=$(lspci --version 2>/dev/null | head -1 || true) ;;
        esac
        echo -e "  ${GREEN}✔${NC} $tool ${ver:+(v$ver)}"
    else
        echo -e "  ${RED}✘${NC} $tool  ← missing"
        MISSING+=("$tool")
    fi
done

MISSING=()
for tool in flint lspci; do
    command -v "$tool" &>/dev/null || MISSING+=("$tool")
done
[[ ${#MISSING[@]} -gt 0 ]] && \
    error "Missing tools: ${MISSING[*]}\n       Fix: sudo apt-get install -y mstflint pciutils"

# ── Validate FW file ──────────────────────────────────────────────────────────
IMAGE_VERSION=""
IMAGE_PSID=""

if [[ -n "$FW_FILE" ]]; then
    [[ "$QUERY_ONLY" == "true" ]] && \
        warn "--fw-file is ignored when --query-only is set"

    [[ -f "$FW_FILE" ]] || error "FW file not found: $FW_FILE"
    [[ "$FW_FILE" == *.bin ]] || warn "FW file does not have a .bin extension — proceeding anyway"

    hdr "Firmware Image Info"
    info "Querying image: $FW_FILE"

    fw_query_out=$(flint -i "$FW_FILE" query 2>&1) || \
        error "flint could not read the firmware image.\n       Output:\n$fw_query_out"

    echo "$fw_query_out" | grep -E "^(FW Version|FW Release Date|Description|Device PSID|Image type|PSID)" || true

    IMAGE_VERSION=$(echo "$fw_query_out" | grep "^FW Version" | awk '{print $NF}')
    IMAGE_PSID=$(echo    "$fw_query_out" | grep "^PSID\|^Device PSID" | awk '{print $NF}' | head -1)

    echo ""
    info "Image FW version : ${BOLD}${IMAGE_VERSION}${NC}"
    [[ -n "$IMAGE_PSID" ]] && info "Image PSID       : $IMAGE_PSID"
fi

# ── Discover CX7 NICs ─────────────────────────────────────────────────────────
hdr "Discovering ConnectX-7 NICs"

declare -A DEV_PCI        # rdma_name  → PCI address (0000:xx:yy.z)
declare -A DEV_NETDEV     # rdma_name  → netdev
declare -A DEV_CUR_FW     # rdma_name  → current FW version string
declare -A DEV_PSID       # rdma_name  → device PSID
declare -a RDMA_DEVS=()

for rdma_path in /sys/class/infiniband/mlx5_*/; do
    [[ -d "$rdma_path" ]] || continue
    dev=$(basename "$rdma_path")

    # PCI address
    pci=$(basename "$(readlink -f "${rdma_path}device")")

    # Confirm it's a CX7 / Mellanox NIC
    desc=$(lspci -s "$pci" 2>/dev/null || true)
    if ! echo "$desc" | grep -qiE "ConnectX-7|0x1021|Mellanox|NVIDIA.*Network"; then
        warn "Skipping $dev ($pci) — not identified as CX7/Mellanox"
        continue
    fi

    # If --device filter specified, skip devices not in the list
    if [[ ${#FILTER_DEVS[@]} -gt 0 ]]; then
        match=false
        for fd in "${FILTER_DEVS[@]}"; do
            [[ "$pci" == "$fd" || "${pci#0000:}" == "$fd" ]] && match=true && break
        done
        if [[ "$match" == "false" ]]; then
            info "Skipping $dev ($pci) — not in --device filter"
            continue
        fi
    fi

    # Netdev
    netdev=""
    for f in "${rdma_path}ports/1/gid_attrs/ndevs/"*; do
        [[ -f "$f" ]] && netdev=$(cat "$f") && break
    done
    if [[ -z "$netdev" ]]; then
        for d in "${rdma_path}device/net/*/"; do
            [[ -d "$d" ]] && netdev=$(basename "$d") && break
        done
    fi

    # Query current FW from device
    cur_fw="N/A"
    cur_psid="N/A"
    fw_out=$(flint -d "$pci" query 2>&1) || true
    if echo "$fw_out" | grep -q "^FW Version"; then
        cur_fw=$(echo   "$fw_out" | grep "^FW Version"            | awk '{print $NF}')
        cur_psid=$(echo "$fw_out" | grep "^PSID\|^Device PSID"   | awk '{print $NF}' | head -1)
    else
        warn "Could not query FW for $dev ($pci) — check flint access"
    fi

    DEV_PCI[$dev]="$pci"
    DEV_NETDEV[$dev]="${netdev:-unknown}"
    DEV_CUR_FW[$dev]="$cur_fw"
    DEV_PSID[$dev]="${cur_psid:-N/A}"
    RDMA_DEVS+=("$dev")

    echo ""
    info "${BOLD}$dev${NC}  ($pci)"
    printf "    Netdev       : %s\n"  "${DEV_NETDEV[$dev]}"
    printf "    Current FW   : %s\n"  "$cur_fw"
    printf "    PSID         : %s\n"  "${DEV_PSID[$dev]}"
    [[ "$desc" != "" ]] && printf "    PCI Desc     : %s\n" "$(echo "$desc" | cut -d: -f3- | xargs)"
done

echo ""
NUM_DEVS=${#RDMA_DEVS[@]}
[[ $NUM_DEVS -eq 0 ]] && error "No ConnectX-7 NICs found on this system."
info "Total CX7 NICs found: $NUM_DEVS"

# ── Query-only mode: exit here ────────────────────────────────────────────────
if [[ "$QUERY_ONLY" == "true" ]]; then
    hdr "FW Version Summary"
    printf "\n  ${BOLD}%-12s  %-16s  %-22s  %-20s${NC}\n" \
        "RDMA Dev" "PCI Address" "Current FW Version" "PSID"
    sep
    for dev in "${RDMA_DEVS[@]}"; do
        printf "  %-12s  %-16s  %-22s  %-20s\n" \
            "$dev" "${DEV_PCI[$dev]}" "${DEV_CUR_FW[$dev]}" "${DEV_PSID[$dev]}"
    done
    sep
    echo ""
    info "Query complete. No changes made."
    exit 0
fi

# ── No FW file and not query-only → nothing to do ────────────────────────────
if [[ -z "$FW_FILE" ]]; then
    error "No action specified.\n       Use --fw-file <path> to flash firmware, or --query-only to just report versions.\n       Run with --help for full usage."
fi

# ── Pre-flash summary table ───────────────────────────────────────────────────
hdr "Pre-Flash Summary"

SKIP_COUNT=0
declare -a FLASH_DEVS=()   # devices that will actually be flashed

printf "\n  ${BOLD}%-12s  %-16s  %-22s  %-22s  %s${NC}\n" \
    "RDMA Dev" "PCI Address" "Current FW" "New FW (image)" "Action"
sep

for dev in "${RDMA_DEVS[@]}"; do
    cur="${DEV_CUR_FW[$dev]}"
    new="${IMAGE_VERSION:-N/A}"
    pci="${DEV_PCI[$dev]}"

    # PSID mismatch check — flashing wrong image for this NIC model is dangerous
    dev_psid="${DEV_PSID[$dev]}"
    if [[ -n "$IMAGE_PSID" && -n "$dev_psid" && "$dev_psid" != "N/A" && "$IMAGE_PSID" != "$dev_psid" ]]; then
        action="${RED}SKIP (PSID mismatch)${NC}"
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
        printf "  %-12s  %-16s  %-22s  %-22s  " "$dev" "$pci" "$cur" "$new"
        echo -e "${RED}SKIP — PSID mismatch${NC}"
        echo -e "    ${YELLOW}⚠  Device PSID : $dev_psid${NC}"
        echo -e "    ${YELLOW}⚠  Image  PSID : $IMAGE_PSID${NC}"
        warn "Skipping $dev — image PSID does not match device PSID. Wrong FW file?"
        continue
    fi

    if [[ "$cur" == "$new" ]]; then
        tag="${YELLOW}(same version)${NC}"
    elif [[ "$cur" == "N/A" ]]; then
        tag="${YELLOW}(current unknown)${NC}"
    else
        tag="${GREEN}(upgrade)${NC}"
    fi

    printf "  %-12s  %-16s  %-22s  %-22s  " "$dev" "$pci" "$cur" "$new"
    echo -e "FLASH $tag"
    FLASH_DEVS+=("$dev")
done
sep

echo ""
echo -e "  Devices to flash  : ${BOLD}${#FLASH_DEVS[@]}${NC}"
[[ $SKIP_COUNT -gt 0 ]] && \
    echo -e "  Devices skipped   : ${YELLOW}${SKIP_COUNT} (PSID mismatch — see above)${NC}"

[[ ${#FLASH_DEVS[@]} -eq 0 ]] && {
    warn "No devices eligible for flashing."
    exit 0
}

# ── Reboot reminder ───────────────────────────────────────────────────────────
echo ""
echo -e "  ${YELLOW}⚠  IMPORTANT: A COLD REBOOT is required after flashing for the new${NC}"
echo -e "  ${YELLOW}   firmware to become active. Plan for downtime accordingly.${NC}"
echo ""

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$AUTO_YES" == "false" ]]; then
    echo -en "  ${BOLD}Flash ${#FLASH_DEVS[@]} device(s) with ${FW_FILE##*/}? [y/N]: ${NC}"
    read -r answer
    [[ "${answer,,}" =~ ^y(es)?$ ]] || { info "Aborted by user."; exit 0; }
    echo ""
fi

# ── Flash loop ────────────────────────────────────────────────────────────────
hdr "Flashing Firmware"

PASS_COUNT=0
FAIL_COUNT=0
declare -A FLASH_RESULT   # dev → PASS|FAIL

for dev in "${FLASH_DEVS[@]}"; do
    pci="${DEV_PCI[$dev]}"
    out_file="$LOG_DIR/flint_${dev}.log"

    echo ""
    echo -e "${BOLD}${CYAN}┌─ $dev  ($pci)${NC}"
    echo -e "${BOLD}${CYAN}│${NC}  Burning: $FW_FILE"
    echo -e "${BOLD}${CYAN}│${NC}  Log   : $out_file"
    printf  "${BOLD}${CYAN}└─${NC} "

    if flint -d "$pci" -i "$FW_FILE" --allow_psid_change burn \
            > "$out_file" 2>&1 </dev/null; then
        echo -e "${GREEN}PASS${NC}"
        FLASH_RESULT[$dev]="PASS"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        echo -e "${RED}FAIL${NC}"
        FLASH_RESULT[$dev]="FAIL"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        warn "Flash failed for $dev — see $out_file"
        # Print last few lines of flint output for quick diagnosis
        echo    "  ── flint output (last 10 lines) ──"
        tail -10 "$out_file" | sed 's/^/    /'
        echo    "  ──────────────────────────────────"
    fi
done

# ── Post-flash FW version query ───────────────────────────────────────────────
hdr "Post-Flash FW Versions"

printf "\n  ${BOLD}%-12s  %-16s  %-22s  %-22s  %s${NC}\n" \
    "RDMA Dev" "PCI Address" "FW Before" "FW After" "Result"
sep

for dev in "${FLASH_DEVS[@]}"; do
    pci="${DEV_PCI[$dev]}"
    before="${DEV_CUR_FW[$dev]}"
    result="${FLASH_RESULT[$dev]:-N/A}"

    after="N/A"
    fw_out_after=$(flint -d "$pci" query 2>&1) || true
    if echo "$fw_out_after" | grep -q "^FW Version"; then
        after=$(echo "$fw_out_after" | grep "^FW Version" | awk '{print $NF}')
    fi

    if [[ "$result" == "PASS" ]]; then
        rc="${GREEN}PASS${NC}"
    else
        rc="${RED}FAIL${NC}"
    fi

    printf "  %-12s  %-16s  %-22s  %-22s  " "$dev" "$pci" "$before" "$after"
    echo -e "$rc"
done
sep

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo    "  ─── Flash Summary ────────────────────────────────────────────"
echo -e "  Devices flashed   : ${BOLD}${#FLASH_DEVS[@]}${NC}"
echo -e "  Passed            : ${GREEN}${PASS_COUNT}${NC}"
[[ $FAIL_COUNT -gt 0 ]] && \
    echo -e "  Failed            : ${RED}${FAIL_COUNT}${NC}" || \
    echo -e "  Failed            : ${FAIL_COUNT}"
[[ $SKIP_COUNT -gt 0 ]] && \
    echo -e "  Skipped (PSID)    : ${YELLOW}${SKIP_COUNT}${NC}"
echo    "  ──────────────────────────────────────────────────────────────"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}✔ All flashes succeeded.${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  COLD REBOOT required for new firmware to become active.${NC}"
    echo -e "     Run: ${BOLD}sudo reboot${NC}"
else
    echo -e "  ${RED}✘ Some flashes failed. Check logs in: $LOG_DIR${NC}"
fi

echo ""
info "Full log: $LOG"
