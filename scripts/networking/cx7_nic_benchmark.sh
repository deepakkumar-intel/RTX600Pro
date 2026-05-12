#!/bin/bash
# =============================================================================
# cx7_nic_benchmark.sh
#
# Description:
#   Discover all ConnectX-7 (CX7) NIC RDMA devices on this host and run
#   bandwidth and latency benchmarks across every unique pair using perftest.
#
#   Tests run per pair:
#     Bandwidth : ib_send_bw, ib_write_bw, ib_read_bw
#     Latency   : ib_send_lat, ib_write_lat, ib_read_lat
#
# Usage:
#   bash cx7_nic_benchmark.sh [OPTIONS]
#
# Options:
#   --bw-only          Run bandwidth tests only
#   --lat-only         Run latency tests only
#   --iters <N>        Number of iterations per test  (default: 1000)
#   --size <bytes>     Message size for BW tests      (default: 65536)
#   --output-dir <dir> Directory to save results      (default: ./cx7_results_<timestamp>)
#   --port <N>         Base TCP port for perftest      (default: 18515)
#   --no-color         Disable colored output
#
# Requirements:
#   sudo apt-get install -y perftest ibverbs-utils rdma-core
#
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BW_ONLY=false
LAT_ONLY=false
ITERS=1000
BW_SIZE=65536
BASE_PORT=18515
OUTPUT_DIR="./cx7_results_$(date +%Y%m%d_%H%M%S)"
COLOR=true

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bw-only)         BW_ONLY=true ;;
        --lat-only)        LAT_ONLY=true ;;
        --iters)           ITERS="$2";      shift ;;
        --size)            BW_SIZE="$2";    shift ;;
        --output-dir)      OUTPUT_DIR="$2"; shift ;;
        --port)            BASE_PORT="$2";  shift ;;
        --no-color)        COLOR=false ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ "$COLOR" == "true" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"; }
pass()    { echo -e "  ${GREEN}✔${NC} $*"; }
fail()    { echo -e "  ${RED}✘${NC} $*"; }

# ── Output directory + logging ────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
SUMMARY_LOG="$OUTPUT_DIR/summary.log"
CSV_FILE="$OUTPUT_DIR/results.csv"
exec > >(tee -a "$SUMMARY_LOG") 2>&1

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       CX7 NIC Bandwidth & Latency Benchmark              ║"
echo "║       $(date '+%Y-%m-%d %H:%M:%S')                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
info "Output directory : $OUTPUT_DIR"
info "Iterations       : $ITERS"
info "BW message size  : $BW_SIZE bytes"
info "Base port        : $BASE_PORT"

# ── Prerequisites ─────────────────────────────────────────────────────────────
section "Checking Prerequisites"

REQUIRED_TOOLS=(ib_send_bw ib_send_lat ib_write_bw ib_write_lat ib_read_bw ib_read_lat ibv_devinfo)
MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool"
    else
        fail "$tool  (missing)"
        MISSING+=("$tool")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing tools: ${MISSING[*]}. Install with:\n  sudo apt-get install -y perftest ibverbs-utils rdma-core"
fi

# ── Discover CX7 devices ──────────────────────────────────────────────────────
section "Discovering ConnectX-7 NIC Devices"

# Map every mlx5 RDMA device to its PCI address, then check if it is CX7
# CX7 PCI subsystem device ID = 0x1021 (Mellanox/NVIDIA)
declare -A DEV_PCI       # rdma_dev → pci_addr
declare -A DEV_NETDEV    # rdma_dev → netdev name
declare -A DEV_IP        # rdma_dev → IPv4 address
declare -A DEV_ROCE      # rdma_dev → "true" if RoCE, "false" if pure IB
declare -A DEV_GID       # rdma_dev → GID index 0
declare -a RDMA_DEVS     # ordered list of discovered devices

