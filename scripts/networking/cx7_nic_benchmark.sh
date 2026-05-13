#!/bin/bash
# =============================================================================
# cx7_nic_benchmark.sh
#
# Discovers all ConnectX-7 RDMA devices on this host and runs RDMA bandwidth
# and latency benchmarks across every unique NIC pair using perftest.
#
# Tests per pair:
#   ib_write_bw   — RDMA Write bandwidth
#   ib_read_bw    — RDMA Read  bandwidth
#   ib_write_lat  — RDMA Write latency
#   ib_read_lat   — RDMA Read  latency
#
# Usage:
#   bash cx7_nic_benchmark.sh [OPTIONS]
#
# Options:
#   --bw-only            Run bandwidth tests only
#   --lat-only           Run latency tests only
#   --iters   <N>        Iterations per test           (default: 1000)
#   --size    <bytes>    Message size for BW tests     (default: 65536)
#   --port    <N>        Base TCP port                 (default: 18515)
#   --wait    <sec>      Seconds to wait for server    (default: 3)
#   --output-dir <dir>   Directory for results         (default: ./cx7_results_<ts>)
#   --no-color           Disable colour output
#
# Requirements (Ubuntu 24.04):
#   sudo apt-get install -y perftest ibverbs-utils rdma-core
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BW_ONLY=false
LAT_ONLY=false
ITERS=1000
BW_SIZE=65536
BASE_PORT=18515
SERVER_WAIT=3
OUTPUT_DIR="./cx7_results_$(date +%Y%m%d_%H%M%S)"
COLOR=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bw-only)    BW_ONLY=true ;;
        --lat-only)   LAT_ONLY=true ;;
        --iters)      ITERS="$2";       shift ;;
        --size)       BW_SIZE="$2";     shift ;;
        --port)       BASE_PORT="$2";   shift ;;
        --wait)       SERVER_WAIT="$2"; shift ;;
        --output-dir) OUTPUT_DIR="$2";  shift ;;
        --no-color)   COLOR=false ;;
        *) echo "Unknown option: $1"; exit 1 ;;
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

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
hdr()     { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}"; }

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/summary.log"
CSV="$OUTPUT_DIR/results.csv"
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "  CX7 RDMA Benchmark — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  iters=${ITERS}  bw_size=${BW_SIZE}B  base_port=${BASE_PORT}  server_wait=${SERVER_WAIT}s"
echo "  output → $OUTPUT_DIR"
echo ""

# ── Prerequisites ─────────────────────────────────────────────────────────────
hdr "Prerequisites"

REQUIRED=(ib_write_bw ib_read_bw ib_write_lat ib_read_lat ibv_devinfo)
MISSING=()
for t in "${REQUIRED[@]}"; do
    if command -v "$t" &>/dev/null; then
        echo -e "  ${GREEN}✔${NC} $t"
    else
        echo -e "  ${RED}✘${NC} $t"
        MISSING+=("$t")
    fi
