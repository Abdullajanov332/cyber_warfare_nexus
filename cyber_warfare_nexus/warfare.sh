#!/bin/bash
#
# =============================================================================
# HACKERAI CYBER WARFARE NEXUS - MASTER ORCHESTRATOR v3.0
# =============================================================================
# Barcha modullarni boshqaruvchi markaziy yadro.
# Birgina buyruq bilan to'liq Offensive Operations rejimiga o'tadi.
#
# Usage:
#   ./warfare.sh                    # Interaktiv rejim
#   ./warfare.sh --full             # To'liq avtomatik
#   ./warfare.sh --recon            # Faqat razvedka
#   ./warfare.sh --target 10.10.10.0/24
#   ./warfare.sh --stealth ghost    # Ghost stealth rejimi
#   ./warfare.sh --cleanup          # Izlarni tozalash
# =============================================================================

set -euo pipefail

# ============================================================================
# GLOBAL SOZLAMALAR
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$SCRIPT_DIR"
CONFIG_FILE="$WORKSPACE/config.env"
DB_PATH="$WORKSPACE/database/intel.db"
LOG_DIR="$WORKSPACE/logs"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="$LOG_DIR/operations_${TIMESTAMP}.log"

# Ranglar
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# FUNKSIYALAR
# ============================================================================

print_banner() {
    clear 2>/dev/null || true
    echo -e "${RED}"
    echo '╔══════════════════════════════════════════════════════════════════╗'
    echo '║      ██╗  ██╗ █████╗  ██████╗██╗  ██╗███████╗██████╗  █████╗ ██╗'
    echo '║      ██║  ██║██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗██╔══██╗██║'
    echo '║      ███████║███████║██║     █████╔╝ █████╗  ██████╔╝███████║██║'
    echo '║      ██╔══██║██╔══██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗██╔══██║██║'
    echo '║      ██║  ██║██║  ██║╚██████╗██║  ██╗███████╗██║  ██║██║  ██║██║'
    echo '║      ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝'
    echo '║                                                                    '
    echo '║          CYBER WARFARE NEXUS - OFFENSIVE OPERATIONS ENGINE         '
    echo '║               All-in-One Red Team Framework v3.0                   '
    echo '╚══════════════════════════════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "${YELLOW}[*] Workspace: ${WORKSPACE}${NC}"
    echo -e "${YELLOW}[*] Timestamp: $(date)${NC}"
    echo ""
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[${timestamp}] [INFO] ${message}${NC}" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN] ${message}${NC}" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR] ${message}${NC}" ;;
        *)     echo -e "${CYAN}[${timestamp}] [${level}] ${message}${NC}" ;;
    esac
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log INFO "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        log WARN "Configuration file not found. Using defaults."
    fi
}

check_dependencies() {
    local deps=("gcc" "g++" "go" "python3" "node" "nmap" "sqlite3" "curl" "git")
    local missing=()
    log INFO "Checking dependencies..."
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log WARN "Missing dependencies: ${missing[*]}"
    else
        log INFO "All dependencies satisfied."
    fi
}

build_core() {
    log INFO "Building C/C++ core modules..."
    if [[ -f "$WORKSPACE/core/fast_scanner.c" ]]; then
        log INFO "Compiling fast_scanner.c..."
        gcc -O3 -D_POSIX_C_SOURCE=200112L -o "$WORKSPACE/core/fast_scanner" \
            "$WORKSPACE/core/fast_scanner.c" -lpthread 2>&1 | tee -a "$LOG_FILE" || true
        chmod +x "$WORKSPACE/core/fast_scanner" 2>/dev/null || true
        log INFO "fast_scanner compiled."
    fi
    if [[ -f "$WORKSPACE/core/stealth_runner.cpp" ]]; then
        log INFO "Compiling stealth_runner.cpp..."
        g++ -O2 -s -o "$WORKSPACE/core/stealth_runner" \
            "$WORKSPACE/core/stealth_runner.cpp" -ldl 2>&1 | tee -a "$LOG_FILE" || true
        chmod +x "$WORKSPACE/core/stealth_runner" 2>/dev/null || true
        log INFO "stealth_runner compiled."
    fi
}