for rdma_path in /sys/class/infiniband/mlx5_*/; do
    [[ -d "$rdma_path" ]] || continue
    rdma_dev=$(basename "$rdma_path")

    # Resolve PCI address
    pci_addr=$(basename "$(readlink -f "${rdma_path}device")")
    DEV_PCI["$rdma_dev"]="$pci_addr"

    # Check if CX7 — PCI device ID 0x1021; also accept by name in lspci
    pci_desc=$(lspci -s "$pci_addr" 2>/dev/null || true)
    if echo "$pci_desc" | grep -qiE "ConnectX-7|0x1021"; then
        is_cx7=true
    else
        # Fallback: accept any mlx5 Mellanox device if no strict CX7 found
        is_cx7=false
        echo "$pci_desc" | grep -qi "Mellanox" && is_cx7=true
    fi

    if [[ "$is_cx7" == "false" ]]; then
        warn "Skipping $rdma_dev ($pci_addr) — not identified as CX7/Mellanox"
        continue
    fi

    # Find associated netdev
    netdev=""
    # Primary path: ports/1/gid_attrs/ndevs/
    for ndev_file in "${rdma_path}ports/1/gid_attrs/ndevs/"*; do
        [[ -f "$ndev_file" ]] && netdev=$(cat "$ndev_file") && break
    done
    # Fallback: device/net/
    if [[ -z "$netdev" ]]; then
        for ndev_dir in "${rdma_path}device/net/"/; do
            [[ -d "$ndev_dir" ]] && netdev=$(basename "$ndev_dir") && break
        done
    fi
    DEV_NETDEV["$rdma_dev"]="${netdev:-unknown}"

    # Get IPv4 (RoCE mode)
    ip_addr=""
    if [[ -n "$netdev" && "$netdev" != "unknown" ]]; then
        ip_addr=$(ip -4 addr show "$netdev" 2>/dev/null \
            | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1 || true)
    fi
    DEV_IP["$rdma_dev"]="${ip_addr:-}"
    DEV_ROCE["$rdma_dev"]="$( [[ -n "$ip_addr" ]] && echo true || echo false )"

    # Get GID for IB mode (index 0)
    gid_file="${rdma_path}ports/1/gids/0"
    DEV_GID["$rdma_dev"]="$( [[ -f "$gid_file" ]] && cat "$gid_file" || echo '' )"

    RDMA_DEVS+=("$rdma_dev")

    echo ""
    info "$rdma_dev"
    echo "    PCI      : $pci_addr  ($pci_desc)"
    echo "    Netdev   : ${DEV_NETDEV[$rdma_dev]}"
    echo "    IP       : ${DEV_IP[$rdma_dev]:-N/A (IB mode)}"
    echo "    RoCE     : ${DEV_ROCE[$rdma_dev]}"
done