done
[[ ${#MISSING[@]} -gt 0 ]] && \
    error "Missing: ${MISSING[*]}\n  Fix: sudo apt-get install -y perftest ibverbs-utils rdma-core"

# ── Discover devices ──────────────────────────────────────────────────────────
hdr "Discovering ConnectX-7 Devices"

declare -A DEV_NETDEV   # rdma_dev → netdev
declare -A DEV_IP       # rdma_dev → IPv4 (empty = IB/no-IP mode)
declare -a RDMA_DEVS    # ordered list

for rdma_path in /sys/class/infiniband/mlx5_*/; do
    [[ -d "$rdma_path" ]] || continue
    dev=$(basename "$rdma_path")

    # Map to PCI address
    pci=$(basename "$(readlink -f "${rdma_path}device")")

    # Confirm CX7 or Mellanox
    desc=$(lspci -s "$pci" 2>/dev/null || true)
    if ! echo "$desc" | grep -qiE "ConnectX-7|0x1021|Mellanox|NVIDIA.*Network"; then
        warn "Skipping $dev ($pci) — not CX7/Mellanox"
        continue
    fi

    # Netdev — try gid_attrs first, then device/net
    netdev=""
    for f in "${rdma_path}ports/1/gid_attrs/ndevs/"*; do
        [[ -f "$f" ]] && netdev=$(cat "$f") && break
    done
    if [[ -z "$netdev" ]]; then
        for d in "${rdma_path}device/net/*/"; do
            [[ -d "$d" ]] && netdev=$(basename "$d") && break
        done
    fi
    DEV_NETDEV["$dev"]="${netdev:-unknown}"

    # IPv4 (used for RoCE; absent = IB mode, use localhost for CM)
    ip=""
    if [[ -n "$netdev" && "$netdev" != "unknown" ]]; then
        ip=$(ip -4 addr show "$netdev" 2>/dev/null \
             | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1 || true)
    fi
    DEV_IP["$dev"]="${ip:-}"
    RDMA_DEVS+=("$dev")

    echo ""
    info "$dev"
    printf "      PCI    : %s\n" "$pci"
    printf "      Netdev : %s\n" "${DEV_NETDEV[$dev]}"
    printf "      IP     : %s\n" "${ip:-N/A (IB — will use localhost for CM)}"
done

echo ""
NUM_DEVS=${#RDMA_DEVS[@]}
[[ $NUM_DEVS -lt 2 ]] && error "Need ≥ 2 CX7 devices. Found: $NUM_DEVS"
info "Total devices : $NUM_DEVS"

# ── Build all unique pairs ────────────────────────────────────────────────────
hdr "Test Pairs  (N*(N-1)/2 = ${NUM_DEVS}*$(( NUM_DEVS - 1 ))/2)"

declare -a PAIRS=()
for (( i = 0; i < NUM_DEVS; i++ )); do
    for (( j = i + 1; j < NUM_DEVS; j++ )); do
        PAIRS+=("${RDMA_DEVS[$i]}:${RDMA_DEVS[$j]}")
        echo "  ↔  ${RDMA_DEVS[$i]}  ←→  ${RDMA_DEVS[$j]}"
    done
done
TOTAL_PAIRS=${#PAIRS[@]}

# ── CSV header ────────────────────────────────────────────────────────────────
echo "pair,server,client,test,type,size_bytes,bw_avg_GBs,bw_peak_GBs,lat_min_us,lat_max_us,lat_avg_us,lat_99p_us,status" \
    > "$CSV"

# ── Port allocator (no (( n++ )) to avoid set -e exit-code trap) ─────────────
NEXT_PORT=$BASE_PORT
alloc_port() {
    local p=$NEXT_PORT
    while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}$"; do
        p=$(( p + 1 ))
    done
    NEXT_PORT=$(( p + 1 ))
    echo "$p"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
SRV_PID=""
cleanup() {
    if [[ -n "$SRV_PID" ]] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── run_rdma_bw <binary> <srv_dev> <cli_dev> <srv_ip> <port> <outfile> ───────
# Sets globals: BW_AVG  BW_PEAK
run_rdma_bw() {
    local bin="$1" srv_dev="$2" cli_dev="$3" srv_ip="$4" port="$5" outfile="$6"
    BW_AVG="N/A"; BW_PEAK="N/A"

    # Build flags as array — avoids empty-string arg bugs
    local -a flags=(-p "$port" --iters "$ITERS" -s "$BW_SIZE")
    [[ -n "$srv_ip" ]] && flags+=(-R)   # enable RoCE only when IP is present

    # Start server in background
    "$bin" --ib-dev "$srv_dev" "${flags[@]}" \
        > "${outfile}.server" 2>&1 &
    SRV_PID=$!
    sleep "$SERVER_WAIT"

    # Abort if server already died
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        warn "Server exited early — check ${outfile}.server"
        SRV_PID=""
        return 1
    fi

    # Connect client to server IP (RoCE) or localhost (IB CM)
    local target="${srv_ip:-127.0.0.1}"
    if "$bin" --ib-dev "$cli_dev" "${flags[@]}" "$target" \
            > "$outfile" 2>&1; then
        # perftest output last data line: bytes iters bw_peak bw_avg msgrate
        local last
        last=$(grep -v '^[[:space:]]*#' "$outfile" | grep -v '^[[:space:]]*$' | tail -1)
        BW_PEAK=$(awk '{print $3}' <<< "$last")
        BW_AVG=$(awk  '{print $4}' <<< "$last")
        wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
        return 0
    else
        wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
        return 1
    fi
}

# ── run_rdma_lat <binary> <srv_dev> <cli_dev> <srv_ip> <port> <outfile> ──────
# Sets globals: LAT_MIN  LAT_MAX  LAT_AVG  LAT_99P
run_rdma_lat() {
    local bin="$1" srv_dev="$2" cli_dev="$3" srv_ip="$4" port="$5" outfile="$6"
    LAT_MIN="N/A"; LAT_MAX="N/A"; LAT_AVG="N/A"; LAT_99P="N/A"

    local -a flags=(-p "$port" --iters "$ITERS")
    [[ -n "$srv_ip" ]] && flags+=(-R)

    "$bin" --ib-dev "$srv_dev" "${flags[@]}" \
        > "${outfile}.server" 2>&1 &
    SRV_PID=$!
    sleep "$SERVER_WAIT"

    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        warn "Server exited early — check ${outfile}.server"
        SRV_PID=""
        return 1
    fi

    local target="${srv_ip:-127.0.0.1}"
    if "$bin" --ib-dev "$cli_dev" "${flags[@]}" "$target" \
            > "$outfile" 2>&1; then
        # perftest lat output last data line: bytes iters t_min t_max t_typical t_avg t_stdev 99p 99.9p
        local last
        last=$(grep -v '^[[:space:]]*#' "$outfile" | grep -v '^[[:space:]]*$' | tail -1)
        LAT_MIN=$(awk '{print $3}' <<< "$last")
        LAT_MAX=$(awk '{print $4}' <<< "$last")
        LAT_AVG=$(awk '{print $6}' <<< "$last")
        LAT_99P=$(awk '{print $8}' <<< "$last")
        wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
        return 0
    else
        wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
        return 1
    fi
}

# ── Main test loop ────────────────────────────────────────────────────────────
hdr "Running RDMA Benchmarks"

PAIR_IDX=0
PASSED=0
FAILED=0

for pair in "${PAIRS[@]}"; do
    PAIR_IDX=$(( PAIR_IDX + 1 ))     # ← safe: var=$(( )) never returns exit 1
    srv_dev="${pair%%:*}"
    cli_dev="${pair##*:}"
    srv_ip="${DEV_IP[$srv_dev]:-}"
    mode="$( [[ -n "$srv_ip" ]] && echo "RoCE target=$srv_ip" || echo "IB CM=localhost" )"

    echo ""
    echo -e "${BOLD}${CYAN}┌─ [${PAIR_IDX}/${TOTAL_PAIRS}]  ${srv_dev} ↔ ${cli_dev}  (${mode})${NC}"
    echo -e "${BOLD}${CYAN}│${NC}  srv: $srv_dev  netdev=${DEV_NETDEV[$srv_dev]}"
    echo -e "${BOLD}${CYAN}│${NC}  cli: $cli_dev  netdev=${DEV_NETDEV[$cli_dev]}"
    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────${NC}"

    pair_dir="$OUTPUT_DIR/${srv_dev}_vs_${cli_dev}"
    mkdir -p "$pair_dir"

    # ── RDMA Bandwidth ─────────────────────────────────────────────────────────
    if [[ "$LAT_ONLY" == "false" ]]; then
        for bin in ib_write_bw ib_read_bw; do
            port=$(alloc_port)
            out="${pair_dir}/${bin}.txt"
            printf "  %-16s  port=%-6s  " "$bin" "$port"

            if run_rdma_bw "$bin" "$srv_dev" "$cli_dev" "$srv_ip" "$port" "$out"; then
                echo -e "${GREEN}PASS${NC}  avg=${BW_AVG} GB/s  peak=${BW_PEAK} GB/s"
                PASSED=$(( PASSED + 1 ))
                status="PASS"
            else
                echo -e "${RED}FAIL${NC}  → $out  ${out}.server"
                FAILED=$(( FAILED + 1 ))
                BW_AVG="N/A"; BW_PEAK="N/A"; status="FAIL"
            fi
            echo "${pair},${srv_dev},${cli_dev},${bin},bandwidth,${BW_SIZE},${BW_AVG},${BW_PEAK},,,,$status" \
                >> "$CSV"
        done
    fi

    # ── RDMA Latency ──────────────────────────────────────────────────────────
    if [[ "$BW_ONLY" == "false" ]]; then
        for bin in ib_write_lat ib_read_lat; do
            port=$(alloc_port)
            out="${pair_dir}/${bin}.txt"
            printf "  %-16s  port=%-6s  " "$bin" "$port"

            if run_rdma_lat "$bin" "$srv_dev" "$cli_dev" "$srv_ip" "$port" "$out"; then
                echo -e "${GREEN}PASS${NC}  avg=${LAT_AVG} us  min=${LAT_MIN} us  max=${LAT_MAX} us  99p=${LAT_99P} us"
                PASSED=$(( PASSED + 1 ))
                status="PASS"
            else
                echo -e "${RED}FAIL${NC}  → $out  ${out}.server"
                FAILED=$(( FAILED + 1 ))
                LAT_MIN="N/A"; LAT_MAX="N/A"; LAT_AVG="N/A"; LAT_99P="N/A"; status="FAIL"
            fi
            echo "${pair},${srv_dev},${cli_dev},${bin},latency,1,,,$LAT_MIN,$LAT_MAX,$LAT_AVG,$LAT_99P,$status" \
                >> "$CSV"
        done
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Results Summary"
echo ""
printf "${BOLD}%-26s %-16s %-8s %-13s %-13s %-12s %-12s${NC}\n" \
    "Pair" "Test" "Status" "BW Avg(GB/s)" "BW Peak(GB/s)" "Lat Avg(us)" "Lat 99p(us)"
printf '%.0s─' {1..100}; echo ""

tail -n +2 "$CSV" | while IFS=',' read -r pair srv cli test type size \
        bw_avg bw_peak lat_min lat_max lat_avg lat_99p status; do
    [[ "$status" == "PASS" ]] && sc="${GREEN}" || sc="${RED}"
    printf "%-26s %-16s ${sc}%-8s${NC} %-13s %-13s %-12s %-12s\n" \
        "$pair" "$test" "$status" \
        "${bw_avg:--}" "${bw_peak:--}" "${lat_avg:--}" "${lat_99p:--}"
done

echo ""
echo    "  Pairs tested : $TOTAL_PAIRS"
echo -e "  Passed       : ${GREEN}${PASSED}${NC}"
echo -e "  Failed       : ${RED}${FAILED}${NC}"
echo ""
info "Log : $LOG"
info "CSV : $CSV"
info "Raw : $OUTPUT_DIR/<pair>/<test>.txt[.server]"