build_recon() {
    log INFO "Building Go reconnaissance modules..."
    if [[ -f "$WORKSPACE/recon/enumerator.go" ]]; then
        (cd "$WORKSPACE/recon" && go build -ldflags="-s -w" -o enumerator . 2>&1 | tee -a "$LOG_FILE") || true
        chmod +x "$WORKSPACE/recon/enumerator" 2>/dev/null || true
        log INFO "Go enumerator built."
    fi
}

init_database() {
    log INFO "Initializing intelligence database..."
    mkdir -p "$WORKSPACE/database"
    if [[ ! -f "$DB_PATH" ]]; then
        if [[ -f "$WORKSPACE/database/schema.sql" ]]; then
            sqlite3 "$DB_PATH" < "$WORKSPACE/database/schema.sql" 2>&1 | tee -a "$LOG_FILE" || true
            log INFO "Database initialized at $DB_PATH"
        fi
    else
        log INFO "Database already exists."
    fi
}

phase_recon() {
    local target="${1:-$TARGET_DOMAIN}"
    local ip_range="${2:-$TARGET_IP_RANGE}"
    log INFO "${BOLD}[PHASE 1] Starting Network Reconnaissance${NC}"
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"

    if command -v nmap &>/dev/null; then
        log INFO "Running nmap ping scan on $ip_range..."
        nmap -sn -T4 "$ip_range" -oG - | grep "Up$" | awk '{print $2}' > "$WORKSPACE/logs/alive_hosts.txt" || true
        log INFO "Alive hosts saved to logs/alive_hosts.txt"
    fi

    if [[ -x "$WORKSPACE/recon/enumerator" ]] && [[ -n "$target" ]] && [[ "$target" != "example.com" ]]; then
        log INFO "Running subdomain enumeration on $target..."
        "$WORKSPACE/recon/enumerator" \
            -d "$target" \
            -w "$WORKSPACE/wordlists/subdomains.txt" \
            -t "${THREADS:-5000}" \
            -o "$WORKSPACE/logs/subdomains_${TIMESTAMP}.json" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    log INFO "Reconnaissance phase complete."
}

phase_vuln_assessment() {
    local target="${1:-$TARGET_IP_RANGE}"
    log INFO "${BOLD}[PHASE 2] Starting Vulnerability Assessment${NC}"
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"

    if [[ -f "$WORKSPACE/exploits/cve_automator.py" ]]; then
        log INFO "Running CVE automation engine..."
        python3 "$WORKSPACE/exploits/cve_automator.py" \
            --target "$target" \
            --cvss "${CVSS_THRESHOLD:-7.0}" \
            --threads "${THREADS:-50}" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    log INFO "Vulnerability assessment complete."
}

phase_web_intel() {
    local target_url="${1:-https://$TARGET_DOMAIN}"
    log INFO "${BOLD}[PHASE 3] Starting Web Intelligence${NC}"
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"

    if [[ -f "$WORKSPACE/web_intel/browser_spy.js" ]]; then
        log INFO "Launching browser intelligence on $target_url..."
        (cd "$WORKSPACE/web_intel" && node browser_spy.js \
            --target "$target_url" --xss --screenshot \
            --output "$WORKSPACE/logs/" 2>&1 | tee -a "$LOG_FILE") || true
    fi
    log INFO "Web intelligence complete."
}

phase_collect() {
    log INFO "${BOLD}[PHASE 4] Data Collection & Analysis${NC}"
    echo -e "${CYAN}═════════════════════════════════════════════════${NC}"

    if [[ -f "$DB_PATH" ]]; then
        local report_file="$WORKSPACE/logs/intel_report_${TIMESTAMP}.txt"
        {
            echo "══════════════════════════════════════════════"
            echo " HACKERAI CYBER WARFARE NEXUS - INTEL REPORT"
            echo " Generated: $(date)"
            echo "══════════════════════════════════════════════"
            echo ""
            echo "[LIVE HOSTS]"
            sqlite3 "$DB_PATH" "SELECT ip, hostname, os, last_seen FROM targets ORDER BY last_seen DESC LIMIT 20;" 2>/dev/null || echo "  No data"
            echo ""
            echo "[CRITICAL VULNERABILITIES]"
            sqlite3 "$DB_PATH" "SELECT t.ip, v.cve_id, v.cvss, substr(v.description,1,80) FROM vulnerabilities v JOIN targets t ON t.id=v.target_id WHERE v.cvss >= 7.0 ORDER BY v.cvss DESC LIMIT 20;" 2>/dev/null || echo "  No data"
        } > "$report_file"
        log INFO "Report saved: $report_file"
    fi
    log INFO "Data collection complete."
}