NUM_DEVS=${#RDMA_DEVS[@]}
echo ""
if [[ $NUM_DEVS -lt 2 ]]; then
    error "Found only $NUM_DEVS CX7 device(s). Need at least 2 for pair testing."
fi
info "Total CX7 devices found: $NUM_DEVS"

# ── Generate all unique pairs ─────────────────────────────────────────────────
section "Test Pairs (all combinations)"

declare -a PAIRS=()
for (( i=0; i<NUM_DEVS; i++ )); do
    for (( j=i+1; j<NUM_DEVS; j++ )); do
        PAIRS+=("${RDMA_DEVS[$i]}:${RDMA_DEVS[$j]}")
    done
done

TOTAL_PAIRS=${#PAIRS[@]}
info "Pairs to test: $TOTAL_PAIRS  (N*(N-1)/2 = ${NUM_DEVS}*(${NUM_DEVS}-1)/2)"
for pair in "${PAIRS[@]}"; do
    echo "  ↔  $pair"
done

# ── CSV header ────────────────────────────────────────────────────────────────
echo "pair,server_dev,client_dev,test,type,msg_size_bytes,bw_avg_GBs,bw_peak_GBs,lat_min_us,lat_max_us,lat_avg_us,lat_99p_us,status" \
    > "$CSV_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
NEXT_PORT=$BASE_PORT
alloc_port() {
    local p=$NEXT_PORT
    # Scan for in-use ports
    while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}$"; do
        (( p++ ))
    done
    NEXT_PORT=$(( p + 1 ))
    echo "$p"
}

SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # Belt-and-suspenders: kill any stray perftest servers
    pkill -f "ib_send_bw --server\|ib_write_bw --server\|ib_read_bw\|ib_send_lat\|ib_write_lat\|ib_read_lat" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# run_bw_test <binary> <srv_dev> <cli_dev> <srv_ip_or_empty> <port> <outfile>
run_bw_test() {
    local bin=$1 srv_dev=$2 cli_dev=$3 srv_ip=$4 port=$5 outfile=$6
    local roce_flag=""
    [[ -n "$srv_ip" ]] && roce_flag="-R"

    # Server (background)
    $bin --ib-dev "$srv_dev" -p "$port" \
        --iters "$ITERS" -s "$BW_SIZE" \
        $roce_flag \
        > "${outfile}.server" 2>&1 &
    SERVER_PID=$!
    sleep 2

    # Client
    $bin --ib-dev "$cli_dev" -p "$port" \
        --iters "$ITERS" -s "$BW_SIZE" \
        $roce_flag \
        "${srv_ip:-127.0.0.1}" \
        > "$outfile" 2>&1
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""

    # Parse: last non-comment line — fields: bytes iters bw_peak bw_avg msgrate
    local last_line
    last_line=$(grep -v '^[[:space:]]*#' "$outfile" | grep -v '^$' | tail -1)
    BW_PEAK=$(echo "$last_line" | awk '{print $3}')
    BW_AVG=$(echo  "$last_line" | awk '{print $4}')
}

# run_lat_test <binary> <srv_dev> <cli_dev> <srv_ip_or_empty> <port> <outfile>
run_lat_test() {
    local bin=$1 srv_dev=$2 cli_dev=$3 srv_ip=$4 port=$5 outfile=$6
    local roce_flag=""
    [[ -n "$srv_ip" ]] && roce_flag="-R"

    $bin --ib-dev "$srv_dev" -p "$port" \
        --iters "$ITERS" \
        $roce_flag \
        > "${outfile}.server" 2>&1 &
    SERVER_PID=$!
    sleep 2

    $bin --ib-dev "$cli_dev" -p "$port" \
        --iters "$ITERS" \
        $roce_flag \
        "${srv_ip:-127.0.0.1}" \
        > "$outfile" 2>&1
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""

    # Parse: last non-comment line — fields: bytes iters t_min t_max t_typical t_avg t_stdev 99p 99.9p
    local last_line
    last_line=$(grep -v '^[[:space:]]*#' "$outfile" | grep -v '^$' | tail -1)
    LAT_MIN=$(echo "$last_line"  | awk '{print $3}')
    LAT_MAX=$(echo "$last_line"  | awk '{print $4}')
    LAT_AVG=$(echo "$last_line"  | awk '{print $6}')
    LAT_99P=$(echo "$last_line"  | awk '{print $8}')
}

# ── Run all tests ─────────────────────────────────────────────────────────────
section "Running Benchmarks"

PAIR_IDX=0
PASSED=0
FAILED=0

for pair in "${PAIRS[@]}"; do
    (( PAIR_IDX++ ))
    srv_dev="${pair%%:*}"
    cli_dev="${pair##*:}"
    pair_label="${srv_dev}_vs_${cli_dev}"
    srv_ip="${DEV_IP[$srv_dev]:-}"

    echo ""
    echo -e "${BOLD}${CYAN}┌─ Pair [${PAIR_IDX}/${TOTAL_PAIRS}]: ${srv_dev} ↔ ${cli_dev} $( [[ -n "$srv_ip" ]] && echo "(RoCE: $srv_ip)" || echo "(IB mode)" ) ─${NC}"
    echo -e "${BOLD}${CYAN}│${NC}  Server dev : $srv_dev  (${DEV_NETDEV[$srv_dev]})"
    echo -e "${BOLD}${CYAN}│${NC}  Client dev : $cli_dev  (${DEV_NETDEV[$cli_dev]})"
    echo -e "${BOLD}${CYAN}└───────────────────────────────────────────────────────${NC}"

    pair_dir="$OUTPUT_DIR/${pair_label}"
    mkdir -p "$pair_dir"

    # ── Bandwidth Tests ────────────────────────────────────────────────────────
    if [[ "$LAT_ONLY" == "false" ]]; then
        for bw_bin in ib_send_bw ib_write_bw ib_read_bw; do
            port=$(alloc_port)
            outfile="${pair_dir}/${bw_bin}.txt"
            printf "  %-20s (port %-5s) ... " "$bw_bin" "$port"

            BW_PEAK="N/A"; BW_AVG="N/A"; status="PASS"
            if run_bw_test "$bw_bin" "$srv_dev" "$cli_dev" "$srv_ip" "$port" "$outfile" 2>/dev/null; then
                echo -e "${GREEN}PASS${NC}  avg=${BW_AVG} GB/s  peak=${BW_PEAK} GB/s"
                (( PASSED++ ))
            else
                status="FAIL"; echo -e "${RED}FAIL${NC}  (see $outfile)"
                (( FAILED++ ))
            fi
            echo "${pair},${srv_dev},${cli_dev},${bw_bin},bandwidth,${BW_SIZE},${BW_AVG},${BW_PEAK},,,,${status}" >> "$CSV_FILE"
        done
    fi

    # ── Latency Tests ──────────────────────────────────────────────────────────
    if [[ "$BW_ONLY" == "false" ]]; then
        for lat_bin in ib_send_lat ib_write_lat ib_read_lat; do
            port=$(alloc_port)
            outfile="${pair_dir}/${lat_bin}.txt"
            printf "  %-20s (port %-5s) ... " "$lat_bin" "$port"

            LAT_MIN="N/A"; LAT_MAX="N/A"; LAT_AVG="N/A"; LAT_99P="N/A"; status="PASS"
            if run_lat_test "$lat_bin" "$srv_dev" "$cli_dev" "$srv_ip" "$port" "$outfile" 2>/dev/null; then
                echo -e "${GREEN}PASS${NC}  avg=${LAT_AVG} us  min=${LAT_MIN} us  max=${LAT_MAX} us  99p=${LAT_99P} us"
                (( PASSED++ ))
            else
                status="FAIL"; echo -e "${RED}FAIL${NC}  (see $outfile)"
                (( FAILED++ ))
            fi
            echo "${pair},${srv_dev},${cli_dev},${lat_bin},latency,1,,,${LAT_MIN},${LAT_MAX},${LAT_AVG},${LAT_99P},${status}" >> "$CSV_FILE"
        done
    fi
done

# ── Summary table ─────────────────────────────────────────────────────────────
section "Results Summary"

echo ""
printf "${BOLD}%-28s %-18s %-10s %-12s %-12s %-12s %-12s${NC}\n" \
    "Pair" "Test" "Status" "BW Avg GB/s" "BW Peak GB/s" "Lat Avg us" "Lat 99p us"
printf '%.0s─' {1..106}; echo ""

tail -n +2 "$CSV_FILE" | while IFS=',' read -r pair srv cli test type size bw_avg bw_peak lat_min lat_max lat_avg lat_99p status; do
    status_color="${GREEN}"
    [[ "$status" == "FAIL" ]] && status_color="${RED}"
    printf "%-28s %-18s ${status_color}%-10s${NC} %-12s %-12s %-12s %-12s\n" \
        "$pair" "$test" "$status" \
        "${bw_avg:--}" "${bw_peak:--}" "${lat_avg:--}" "${lat_99p:--}"
done

echo ""
echo "────────────────────────────────────────"
echo -e "  Total pairs tested : ${TOTAL_PAIRS}"
echo -e "  Tests ${GREEN}passed${NC}         : ${PASSED}"
echo -e "  Tests ${RED}failed${NC}         : ${FAILED}"
echo "────────────────────────────────────────"
echo ""
info "Full results saved to : $OUTPUT_DIR/"
info "CSV summary           : $CSV_FILE"
info "Per-pair raw logs     : $OUTPUT_DIR/<pair>/<test>.txt"