cleanup_trails() {
    log WARN "Running anti-forensics cleanup..."
    history -c 2>/dev/null || true
    > ~/.bash_history 2>/dev/null || true
    rm -rf "$WORKSPACE/web_intel/node_modules" 2>/dev/null || true
    find "$WORKSPACE" -name "*.pyc" -delete 2>/dev/null || true
    log INFO "Cleanup complete."
}

run_full_pipeline() {
    local target_ip="${1:-$TARGET_IP_RANGE}"
    local target_domain="${2:-$TARGET_DOMAIN}"

    print_banner
    log INFO "${BOLD} FULL OFFENSIVE OPERATIONS PIPELINE INITIATED${NC}"

    SECONDS=0
    phase_recon "$target_domain" "$target_ip"
    phase_vuln_assessment "$target_ip"
    phase_web_intel "https://$target_domain"
    phase_collect

    if [[ "${STEALTH_MODE:-}" == "ghost" ]]; then cleanup_trails; fi

    local duration=$SECONDS
    log INFO "${GREEN}${BOLD} OPERATION COMPLETE in $((duration / 60))m $((duration % 60))s${NC}"
    log INFO "${GREEN}${BOLD} Database: $DB_PATH${NC}"
}

# ============================================================================
# MAIN
# ============================================================================

MODE="interactive"
TARGET=""
DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full|--all|-a)    MODE="full"; shift ;;
        --recon|-r)         MODE="recon"; shift ;;
        --web|-w)           MODE="web"; shift ;;
        --collect|-c)       MODE="collect"; shift ;;
        --target|-t)        TARGET="$2"; shift 2 ;;
        --domain|-d)        DOMAIN="$2"; shift 2 ;;
        --stealth|-s)       STEALTH_MODE="${2:-ghost}"; shift 2 ;;
        --cleanup)          CLEANUP=true; shift ;;
        --help|-h)
            echo "Usage: ./warfare.sh [OPTIONS]"
            echo "  --full,-a       Full operations pipeline"
            echo "  --recon,-r      Reconnaissance only"
            echo "  --web,-w        Web intelligence only"
            echo "  --collect,-c    Data collection"
            echo "  --target,-t     Target IP/CIDR"
            echo "  --domain,-d     Target domain"
            echo "  --stealth,-s    Ghost mode"
            echo "  --cleanup       Remove traces"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

print_banner
load_config
check_dependencies
build_core
build_recon
init_database

case "$MODE" in
    full)    run_full_pipeline "${TARGET:-$TARGET_IP_RANGE}" "${DOMAIN:-$TARGET_DOMAIN}" ;;
    recon)   phase_recon "${DOMAIN:-$TARGET_DOMAIN}" "${TARGET:-$TARGET_IP_RANGE}" ;;
    web)     phase_web_intel "https://${DOMAIN:-$TARGET_DOMAIN}" ;;
    collect) phase_collect ;;
    interactive)
        echo -e "${CYAN}${BOLD}Select Mode:${NC}"
        echo "  1) Full Pipeline"
        echo "  2) Reconnaissance"
        echo "  3) Web Intelligence"
        echo "  4) Data Collection"
        echo "  5) Cleanup"
        echo "  0) Exit"
        read -p "Choice [0-5]: " choice
        case "$choice" in
            1) run_full_pipeline "${TARGET:-$TARGET_IP_RANGE}" "${DOMAIN:-$TARGET_DOMAIN}" ;;
            2) phase_recon "${DOMAIN:-$TARGET_DOMAIN}" "${TARGET:-$TARGET_IP_RANGE}" ;;
            3) phase_web_intel "https://${DOMAIN:-$TARGET_DOMAIN}" ;;
            4) phase_collect ;;
            5) cleanup_trails ;;
            0) exit 0 ;;
        esac
        ;;
esac

log INFO "HACKERAI operation completed."
echo -e "${GREEN}${BOLD}[V] Log: ${LOG_FILE}${NC}"
echo -e "${GREEN}${BOLD}[V] Database: ${DB_PATH}${NC}"
