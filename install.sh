#!/bin/bash

# ==============================================================================
#   Hashem — GRE + FRP Reverse Tunnel Automated Setup Script (hashem.sh)
#   Architecture: GRE Layer 3 Tunnel + FRP Reverse TLS Tunnel
#   Tunnel-only edition: NO web panel. Everything is done from this script.
#   Features: Auto Arch Detect, Systemd Auto-start on boot, MTU Clamping, TCP/UDP,
#             FULL UNINSTALL that reverts every change made by this script.
#   One file: interactive menu (`bash hashem.sh`) + non-interactive CLI
#   (`hashem setup-iran ...`) — the old gre.sh name still works as symlink.
# ==============================================================================
# ---- installed names (single source of truth for this script) ----
HASHEM_BIN="/usr/local/bin/hashem"       # this script, after install
HASHEM_SCRIPT="/usr/local/bin/hashem.sh" # versioned copy (gre.sh = legacy alias)

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
DEFAULT_FRP_VERSION="0.71.0"

# Default GRE internal IPs (/30 subnet)
IRAN_GRE_IP="10.10.10.2"
FOREIGN_GRE_IP="10.10.10.1"
TUNNEL_NAME="gre-tunnel"

# State/config dir (name kept for compatibility with existing installs).
STATE_DIR="/etc/gre-panel"
WATCHDOG_FILE="${STATE_DIR}/watchdog.json"
PERF_FILE="${STATE_DIR}/perf.json"
CARRIER_FILE="${STATE_DIR}/carrier.json"
UFW_LEDGER="${STATE_DIR}/ufw-rules.list"     # ufw rules WE added (removed on uninstall)
BACKUP_KEY="${STATE_DIR}/backup.key"         # passphrase for encrypted backups
BACKUP_DIR="/var/backups/hashem"

ensure_hashem_bin() {
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p /usr/local/bin
    if [[ -f "$0" && "$0" != "$HASHEM_BIN" ]]; then
        cp "$0" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN" 2>/dev/null || true
        cp "$0" "$HASHEM_SCRIPT" 2>/dev/null && chmod +x "$HASHEM_SCRIPT" 2>/dev/null || true
        ln -sf "$HASHEM_SCRIPT" /usr/local/bin/gre.sh 2>/dev/null || true
    elif [[ ! -x "$HASHEM_BIN" ]]; then
        local cand
        for cand in "$0" ./hashem.sh /tmp/hashem.sh "$HASHEM_SCRIPT"; do
            if [[ -f "$cand" ]]; then
                cp "$cand" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN" 2>/dev/null || true
                break
            fi
        done
    fi
}
ensure_hashem_bin

LOG_DIR="/var/log/hashem"

# Mask tokens and sensitive credentials in log strings
mask_sensitive() {
    local text="$1"
    echo "$text" | sed -E \
        -e 's/(hsh1_[^_]+_[0-9]+_[^_]+_[^_]+_)[A-Za-z0-9_-]{8,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(--token[[:space:]]+)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(Token:[[:space:]]*)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g'
}

log_msg() {
    local category="${1:-installer}"
    local level="${2:-INFO}"
    local msg="$3"
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    local logfile="${LOG_DIR}/${category}.log"
    local masked
    masked=$(mask_sensitive "$msg")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${masked}" >> "$logfile" 2>/dev/null || true
}

backup_configs() {
    local label="${1:-manual}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local bdir="${BACKUP_DIR}/${ts}_${label}"
    mkdir -p "$bdir" 2>/dev/null || return 1

    # Backup configuration folders
    [[ -d /etc/hashem ]] && cp -rp /etc/hashem "$bdir/" 2>/dev/null || true
    [[ -d "$STATE_DIR" ]] && cp -rp "$STATE_DIR" "$bdir/" 2>/dev/null || true
    [[ -d /etc/frp ]] && cp -rp /etc/frp "$bdir/" 2>/dev/null || true

    # Backup relevant systemd units
    mkdir -p "$bdir/systemd" 2>/dev/null || true
    local u
    for u in /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service; do
        [[ -f "$u" ]] && cp -p "$u" "$bdir/systemd/" 2>/dev/null || true
    done

    echo "$bdir" > "${BACKUP_DIR}/latest" 2>/dev/null || true
    log_msg "installer" "INFO" "Created config backup at $bdir"
    echo "$bdir"
}

rollback_configs() {
    local bdir="$1"
    [[ -z "$bdir" && -f "${BACKUP_DIR}/latest" ]] && bdir=$(cat "${BACKUP_DIR}/latest" 2>/dev/null)
    if [[ -z "$bdir" || ! -d "$bdir" ]]; then
        echo -e "${RED}[!] No valid backup directory found for rollback.${NC}"
        return 1
    fi
    echo -e "${YELLOW}[*] Rolling back configurations from: $bdir ...${NC}"
    log_msg "installer" "WARN" "Initiating rollback from $bdir"

    [[ -d "$bdir/hashem" ]] && cp -rp "$bdir/hashem" /etc/ 2>/dev/null || true
    [[ -d "$bdir/gre-panel" ]] && cp -rp "$bdir/gre-panel" /etc/ 2>/dev/null || true
    [[ -d "$bdir/frp" ]] && cp -rp "$bdir/frp" /etc/ 2>/dev/null || true
    if [[ -d "$bdir/systemd" ]]; then
        cp -p "$bdir/systemd/"* /etc/systemd/system/ 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}[✔️] Rollback completed.${NC}"
    log_msg "installer" "INFO" "Rollback completed successfully"
}

# ---- ufw ledger: remember ONLY the rules this script added, so a full
# uninstall removes exactly those and never touches rules you had before ----
ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"
}

ufw_allow_track() { # $1 = "PORT/proto"
    local RULE=$1
    ufw_active || return 0
    if ufw status 2>/dev/null | grep -qE "^${RULE}[[:space:]]+ALLOW"; then
        return 0   # already open before us — leave it alone, never remove it later
    fi
    ufw allow "$RULE" >/dev/null 2>&1 || return 0
    mkdir -p "$STATE_DIR"
    grep -qxF "$RULE" "$UFW_LEDGER" 2>/dev/null || echo "$RULE" >> "$UFW_LEDGER"
}

ufw_revert_tracked() {
    command -v ufw >/dev/null 2>&1 || return 0
    local RULE p f
    if [[ -f "$UFW_LEDGER" ]]; then
        while IFS= read -r RULE; do
            [[ -n "$RULE" ]] || continue
            ufw --force delete allow "$RULE" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ufw rule removed: ${RULE}${NC}"
        done < "$UFW_LEDGER"
        rm -f "$UFW_LEDGER"
    else
        # older install without a ledger: only the FRP control ports are unambiguously ours
        for f in "${CONFIG_DIR}"/frps*.toml; do
            [[ -f "$f" ]] || continue
            p=$(awk -F= '/^[[:space:]]*bindPort/{gsub(/[ "\r]/,"",$2); print $2}' "$f" 2>/dev/null)
            [[ -n "$p" ]] && ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ufw rule removed: ${p}/tcp${NC}"
        done
    fi
    return 0
}

ensure_dependencies_smart() {
    local missing_pkgs=()
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v tar >/dev/null 2>&1 || missing_pkgs+=("tar")
    command -v iptables >/dev/null 2>&1 || missing_pkgs+=("iptables")
    command -v systemctl >/dev/null 2>&1 || missing_pkgs+=("systemd")
    command -v python3 >/dev/null 2>&1 || missing_pkgs+=("python3")
    command -v ping >/dev/null 2>&1 || missing_pkgs+=("iputils-ping")
    command -v ss >/dev/null 2>&1 || missing_pkgs+=("iproute2")

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        echo -e "${GREEN}[✔️] All system dependencies are satisfied.${NC}"
        return 0
    fi

    local uniq_pkgs
    uniq_pkgs=$(printf "%s\n" "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    echo -e "${CYAN}[*] Installing missing dependencies: ${uniq_pkgs}...${NC}"
    log_msg "installer" "INFO" "Installing missing dependencies: ${uniq_pkgs}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq $uniq_pkgs || {
            echo -e "${RED}[!] Failed to install some dependencies via apt-get: ${uniq_pkgs}${NC}"
            return 1
        }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q $uniq_pkgs || true
    fi
    echo -e "${GREEN}[✔️] Missing dependencies installed successfully.${NC}"
}

is_port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn "sport = :$port" 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1 && return 0
    fi
    return 1
}

diagnose_port_process() {
    local port=$1
    echo -e "${CYAN}=== Diagnosing Process Holding Port :$port ===${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn "sport = :$port" 2>/dev/null
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" 2>/dev/null
    elif command -v fuser >/dev/null 2>&1; then
        fuser "$port/tcp" 2>/dev/null
    fi
    echo -e "${CYAN}=============================================${NC}"
}

# NOTE: callers capture stdout with $(...) — the final "echo $port" is the ONLY
# thing allowed on stdout; every message goes to stderr.
ensure_port_available() {
    local port=$1
    local purpose=${2:-"Required port"}
    local is_bundle=${3:-0}

    while is_port_in_use "$port"; do
        echo -e "${YELLOW}[!] WARNING: ${purpose} ${port} is already in use by another process.${NC}" >&2
        log_msg "tunnel" "WARN" "${purpose} ${port} is in use"
        if [[ ! -t 0 ]]; then
            echo -e "${CYAN}[*] Non-interactive mode: continuing despite port conflict (service will try to start anyway).${NC}" >&2
            echo "$port"
            return 0
        fi
        {
            echo "Options:"
            echo "  1) Retry (after stopping conflicting process)"
            echo "  2) Diagnose process"
            echo "  3) Cancel"
            if [[ "$is_bundle" -ne 1 ]]; then
                echo "  4) Choose another port"
            else
                echo "  4) Explicitly choose another port (override bundle)"
            fi
        } >&2
        read -p "Select option [1-4]: " P_OPT || return 1
        case "$P_OPT" in
            1)
                continue
                ;;
            2)
                diagnose_port_process "$port" >&2
                echo "" >&2
                ;;
            3)
                return 1
                ;;
            4)
                prompt_port NEW_PORT "Enter new ${purpose}" "$(gen_random_port)" >&2 || return 1
                port=$NEW_PORT
                ;;
            *)
                echo -e "${RED}[!] Invalid option.${NC}" >&2
                ;;
        esac
    done
    echo "$port"
    return 0
}

cli_bundle_inspect() {
    local BUNDLE="" SHOW_TOKEN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --show-token|-s) SHOW_TOKEN=1; shift ;;
            hsh1_*) BUNDLE="$1"; shift ;;
            *) BUNDLE="$1"; shift ;;
        esac
    done
    if [[ -z "$BUNDLE" ]]; then
        read -p "Enter setup bundle (hsh1_...): " BUNDLE || return 1
    fi
    if ! bundle_parse "$BUNDLE"; then
        echo -e "${RED}[!] Invalid bundle format. Expected: hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>][_fou<P1>-<P2>]${NC}"
        return 1
    fi

    local DISP_TOKEN="******************************** (Masked, pass --show-token to reveal)"
    if [[ "$SHOW_TOKEN" -eq 1 ]]; then
        DISP_TOKEN="$B_TOKEN"
    fi

    echo -e "\n${CYAN}=============================================================="
    echo "                 HASHEM TUNNEL BUNDLE INSPECT"
    echo -e "==============================================================${NC}"
    echo -e "Bundle Version:        ${GREEN}hsh1${NC}"
    echo -e "Iran Public IP:        ${CYAN}${B_IRAN_PUB}${NC}"
    echo -e "FRP Server Port:       ${CYAN}${B_FRP_PORT}${NC} (serverPort / bindPort)"
    echo -e "Iran GRE Internal IP:  ${CYAN}${B_IRAN_GRE}${NC}"
    echo -e "Foreign GRE IP:        ${CYAN}${B_FOREIGN_GRE}${NC}"
    echo -e "Reverse Proxy Ports:   ${CYAN}${B_PORTS:-None (Manual configuration)}${NC}"
    echo -e "FOU UDP Ports:         ${CYAN}${B_FOU_P1}, ${B_FOU_P2}${NC}"
    echo -e "Auth Token:            ${YELLOW}${DISP_TOKEN}${NC}"
    echo -e "Source of Truth:       ${GREEN}Enforced on Foreign Server${NC}"
    echo -e "${CYAN}==============================================================${NC}\n"
    return 0
}

# ---- Performance / Obfuscation Configuration (/etc/gre-panel/perf.json) ----
init_perf_json() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$PERF_FILE" ]]; then
        cat << 'EOF' > "$PERF_FILE"
{
  "proxy_encryption": false,
  "proxy_compression": false,
  "force_tls": false,
  "chaff_profile": "off",
  "dpi_enabled": false,
  "dpi_rate": "60/sec",
  "dpi_burst": 120
}
EOF
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

# $1 = json key, $2 = env override (may be empty). Prints 1 or 0.
_perf_bool() {
    if [[ -n "${2:-}" ]]; then
        [[ "$2" == "1" || "$2" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        PERF_F="$PERF_FILE" PERF_K="$1" python3 -c '
import json, os
try:
    with open(os.environ["PERF_F"]) as f:
        print(1 if json.load(f).get(os.environ["PERF_K"], False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    elif [[ -f "$PERF_FILE" ]]; then
        grep -q "\"$1\"[[:space:]]*:[[:space:]]*true" "$PERF_FILE" && echo 1 || echo 0
        return 0
    fi
    echo 0
}

perf_get_enc() { _perf_bool proxy_encryption "${PERF_ENC:-}"; }
perf_get_comp() { _perf_bool proxy_compression "${PERF_COMP:-}"; }
perf_get_tls() { _perf_bool force_tls "${PERF_TLS:-}"; }
perf_get_dpi_enabled() { _perf_bool dpi_enabled "${PERF_DPI:-}"; }

perf_get_chaff() {
    if [[ -n "${CHAFF_PROFILE:-}" ]]; then
        echo "$CHAFF_PROFILE"
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        p = json.load(f).get("chaff_profile", "off")
        print(p if p in ("off", "low", "mid") else "off")
except Exception:
    print("off")
' 2>/dev/null && return 0
    fi
    echo "off"
}

perf_get_dpi_rate() {
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        r = json.load(f).get("dpi_rate", "60/sec")
        print(r if r else "60/sec")
except Exception:
    print("60/sec")
' 2>/dev/null && return 0
    fi
    echo "60/sec"
}

perf_get_dpi_burst() {
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        b = json.load(f).get("dpi_burst", 120)
        print(int(b) if int(b) > 0 else 120)
except Exception:
    print(120)
' 2>/dev/null && return 0
    fi
    echo 120
}

perf_get_max_pool() {
    local V=50
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        V=$(python3 -c "import json; print(int(json.load(open('$PERF_FILE')).get('frp_max_pool', 50)))" 2>/dev/null || echo 50)
    fi
    [[ "$V" =~ ^[0-9]+$ ]] || V=50
    echo "$V"
}

perf_set_val() {
    local key="$1" val="$2" is_raw="${3:-0}"
    init_perf_json
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
path = "'"$PERF_FILE"'"
key = "'"$key"'"
raw = '"$is_raw"'
val_str = """'"$val"'"""
try:
    with open(path, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if raw:
    if val_str in ("true", "True", "1"):
        d[key] = True
    elif val_str in ("false", "False", "0"):
        d[key] = False
    else:
        try:
            d[key] = int(val_str)
        except Exception:
            d[key] = val_str
else:
    d[key] = val_str
with open(path, "w") as f:
    json.dump(d, f, indent=2)
'
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

# ---- input validation (IPv4, port 1-65535) ----
is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. a b c d o
    read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        ((10#$o <= 255)) || return 1
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

gen_token32() { # 32-char alphanumeric secret (FRP auth token)
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32 2>/dev/null || openssl rand -hex 16
}

gen_random_port() { # random port 20000-60000 for FRP
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-60000 -n 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import random; print(random.randint(20000, 60000))'
    else
        awk 'BEGIN{srand(); print int(20000 + rand() * 40001)}'
    fi
}

# ---- Carrier & Multi-Protocol Failover (Direct GRE <-> FOU UDP) ----
init_carrier_json() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$CARRIER_FILE" ]]; then
        cat << 'EOF' > "$CARRIER_FILE"
{
  "mode": "auto",
  "active_carrier": "direct",
  "fou_port1": 443,
  "fou_port2": 55555,
  "candidates": [
    "direct",
    "fou:443",
    "fou:55555"
  ],
  "last_switch": "",
  "switch_count": 0
}
EOF
        chmod 600 "$CARRIER_FILE" 2>/dev/null || true
    fi
}

carrier_get_mode() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        print(json.load(f).get("mode", "auto"))
except Exception:
    print("auto")
' 2>/dev/null || echo "auto"
}

carrier_get_active() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        print(json.load(f).get("active_carrier", "direct"))
except Exception:
    print("direct")
' 2>/dev/null || echo "direct"
}

carrier_get_fou_ports() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
        p1 = d.get("fou_port1", 443)
        p2 = d.get("fou_port2", 55555)
        print(f"{p1} {p2}")
except Exception:
    print("443 55555")
' 2>/dev/null || echo "443 55555"
}

carrier_set_mode() {
    local M="$1"
    [[ "$M" == "auto" || "$M" == "direct" || "$M" == fou:* || "$M" == wss* ]] || return 1
    init_carrier_json
    python3 -c '
import json, sys
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["mode"] = sys.argv[1]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$M" 2>/dev/null || true
}

carrier_set_fou_ports() {
    local P1=$1 P2=$2
    is_valid_port "$P1" || return 1
    is_valid_port "$P2" || return 1
    init_carrier_json
    python3 -c '
import json, sys
p = "'"$CARRIER_FILE"'"
p1 = int(sys.argv[1])
p2 = int(sys.argv[2])
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
wp = d.get("wss_port", 8443)
d["fou_port1"] = p1
d["fou_port2"] = p2
d["candidates"] = ["direct", f"fou:{p1}", f"fou:{p2}", f"wss:{wp}"]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$P1" "$P2" 2>/dev/null || true
}

carrier_init_kernel() {
    modprobe fou >/dev/null 2>&1 || true
    modprobe ip_gre >/dev/null 2>&1 || true
    local P1 P2
    read -r P1 P2 <<< "$(carrier_get_fou_ports)"
    if is_valid_port "$P1"; then
        ip fou add port "$P1" ipproto 47 >/dev/null 2>&1 || true
        iptables -C INPUT -p udp --dport "$P1" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT 1 -p udp --dport "$P1" -j ACCEPT >/dev/null 2>&1 || true
        ufw_allow_track "${P1}/udp"
    fi
    if is_valid_port "$P2" && [[ "$P2" != "$P1" ]]; then
        ip fou add port "$P2" ipproto 47 >/dev/null 2>&1 || true
        iptables -C INPUT -p udp --dport "$P2" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT 1 -p udp --dport "$P2" -j ACCEPT >/dev/null 2>&1 || true
        ufw_allow_track "${P2}/udp"
    fi
    ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
}

carrier_apply() {
    local TARGET="$1"
    local SPECIFIC_IF="${2:-}"
    [[ -z "$TARGET" ]] && TARGET="direct"
    carrier_init_kernel

    local IFS_TO_APPLY=()
    local dev
    if [[ -n "$SPECIFIC_IF" ]]; then
        IFS_TO_APPLY+=("$SPECIFIC_IF")
    else
        for dev in $(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            [[ "$dev" == "gre0" || "$dev" == "gretap0" ]] && continue
            IFS_TO_APPLY+=("$dev")
        done
        if [[ ${#IFS_TO_APPLY[@]} -eq 0 ]]; then
            IFS_TO_APPLY+=("$TUNNEL_NAME")
        fi
    fi

    local ANY_APPLIED=0
    for dev in "${IFS_TO_APPLY[@]}"; do
        if ip link show "$dev" >/dev/null 2>&1; then
            # Record current IPv4 address so it can NEVER be lost when toggling state
            local DEV_IP=""
            DEV_IP=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
            if [[ -z "$DEV_IP" ]]; then
                if [[ "$dev" == "$TUNNEL_NAME" ]]; then
                    if [[ -f "/etc/frp/frps.toml" ]]; then
                        DEV_IP="10.10.10.2/30"
                    elif [[ -f "/etc/frp/frpc.toml" ]]; then
                        DEV_IP="10.10.10.1/30"
                    fi
                fi
            fi

            local TARGET_MTU=1380
            [[ "$TARGET" == wss* ]] && TARGET_MTU=1360

            local CHANGED=0
            if [[ "$TARGET" == "direct" ]]; then
                if ip link set dev "$dev" type gre encap none >/dev/null 2>&1; then
                    CHANGED=1
                else
                    ip link set dev "$dev" down >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap none >/dev/null 2>&1; then
                        CHANGED=1
                    fi
                fi
                ANY_APPLIED=1
            elif [[ "$TARGET" == fou:* ]]; then
                local DPORT="${TARGET#fou:}"
                if is_valid_port "$DPORT"; then
                    ip fou add port "$DPORT" ipproto 47 >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1; then
                        CHANGED=1
                    else
                        ip link set dev "$dev" down >/dev/null 2>&1 || true
                        if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1; then
                            CHANGED=1
                        fi
                    fi
                    ANY_APPLIED=1
                fi
            elif [[ "$TARGET" == wss* ]]; then
                ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
                if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport 19998 >/dev/null 2>&1; then
                    CHANGED=1
                else
                    ip link set dev "$dev" down >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport 19998 >/dev/null 2>&1; then
                        CHANGED=1
                    fi
                fi
                ANY_APPLIED=1
            fi

            # If dynamic changelink is unsupported by this kernel, re-instantiate cleanly in-place
            if [[ "$CHANGED" -eq 0 ]]; then
                local REMOTE_PUB LOCAL_PUB
                REMOTE_PUB=$(ip tunnel show "$dev" 2>/dev/null | awk '/remote/ {for(i=1;i<=NF;i++) if($i=="remote") print $(i+1)}' | head -1)
                LOCAL_PUB=$(ip tunnel show "$dev" 2>/dev/null | awk '/local/ {for(i=1;i<=NF;i++) if($i=="local") print $(i+1)}' | head -1)
                if [[ -n "$REMOTE_PUB" ]]; then
                    ip tunnel del "$dev" >/dev/null 2>&1 || ip link del "$dev" >/dev/null 2>&1 || true
                    local LOCAL_OPTS=""
                    [[ -n "$LOCAL_PUB" && "$LOCAL_PUB" != "any" ]] && LOCAL_OPTS="local $LOCAL_PUB"
                    if [[ "$TARGET" == "direct" ]]; then
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 >/dev/null 2>&1 || true
                    elif [[ "$TARGET" == fou:* ]]; then
                        local DPORT="${TARGET#fou:}"
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1 || true
                    elif [[ "$TARGET" == wss* ]]; then
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 encap fou encap-sport auto encap-dport 19998 >/dev/null 2>&1 || true
                    fi
                    ANY_APPLIED=1
                fi
            fi

            # Always bring interface up with proper MTU and restore inner IPv4 address
            ip link set dev "$dev" up mtu "$TARGET_MTU" >/dev/null 2>&1 || true
            if [[ -n "$DEV_IP" ]]; then
                if ! ip -o -4 addr show dev "$dev" 2>/dev/null | grep -q "${DEV_IP%/*}"; then
                    ip addr add "$DEV_IP" dev "$dev" >/dev/null 2>&1 || true
                fi
            fi
            iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
                iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
        fi
    done

    python3 -c '
import json, time, sys
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["active_carrier"] = sys.argv[1]
d["last_switch"] = time.strftime("%Y-%m-%d %H:%M:%S")
d["switch_count"] = int(d.get("switch_count", 0)) + 1
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$TARGET" 2>/dev/null || true

    if [[ $ANY_APPLIED -eq 1 ]]; then
        return 0
    fi
    # Don't call systemctl restart recursively if invoked from a systemd service hook
    if [[ -z "${SYSTEMD_EXEC_PID:-}" && -z "${INVOCATION_ID:-}" && -n "${IFS_TO_APPLY[0]:-}" ]]; then
        systemctl restart "${IFS_TO_APPLY[0]}.service" >/dev/null 2>&1 || true
    fi
    return 0
}

carrier_apply_active() {
    local IFNAME="${1:-}"
    local ACT
    ACT=$(carrier_get_active)
    carrier_apply "$ACT" "$IFNAME"
}

carrier_cycle_next() {
    init_carrier_json
    local NEXT
    NEXT=$(python3 -c '
import json
path = "'"$CARRIER_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    cur = d.get("active_carrier", "direct")
    p1 = d.get("fou_port1", 443)
    p2 = d.get("fou_port2", 55555)
    wp = d.get("wss_port", 8443)
    cands = d.get("candidates", ["direct", f"fou:{p1}", f"fou:{p2}", f"wss:{wp}"])
    if cur in cands:
        idx = (cands.index(cur) + 1) % len(cands)
        next_cand = cands[idx]
    else:
        next_cand = cands[0] if cands else "direct"
    print(next_cand)
except Exception:
    print("direct")
' 2>/dev/null || echo "direct")

    carrier_apply "$NEXT" >/dev/null 2>&1
    echo "$NEXT"
}

# ---- setup bundle: one readable string with everything foreign needs ----
# Format: hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>][_fou<P1>-<P2>]
BUNDLE_PREFIX="hsh1_"
bundle_make() { # $1=iran_pub $2=frp_port $3=iran_gre $4=foreign_gre $5=token [$6="p1 p2"] [$7="p1-p2"]
    local IRAN_PUB=$1 FRP_PORT=$2 IRAN_GRE=$3 FOREIGN_GRE=$4 TOKEN=$5 PORTS_SP=${6:-} FOU_ARG=${7:-}
    local PORTS_DASH=""
    if [[ -n "$PORTS_SP" ]]; then
        PORTS_DASH=$(echo "$PORTS_SP" | xargs | tr ' ' '-')
    fi
    if [[ -z "$FOU_ARG" ]]; then
        local P1 P2
        read -r P1 P2 <<< "$(carrier_get_fou_ports 2>/dev/null || echo '443 55555')"
        FOU_ARG="${P1}-${P2}"
    fi
    if [[ -n "$PORTS_DASH" ]]; then
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}_${PORTS_DASH}_fou${FOU_ARG}"
    else
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}__fou${FOU_ARG}"
    fi
}
bundle_parse() {
    B_IRAN_PUB=""; B_FRP_PORT=""; B_IRAN_GRE=""; B_FOREIGN_GRE=""; B_TOKEN=""; B_PORTS=""; B_FOU_P1=443; B_FOU_P2=55555
    local IN=$1 rest a b c d e f g
    [[ "$IN" == ${BUNDLE_PREFIX}* ]] || return 1
    rest=${IN#${BUNDLE_PREFIX}}
    IFS=_ read -r a b c d e f g <<<"$rest"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" ]] || return 1
    is_valid_ip "$a" || return 1
    is_valid_port "$b" || return 1
    is_valid_ip "$c" || return 1
    is_valid_ip "$d" || return 1
    [[ ${#e} -ge 1 && ${#e} -le 128 ]] || return 1
    local CLEANED="" p
    if [[ -n "${f:-}" && "$f" != fou* ]]; then
        for p in $(echo "$f" | tr -- '-,' '  '); do
            is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"
        done
        CLEANED=$(echo "$CLEANED" | xargs)
        [[ -n "$CLEANED" ]] || return 1
    fi
    local FOU_RAW="${g:-}"
    if [[ -z "$FOU_RAW" && "${f:-}" == fou* ]]; then
        FOU_RAW="$f"
    fi
    if [[ -n "$FOU_RAW" && "$FOU_RAW" == fou* ]]; then
        local FP1 FP2
        IFS=- read -r FP1 FP2 <<< "${FOU_RAW#fou}"
        is_valid_port "$FP1" && B_FOU_P1=$((10#$FP1))
        is_valid_port "$FP2" && B_FOU_P2=$((10#$FP2))
    fi
    B_IRAN_PUB=$a; B_FRP_PORT=$((10#$b)); B_IRAN_GRE=$c; B_FOREIGN_GRE=$d; B_TOKEN=$e; B_PORTS=$CLEANED
    return 0
}

# ---- interactive prompts (return 1 on EOF / Ctrl+D instead of looping forever) ----
prompt_ip() { # $1=varname $2=label $3=default (empty = required)
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        if [[ -n "$__def" ]]; then
            read -p "$__label [Default: $__def]: " __in || { echo; return 1; }
            __in=${__in:-$__def}
        else
            read -p "$__label: " __in || { echo; return 1; }
        fi
        if is_valid_ip "$__in"; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] Invalid IPv4 address: '${__in}'. Example: 203.0.113.10${NC}"
    done
}

prompt_port() { # $1=varname $2=label $3=default
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -p "$__label [Default: $__def]: " __in || { echo; return 1; }
        __in=${__in:-$__def}
        if is_valid_port "$__in"; then printf -v "$__var" '%s' "$((10#$__in))"; return 0; fi
        echo -e "${RED}[!] Invalid port: '${__in}'. Must be 1-65535.${NC}"
    done
}

prompt_required() { # $1=varname $2=label — must be non-empty
    local __var=$1 __label=$2 __in
    while true; do
        read -p "$__label: " __in || { echo; return 1; }
        if [[ -n "$__in" ]]; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] This field is required and cannot be empty.${NC}"
    done
}

prompt_token() { # $1=varname $2=label $3=default (empty accepts default)
    local __var=$1 __label=$2 __def=$3 __in
    read -p "$__label [Press Enter for: $__def]: " __in || { echo; return 1; }
    printf -v "$__var" '%s' "${__in:-$__def}"
}

prompt_ports() { # $1=varname $2=label — at least one valid port
    local __var=$1 __label=$2 __in __ok p
    while true; do
        read -p "$__label (e.g. 443, 2083, 8080): " __in || { echo; return 1; }
        __ok=""
        for p in $(echo "$__in" | tr ',' ' '); do
            is_valid_port "$p" && __ok="$__ok $((10#$p))"
        done
        __ok=$(echo "$__ok" | xargs)
        if [[ -n "$__ok" ]]; then printf -v "$__var" '%s' "$__ok"; return 0; fi
        echo -e "${RED}[!] Enter at least one valid port (1-65535).${NC}"
    done
}

# validate_setup_common checks non-interactive args with the same rules as
# the prompts above. Prints a clear error per bad field, returns non-zero.
validate_setup_common() { # $1=local_pub $2=remote_pub $3=frp_port $4=local_gre
    local ok=1
    is_valid_ip "$1" || { echo -e "${RED}[!] Invalid local public IP: '$1'${NC}"; ok=0; }
    is_valid_ip "$2" || { echo -e "${RED}[!] Invalid remote public IP: '$2'${NC}"; ok=0; }
    is_valid_port "$3" || { echo -e "${RED}[!] Invalid FRP port: '$3' (must be 1-65535)${NC}"; ok=0; }
    is_valid_ip "$4" || { echo -e "${RED}[!] Invalid local GRE IP: '$4'${NC}"; ok=0; }
    return $((1 - ok))
}

tunnel_present() {
    ip link show "$TUNNEL_NAME" >/dev/null 2>&1 && return 0
    ip tunnel show 2>/dev/null | grep -q "$TUNNEL_NAME" && return 0
    [[ -f "${CONFIG_DIR}/frps.toml" || -f "${CONFIG_DIR}/frpc.toml" ]] && return 0
    return 1
}

check_root() {
    [[ "${HASHEM_NO_ROOT_CHECK:-0}" == "1" ]] && return 0
    if [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            FRP_ARCH="amd64"
            ;;
        aarch64|arm64)
            FRP_ARCH="arm64"
            ;;
        armv7l|armhf)
            FRP_ARCH="arm"
            ;;
        *)
            echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"
            return 1
            ;;
    esac
}

get_latest_frp_version() {
    LATEST_VER=$(curl -sSL --max-time 5 "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        FRP_VERSION="$DEFAULT_FRP_VERSION"
    else
        FRP_VERSION="$LATEST_VER"
    fi
}

download_with_fallback() {
    local DEST="$1"
    local URL="$2"
    local TIMEOUT="${3:-45}"

    # Try direct URL first
    if curl -fsSL --max-time "$TIMEOUT" -o "$DEST" "$URL" 2>/dev/null && [[ -s "$DEST" ]]; then
        return 0
    fi

    # Iran-friendly GitHub proxy mirrors if it is a GitHub URL
    if [[ "$URL" == https://github.com/* || "$URL" == https://raw.githubusercontent.com/* ]]; then
        echo -e "${YELLOW}[*] Direct download timed out / blocked — trying Iran proxy mirror...${NC}"
        local MIRRORS=(
            "https://ghproxy.net/${URL}"
            "https://mirror.ghproxy.com/${URL}"
            "https://gh.ddlc.top/${URL}"
        )
        local M
        for M in "${MIRRORS[@]}"; do
            if curl -fsSL --max-time "$TIMEOUT" -o "$DEST" "$M" 2>/dev/null && [[ -s "$DEST" ]]; then
                echo -e "${GREEN}[✔️] Download succeeded via mirror: ${M%/*}${NC}"
                return 0
            fi
        done
    fi
    return 1
}

install_frp_binaries() {
    # already installed → reuse (add-peer must not re-download FRP per peer).
    if [[ -x "${INSTALL_DIR}/frps" && -x "${INSTALL_DIR}/frpc" ]]; then
        return 0
    fi
    detect_arch || return 1
    get_latest_frp_version
    echo -e "${CYAN}[*] Downloading FRP v${FRP_VERSION} (${FRP_ARCH})...${NC}"

    mkdir -p "$CONFIG_DIR"
    local TMP_DIR TAR_FILE DOWNLOAD_URL EXTRACTED_DIR
    TMP_DIR=$(mktemp -d)
    TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TAR_FILE}"

    if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL" 60; then
        echo -e "${RED}[!] Failed to download FRP from GitHub or mirrors.${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    tar -xzf "${TMP_DIR}/${TAR_FILE}" -C "$TMP_DIR"
    EXTRACTED_DIR="${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}"

    cp "${EXTRACTED_DIR}/frps" "$INSTALL_DIR/" 2>/dev/null
    cp "${EXTRACTED_DIR}/frpc" "$INSTALL_DIR/" 2>/dev/null
    chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"

    rm -rf "$TMP_DIR"
    echo -e "${GREEN}[✔️] FRP installed to ${INSTALL_DIR}.${NC}"
}

setup_gre_systemd() {
    setup_gre_iface "$TUNNEL_NAME" "$1" "$2" "$3" "$4"
}

# Generalized GRE interface setup: $1=ifname $2=local_pub $3=remote_pub $4=inner_ip.
# setup_gre_systemd() above is the legacy single-tunnel wrapper; peers call this
# directly with gre-tN names so every tunnel is the same GRE, just N of them.
setup_gre_iface() {
    local IFNAME=$1
    local LOCAL_IP=$2
    local REMOTE_IP=$3
    local GRE_INTERNAL_IP=$4
    local PEER_INNER=$5

    echo -e "${CYAN}[*] Configuring persistent GRE tunnel service (${IFNAME})...${NC}"

    ensure_hashem_bin

    local IP_BIN
    IP_BIN=$(command -v ip || echo "/sbin/ip")
    modprobe ip_gre >/dev/null 2>&1 || true
    modprobe fou >/dev/null 2>&1 || true

    # Tear down existing if present
    "$IP_BIN" link del "$IFNAME" >/dev/null 2>&1 || "$IP_BIN" tunnel del "$IFNAME" >/dev/null 2>&1 || true

    # Intelligent NAT / local IP handling:
    # If LOCAL_IP is not bound directly to a local interface (common on cloud/NAT VPS in Iran),
    # binding explicitly causes Linux kernel EADDRNOTAVAIL (Cannot assign requested address).
    # In that case, use the interface IP that routes to REMOTE_IP, or wildcard (omit local).
    local LOCAL_ARG=""
    if [[ -n "$LOCAL_IP" ]] && "$IP_BIN" -o addr show 2>/dev/null | grep -qw "$LOCAL_IP"; then
        LOCAL_ARG="local ${LOCAL_IP}"
    else
        local NIC_IP
        NIC_IP=$("$IP_BIN" route get "$REMOTE_IP" 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        if [[ -n "$NIC_IP" ]] && "$IP_BIN" -o addr show 2>/dev/null | grep -qw "$NIC_IP"; then
            LOCAL_ARG="local ${NIC_IP}"
        else
            LOCAL_ARG=""
        fi
    fi

    if [[ -z "$PEER_INNER" ]]; then
        if [[ "$GRE_INTERNAL_IP" =~ \.2$ ]]; then
            PEER_INNER="${GRE_INTERNAL_IP%.*}.1"
        else
            PEER_INNER="${GRE_INTERNAL_IP%.*}.2"
        fi
    fi

    # Create systemd service for GRE
    # Robust architecture:
    # 1. Multi-fallback: try netlink `ip link add` (modern), then `ip tunnel add` (ioctl),
    #    and if local address binding failed due to NAT/routing, retry without local arg.
    # 2. Fixed TTL (255) without incompatible nopmtudisc.
    # 3. Wrap hooks in /bin/sh -c with [ -x ... ] checks so systemd never exits with status 203/EXEC.
    # 4. Use addr replace / add to avoid failure when address is already assigned.
    # 5. Add direct point-to-point /32 route to the peer inner GRE IP.
    cat <<EOF > /etc/systemd/system/${IFNAME}.service
[Unit]
Description=GRE Tunnel Interface
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/bin/sh -c "modprobe ip_gre 2>/dev/null; modprobe fou 2>/dev/null; if [ -x /usr/local/bin/hashem ]; then /usr/local/bin/hashem carrier-kernel-init 2>/dev/null; fi; true"
ExecStartPre=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"
ExecStart=/bin/sh -c '(\
    ${IP_BIN} link add ${IFNAME} type gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} link add ${IFNAME} type gre remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre remote ${REMOTE_IP} ttl 255 2>/dev/null || true); \
    ${IP_BIN} link set dev ${IFNAME} up mtu 1380 && \
    (${IP_BIN} addr replace ${GRE_INTERNAL_IP}/30 dev ${IFNAME} 2>/dev/null || ${IP_BIN} addr add ${GRE_INTERNAL_IP}/30 dev ${IFNAME} 2>/dev/null || true) && \
    (${IP_BIN} route replace ${PEER_INNER}/32 dev ${IFNAME} 2>/dev/null || true)'
ExecStartPost=-/bin/sh -c "if [ -x /usr/local/bin/hashem ]; then /usr/local/bin/hashem carrier-apply-active ${IFNAME} 2>/dev/null; fi; true"
ExecStop=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl reset-failed "${IFNAME}.service" >/dev/null 2>&1 || true
    systemctl enable "${IFNAME}.service" >/dev/null 2>&1
    local GRE_STARTED=0
    if systemctl restart "${IFNAME}.service" >/dev/null 2>&1; then
        if "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 && "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${GRE_INTERNAL_IP%/*}"; then
            GRE_STARTED=1
        fi
    fi

    if [[ "$GRE_STARTED" -ne 1 ]]; then
        # Direct fallback in bash if systemctl restart did not bring up interface
        "$IP_BIN" link del "$IFNAME" >/dev/null 2>&1 || "$IP_BIN" tunnel del "$IFNAME" >/dev/null 2>&1 || true
        ( "$IP_BIN" link add "$IFNAME" type gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" link add "$IFNAME" type gre remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre remote "$REMOTE_IP" ttl 255 2>/dev/null || true )
        "$IP_BIN" link set dev "$IFNAME" up mtu 1380 >/dev/null 2>&1 || true
        ( "$IP_BIN" addr replace "${GRE_INTERNAL_IP}/30" dev "$IFNAME" 2>/dev/null || "$IP_BIN" addr add "${GRE_INTERNAL_IP}/30" dev "$IFNAME" 2>/dev/null || true )
        ( "$IP_BIN" route replace "${PEER_INNER}/32" dev "$IFNAME" 2>/dev/null || true )

        if "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 && "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${GRE_INTERNAL_IP%/*}"; then
            GRE_STARTED=1
        fi
    fi

    if [[ "$GRE_STARTED" -ne 1 ]]; then
        echo -e "${RED}[!] GRE interface ${IFNAME} failed to start — check: ip tunnel show; journalctl -u ${IFNAME}.service${NC}"
        journalctl -u "${IFNAME}.service" -n 5 --no-pager 2>/dev/null || true
        return 1
    fi

    carrier_apply_active "${IFNAME}" >/dev/null 2>&1 || true

    # Enable packet forwarding & MSS clamping to avoid fragmentation
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340

    echo -e "${GREEN}[✔️] GRE Tunnel service active with IP ${GRE_INTERNAL_IP} (MTU 1380, MSS 1340).${NC}"
}

# ---- Traffic Obfuscation / Chaff Service (idle gap filler) ----
CHAFF_BIN="/usr/local/bin/hashem-chaff.sh"

install_chaff_script() {
    cat <<'EOF' > "$CHAFF_BIN"
#!/usr/bin/env bash
# /usr/local/bin/hashem-chaff.sh - GRE tunnel idle-gap chaff generator

PEER_IP="${1:-}"
if [[ -z "$PEER_IP" ]]; then
    echo "Usage: $0 <peer_inner_ip> [low|mid]" >&2
    exit 1
fi

PROFILE="${2:-${CHAFF_PROFILE:-low}}"

trap 'exit 0' SIGTERM SIGINT

while true; do
    if [[ "$PROFILE" == "mid" ]]; then
        # mid: intervals 0.15-1.2s, size 200-1280 (fits within MTU 1380)
        ms=$(( 150 + RANDOM % 1051 ))
        sleep_sec=$(printf "%d.%03d" $((ms / 1000)) $((ms % 1000)))
        size=$(( 200 + RANDOM % 1081 ))
    else
        # low (default): intervals 0.4-2.8s, size 64-1200
        ms=$(( 400 + RANDOM % 2401 ))
        sleep_sec=$(printf "%d.%03d" $((ms / 1000)) $((ms % 1000)))
        size=$(( 64 + RANDOM % 1137 ))
    fi

    sleep "$sleep_sec"

    # 16 random hex bytes (32 hex characters)
    pattern=$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)

    ping -c1 -W1 -s "$size" -p "$pattern" "$PEER_IP" >/dev/null 2>&1 || true
done
EOF
    chmod +x "$CHAFF_BIN"
}

# setup_chaff: $1=ifname_suffix("" for legacy, "-N" for peers) $2=peer_gre_ip
setup_chaff() {
    local SUF=$1 PEER_GRE=$2
    local PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    if [[ "$PROFILE" == "off" ]]; then
        return 0
    fi
    is_valid_ip "$PEER_GRE" || return 1
    install_chaff_script || return 1

    local SVC="gre-chaff"
    local GRE_IF="$TUNNEL_NAME"
    if [[ -n "$SUF" ]]; then
        local ID="${SUF#-}"
        SVC="gre-chaff-${ID}"
        GRE_IF="gre-t${ID}"
    fi

    local AFTER_GRE=""
    if [[ -f "/etc/systemd/system/${GRE_IF}.service" ]]; then
        AFTER_GRE=" ${GRE_IF}.service"
    fi

    cat <<EOF > "/etc/systemd/system/${SVC}.service"
[Unit]
Description=GRE Tunnel Chaff Service (idle gap filler)${SUF:+ (peer${SUF#-})}
After=network.target${AFTER_GRE}
${AFTER_GRE:+Wants=${GRE_IF}.service}

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
ExecStart=${CHAFF_BIN} ${PEER_GRE} ${PROFILE}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SVC}.service" >/dev/null 2>&1
    systemctl restart "${SVC}.service" >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] Chaff service ${SVC} configured for peer ${PEER_GRE} (profile: ${PROFILE}).${NC}"
}

cli_chaff() {
    local ACTION="${1:-status}"
    case "$ACTION" in
        on)
            echo -e "${CYAN}[*] Enabling and starting GRE chaff services...${NC}"
            local found=0 u bname
            for u in /etc/systemd/system/gre-chaff*.service; do
                [[ -f "$u" ]] || continue
                found=1
                bname=$(basename "$u")
                systemctl enable "$bname" >/dev/null 2>&1
                systemctl restart "$bname" >/dev/null 2>&1
                echo -e "${GREEN}[✔️] Started and enabled ${bname}.${NC}"
            done
            if [[ "$found" -eq 0 ]]; then
                echo -e "${YELLOW}[*] No existing chaff services found — configuring for active tunnels...${NC}"
                update_chaff_existing_tunnels
            fi
            ;;
        off)
            echo -e "${CYAN}[*] Stopping and disabling GRE chaff services...${NC}"
            local found=0 u bname
            for u in /etc/systemd/system/gre-chaff*.service; do
                [[ -f "$u" ]] || continue
                found=1
                bname=$(basename "$u")
                systemctl stop "$bname" >/dev/null 2>&1
                systemctl disable "$bname" >/dev/null 2>&1
                echo -e "${GREEN}[✔️] Stopped and disabled ${bname}.${NC}"
            done
            if [[ "$found" -eq 0 ]]; then
                echo -e "${YELLOW}[*] No chaff services found.${NC}"
            fi
            ;;
        status)
            echo -e "${CYAN}=== GRE Chaff (Traffic Obfuscation) Status ===${NC}"
            echo -e "${YELLOW}Notice: Fills idle gaps to break timing analysis; does not hide volume under load.${NC}"
            local found=0 u bname active enabled exec_line peer_ip prof
            for u in /etc/systemd/system/gre-chaff*.service; do
                [[ -f "$u" ]] || continue
                found=1
                bname=$(basename "$u")
                active=$(systemctl is-active "$bname" 2>/dev/null)
                [[ -z "$active" ]] && active="inactive"
                enabled=$(systemctl is-enabled "$bname" 2>/dev/null)
                [[ -z "$enabled" ]] && enabled="disabled"
                exec_line=$(grep -E '^[[:space:]]*ExecStart[[:space:]]*=' "$u" | head -1)
                peer_ip=$(echo "$exec_line" | awk '{print $2}')
                prof=$(echo "$exec_line" | awk '{print $3}')
                prof=${prof:-low}
                if [[ "$active" == "active" ]]; then
                    echo -e "  ${bname}: ${GREEN}ACTIVE${NC} (${enabled}) | peer: ${CYAN}${peer_ip}${NC} | profile: ${YELLOW}${prof}${NC}"
                else
                    echo -e "  ${bname}: ${RED}${active}${NC} (${enabled}) | peer: ${CYAN}${peer_ip}${NC} | profile: ${YELLOW}${prof}${NC}"
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                echo -e "${YELLOW}[*] No chaff services currently installed.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}[!] Usage: hashem chaff on|off|status${NC}"
            return 1
            ;;
    esac
}

menu_chaff() {
    echo -e "\n${YELLOW}=== Traffic Chaff / Obfuscation (Idle-Gap Filler) ===${NC}"
    echo -e "Random pings fill idle gaps to break timing analysis (low overhead, ~few KB/s)."
    cli_chaff status
    echo ""
    echo "  1) Enable / Start chaff services (on)"
    echo "  2) Disable / Stop chaff services (off)"
    echo "  3) Check status"
    echo "  0) Back to main menu"
    echo ""
    read -p "Select an action [0-3]: " CH_OPT || return 1
    case "$CH_OPT" in
        1) cli_chaff on ;;
        2) cli_chaff off ;;
        3) cli_chaff status ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] Invalid option.${NC}"; return 1 ;;
    esac
}

# ---- DPI Shield: protect reverse proxy ports against scanner floods ----
DPI_PORTS_FILE="${STATE_DIR}/dpi-ports.conf"

dpi_collect_reverse_ports() {
    local PORTS=()
    local EXCLUDE_PORTS=()

    # 1. Collect FRP bind/control ports to exclude
    local f bp sp fp p ex excluded
    for f in "${CONFIG_DIR}"/frps*.toml /etc/frp/frps*.toml; do
        [[ -f "$f" ]] || continue
        while read -r bp; do
            [[ -n "$bp" ]] && EXCLUDE_PORTS+=("$bp")
        done < <(grep -E '^\s*bindPort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done
    for f in "${CONFIG_DIR}/frpc.toml" /etc/frp/frpc.toml; do
        [[ -f "$f" ]] || continue
        while read -r sp; do
            [[ -n "$sp" ]] && EXCLUDE_PORTS+=("$sp")
        done < <(grep -E '^\s*serverPort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r fp; do
            [[ -n "$fp" ]] && EXCLUDE_PORTS+=("$fp")
        done < <(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    with open(os.environ["PEERS_F"]) as f:
        d = json.load(f)
        for p in d.get("peers", []):
            pt = p.get("frp_port")
            if pt:
                print(pt)
except Exception:
    pass
' 2>/dev/null)
    fi

    # 2. Collect SSH ports to exclude
    EXCLUDE_PORTS+=(22)
    if command -v ss >/dev/null 2>&1; then
        while read -r sp; do
            [[ -n "$sp" ]] && EXCLUDE_PORTS+=("$sp")
        done < <(ss -ltnp 2>/dev/null | grep 'sshd' | awk '{print $4}' | awk -F: '{print $NF}')
    fi

    # Candidate reverse ports:
    # A. peers.json
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    with open(os.environ["PEERS_F"]) as f:
        d = json.load(f)
        for p in d.get("peers", []):
            for pt in p.get("ports", []):
                print(pt)
except Exception:
    pass
' 2>/dev/null)
    fi

    # B. frpc.toml remotePort
    for f in "${CONFIG_DIR}/frpc.toml" /etc/frp/frpc.toml; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^\s*remotePort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done

    # C. Active frps listeners via ss -ltn (excluding control ports)
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(ss -ltnp 2>/dev/null | grep -E 'users:.*\("frps"' | awk '{print $4}' | awk -F: '{print $NF}')
    fi

    # D. Saved DPI ports cache (for reboots before frps connects)
    if [[ -f "$DPI_PORTS_FILE" ]]; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < "$DPI_PORTS_FILE"
    fi

    # Filter candidates: remove excluded, check validity (1..65535)
    local FINAL_PORTS=()
    for p in "${PORTS[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        (( p >= 1 && p <= 65535 )) || continue
        excluded=0
        for ex in "${EXCLUDE_PORTS[@]}"; do
            if [[ "$p" -eq "$ex" ]]; then
                excluded=1
                break
            fi
        done
        [[ "$excluded" -eq 0 ]] && FINAL_PORTS+=("$p")
    done

    if [[ ${#FINAL_PORTS[@]} -gt 0 ]]; then
        printf "%s\n" "${FINAL_PORTS[@]}" | sort -n -u
    fi
}

dpi_shield_on() {
    command -v iptables >/dev/null 2>&1 || {
        echo -e "${RED}[!] iptables is required for DPI shield but not installed.${NC}"
        return 1
    }

    local REVERSE_PORTS=() p
    while read -r p; do
        [[ -n "$p" ]] && REVERSE_PORTS+=("$p")
    done < <(dpi_collect_reverse_ports)

    if [[ ${#REVERSE_PORTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}[!] No reverse tunnel ports found in peers.json, frpc.toml, or active frps listeners.${NC}"
        echo -e "${YELLOW}[*] Set up a tunnel or configure reverse ports first.${NC}"
        return 1
    fi

    mkdir -p "$(dirname "$DPI_PORTS_FILE")"
    printf "%s\n" "${REVERSE_PORTS[@]}" > "$DPI_PORTS_FILE"

    echo -e "${CYAN}[*] Installing DPI shield for reverse ports: ${REVERSE_PORTS[*]}...${NC}"

    # Idempotent chain setup: flush existing HASHEM-DPI chain or create it
    if iptables -L HASHEM-DPI -n >/dev/null 2>&1; then
        iptables -F HASHEM-DPI
    else
        iptables -N HASHEM-DPI
    fi

    # Ensure jump from INPUT exists
    if ! iptables -C INPUT -j HASHEM-DPI 2>/dev/null; then
        iptables -I INPUT 1 -j HASHEM-DPI
    fi

    # 1. Always allow loopback traffic (localhost, internal proxying frpc <-> 3x-ui / local services)
    iptables -A HASHEM-DPI -i lo -j ACCEPT

    # 2. Always accept established and related connections so active traffic/downloads are NEVER throttled or dropped
    iptables -A HASHEM-DPI -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A HASHEM-DPI -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # 3. Kernel SYN flood hardening (syncookies absorb connection spikes without dropping legitimate handshakes)
    sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1 || true

    # 4. Anti-scanner flood defense per source IP (protects against high-rate port scanners without dropping normal users)
    local port
    for port in "${REVERSE_PORTS[@]}"; do
        # Use hashlimit per source IP if supported (blocks abusive scanners > 60/sec from one IP, never drops normal clients)
        if ! iptables -A HASHEM-DPI -p tcp --dport "$port" --syn -m hashlimit --hashlimit-name "hsh_${port}" --hashlimit-mode srcip --hashlimit-above 60/sec --hashlimit-burst 120 -j DROP 2>/dev/null; then
            iptables -A HASHEM-DPI -p tcp --dport "$port" --syn -j ACCEPT 2>/dev/null || true
        fi
    done

    # 5. If UFW is active, also ensure reverse ports are allowed so UFW does not block them
    for port in "${REVERSE_PORTS[@]}"; do
        ufw_allow_track "${port}/tcp"
        ufw_allow_track "${port}/udp"
    done

    # Persist across reboot via systemd oneshot unit
    [[ -x "$HASHEM_BIN" ]] || { cp "$0" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN"; } || true
    cat << 'EOF' > /etc/systemd/system/hashem-dpi.service
[Unit]
Description=Hashem DPI Shield Protection
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hashem dpi-shield on

[Install]
WantedBy=network-pre.target
EOF
    systemctl daemon-reload
    systemctl enable hashem-dpi.service >/dev/null 2>&1 || true

    echo -e "${GREEN}[✔️] DPI shield ACTIVE: ${#REVERSE_PORTS[@]} port(s) protected (${REVERSE_PORTS[*]}).${NC}"
    echo -e "${GREEN}[✔️] Persisted via systemd unit hashem-dpi.service (WantedBy=network-pre.target).${NC}"
}

dpi_shield_off() {
    # Disable and remove systemd persistence unit
    systemctl disable --now hashem-dpi.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/hashem-dpi.service "$DPI_PORTS_FILE"
    systemctl daemon-reload

    # Remove jump from INPUT
    while iptables -C INPUT -j HASHEM-DPI 2>/dev/null; do
        iptables -D INPUT -j HASHEM-DPI
    done

    # Flush and delete HASHEM-DPI chain
    iptables -F HASHEM-DPI 2>/dev/null || true
    iptables -X HASHEM-DPI 2>/dev/null || true

    echo -e "${GREEN}[✔️] DPI shield DISABLED (HASHEM-DPI chain removed and service disabled).${NC}"
}

dpi_shield_status() {
    if iptables -L HASHEM-DPI -n >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] DPI shield is ACTIVE (chain HASHEM-DPI installed).${NC}"
        echo -e "${CYAN}Packet counters and rules in HASHEM-DPI:${NC}"
        iptables -L HASHEM-DPI -v -n
        if systemctl is-enabled hashem-dpi.service >/dev/null 2>&1; then
            echo -e "${GREEN}[✔️] Persistence: hashem-dpi.service is enabled.${NC}"
        else
            echo -e "${YELLOW}[!] Persistence: hashem-dpi.service is not enabled.${NC}"
        fi
    else
        echo -e "${YELLOW}[!] DPI shield is INACTIVE (chain HASHEM-DPI does not exist).${NC}"
        if systemctl is-enabled hashem-dpi.service >/dev/null 2>&1; then
            echo -e "${YELLOW}[*] hashem-dpi.service is enabled for boot.${NC}"
        fi
    fi
}

cli_dpi_shield() {
    local ACTION="${1:-}"
    case "$ACTION" in
        on)
            dpi_shield_on
            ;;
        off)
            dpi_shield_off
            ;;
        status)
            dpi_shield_status
            ;;
        *)
            echo -e "${RED}[!] Usage: hashem dpi-shield on|off|status${NC}"
            return 1
            ;;
    esac
}

menu_dpi_shield() {
    echo -e "\n${YELLOW}=== DPI Shield (Reverse Port Flood Protection) ===${NC}"
    echo -e "Protects reverse ports against DPI scanner floods using iptables rate limiting."
    echo ""
    cli_dpi_shield status
    echo ""
    echo "  1) Enable DPI Shield (on)"
    echo "  2) Disable DPI Shield (off)"
    echo "  3) Check status"
    echo "  0) Back to main menu"
    echo ""
    read -p "Select an action [0-3]: " DPI_OPT || return 1
    case "$DPI_OPT" in
        1) cli_dpi_shield on ;;
        2) cli_dpi_shield off ;;
        3) cli_dpi_shield status ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] Invalid option.${NC}"; return 1 ;;
    esac
}

update_chaff_existing_tunnels() {
    if [[ "${CHAFF_PROFILE:-low}" == "off" ]]; then
        return 0
    fi
    # 1. Multi-peer registry (/etc/gre-panel/peers.json)
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        local PEER_DATA
        PEER_DATA=$(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    d = json.load(open(os.environ["PEERS_F"]))
    for p in d.get("peers", []):
        pid = p.get("id", "")
        suf = "" if p.get("legacy") else "-" + str(pid)
        pgre = p.get("peer_gre", "")
        prof = p.get("chaff_profile", "")
        if pgre:
            print(suf + ":" + pgre + ":" + prof)
except Exception:
    pass
' 2>/dev/null)
        if [[ -n "$PEER_DATA" ]]; then
            local suf pgre prof saved_prof
            while IFS=':' read -r suf pgre prof; do
                [[ -n "$pgre" ]] || continue
                saved_prof="${CHAFF_PROFILE:-}"
                [[ -n "$prof" ]] && CHAFF_PROFILE="$prof"
                setup_chaff "$suf" "$pgre"
                CHAFF_PROFILE="$saved_prof"
            done <<< "$PEER_DATA"
            return 0
        fi
    fi

    # 2. Foreign server (/etc/frp/frpc.toml)
    if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
        local PEER_GRE
        PEER_GRE=$(grep -E '^[[:space:]]*serverAddr[[:space:]]*=' "${CONFIG_DIR}/frpc.toml" | cut -d'=' -f2 | tr -d ' "' | tr -d " \t\r\n")
        if is_valid_ip "$PEER_GRE"; then
            setup_chaff "" "$PEER_GRE"
            return 0
        fi
    fi

    # 3. Legacy Iran server (/etc/systemd/system/gre-tunnel.service or /etc/frp/frps.toml)
    if [[ -f "/etc/systemd/system/${TUNNEL_NAME}.service" || -f "${CONFIG_DIR}/frps.toml" ]]; then
        local INNER_IP=""
        if [[ -f "/etc/systemd/system/${TUNNEL_NAME}.service" ]]; then
            INNER_IP=$(grep -oE 'addr add [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "/etc/systemd/system/${TUNNEL_NAME}.service" | awk '{print $3}' | head -1)
        fi
        if [[ -z "$INNER_IP" ]] && ip addr show "$TUNNEL_NAME" >/dev/null 2>&1; then
            INNER_IP=$(ip addr show "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
        fi
        if is_valid_ip "$INNER_IP"; then
            local last=${INNER_IP##*.}; local prefix=${INNER_IP%.*}
            if (( last % 2 == 0 )); then last=$((last - 1)); else last=$((last + 1)); fi
            local P_GRE="${prefix}.${last}"
            if is_valid_ip "$P_GRE"; then
                setup_chaff "" "$P_GRE"
            fi
        fi
    fi
}

# ---- Performance & Obfuscation Controls (CLI + Menu) ----

perf_apply() {
    init_perf_json
    local EFF_ENC EFF_COMP EFF_TLS
    EFF_ENC=$(perf_get_enc)
    EFF_COMP=$(perf_get_comp)
    EFF_TLS=$(perf_get_tls)

    local IS_FOREIGN=0
    local IS_IRAN=0
    [[ -f "${CONFIG_DIR}/frpc.toml" ]] && IS_FOREIGN=1
    [[ -f "${CONFIG_DIR}/frps.toml" ]] && IS_IRAN=1
    local f
    for f in "${CONFIG_DIR}"/frps*.toml; do
        [[ -f "$f" ]] && IS_IRAN=1
    done

    if [[ "$IS_FOREIGN" -eq 0 && "$IS_IRAN" -eq 0 ]]; then
        echo -e "${YELLOW}[!] No frps.toml or frpc.toml found in ${CONFIG_DIR}.${NC}"
        echo -e "${YELLOW}[*] Set up a tunnel first before applying performance settings.${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] Applying performance settings (enc=${EFF_ENC} comp=${EFF_COMP} tls=${EFF_TLS})...${NC}"

    if [[ "$IS_FOREIGN" -eq 1 ]]; then
        local TOML_FILE="${CONFIG_DIR}/frpc.toml"
        if command -v python3 >/dev/null 2>&1; then
            python3 -c '
path = "'"$TOML_FILE"'"
enc = ("'"$EFF_ENC"'".strip() in ("1", "true", "True"))
comp = ("'"$EFF_COMP"'".strip() in ("1", "true", "True"))
tls = ("'"$EFF_TLS"'".strip() in ("1", "true", "True"))

with open(path, "r") as f:
    lines = f.read().splitlines()

sections = []
current = []
for line in lines:
    if line.strip().startswith("[[proxies]]"):
        if current:
            sections.append(current)
        current = [line]
    else:
        current.append(line)
if current:
    sections.append(current)

out_sections = []
for i, sec in enumerate(sections):
    if i == 0 and not sec[0].strip().startswith("[[proxies]]"):
        new_sec = []
        has_tls_enable = False
        for l in sec:
            s = l.strip()
            if s.startswith("transport.tls.disableCustomTLSFirstByte"):
                continue
            if s.startswith("transport.tls.enable"):
                has_tls_enable = True
            new_sec.append(l)
        final_hdr = []
        for l in new_sec:
            final_hdr.append(l)
            if l.strip().startswith("transport.tls.enable") and tls:
                final_hdr.append("transport.tls.disableCustomTLSFirstByte = true")
        if tls and not any("transport.tls.disableCustomTLSFirstByte" in x for x in final_hdr):
            if not has_tls_enable:
                final_hdr.append("transport.tls.enable = true")
            final_hdr.append("transport.tls.disableCustomTLSFirstByte = true")
        out_sections.append(final_hdr)
    else:
        new_sec = []
        is_tcp = any("type = \"tcp\"" in l or "type=\"tcp\"" in l for l in sec)
        for l in sec:
            s = l.strip()
            if s.startswith("transport.useEncryption") or s.startswith("transport.useCompression"):
                continue
            new_sec.append(l)
        while new_sec and new_sec[-1].strip() == "":
            new_sec.pop()
        if enc and is_tcp:
            new_sec.append("transport.useEncryption = true")
        if comp and is_tcp:
            new_sec.append("transport.useCompression = true")
        new_sec.append("")
        out_sections.append(new_sec)

result = "\n".join("\n".join(s) for s in out_sections).strip() + "\n"
with open(path, "w") as f:
    f.write(result)
'
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart frpc
        echo -e "${GREEN}[✔️] frpc.toml updated & frpc service restarted.${NC}"
    fi

    if [[ "$IS_IRAN" -eq 1 ]]; then
        for TOML_FILE in "${CONFIG_DIR}"/frps*.toml; do
            [[ -f "$TOML_FILE" ]] || continue
            if command -v python3 >/dev/null 2>&1; then
                python3 -c '
path = "'"$TOML_FILE"'"
tls = ("'"$EFF_TLS"'".strip() in ("1", "true", "True"))

import json, os
max_pool = "50"
try:
    with open("'"$PERF_FILE"'") as jf:
        max_pool = str(json.load(jf).get("frp_max_pool", 50))
except Exception:
    pass

with open(path, "r") as f:
    lines = f.read().splitlines()

new_lines = []
for l in lines:
    s = l.strip()
    if s.startswith("transport.tls.force"):
        continue
    new_lines.append(l)

final_lines = []
if tls:
    has_tls = False
    for l in new_lines:
        final_lines.append(l)
        if l.strip().startswith("auth.token"):
            final_lines.append("transport.tls.force = true")
            has_tls = True
    if not has_tls:
        final_lines.append("transport.tls.force = true")
else:
    final_lines = new_lines

# Update maxPoolCount
out_lines = []
has_pool = False
for l in final_lines:
    if l.strip().startswith("transport.maxPoolCount"):
        out_lines.append("transport.maxPoolCount = " + max_pool)
        has_pool = True
    else:
        out_lines.append(l)
if not has_pool:
    out_lines.append("transport.maxPoolCount = " + max_pool)

result = "\n".join(out_lines).strip() + "\n"
with open(path, "w") as f:
    f.write(result)
'
            fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart frps >/dev/null 2>&1 || true
        local s sname
        for s in /etc/systemd/system/frps-*.service; do
            [[ -f "$s" ]] || continue
            sname=$(basename "$s")
            systemctl restart "$sname" >/dev/null 2>&1 || true
        done
        echo -e "${GREEN}[✔️] frps toml(s) updated & frps service(s) restarted.${NC}"
    fi

    # Also apply chaff profile
    local CHAFF_PROF DPI_EN
    CHAFF_PROF=$(perf_get_chaff)
    if [[ "$CHAFF_PROF" == "off" ]]; then
        cli_chaff off >/dev/null 2>&1 || true
    else
        CHAFF_PROFILE="$CHAFF_PROF" cli_chaff on >/dev/null 2>&1 || true
    fi

    # Also apply DPI shield setting
    DPI_EN=$(perf_get_dpi_enabled)
    if [[ "$DPI_EN" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    else
        dpi_shield_off >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}[✔️] Performance settings successfully applied.${NC}"
    return 0
}

cli_perf() {
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            init_perf_json
            local ENC COMP TLS CHAFF DPI_EN DPI_R DPI_B
            ENC=$(perf_get_enc)
            COMP=$(perf_get_comp)
            TLS=$(perf_get_tls)
            CHAFF=$(perf_get_chaff)
            DPI_EN=$(perf_get_dpi_enabled)
            DPI_R=$(perf_get_dpi_rate)
            DPI_B=$(perf_get_dpi_burst)

            echo -e "\n${CYAN}==========================================================${NC}"
            echo -e "${CYAN}            Performance & Obfuscation Status              ${NC}"
            echo -e "${CYAN}==========================================================${NC}"
            echo -e "Settings (${PERF_FILE}):"
            echo -e "  Proxy Encryption:  $([[ "$ENC" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  Proxy Compression: $([[ "$COMP" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  Forced TLS:        $([[ "$TLS" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  Chaff Profile:     ${CYAN}${CHAFF}${NC}"
            echo -e "  DPI Shield:        $([[ "$DPI_EN" == "1" ]] && echo -e "${GREEN}enabled${NC} (${DPI_R}, burst ${DPI_B})" || echo -e "${YELLOW}disabled${NC}")"

            if [[ -n "${PERF_ENC:-}" || -n "${PERF_COMP:-}" || -n "${PERF_TLS:-}" ]]; then
                echo -e "${YELLOW}[!] Env overrides active: PERF_ENC=${PERF_ENC:-unset} PERF_COMP=${PERF_COMP:-unset} PERF_TLS=${PERF_TLS:-unset}${NC}"
            fi

            echo ""
            echo -e "Live Tunnel Configuration:"
            local MATCH=1

            if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
                local LIVE_ENC=0 LIVE_COMP=0 LIVE_TLS=0
                grep -E -q '^[[:space:]]*transport\.useEncryption[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_ENC=1
                grep -E -q '^[[:space:]]*transport\.useCompression[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_COMP=1
                grep -E -q '^[[:space:]]*transport\.tls\.disableCustomTLSFirstByte[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_TLS=1

                echo -e "  Role: Foreign client (frpc)"
                echo -e "  Live Proxy Encryption:  $([[ "$LIVE_ENC" == "1" ]] && echo "on" || echo "off") $([[ "$LIVE_ENC" == "$ENC" ]] && echo -e "${GREEN}[MATCH]${NC}" || { echo -e "${RED}[MISMATCH]${NC}"; MATCH=0; })"
                echo -e "  Live Proxy Compression: $([[ "$LIVE_COMP" == "1" ]] && echo "on" || echo "off") $([[ "$LIVE_COMP" == "$COMP" ]] && echo -e "${GREEN}[MATCH]${NC}" || { echo -e "${RED}[MISMATCH]${NC}"; MATCH=0; })"
                echo -e "  Live Forced TLS:        $([[ "$LIVE_TLS" == "1" ]] && echo "on" || echo "off") $([[ "$LIVE_TLS" == "$TLS" ]] && echo -e "${GREEN}[MATCH]${NC}" || { echo -e "${RED}[MISMATCH]${NC}"; MATCH=0; })"
            elif [[ -f "${CONFIG_DIR}/frps.toml" ]] || ls "${CONFIG_DIR}"/frps*.toml >/dev/null 2>&1; then
                local LIVE_TLS=0
                local F
                for F in "${CONFIG_DIR}"/frps*.toml; do
                    [[ -f "$F" ]] || continue
                    grep -E -q '^[[:space:]]*transport\.tls\.force[[:space:]]*=[[:space:]]*true' "$F" && LIVE_TLS=1
                done
                echo -e "  Role: Iran server (frps)"
                echo -e "  Live Forced TLS:        $([[ "$LIVE_TLS" == "1" ]] && echo "on" || echo "off") $([[ "$LIVE_TLS" == "$TLS" ]] && echo -e "${GREEN}[MATCH]${NC}" || { echo -e "${RED}[MISMATCH]${NC}"; MATCH=0; })"
                echo -e "  (Proxy encryption & compression are client-side settings on Foreign VPS)"
            else
                echo -e "  No live tunnel configs found."
            fi

            # DPI live
            if iptables -L HASHEM-DPI -n >/dev/null 2>&1; then
                echo -e "  DPI Shield (iptables):  ${GREEN}ACTIVE${NC}"
            else
                echo -e "  DPI Shield (iptables):  ${YELLOW}INACTIVE${NC}"
            fi

            # Chaff live
            if systemctl is-active --quiet gre-chaff 2>/dev/null || systemctl list-units --type=service 2>/dev/null | grep -q 'gre-chaff.*running'; then
                echo -e "  Chaff Service:          ${GREEN}RUNNING${NC}"
            else
                echo -e "  Chaff Service:          ${YELLOW}STOPPED${NC}"
            fi

            echo ""
            if [[ "$MATCH" -eq 1 ]]; then
                echo -e "${GREEN}[✔️] Live configuration matches effective settings.${NC}"
            else
                echo -e "${RED}[!] Live configuration does NOT match settings. Run 'hashem perf apply' to sync.${NC}"
            fi
            ;;
        enc)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "proxy_encryption" "true" 1; echo -e "${GREEN}[✔️] Proxy encryption set to 'on'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                off) perf_set_val "proxy_encryption" "false" 1; echo -e "${GREEN}[✔️] Proxy encryption set to 'off'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                *)   echo -e "${RED}[!] Usage: hashem perf enc on|off${NC}"; return 1 ;;
            esac
            ;;
        comp)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "proxy_compression" "true" 1; echo -e "${GREEN}[✔️] Proxy compression set to 'on'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                off) perf_set_val "proxy_compression" "false" 1; echo -e "${GREEN}[✔️] Proxy compression set to 'off'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                *)   echo -e "${RED}[!] Usage: hashem perf comp on|off${NC}"; return 1 ;;
            esac
            ;;
        tls)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "force_tls" "true" 1; echo -e "${GREEN}[✔️] Forced TLS set to 'on'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                off) perf_set_val "force_tls" "false" 1; echo -e "${GREEN}[✔️] Forced TLS set to 'off'. Run 'hashem perf apply' to apply and restart tunnels.${NC}" ;;
                *)   echo -e "${RED}[!] Usage: hashem perf tls on|off${NC}"; return 1 ;;
            esac
            ;;
        chaff)
            local VAL="${2:-}"
            case "$VAL" in
                off)
                    perf_set_val "chaff_profile" "off" 0
                    cli_chaff off
                    echo -e "${GREEN}[✔️] Chaff profile set to 'off' and services stopped.${NC}"
                    ;;
                low|mid)
                    perf_set_val "chaff_profile" "$VAL" 0
                    CHAFF_PROFILE="$VAL" cli_chaff on
                    echo -e "${GREEN}[✔️] Chaff profile set to '$VAL' and services started.${NC}"
                    ;;
                *)
                    echo -e "${RED}[!] Usage: hashem perf chaff off|low|mid${NC}"
                    return 1
                    ;;
            esac
            ;;
        dpi)
            local VAL="${2:-}"
            case "$VAL" in
                on)
                    perf_set_val "dpi_enabled" "true" 1
                    dpi_shield_on
                    echo -e "${GREEN}[✔️] DPI shield enabled.${NC}"
                    ;;
                off)
                    perf_set_val "dpi_enabled" "false" 1
                    dpi_shield_off
                    echo -e "${GREEN}[✔️] DPI shield disabled.${NC}"
                    ;;
                *)
                    echo -e "${RED}[!] Usage: hashem perf dpi on|off${NC}"
                    return 1
                    ;;
            esac
            ;;
        apply)
            perf_apply
            ;;
        reset)
            init_perf_json
            perf_set_val "proxy_encryption" "false" 1
            perf_set_val "proxy_compression" "false" 1
            perf_set_val "force_tls" "false" 1
            perf_set_val "chaff_profile" "off" 0
            perf_set_val "dpi_enabled" "false" 1
            dpi_shield_off >/dev/null 2>&1 || true
            cli_chaff off >/dev/null 2>&1 || true
            perf_apply
            echo -e "${GREEN}[✔️] Performance & Obfuscation RESET to safe defaults (encryption: off, compression: off, TLS: standard, chaff: off, DPI shield: off).${NC}"
            ;;
        -h|--help|help)
            echo "Usage: hashem perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|dpi on|off|apply|reset"
            ;;
        *)
            echo -e "${RED}[!] Unknown subcommand: $SUB${NC}"
            echo "Usage: hashem perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|dpi on|off|apply|reset"
            return 1
            ;;
    esac
}

menu_perf() {
    local P_OPT C_OPT cur
    while true; do
        cli_perf status
        echo ""
        echo "  1) Toggle Proxy Encryption (enc on/off)"
        echo "  2) Toggle Proxy Compression (comp on/off)"
        echo "  3) Toggle Forced TLS (tls on/off)"
        echo "  4) Set Chaff Profile (off / low / mid)"
        echo "  5) Toggle DPI Shield (on/off)"
        echo "  6) Apply settings & restart tunnels"
        echo "  0) Back to main menu"
        echo ""
        read -p "Select an option [0-6]: " P_OPT || return 1
        case "$P_OPT" in
            1)
                cur=$(perf_get_enc)
                if [[ "$cur" == "1" ]]; then cli_perf enc off; else cli_perf enc on; fi
                ;;
            2)
                cur=$(perf_get_comp)
                if [[ "$cur" == "1" ]]; then cli_perf comp off; else cli_perf comp on; fi
                ;;
            3)
                cur=$(perf_get_tls)
                if [[ "$cur" == "1" ]]; then cli_perf tls off; else cli_perf tls on; fi
                ;;
            4)
                echo "Select chaff profile:"
                echo "  1) off"
                echo "  2) low (default)"
                echo "  3) mid"
                read -p "Option [1-3]: " C_OPT || return 1
                case "$C_OPT" in
                    1) cli_perf chaff off ;;
                    2) cli_perf chaff low ;;
                    3) cli_perf chaff mid ;;
                    *) echo "Invalid option." ;;
                esac
                ;;
            5)
                cur=$(perf_get_dpi_enabled)
                if [[ "$cur" == "1" ]]; then cli_perf dpi off; else cli_perf dpi on; fi
                ;;
            6)
                cli_perf apply
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option.${NC}"
                ;;
        esac
    done
}

# ---- SINGLE SOURCE OF TRUTH for install logic ----
# setup_iran_server_noninteractive / setup_foreign_server_noninteractive do the
# real work. The interactive menu functions below only prompt + validate, then
# delegate here. The CLI flags at the bottom of this file (setup-iran /
# setup-foreign) call the same functions, so menu and CLI run identical steps.
# Args: $1=local_pub $2=remote_pub $3=frp_port $4=token [$5=local_gre [$6=peer_gre]]
setup_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$IRAN_GRE_IP} PEER_GRE=${6:-$FOREIGN_GRE_IP}

    log_msg "tunnel" "INFO" "Starting IRAN server setup: GRE ${IP_IRAN} <-> ${IP_FOREIGN}, FRP port: ${BIND_PORT}"
    backup_configs "pre_setup_iran" >/dev/null
    ensure_dependencies_smart

    local STATUS_GRE="OK"
    local STATUS_FRP="OK"
    local GRE_ERR="" FRP_ERR=""

    # 1. Setup GRE interface
    if ! setup_gre_systemd "$IP_IRAN" "$IP_FOREIGN" "$LOCAL_GRE" "$PEER_GRE"; then
        STATUS_GRE="FAILED"
        GRE_ERR="GRE interface failed to start or configure IP"
        log_msg "tunnel" "ERROR" "GRE setup failed on IRAN server"
    fi

    # 2. Setup FRP Server
    if ! install_frp_binaries; then
        STATUS_FRP="FAILED"
        FRP_ERR="FRP binaries could not be installed"
    else
        local EFF_TLS MAX_POOL TLS_LINE=""
        EFF_TLS=$(perf_get_tls)
        MAX_POOL=$(perf_get_max_pool)
        [[ "$EFF_TLS" == "1" ]] && TLS_LINE="transport.tls.force = true"
        mkdir -p "${CONFIG_DIR}"
        cat <<EOF > "${CONFIG_DIR}/frps.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
${TLS_LINE:+$TLS_LINE
}transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 15
transport.heartbeatTimeout = 30
transport.maxPoolCount = ${MAX_POOL}
EOF
        chmod 600 "${CONFIG_DIR}/frps.toml" 2>/dev/null || true
        cat <<EOF > /etc/systemd/system/frps.service
[Unit]
Description=FRP Server Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps.toml

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl reset-failed frps >/dev/null 2>&1 || true
        systemctl enable frps >/dev/null 2>&1
        systemctl restart frps

        local _frps_ok=0 _i
        for _i in {1..5}; do
            sleep 2
            if systemctl is-active --quiet frps 2>/dev/null; then
                _frps_ok=1
                break
            fi
        done

        if [[ "$_frps_ok" -ne 1 ]]; then
            STATUS_FRP="FAILED"
            FRP_ERR="frps service failed to start — check: journalctl -u frps"
            log_msg "tunnel" "ERROR" "frps service failed to start"
        fi
    fi

    setup_chaff "" "$PEER_GRE"
    ufw_allow_track "${BIND_PORT}/tcp"

    if [[ "$(perf_get_dpi_enabled)" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    fi
    tune_apply >/dev/null 2>&1 || true
    watchdog_on >/dev/null 2>&1 || true

    # 3. Summary & Verification
    echo -e "\n=============================================================="
    echo "                   INSTALLATION SUMMARY"
    echo "=============================================================="
    if [[ "$STATUS_GRE" == "OK" ]]; then
        echo -e "[${GREEN}OK${NC}]     GRE Tunnel Interface (${TUNNEL_NAME}: ${IP_IRAN} <-> ${IP_FOREIGN}, IP: ${LOCAL_GRE})"
    else
        echo -e "[${RED}FAILED${NC}] GRE Tunnel Interface (${GRE_ERR})"
    fi

    if [[ "$STATUS_FRP" == "OK" ]]; then
        echo -e "[${GREEN}OK${NC}]     FRP Server Service (frps listening on port :${BIND_PORT})"
    else
        echo -e "[${RED}FAILED${NC}] FRP Server Service (${FRP_ERR})"
    fi
    echo "=============================================================="

    if [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" ]]; then
        echo -e "Overall Installation Status: ${GREEN}SUCCESS${NC}\n"
        echo -e "GRE Public Link:      ${CYAN}${IP_IRAN} <--> ${IP_FOREIGN}${NC}"
        echo -e "IRAN GRE Internal IP: ${CYAN}${LOCAL_GRE}${NC}"
        echo -e "FRP Bind Port:        ${CYAN}${BIND_PORT}${NC}"
        echo -e "Secret Token:         ${CYAN}${TOKEN}${NC}"
        echo -e "Setup Bundle:         ${CYAN}$(bundle_make "$IP_IRAN" "$BIND_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN")${NC}"
        echo -e "BUNDLE:$(bundle_make "$IP_IRAN" "$BIND_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN")"
        log_msg "tunnel" "INFO" "IRAN server setup completed successfully"
        return 0
    else
        echo -e "Overall Installation Status: ${RED}PARTIALLY FAILED${NC}"
        echo -e "${YELLOW}[!] Review component failure(s) above. Do NOT assume tunnel is ready.${NC}\n"
        log_msg "tunnel" "ERROR" "IRAN server setup partially failed: GRE=${STATUS_GRE}, FRP=${STATUS_FRP}"
        return 1
    fi
}

setup_foreign_server_noninteractive() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$FOREIGN_GRE_IP} PEER_GRE=${6:-$IRAN_GRE_IP}
    local PORTS_CLEANED=${7:-}
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_CLEANED"
}

# shared full foreign path: GRE + ping feedback + frpc binaries/config/service.
# Called by the interactive menu and the CLI.
_setup_foreign_full() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=$5 PEER_GRE=$6 PORTS_CLEANED=$7

    log_msg "tunnel" "INFO" "Starting FOREIGN server setup: GRE ${IP_FOREIGN} <-> ${IP_IRAN}, serverPort: ${SERVER_PORT}, reverse ports: ${PORTS_CLEANED}"
    backup_configs "pre_setup_foreign" >/dev/null
    ensure_dependencies_smart

    local STATUS_GRE="OK"
    local STATUS_PING="OK"
    local STATUS_FRP="OK"
    local GRE_ERR="" PING_ERR="" FRP_ERR=""

    carrier_init_kernel 2>/dev/null || true
    if ! setup_gre_systemd "$IP_FOREIGN" "$IP_IRAN" "$LOCAL_GRE" "$PEER_GRE"; then
        STATUS_GRE="FAILED"
        GRE_ERR="GRE interface failed to configure or initialize"
        log_msg "tunnel" "ERROR" "GRE setup failed on FOREIGN server"
    fi
    carrier_apply_active "$TUNNEL_NAME" >/dev/null 2>&1 || true

    echo -e "${CYAN}[*] Testing GRE internal ping to Iran (${PEER_GRE})...${NC}"
    if ping -c 3 -W 2 "$PEER_GRE" >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] GRE Tunnel link is UP and reachable!${NC}"
    else
        STATUS_PING="WARN"
        PING_ERR="Ping to peer GRE IP ${PEER_GRE} timed out (may need Iran side up)"
        echo -e "${YELLOW}[!] Warning: Ping to ${PEER_GRE} did not respond yet.${NC}"
    fi

    if ! install_frp_binaries; then
        STATUS_FRP="FAILED"
        FRP_ERR="FRP binaries could not be installed"
    else
        local EFF_TLS EFF_ENC EFF_COMP TLS_CUSTOM=""
        EFF_TLS=$(perf_get_tls)
        EFF_ENC=$(perf_get_enc)
        EFF_COMP=$(perf_get_comp)
        [[ "$EFF_TLS" == "1" ]] && TLS_CUSTOM="transport.tls.disableCustomTLSFirstByte = true"
        mkdir -p "${CONFIG_DIR}"
        cat <<EOF > "${CONFIG_DIR}/frpc.toml"
serverAddr = "${PEER_GRE}"
serverPort = ${SERVER_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
transport.tls.enable = true
${TLS_CUSTOM:+$TLS_CUSTOM
}transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 15
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30
transport.poolCount = 2

EOF
        local PORT
        local ENC_LINE=""
        [[ "$EFF_ENC" == "1" ]] && ENC_LINE="transport.useEncryption = true"
        local COMP_LINE=""
        [[ "$EFF_COMP" == "1" ]] && COMP_LINE="transport.useCompression = true"
        for PORT in $PORTS_CLEANED; do
            cat <<EOF >> "${CONFIG_DIR}/frpc.toml"
[[proxies]]
name = "tcp_${PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${PORT}
remotePort = ${PORT}
${ENC_LINE:+$ENC_LINE
}${COMP_LINE:+$COMP_LINE
}
[[proxies]]
name = "udp_${PORT}"
type = "udp"
localIP = "127.0.0.1"
localPort = ${PORT}
remotePort = ${PORT}
${ENC_LINE:+$ENC_LINE
}${COMP_LINE:+$COMP_LINE
}
EOF
        done
        chmod 600 "${CONFIG_DIR}/frpc.toml" 2>/dev/null || true

        cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=FRP Client Reverse Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl reset-failed frpc >/dev/null 2>&1 || true
        systemctl enable frpc >/dev/null 2>&1
        systemctl restart frpc

        local _frpc_ok=0 _i
        for _i in {1..5}; do
            sleep 2
            if systemctl is-active --quiet frpc 2>/dev/null; then
                _frpc_ok=1
                break
            fi
        done

        if [[ "$_frpc_ok" -ne 1 ]]; then
            STATUS_FRP="FAILED"
            FRP_ERR="frpc service failed to start — check: journalctl -u frpc"
            log_msg "tunnel" "ERROR" "frpc service failed to start"
        fi
    fi

    setup_chaff "" "$PEER_GRE"
    if [[ "$(perf_get_dpi_enabled)" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    fi
    tune_apply >/dev/null 2>&1 || true
    watchdog_on >/dev/null 2>&1 || true

    echo -e "\n=============================================================="
    echo "                   INSTALLATION SUMMARY"
    echo "=============================================================="
    if [[ "$STATUS_GRE" == "OK" ]]; then
        echo -e "[${GREEN}OK${NC}]     GRE Tunnel Interface (${TUNNEL_NAME}: ${IP_FOREIGN} <-> ${IP_IRAN}, IP: ${LOCAL_GRE})"
    else
        echo -e "[${RED}FAILED${NC}] GRE Tunnel Interface (${GRE_ERR})"
    fi

    if [[ "$STATUS_PING" == "OK" ]]; then
        echo -e "[${GREEN}OK${NC}]     GRE Ping Connectivity (Peer ${PEER_GRE} reachable)"
    else
        echo -e "[${YELLOW}WARN${NC}]   GRE Ping Connectivity (${PING_ERR})"
    fi

    if [[ "$STATUS_FRP" == "OK" ]]; then
        echo -e "[${GREEN}OK${NC}]     FRP Client Service (frpc active, connecting to ${PEER_GRE}:${SERVER_PORT})"
        echo -e "         Reverse ports: ${PORTS_CLEANED} (TCP & UDP, TLS)"
    else
        echo -e "[${RED}FAILED${NC}] FRP Client Service (${FRP_ERR})"
    fi
    echo "=============================================================="

    if [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" ]]; then
        echo -e "Overall Installation Status: ${GREEN}SUCCESS${NC}\n"
        log_msg "tunnel" "INFO" "FOREIGN server setup completed successfully"
        return 0
    else
        echo -e "Overall Installation Status: ${RED}PARTIALLY FAILED${NC}"
        echo -e "${YELLOW}[!] Review component failure(s) above. Do NOT assume tunnel is ready.${NC}\n"
        log_msg "tunnel" "ERROR" "FOREIGN server setup partially failed: GRE=${STATUS_GRE}, FRP=${STATUS_FRP}"
        return 1
    fi
}

# ---- Multi-peer tunnels: up to MAX_PEERS foreign servers on one Iran ----
# Peer 1 reuses the legacy names (gre-tunnel, frps.toml, frps.service) so
# existing installs keep working. Peers 2..5 get gre-tN + frps-N.toml +
# frps-N.service, each with its own token and control port (one frps
# understands only one token). Registry: /etc/gre-panel/peers.json.
PEERS_FILE="${STATE_DIR}/peers.json"
MAX_PEERS=5

peer_init() {
    mkdir -p "$(dirname "$PEERS_FILE")" "$CONFIG_DIR"
    [[ -f "$PEERS_FILE" ]] || echo '{"peers":[]}' > "$PEERS_FILE"
}

peer_require_py() {
    command -v python3 >/dev/null 2>&1 || { echo -e "${RED}[!] python3 is required for peer management.${NC}"; return 1; }
}

# print registry as-is (JSON)
peer_list() { peer_init; cat "$PEERS_FILE"; }

# smallest free peer id (1..MAX_PEERS), or 0 when full
peer_next_id() {
    peer_require_py || return 1
    PEERS_F="$PEERS_FILE" MAX_PEERS="$MAX_PEERS" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); used={p["id"] for p in d.get("peers",[])}; ids=[i for i in range(1,int(os.environ["MAX_PEERS"])+1) if i not in used]; print(ids[0] if ids else 0)'
}

# space-separated "port:peername" of all claimed reverse ports
peer_ports_used() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); print(" ".join(str(p) + ":" + str(r.get("name","")) for r in d.get("peers",[]) for p in r.get("ports",[])))'
}

# $1=id -> compact JSON record or empty
peer_get() {
    PEERS_F="$PEERS_FILE" PEER_ID="$1" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); m=[p for p in d.get("peers",[]) if p["id"]==int(os.environ["PEER_ID"])]; print(json.dumps(m[0]) if m else "")'
}

peer_token() {
    peer_init; peer_require_py || return 1
    local ID=$1 rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] No peer with id $ID.${NC}"; return 1; }
    echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
    # second line: full foreign-setup bundle (token + addresses + ports).
    # First-line token output stays unchanged for scripts.
    local B_TOK LIP FP LGRE PGRE PTS
    B_TOK=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    LIP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_pub",""))')
    FP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frp_port",""))')
    LGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_gre",""))')
    PGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("peer_gre",""))')
    PTS=$(echo "$rec" | python3 -c 'import json,sys; print(" ".join(str(x) for x in json.load(sys.stdin).get("ports",[])))')
    if is_valid_ip "$LIP" && is_valid_port "$FP" && is_valid_ip "$LGRE" && is_valid_ip "$PGRE"; then
        echo "BUNDLE:$(bundle_make "$LIP" "$FP" "$LGRE" "$PGRE" "$B_TOK" "$PTS")"
    fi
}

# write one frps instance: $1=suffix("" for legacy, "-N" for peers) $2=bind_port $3=token
peer_write_frps() {
    local SUF=$1 BIND_PORT=$2 TOKEN=$3
    local EFF_TLS MAX_POOL TLS_LINE=""
    EFF_TLS=$(perf_get_tls)
    MAX_POOL=$(perf_get_max_pool)
    [[ "$EFF_TLS" == "1" ]] && TLS_LINE="transport.tls.force = true"
    cat <<EOF > "${CONFIG_DIR}/frps${SUF}.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
${TLS_LINE:+$TLS_LINE
}transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 15
transport.heartbeatTimeout = 30
transport.maxPoolCount = ${MAX_POOL}
EOF
    chmod 600 "${CONFIG_DIR}/frps${SUF}.toml" 2>/dev/null || true
    local SVC="frps${SUF}"
    cat <<EOF > /etc/systemd/system/${SVC}.service
[Unit]
Description=FRP Server Service${SUF:+ (peer${SUF#-})}
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps${SUF}.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SVC" >/dev/null 2>&1
    systemctl restart "$SVC"
    ufw_allow_track "${BIND_PORT}/tcp"
}

# add a peer tunnel on the Iran side.
# Flags: --name --local-pub --remote-pub --frp-port --token --local-gre --peer-gre --ports "443, 2083" [--bundle hsh1_...] [--chaff low|mid|off] [--force]
# --bundle pastes a foreign-setup string: empty flags are filled from it,
# explicit flags always win.
cli_add_peer() {
    local NAME="" LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" TOKEN="" LOCAL_GRE="" PEER_GRE="" PORTS="" FORCE=0 BUNDLE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) NAME="$2"; shift 2 ;;
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) echo 'Usage: hashem.sh add-peer --local-pub IP --remote-pub IP [--frp-port N] --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL] [--bundle hsh1_...] [--chaff low|mid|off] [--force]'; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; return 1 ;;
        esac
    done
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] Unknown chaff profile '${CHAFF_PROFILE}', defaulting to low.${NC}"; CHAFF_PROFILE="low" ;;
    esac
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || { echo -e "${RED}[!] Bad --bundle (want hsh1_<IRAN_PUB>_<PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]).${NC}"; return 1; }
        # add-peer runs on Iran: bundle Iran pub/GRE are OURS, foreign GRE is THEIRS
        [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$B_IRAN_PUB
        [[ -z "$FRP_PORT" ]] && FRP_PORT=$B_FRP_PORT
        [[ -z "$LOCAL_GRE" ]] && LOCAL_GRE=$B_IRAN_GRE
        [[ -z "$PEER_GRE" ]] && PEER_GRE=$B_FOREIGN_GRE
        [[ -z "$TOKEN" ]] && TOKEN=$B_TOKEN
        [[ -z "$PORTS" ]] && PORTS=$B_PORTS
    fi
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] Invalid peer GRE IP: '$PEER_GRE'${NC}"; return 1; }
    [[ "$LOCAL_GRE" != "$PEER_GRE" ]] || { echo -e "${RED}[!] Local and peer GRE IPs must differ.${NC}"; return 1; }
    [[ -n "$TOKEN" ]] || { echo -e "${RED}[!] --token is required (generate one per peer).${NC}"; return 1; }
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do
        is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"
    done
    CLEANED=$(echo "$CLEANED" | xargs)
    [[ -n "$CLEANED" ]] || { echo -e "${RED}[!] --ports needs at least one valid port.${NC}"; return 1; }
    peer_init; peer_require_py || return 1
    local ID
    ID=$(peer_next_id)
    [[ "$ID" -ge 1 ]] || { echo -e "${RED}[!] Peer table full (max ${MAX_PEERS} foreign servers). Remove one first.${NC}"; return 1; }
    # port conflict: a remotePort can be served by only one frpc
    local USED entry CONFLICT=""
    USED=$(peer_ports_used)
    for p in $CLEANED; do
        for entry in $USED; do
            if [[ "${entry%%:*}" == "$p" ]]; then CONFLICT="$CONFLICT $p (used by peer '${entry#*:}')"; fi
        done
    done
    if [[ -n "$CONFLICT" ]]; then
        echo -e "${RED}[!] Port conflict — already claimed by another tunnel:${CONFLICT}${NC}"
        echo -e "${YELLOW}    Pick a different port for this peer (e.g. 8443 instead of 443).${NC}"
        return 1
    fi
    # control port must be free on this machine
    if ss -tln 2>/dev/null | grep -q ":${FRP_PORT} "; then
        echo -e "${RED}[!] Control port ${FRP_PORT} is already in use on this server — use another one.${NC}"
        return 1
    fi
    # GRE inner IPs must be unique across peers
    if grep -q "\"local_gre\": *\"${LOCAL_GRE}\"" "$PEERS_FILE" || grep -q "\"peer_gre\": *\"${LOCAL_GRE}\"" "$PEERS_FILE"; then
        echo -e "${RED}[!] GRE IP ${LOCAL_GRE} is already used by another peer.${NC}"; return 1
    fi
    [[ -z "$NAME" ]] && NAME="peer-${ID}"
    install_frp_binaries || return 1
    local GRE_IF FRPS_SVC LEGACY
    if [[ "$ID" -eq 1 ]] && ! tunnel_present; then
        # first tunnel keeps legacy names (gre-tunnel, frps) — old setups untouched
        setup_gre_systemd "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE"
        peer_write_frps "" "$FRP_PORT" "$TOKEN"
        GRE_IF="$TUNNEL_NAME"; FRPS_SVC="frps"; LEGACY=true
        setup_chaff "" "$PEER_GRE"
    else
        GRE_IF="gre-t${ID}"; FRPS_SVC="frps-${ID}"; LEGACY=false
        setup_gre_iface "$GRE_IF" "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE"
        peer_write_frps "-${ID}" "$FRP_PORT" "$TOKEN"
        # point the new unit at the right interface
        sed -i "s/After=network.target/After=network.target ${GRE_IF}.service/" /etc/systemd/system/${FRPS_SVC}.service
        systemctl daemon-reload; systemctl restart "$FRPS_SVC"
        setup_chaff "-${ID}" "$PEER_GRE"
    fi
    # registry record (ports as JSON array)
    local PORTS_JSON
    PORTS_JSON=$(echo "$CLEANED" | python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.stdin.read().split()]))')
    PEERS_F="$PEERS_FILE" python3 - "$ID" "$NAME" "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_JSON" "$GRE_IF" "$FRPS_SVC" "$LEGACY" "${CHAFF_PROFILE:-low}" <<'PYEOF'
import json, os, sys
f = os.environ["PEERS_F"]
iid, name, lip, rip, fport, tok, lgre, pgre, pjson, gif, svc, leg, prof = sys.argv[1:]
d = json.load(open(f))
d.setdefault("peers", []).append({"id": int(iid), "name": name, "local_pub": lip,
  "remote_pub": rip, "frp_port": int(fport), "token": tok, "local_gre": lgre,
  "peer_gre": pgre, "ports": json.loads(pjson), "gre_if": gif, "frps_svc": svc,
  "legacy": leg == "true", "chaff_profile": prof})
json.dump(d, open(f, "w"), indent=2)
PYEOF
    chmod 600 "$PEERS_FILE" 2>/dev/null || true
    echo -e "${GREEN}[✔️] Peer '${NAME}' (id ${ID}) added: GRE ${LOCAL_PUB} <-> ${REMOTE_PUB} (${LOCAL_GRE} peer ${PEER_GRE} on ${GRE_IF}), ${FRPS_SVC} :${FRP_PORT}${NC}"
    echo -e "${YELLOW}Token for '${NAME}': ${TOKEN} (enter it on the FOREIGN side with ports: ${CLEANED})${NC}"
    echo -e "BUNDLE:$(bundle_make "$LOCAL_PUB" "$FRP_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN" "$CLEANED")"
    echo -e "${CYAN}Foreign side: frpc server ${LOCAL_GRE}:${FRP_PORT}${NC}"
}

# remove one peer ($1=id). Legacy peer 1 also drops the old single tunnel.
cli_remove_peer() {
    local ID="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --id) ID="$2"; shift 2 ;; --force) FORCE=1; shift ;;
            -h|--help) echo 'Usage: hashem.sh remove-peer --id N [--force]'; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; return 1 ;; esac
    done
    [[ "$ID" =~ ^[0-9]+$ ]] || { echo -e "${RED}[!] --id N is required.${NC}"; return 1; }
    peer_init; peer_require_py || return 1
    local rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] No peer with id $ID.${NC}"; return 1; }
    local NAME GIF SVC LEG
    NAME=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    GIF=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gre_if"])')
    SVC=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["frps_svc"])')
    LEG=$(echo "$rec" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("legacy") else "0")')
    if [[ "$FORCE" -ne 1 ]]; then
        read -p "Remove peer '${NAME}' (id ${ID})? GRE + its frps go away. (y/N): " CONFIRM || return 1
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[*] Aborted.${NC}"; return 0; }
    fi
    if [[ "$LEG" == "1" ]]; then
        remove_tunnel_force
    else
        systemctl stop "$SVC" "${GIF}.service" "gre-chaff-${ID}.service" >/dev/null 2>&1
        systemctl disable "$SVC" "${GIF}.service" "gre-chaff-${ID}.service" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${GIF}.service" "/etc/frp/frps-${ID}.toml" "/etc/systemd/system/gre-chaff-${ID}.service"
        systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1 || true
        ip tunnel del "$GIF" >/dev/null 2>&1 || true
    fi
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" python3 -c \
'import json,os; f=os.environ["PEERS_F"]; d=json.load(open(f)); d["peers"]=[p for p in d.get("peers",[]) if p["id"]!=int(os.environ["PEER_ID"])]; json.dump(d,open(f,"w"),indent=2)' \
        || echo -e "${YELLOW}[!] peers registry already gone — nothing left to clean.${NC}"
    echo -e "${GREEN}[✔️] Peer '${NAME}' (id ${ID}) removed.${NC}"
}

# readable peer table for the menu
peer_list_pretty() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 <<'PYEOF'
import json, os, subprocess
try:
    peers = json.load(open(os.environ["PEERS_F"])).get("peers", [])
except Exception as e:
    print(f"[!] cannot read peers registry: {e}"); raise SystemExit(1)
if not peers:
    print("[*] No peer tunnels yet. Use 'Add peer tunnel' to connect a foreign server.")
    raise SystemExit(0)
tun = subprocess.run(["ip", "tunnel", "show"], capture_output=True, text=True).stdout
for p in sorted(peers, key=lambda x: x["id"]):
    gre = "up" if p.get("gre_if", "") in tun else "down"
    try:
        frp = subprocess.run(["systemctl", "is-active", p.get("frps_svc", "")],
                             capture_output=True, text=True).stdout.strip()
    except Exception:
        frp = "?"
    print(f"#{p['id']} {p['name']}: {p['remote_pub']} (GRE {p['local_gre']} peer {p['peer_gre']}, {p['gre_if']} {gre}) "
          f"| {p['frps_svc']} :{p['frp_port']} {frp} | ports: {','.join(map(str, p.get('ports', [])))}")
PYEOF
}

setup_iran_server() {
    echo -e "\n${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}       STEP 1: CONFIGURING IRAN SERVER (GRE + FRPS)  ${NC}"
    echo -e "${YELLOW}====================================================${NC}"

    local MY_PUBLIC_IP IP_IRAN IP_FOREIGN BIND_PORT AUTO_TOKEN TOKEN
    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    prompt_ip IP_IRAN "Enter IRAN Server Public IP" "$MY_PUBLIC_IP" || return 1
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "" || return 1

    prompt_port BIND_PORT "Enter FRP Bind Port" "$(gen_random_port)" || return 1
    BIND_PORT=$(ensure_port_available "$BIND_PORT" "FRP Bind Port" 0) || return 1

    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Enter Secret Auth Token" "$AUTO_TOKEN" || return 1

    # single source of truth: GRE + frps all happen inside
    setup_iran_server_noninteractive "$IP_IRAN" "$IP_FOREIGN" "$BIND_PORT" "$TOKEN" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP"
}

# interactive wrapper for cli_add_peer: prompts for one more foreign server.
menu_add_peer() {
    echo -e "\n${YELLOW}=== Add Peer Tunnel (connect ANOTHER foreign server to this Iran) ===${NC}"
    peer_init
    local USED MYIP
    USED=$(peer_ports_used 2>/dev/null)
    [[ -n "$USED" ]] && echo -e "${CYAN}Already claimed reverse ports: ${USED}${NC}"
    MYIP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    local NAME IP_FOREIGN LOCAL_IRAN CPORT TOKEN LGRE PGRE PPORTS AUTO_TOKEN
    read -p "Peer name (e.g. germany-1) [Enter for auto]: " NAME || return 1
    prompt_ip LOCAL_IRAN "Enter IRAN Server Public IP" "$MYIP" || return 1
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "" || return 1
    # suggest next free control port + GRE pair
    local NEXT_ID SU_FP SU_LG SU_PG
    NEXT_ID=$(peer_next_id 2>/dev/null || echo 2)
    SU_FP=$(gen_random_port)
    SU_LG="10.1${NEXT_ID}.0.2"; SU_PG="10.1${NEXT_ID}.0.1"
    prompt_port CPORT "Enter FRP Control Port (unique per peer)" "$SU_FP" || return 1
    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Peer token (each peer gets its own)" "$AUTO_TOKEN" || return 1
    prompt_ip LGRE "Local GRE IP (unique per peer)" "$SU_LG" || return 1
    prompt_ip PGRE "Peer GRE IP" "$SU_PG" || return 1
    prompt_ports PPORTS "Ports to Reverse-Tunnel" || return 1
    cli_add_peer --name "$NAME" --local-pub "$LOCAL_IRAN" --remote-pub "$IP_FOREIGN" \
        --frp-port "$CPORT" --token "$TOKEN" --local-gre "$LGRE" --peer-gre "$PGRE" --ports "$PPORTS" || return 1
    echo -e "\n${GREEN}=== On the FOREIGN server, run this script option 2 with: ===${NC}"
    echo -e "IRAN Public IP: ${CYAN}${LOCAL_IRAN}${NC} | Port: ${CYAN}${CPORT}${NC} | Token: ${CYAN}${TOKEN}${NC}"
    echo -e "GRE: local ${CYAN}${PGRE}${NC} peer ${CYAN}${LGRE}${NC} | Ports: ${CYAN}${PPORTS}${NC}"
}

menu_remove_peer() {
    echo -e "\n${YELLOW}=== Remove Peer Tunnel ===${NC}"
    peer_list_pretty || return 1
    local ID
    read -p "Peer id to remove: " ID || return 1
    cli_remove_peer --id "$ID"
}

setup_foreign_server() {
    echo -e "\n${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}   STEP 2: CONFIGURING FOREIGN SERVER (GRE + FRPC)  ${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    local MY_PUBLIC_IP BUNDLE_IN CONFIRM_APPLY
    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)

    echo -e "Do you have a Setup Bundle from the Iran server? (${CYAN}hsh1_...${NC})"
    read -p "Enter Setup Bundle [Press Enter to configure manually]: " BUNDLE_IN || return 1
    local SERVER_PORT TOKEN INPUT_PORTS BUNDLE_USED=0 LOCAL_GRE_SET="$FOREIGN_GRE_IP" PEER_GRE_SET="$IRAN_GRE_IP"
    local IP_FOREIGN="" IP_IRAN="" PORTS_CLEANED

    if [[ -n "$BUNDLE_IN" ]]; then
        if bundle_parse "$BUNDLE_IN"; then
            echo ""
            cli_bundle_inspect "$BUNDLE_IN"
            read -p "Apply this bundle configuration? [Y/n]: " CONFIRM_APPLY || return 1
            if [[ "$CONFIRM_APPLY" =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}[*] Bundle application cancelled by user. Returning to menu.${NC}"
                return 0
            fi
            BUNDLE_USED=1
            IP_IRAN=$B_IRAN_PUB
            SERVER_PORT=$B_FRP_PORT
            TOKEN=$B_TOKEN
            LOCAL_GRE_SET=$B_FOREIGN_GRE
            PEER_GRE_SET=$B_IRAN_GRE
            INPUT_PORTS=$(echo "$B_PORTS" | tr ' ' ',')
            carrier_set_fou_ports "$B_FOU_P1" "$B_FOU_P2" 2>/dev/null || true
            carrier_init_kernel 2>/dev/null || true
            prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "$MY_PUBLIC_IP" || return 1
            if [[ -z "$INPUT_PORTS" ]]; then
                prompt_ports INPUT_PORTS "Enter Ports to Reverse-Tunnel" || return 1
            fi
        else
            echo -e "${RED}[!] Invalid bundle format. Falling back to manual input.${NC}"
        fi
    fi

    if [[ "$BUNDLE_USED" -ne 1 ]]; then
        prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "$MY_PUBLIC_IP" || return 1
        prompt_ip IP_IRAN "Enter IRAN Server Public IP" "" || return 1
        prompt_port SERVER_PORT "Enter FRP Server Port (from Iran server)" "$(gen_random_port)" || return 1
        prompt_required TOKEN "Enter Secret Auth Token" || return 1
        prompt_ports INPUT_PORTS "Enter Ports to Reverse-Tunnel" || return 1
    fi

    PORTS_CLEANED=$(echo "$INPUT_PORTS" | tr ',' ' ')

    # single source of truth: GRE + ping + frpc all happen inside
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE_SET" "$PEER_GRE_SET" "$PORTS_CLEANED"
}

check_status() {
    echo -e "\n${YELLOW}=== Checking GRE & FRP Status ===${NC}"

    # 1. GRE Status
    echo -e "\n${CYAN}[1] GRE Tunnel Interface:${NC}"
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        ip addr show dev "$TUNNEL_NAME"
        echo -e "${GREEN}[✔️] Interface ${TUNNEL_NAME} exists and is UP.${NC}"
    else
        echo -e "${RED}[!] Interface ${TUNNEL_NAME} NOT found.${NC}"
    fi

    # 2. Ping Test
    echo -e "\n${CYAN}[2] GRE Ping Test:${NC}"
    local TARGET_PING
    if ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP"; then
        TARGET_PING="$FOREIGN_GRE_IP"
        echo "Testing ping to Foreign GRE IP ($TARGET_PING)..."
    else
        TARGET_PING="$IRAN_GRE_IP"
        echo "Testing ping to Iran GRE IP ($TARGET_PING)..."
    fi
    ping -c 3 -W 2 "$TARGET_PING" && echo -e "${GREEN}[✔️] Ping OK.${NC}" || echo -e "${YELLOW}[!] Remote peer did not answer ping.${NC}"

    # 3. FRP Service Status
    echo -e "\n${CYAN}[3] FRP Service Status:${NC}"
    if systemctl is-active --quiet frps; then
        echo -e "${GREEN}[✔️] frps (Server on IRAN) is ACTIVE and RUNNING.${NC}"
        systemctl status frps --no-pager -l
    elif systemctl is-active --quiet frpc; then
        echo -e "${GREEN}[✔️] frpc (Client on FOREIGN) is ACTIVE and RUNNING.${NC}"
        systemctl status frpc --no-pager -l
    else
        echo -e "${RED}[!] Neither frps nor frpc is active.${NC}"
    fi
}

show_logs() {
    echo -e "\n${YELLOW}=== Live Service Logs (Ctrl+C returns to the menu) ===${NC}"
    if systemctl list-unit-files | grep -q "frps.service"; then
        journalctl -u frps -n 50 -f
    elif systemctl list-unit-files | grep -q "frpc.service"; then
        journalctl -u frpc -n 50 -f
    else
        echo -e "${RED}[!] No FRP service found.${NC}"
    fi
}

restart_all() {
    echo -e "\n${CYAN}[*] Restarting GRE and FRP services (all tunnels)...${NC}"
    local u
    for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-tunnel.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service /etc/systemd/system/gre-chaff*.service; do
        [[ -f "$u" ]] || continue
        systemctl restart "$(basename "$u")" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] $(basename "$u") restarted.${NC}"
    done
    echo -e "${GREEN}[✔️] All services restarted.${NC}"
}

ensure_doctor_tools() {
    local NEED_INSTALL=0 cmd
    for cmd in iperf3 ping curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_INSTALL=1
            break
        fi
    done
    if [[ "$NEED_INSTALL" -eq 1 ]]; then
        local HAD_IPERF=0
        command -v iperf3 >/dev/null 2>&1 && HAD_IPERF=1
        echo -e "${CYAN}[*] Installing diagnostic tools (iperf3, iputils-ping, curl)...${NC}"
        if apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 iputils-ping curl; then
            # remember that WE installed iperf3 so a full uninstall can remove it again
            if [[ "$HAD_IPERF" -eq 0 ]] && command -v iperf3 >/dev/null 2>&1; then
                mkdir -p "$STATE_DIR"; : > "${STATE_DIR}/pkg-iperf3.installed"
            fi
        else
            echo -e "${YELLOW}[!] Warning: failed to install some diagnostic tools.${NC}"
        fi
    fi
}

doctor_diagnostics() {
    ensure_doctor_tools

    echo -e "\n${CYAN}==========================================================${NC}"
    echo -e "${CYAN}      Hashem Diagnostics & Speed Test (Doctor Suite)      ${NC}"
    echo -e "${CYAN}==========================================================${NC}\n"

    # 1. Determine Peer IP
    local ROLE="unknown"
    local TARGET_IP=""
    local LOCAL_IP=""

    if ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP"; then
        ROLE="Iran (Server)"
        LOCAL_IP="$IRAN_GRE_IP"
        TARGET_IP="$FOREIGN_GRE_IP"
    elif ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$FOREIGN_GRE_IP"; then
        ROLE="Foreign (Client)"
        LOCAL_IP="$FOREIGN_GRE_IP"
        TARGET_IP="$IRAN_GRE_IP"
    else
        local IFACE
        IFACE=$(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | head -n1)
        if [[ -n "$IFACE" ]]; then
            LOCAL_IP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            if [[ "$LOCAL_IP" =~ \.1$ ]]; then
                TARGET_IP="${LOCAL_IP%.*}.2"
                ROLE="Foreign"
            elif [[ "$LOCAL_IP" =~ \.2$ ]]; then
                TARGET_IP="${LOCAL_IP%.*}.1"
                ROLE="Iran"
            fi
        fi
    fi

    echo -e "  ${YELLOW}Role:${NC}        ${ROLE}"
    echo -e "  ${YELLOW}Tunnel:${NC}      ${TUNNEL_NAME:-gre-tunnel}"
    echo -e "  ${YELLOW}Local IP:${NC}    ${LOCAL_IP:-N/A}"
    echo -e "  ${YELLOW}Peer IP:${NC}     ${TARGET_IP:-N/A}\n"

    if [[ -z "$TARGET_IP" ]]; then
        echo -e "${RED}[!] Tunnel interface is not active or peer IP cannot be determined.${NC}"
        return 1
    fi

    # 2. Ping & Jitter Test (10 packets)
    echo -e "${CYAN}[1/4] Measuring Latency, Packet Loss & Jitter (10 packets)...${NC}"
    local PING_OUT
    PING_OUT=$(ping -c 10 -W 2 "$TARGET_IP" 2>&1)
    local LOSS
    LOSS=$(echo "$PING_OUT" | awk -F',' '/packet loss/ {for(i=1;i<=NF;i++) if($i~/packet loss/) print $(i-0)}' | tr -dc '0-9.')
    local RTT_LINE
    RTT_LINE=$(echo "$PING_OUT" | grep -E '(rtt|round-trip) min/avg/max')

    local MIN_RTT="0" AVG_RTT="0" MAX_RTT="0" JITTER="0"
    if [[ -n "$RTT_LINE" ]]; then
        local STATS
        STATS=$(echo "$RTT_LINE" | awk -F'=' '{print $2}' | tr -d ' ' | cut -d'/' -f1-4)
        MIN_RTT=$(echo "$STATS" | cut -d'/' -f1)
        AVG_RTT=$(echo "$STATS" | cut -d'/' -f2)
        MAX_RTT=$(echo "$STATS" | cut -d'/' -f3)
        JITTER=$(echo "$STATS" | cut -d'/' -f4)
    fi

    local LOSS_INT="${LOSS%%.*}"
    LOSS_INT="${LOSS_INT:-0}"

    echo -e "  • Packet Loss:  ${LOSS:-0}%"
    echo -e "  • Min RTT:      ${MIN_RTT} ms"
    echo -e "  • Avg RTT:      ${AVG_RTT} ms"
    echo -e "  • Max RTT:      ${MAX_RTT} ms"
    echo -e "  • Jitter (mdev):${JITTER} ms"

    if [[ "$LOSS_INT" -eq 0 ]]; then
        echo -e "  ${GREEN}[✔️] Ping test passed with zero packet loss.${NC}\n"
    elif [[ "$LOSS_INT" -le 10 ]]; then
        echo -e "  ${YELLOW}[⚠️] Mild packet loss (${LOSS}%).${NC}\n"
    else
        echo -e "  ${RED}[!] High packet loss detected (${LOSS}%).${NC}\n"
    fi

    # 3. Path MTU Discovery
    echo -e "${CYAN}[2/4] Testing Path MTU & Fragmentation...${NC}"
    local OPTIMAL_MTU=0
    # 1420
    if ping -c 2 -W 2 -M do -s 1392 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1420: ${GREEN}PASS (Unfragmented)${NC}"
        OPTIMAL_MTU=1420
    else
        echo -e "  • MTU 1420: ${YELLOW}FRAGMENTED${NC}"
    fi

    # 1400
    if ping -c 2 -W 2 -M do -s 1372 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1400: ${GREEN}PASS (Unfragmented)${NC}"
        [[ "$OPTIMAL_MTU" -eq 0 ]] && OPTIMAL_MTU=1400
    else
        echo -e "  • MTU 1400: ${YELLOW}FRAGMENTED${NC}"
    fi

    # 1360
    if ping -c 2 -W 2 -M do -s 1332 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1360: ${GREEN}PASS (Unfragmented)${NC}"
        [[ "$OPTIMAL_MTU" -eq 0 ]] && OPTIMAL_MTU=1360
    else
        echo -e "  • MTU 1360: ${RED}FAILED${NC}"
    fi

    echo -e "  ${GREEN}[✔️] Optimal Recommended MTU: ${OPTIMAL_MTU:-1400} bytes.${NC}\n"

    # 4. Kernel TCP Stack Audit
    echo -e "${CYAN}[3/4] Auditing Kernel TCP Stack & Forwarding...${NC}"
    local CC
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local FWD
    FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    local MSS_COUNT
    MSS_COUNT=$(iptables -t mangle -L -v -n 2>/dev/null | grep -c "TCPMSS" || echo "0")

    if [[ "$CC" == "bbr" ]]; then
        echo -e "  • TCP Congestion Control: ${GREEN}BBR (Active)${NC}"
    else
        echo -e "  • TCP Congestion Control: ${YELLOW}${CC} (BBR not enabled)${NC}"
    fi

    if [[ "$FWD" == "1" ]]; then
        echo -e "  • IPv4 Forwarding:        ${GREEN}Enabled${NC}"
    else
        echo -e "  • IPv4 Forwarding:        ${RED}Disabled${NC}"
    fi

    if [[ "$MSS_COUNT" -gt 0 ]]; then
        echo -e "  • TCP MSS Clamping:       ${GREEN}Active (${MSS_COUNT} rules)${NC}\n"
    else
        echo -e "  • TCP MSS Clamping:       ${YELLOW}Not configured${NC}\n"
    fi

    # 5. Throughput / iPerf3 Test
    echo -e "${CYAN}[4/4] Bandwidth & Throughput Speed Test...${NC}"
    if command -v iperf3 >/dev/null 2>&1; then
        echo -e "  Attempting 3-second throughput benchmark to ${TARGET_IP}:5201..."
        local IPERF_OUT
        IPERF_OUT=$(iperf3 -c "$TARGET_IP" -t 3 -J 2>/dev/null)
        if [[ -n "$IPERF_OUT" ]] && echo "$IPERF_OUT" | grep -q '"bits_per_second"'; then
            local BPS
            BPS=$(echo "$IPERF_OUT" | awk -F'"bits_per_second":' '/"bits_per_second"/ {print $2}' | tr -dc '0-9.' | head -n1)
            local MBPS
            MBPS=$(awk -v b="$BPS" 'BEGIN { if (b > 0) printf "%.2f", b / 1000000; else print "0" }')
            echo -e "  ${GREEN}[✔️] Throughput Speed: ${MBPS} Mbps${NC}\n"
        else
            echo -e "  ${YELLOW}[i] Remote iperf3 server not running on ${TARGET_IP}:5201.${NC}"
            echo -e "      (Run 'hashem doctor server' on the remote server to enable direct speed tests).\n"
        fi
    fi

    # 6. Overall Rating & Recommendations
    local SCORE=100
    if [[ "$LOSS_INT" -gt 0 ]]; then
        SCORE=$((SCORE - LOSS_INT * 2))
    fi
    if [[ "$AVG_RTT" != "0" ]] && awk -v r="$AVG_RTT" 'BEGIN { exit (r > 100 ? 0 : 1) }'; then
        SCORE=$((SCORE - 15))
    fi
    if [[ "$CC" != "bbr" ]]; then
        SCORE=$((SCORE - 15))
    fi
    if [[ "$FWD" != "1" ]]; then
        SCORE=$((SCORE - 20))
    fi
    if [[ "$MSS_COUNT" -eq 0 ]]; then
        SCORE=$((SCORE - 10))
    fi
    if [[ "$OPTIMAL_MTU" -lt 1400 && "$OPTIMAL_MTU" -gt 0 ]]; then
        SCORE=$((SCORE - 10))
    fi
    [[ "$SCORE" -lt 0 ]] && SCORE=0

    echo -e "${CYAN}==========================================================${NC}"
    echo -e "  ${YELLOW}Overall Health Score:${NC} ${SCORE}/100"
    if [[ "$SCORE" -ge 85 ]]; then
        echo -e "  ${GREEN}Status: EXCELLENT — Tunnel is fully optimized.${NC}"
    elif [[ "$SCORE" -ge 70 ]]; then
        echo -e "  ${CYAN}Status: GOOD — Minor optimizations recommended.${NC}"
    elif [[ "$SCORE" -ge 50 ]]; then
        echo -e "  ${YELLOW}Status: WARNING — Packet loss or kernel bottlenecks present.${NC}"
    else
        echo -e "  ${RED}Status: CRITICAL — Major network or routing issues detected.${NC}"
    fi
    echo -e "${CYAN}==========================================================${NC}\n"

    if [[ "$SCORE" -lt 85 ]]; then
        local DO_FIX
        read -p "Would you like to automatically apply recommended fixes (BBR, MSS, MTU)? [y/N]: " DO_FIX || DO_FIX=""
        if [[ "$DO_FIX" =~ ^[Yy]$ ]]; then
            doctor_apply_fixes
        fi
    fi
}

doctor_apply_fixes() {
    echo -e "\n${CYAN}[*] Applying automated optimizations...${NC}"
    tune_apply
    echo -e "${GREEN}[✔️] Optimizations applied successfully.${NC}\n"
}

doctor_start_server() {
    ensure_doctor_tools
    if pgrep -x iperf3 >/dev/null 2>&1; then
        echo -e "${YELLOW}[i] iperf3 server is already running.${NC}"
    else
        iperf3 -s -D
        echo -e "${GREEN}[✔️] iperf3 server started in background on port 5201.${NC}"
    fi
}

doctor_stop_server() {
    pkill -f "iperf3 -s" >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] iperf3 server stopped.${NC}"
}

doctor_health_check() {
    echo -e "\n${CYAN}=============================================================="
    echo "             HASHEM SYSTEM & TUNNEL HEALTH CHECK"
    echo -e "==============================================================${NC}"

    local PASS_COUNT=0 WARN_COUNT=0 FAIL_COUNT=0

    report_item() {
        local name="$1" status="$2" details="$3"
        local badge
        case "$status" in
            PASS) badge="${GREEN}[PASS]${NC}"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
            WARN) badge="${YELLOW}[WARN]${NC}"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
            FAIL) badge="${RED}[FAIL]${NC}"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        esac
        printf "%-8b %-30s %s\n" "$badge" "$name" "$details"
    }

    # 1. OS & Architecture
    local OS_INFO
    OS_INFO=$(uname -s -m 2>/dev/null || echo "Linux")
    report_item "Operating System & Arch" "PASS" "$OS_INFO"

    # 2. Linux Kernel Version
    local KERNEL_VER
    KERNEL_VER=$(uname -r 2>/dev/null || echo "Unknown")
    report_item "Linux Kernel Version" "PASS" "$KERNEL_VER"

    # 3. IP Forwarding
    local IP_FWD
    IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    if [[ "$IP_FWD" == "1" ]]; then
        report_item "IP Forwarding (ip_forward)" "PASS" "Enabled (1)"
    else
        report_item "IP Forwarding (ip_forward)" "WARN" "Disabled (0) — enable via sysctl"
    fi

    # 4. GRE Kernel Modules
    if lsmod 2>/dev/null | grep -q "ip_gre" || modprobe ip_gre 2>/dev/null; then
        report_item "Kernel Module (ip_gre)" "PASS" "Loaded"
    else
        report_item "Kernel Module (ip_gre)" "FAIL" "Missing / Cannot load ip_gre module"
    fi

    # 5. FOU Kernel Module
    if lsmod 2>/dev/null | grep -q "fou" || modprobe fou 2>/dev/null; then
        report_item "Kernel Module (fou)" "PASS" "Loaded"
    else
        report_item "Kernel Module (fou)" "WARN" "FOU module not available (fallback to direct GRE)"
    fi

    # 6. GRE Interface Status
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER_IP
        INNER_IP=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}')
        if [[ -n "$INNER_IP" ]]; then
            report_item "GRE Interface (${TUNNEL_NAME})" "PASS" "UP with IP: $INNER_IP"
        else
            report_item "GRE Interface (${TUNNEL_NAME})" "WARN" "Interface exists but no IPv4 assigned"
        fi
    else
        report_item "GRE Interface (${TUNNEL_NAME})" "WARN" "Interface not found"
    fi

    # 7. GRE Peer Ping Connectivity
    local PEER_PING_TARGET=""
    if [[ -f /etc/frp/frpc.toml ]]; then
        PEER_PING_TARGET=$(awk -F'=' '/serverAddr/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frpc.toml 2>/dev/null)
    elif [[ -f /etc/frp/frps.toml ]]; then
        PEER_PING_TARGET="$FOREIGN_GRE_IP"
    fi
    if [[ -n "$PEER_PING_TARGET" ]]; then
        local P_OUT
        if P_OUT=$(ping -c 2 -W 2 "$PEER_PING_TARGET" 2>/dev/null); then
            local RTT
            RTT=$(echo "$P_OUT" | awk -F'/' '/rtt/ {print $5}')
            report_item "GRE Peer Connectivity" "PASS" "Reachable (${RTT:-<50} ms)"
        else
            report_item "GRE Peer Connectivity" "FAIL" "Cannot ping peer ${PEER_PING_TARGET}"
        fi
    else
        report_item "GRE Peer Connectivity" "WARN" "No peer IP configured yet"
    fi

    # 8. FRPS Service
    if [[ -f /etc/systemd/system/frps.service ]]; then
        if systemctl is-active --quiet frps 2>/dev/null; then
            local F_PORT
            F_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
            report_item "FRP Server (frps)" "PASS" "Active and listening on port :${F_PORT:-unknown}"
        else
            report_item "FRP Server (frps)" "FAIL" "Service installed but NOT running"
        fi
    fi

    # 9. FRPC Service
    if [[ -f /etc/systemd/system/frpc.service ]]; then
        if systemctl is-active --quiet frpc 2>/dev/null; then
            report_item "FRP Client (frpc)" "PASS" "Active (Reverse Tunnel Established)"
        else
            report_item "FRP Client (frpc)" "FAIL" "Service installed but NOT running"
        fi
    fi

    # 10. Firewall / Ports
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        report_item "Firewall (UFW)" "PASS" "Active (ports configured)"
    else
        report_item "Firewall (UFW)" "PASS" "Permissive / inactive"
    fi

    echo -e "${CYAN}==============================================================${NC}"
    if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
        echo -e "OVERALL HEALTH RESULT: ${GREEN}PASS${NC} (All checks passed successfully)"
    elif [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo -e "OVERALL HEALTH RESULT: ${YELLOW}WARN${NC} (${WARN_COUNT} warning(s) detected, system functional)"
    else
        echo -e "OVERALL HEALTH RESULT: ${RED}FAIL${NC} (${FAIL_COUNT} critical failure(s) detected)"
    fi
    echo -e "${CYAN}==============================================================${NC}\n"
}

cli_doctor() {
    case "${1:-}" in
        server) doctor_start_server ;;
        stop-server) doctor_stop_server ;;
        fix) doctor_apply_fixes ;;
        diag|speed) doctor_diagnostics ;;
        check|*) doctor_health_check ;;
    esac
}

remove_gre_interfaces() {
    local gif
    for gif in "$TUNNEL_NAME" $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^gre-t([0-9]+|unnel)$'); do
        ip tunnel del "$gif" >/dev/null 2>&1 || ip link del "$gif" >/dev/null 2>&1 || true
    done
}

# stop+disable a list of unit names (basenames) and delete their unit files
remove_units() {
    local unit
    for unit in "$@"; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${unit}"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
}

# Non-interactive core: stop/disable units, drop interfaces, remove FRP files.
remove_tunnel_force() {
    local u units=()
    for u in /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service \
             /etc/systemd/system/gre-tunnel.service /etc/systemd/system/gre-t[0-9]*.service \
             /etc/systemd/system/gre-chaff*.service; do
        [[ -f "$u" ]] && units+=("$(basename "$u")")
    done
    cli_dpi_shield off >/dev/null 2>&1 || true
    [[ ${#units[@]} -gt 0 ]] && remove_units "${units[@]}"
    rm -f /etc/systemd/system/hashem-dpi.service

    remove_gre_interfaces

    rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
    rm -rf "$CONFIG_DIR"
    rm -f "$PEERS_FILE"

    echo -e "${GREEN}[✔️] Tunnel removed — GRE interfaces, FRP services, binaries and configs gone.${NC}"
}

remove_tunnel() {
    echo -e "\n${RED}=== Removing GRE + FRP Tunnel ===${NC}"
    local CONFIRM
    read -p "Remove the tunnel from THIS server? (y/N): " CONFIRM || return 1
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        remove_tunnel_force
    else
        echo -e "${YELLOW}[*] Aborted.${NC}"
    fi
}

# ---- Network optimization for tunnel throughput ----
# Same on both roles. Backup lives in TUNE_BACKUP (key=value snapshot),
# restored by tune_restore(). Idempotent — safe to run twice.
TUNE_BACKUP="${STATE_DIR}/tune.bak"

tune_backup_once() {
    if [[ -f "$TUNE_BACKUP" ]]; then return 0; fi
    mkdir -p "$(dirname "$TUNE_BACKUP")"
    : > "$TUNE_BACKUP"
    local k v
    for k in net.ipv4.ip_forward net.core.rmem_max net.core.wmem_max \
             net.core.rmem_default net.core.wmem_default net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
             net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
             net.ipv4.tcp_syncookies \
             net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_window_scaling net.ipv4.tcp_mtu_probing \
             net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
             net.core.default_qdisc net.ipv4.tcp_congestion_control; do
        v=$(sysctl -n "$k" 2>/dev/null) || v=""
        echo "$k=$v" >> "$TUNE_BACKUP"
    done
    if lsmod 2>/dev/null | grep -q "^tcp_bbr"; then echo "tcp_bbr=loaded" >> "$TUNE_BACKUP";
    else echo "tcp_bbr=absent" >> "$TUNE_BACKUP"; fi
    echo "gre_mtu=$(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')" >> "$TUNE_BACKUP"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
       iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "mss_clamp=present" >> "$TUNE_BACKUP"
    else
        echo "mss_clamp=absent" >> "$TUNE_BACKUP"
    fi
    echo -e "${CYAN}[*] Current settings backed up to ${TUNE_BACKUP}.${NC}"
}

tune_apply() {
    tune_backup_once
    echo -e "${CYAN}[*] Optimizing network stack for tunnel throughput & stability...${NC}"

    # 1. BBR congestion control + fq queuing (best for high-latency / lossy links)
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] TCP congestion control → bbr + fq${NC}"
    else
        echo -e "${YELLOW}[!] bbr unavailable — keeping current CC.${NC}"
    fi

    # 2. Bigger socket buffers (16MB) and full TCP window scaling
    sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1
    sysctl -w net.core.rmem_default=1048576 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=1048576 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 1048576 16777216" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 1048576 16777216" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] Socket buffers → 16MB (rmem/wmem max + window scaling)${NC}"

    # 3. Deeper NIC queue and connection backlog
    sysctl -w net.core.netdev_max_backlog=10000 >/dev/null 2>&1
    sysctl -w net.core.somaxconn=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] Network backlog → 10000 / 8192${NC}"

    # 4. Anti-stall and keepalive tuning
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_time=30 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] TCP keepalive (30s) + MTU probe + slow-start idle off${NC}"

    # 5. GRE MTU 1380 for tunnel interface and any peer interfaces
    local iface
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^gre-t'); do
        ip link set dev "$iface" mtu 1380 >/dev/null 2>&1 || true
    done
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        ip link set dev "$TUNNEL_NAME" mtu 1380 >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ${TUNNEL_NAME} MTU → 1380${NC}" || echo -e "${YELLOW}[!] Could not set GRE MTU.${NC}"
    else
        echo -e "${YELLOW}[*] No ${TUNNEL_NAME} interface yet — MTU will apply on next setup.${NC}"
    fi

    # 6. MSS clamp (set-mss 1340) so TCP never fragments through the tunnel
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340
    echo -e "${GREEN}[✔️] TCP MSS clamp → 1340 (zero fragmentation)${NC}"

    # 7. Persist across reboots
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-gre-tune.conf <<'EOF'
# Hashem tunnel optimization (applied by the optimize / tune command)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_forward = 1
EOF
    echo -e "${GREEN}[✔️] Settings persisted in /etc/sysctl.d/99-gre-tune.conf${NC}"
    echo -e "${GREEN}[✔️] Optimization done — run Restore if anything feels worse.${NC}"
}

tune_restore() {
    if [[ ! -f "$TUNE_BACKUP" ]]; then
        echo -e "${YELLOW}[!] No backup found at ${TUNE_BACKUP} — nothing to restore.${NC}"
        return 1
    fi
    echo -e "${CYAN}[*] Restoring pre-optimization settings...${NC}"
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            net.*) [[ -n "$v" ]] && sysctl -w "$k=$v" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] $k → $v${NC}" ;;
            gre_mtu)
                if [[ -n "$v" ]] && ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
                    ip link set dev "$TUNNEL_NAME" mtu "$v" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ${TUNNEL_NAME} MTU → $v${NC}"
                fi ;;
            mss_clamp)
                if [[ "$v" == "absent" ]]; then
                    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
                    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
                    echo -e "${GREEN}[✔️] MSS clamp removed${NC}"
                fi ;;
        esac
    done < "$TUNE_BACKUP"
    rm -f /etc/sysctl.d/99-gre-tune.conf
    echo -e "${GREEN}[✔️] Restored.${NC}"
    rm -f "$TUNE_BACKUP"
}

tune_status() {
    echo -e "${CYAN}=== Tunnel Optimization Status ===${NC}"
    echo "CC:        $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?) ($(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?))"
    echo "rmem_max:  $(sysctl -n net.core.rmem_max 2>/dev/null || echo ?)"
    echo "wmem_max:  $(sysctl -n net.core.wmem_max 2>/dev/null || echo ?)"
    echo "backlog:   $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo ?)"
    echo "forward:   $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)"
    echo "GRE MTU:   $(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}' || echo 'no interface')"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
       iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "MSS clamp: on (1340)"
    else
        echo "MSS clamp: off"
    fi
    if [[ -f "$TUNE_BACKUP" ]]; then echo "Backup:    $TUNE_BACKUP (restore available)"; else echo "Backup:    none"; fi
    [[ -f /etc/sysctl.d/99-gre-tune.conf ]] && echo "Persisted: yes (/etc/sysctl.d/99-gre-tune.conf)" || echo "Persisted: no"
}

# free_ram: drop page caches + compact memory + journald cap + ensure 1G swap.
# Everything it changes is remembered in STATE_DIR so a full uninstall can undo it.
free_ram() {
    echo -e "${CYAN}[*] Freeing RAM (safe: caches only, no service touched)...${NC}"
    local before
    before=$(free -m | awk '/^Mem:/{print $7}')
    mkdir -p "$STATE_DIR"
    # 1. journald cap (the #1 silent RAM eater on Ubuntu: 100M+ in RAM)
    if [[ -f /etc/systemd/journald.conf ]]; then
        [[ -f "${STATE_DIR}/journald.conf.orig" ]] || cp -p /etc/systemd/journald.conf "${STATE_DIR}/journald.conf.orig"
        sed -i 's/^#*SystemMaxUse=.*/SystemMaxUse=32M/' /etc/systemd/journald.conf
        sed -i 's/^#*RuntimeMaxUse=.*/RuntimeMaxUse=16M/' /etc/systemd/journald.conf
        grep -q '^SystemMaxUse=32M' /etc/systemd/journald.conf || echo 'SystemMaxUse=32M' >> /etc/systemd/journald.conf
        grep -q '^RuntimeMaxUse=16M' /etc/systemd/journald.conf || echo 'RuntimeMaxUse=16M' >> /etc/systemd/journald.conf
        journalctl --vacuum-size=16M >/dev/null 2>&1
        systemctl restart systemd-journald >/dev/null 2>&1
        echo -e "${GREEN}[✔️] journald capped at 16M (was the main RAM eater)${NC}"
    fi
    # 2. drop page caches + compact
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
    echo -e "${GREEN}[✔️] page cache dropped + memory compacted${NC}"
    # 3. ensure 1G swap (safety net for 1GB VPS)
    if ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        echo -e "${CYAN}[*] Creating 1G swapfile...${NC}"
        if [[ ! -e /swapfile ]] && { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null; }; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            : > "${STATE_DIR}/swapfile.created"   # marker: WE created it → uninstall removes it
            echo -e "${GREEN}[✔️] 1G swap created${NC}"
        else
            echo -e "${YELLOW}[!] Could not create swapfile (disk full or /swapfile already exists)${NC}"
        fi
    else
        echo -e "${GREEN}[✔️] swap already active${NC}"
    fi
    [[ -f "${STATE_DIR}/swappiness.orig" ]] || sysctl -n vm.swappiness > "${STATE_DIR}/swappiness.orig" 2>/dev/null
    sysctl -w vm.swappiness=15 >/dev/null 2>&1
    echo 'vm.swappiness=15' > /etc/sysctl.d/99-swappiness.conf 2>/dev/null
    local after
    after=$(free -m | awk '/^Mem:/{print $7}')
    echo -e "${GREEN}[✔️] Available RAM: ${before}M → ${after}M${NC}"
    free -m | head -2
}

free_ram_revert() {
    if [[ -f "${STATE_DIR}/journald.conf.orig" ]]; then
        cp -p "${STATE_DIR}/journald.conf.orig" /etc/systemd/journald.conf 2>/dev/null && \
            systemctl restart systemd-journald >/dev/null 2>&1
        echo -e "${GREEN}[✔️] journald.conf restored to the original${NC}"
    fi
    if [[ -f "${STATE_DIR}/swapfile.created" ]]; then
        swapoff /swapfile >/dev/null 2>&1 || true
        rm -f /swapfile
        sed -i '\|^/swapfile none swap sw 0 0$|d' /etc/fstab 2>/dev/null || true
        echo -e "${GREEN}[✔️] swapfile created by Hashem removed${NC}"
    fi
    rm -f /etc/sysctl.d/99-swappiness.conf
    if [[ -f "${STATE_DIR}/swappiness.orig" ]]; then
        sysctl -w vm.swappiness="$(cat "${STATE_DIR}/swappiness.orig")" >/dev/null 2>&1 || true
        echo -e "${GREEN}[✔️] vm.swappiness restored${NC}"
    fi
    return 0
}

# Undo every system-level tweak (no tunnel files touched).
revert_system_tweaks() {
    echo -e "${CYAN}[*] Reverting system tweaks (sysctl, iptables, ufw, journald, swap)...${NC}"
    # sysctl tuning (uses the snapshot taken before the first optimize)
    if [[ -f "$TUNE_BACKUP" ]]; then
        tune_restore
    else
        rm -f /etc/sysctl.d/99-gre-tune.conf
    fi
    # MSS clamp rule(s) added by this script
    while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1; do :; done
    # DPI shield chain + its systemd unit
    dpi_shield_off >/dev/null 2>&1 || true
    # FOU UDP accept rules
    local P1=443 P2=55555 p
    if [[ -f "$CARRIER_FILE" ]]; then read -r P1 P2 <<< "$(carrier_get_fou_ports)"; fi
    for p in "$P1" "$P2"; do
        is_valid_port "$p" || continue
        while iptables -D INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1; do :; done
    done
    # ufw rules that this script added (ledger)
    ufw_revert_tracked
    # journald / swap / swappiness
    free_ram_revert
    echo -e "${GREEN}[✔️] System tweaks reverted.${NC}"
    return 0
}

# Leftovers of the old web panel (older installs of this script). Safe to run any time.
remove_legacy_panel() {
    echo -e "${CYAN}[*] Removing old web panel leftovers (if any)...${NC}"
    # keep old encrypted backups restorable: panel password becomes the backup key
    if [[ -s "${STATE_DIR}/panel.pass" && ! -s "$BACKUP_KEY" ]]; then
        cp -p "${STATE_DIR}/panel.pass" "$BACKUP_KEY" 2>/dev/null && chmod 600 "$BACKUP_KEY"
    fi
    systemctl stop gre-panel >/dev/null 2>&1 || true
    systemctl disable gre-panel >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/gre-panel.service /usr/local/bin/gre-panel /usr/local/bin/grepanel
    rm -rf /usr/local/gre-panel "${STATE_DIR}/tls"
    rm -f "${STATE_DIR}/panel.json" "${STATE_DIR}/panel.pass"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] Old web panel removed.${NC}"
}

# Interactive: shows exactly what will go, asks once, then reverts EVERYTHING.
# Returns 99 when the uninstall really ran (menu then exits), 0 when aborted.
uninstall_all() {
    echo -e "\n${RED}=============================================================="
    echo "        FULL UNINSTALL — revert every change made by Hashem"
    echo -e "==============================================================${NC}"
    echo "This will remove:"
    echo "  - GRE tunnels (gre-tunnel, gre-tN) + FOU ports + chaff services"
    echo "  - FRP server/client services, binaries (frps/frpc) and /etc/frp"
    echo "  - Watchdog timer, DPI shield (iptables chain), TCP MSS rule"
    echo "  - Network tuning (sysctl restored from snapshot), journald cap, swapfile"
    echo "  - ufw rules that Hashem added (rules you had before are kept)"
    echo "  - Config, logs, ALL backups (${STATE_DIR}, ${BACKUP_DIR}, ${LOG_DIR})"
    echo "  - The 'hashem' command itself + any old web panel leftovers"
    echo -e "${YELLOW}NOT removed: apt packages (python3, curl, iproute2 ...) and loaded kernel modules.${NC}"
    echo -e "${YELLOW}If another tool on this server also uses /etc/frp or frps/frpc, it will be removed too.${NC}"
    echo ""
    local CONFIRM
    read -p "Type YES to continue: " CONFIRM || return 0
    if [[ "$CONFIRM" == "YES" ]]; then
        uninstall_all_force
        return 99
    fi
    echo -e "${YELLOW}[*] Aborted — nothing was changed.${NC}"
    return 0
}

# Non-interactive core: full wipe / revert of everything.
uninstall_all_force() {
    echo -e "\n${RED}=== Reverting EVERY change made by Hashem ===${NC}"
    log_msg "installer" "WARN" "Full uninstall started"

    # 1. stop + remove every systemd unit we created
    local u units=()
    for u in /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service \
             /etc/systemd/system/frpc*.service /etc/systemd/system/hashem-*.service \
             /etc/systemd/system/hashem-*.timer; do
        [[ -f "$u" ]] && units+=("$(basename "$u")")
    done
    # timer first so the watchdog cannot restart anything while we tear down
    systemctl stop hashem-watchdog.timer >/dev/null 2>&1 || true
    [[ ${#units[@]} -gt 0 ]] && remove_units "${units[@]}"
    echo -e "${GREEN}[✔️] systemd units removed (${#units[@]})${NC}"

    # carrier ports must be read BEFORE the state dir is deleted
    local P1=443 P2=55555
    if [[ -f "$CARRIER_FILE" ]]; then read -r P1 P2 <<< "$(carrier_get_fou_ports)"; fi

    # 2. GRE interfaces, then FOU listeners
    remove_gre_interfaces
    local p
    for p in "$P1" "$P2" 19998; do
        is_valid_port "$p" && ip fou del port "$p" >/dev/null 2>&1
    done
    echo -e "${GREEN}[✔️] GRE interfaces + FOU ports removed${NC}"

    # 3. iptables / ufw / sysctl / journald / swap
    revert_system_tweaks

    # 4. iperf3 (only if Hashem installed it) + running test server
    if [[ -f "${STATE_DIR}/pkg-iperf3.installed" ]]; then
        pkill -x iperf3 >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq iperf3 >/dev/null 2>&1 && \
            echo -e "${GREEN}[✔️] iperf3 (installed by Hashem) removed${NC}"
    fi

    # 5. binaries, configs, scripts, logs, backups
    rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/hashem-chaff.sh /usr/local/bin/gre-chaff.sh
    rm -f /var/lock/hashem-watchdog.lock /tmp/hashem-watchdog.lock /var/log/hashem_autotune.log
    rm -rf "$LOG_DIR" "$BACKUP_DIR" /etc/hashem
    echo -e "${GREEN}[✔️] FRP binaries/config, logs and backups removed${NC}"

    # 6. old web panel leftovers, then the state dir itself (last: ledgers live there)
    remove_legacy_panel
    rm -rf "$STATE_DIR"

    # 7. the hashem command (deleting a running script is safe on Linux)
    rm -f /usr/local/bin/hashem /usr/local/bin/hashem.sh /usr/local/bin/gre.sh

    echo -e "\n${GREEN}[✔️] Everything reverted: tunnel, services, firewall rules, tuning, configs and the 'hashem' command are gone.${NC}"
    echo -e "${CYAN}[i] The file you launched this script from (e.g. ./hashem.sh) is left in place — delete it manually if you want.${NC}"
    echo -e "${CYAN}[i] A reboot is optional; it only unloads kernel modules that were loaded (ip_gre, fou, tcp_bbr).${NC}"
    return 0
}

# ---- Watchdog & Scheduled Encrypted Backup ----
init_watchdog_json() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$WATCHDOG_FILE" ]]; then
        cat << 'EOF' > "$WATCHDOG_FILE"
{
  "enabled": true,
  "interval_sec": 60,
  "fail_threshold": 2,
  "tg_bot_token": "",
  "tg_chat_id": "",
  "tg_route": "direct",
  "tg_tunnel_port": 0,
  "backup_every_hours": 0,
  "backup_daily_at": "",
  "last_check": "",
  "consec_fails": 0,
  "last_alert": ""
}
EOF
        chmod 600 "$WATCHDOG_FILE" 2>/dev/null || true
    fi
}

# wd_set key type value [key type value ...]   (type: s=string i=int b=bool)
wd_set() {
    init_watchdog_json
    python3 - "$WATCHDOG_FILE" "$@" <<'PYEOF' 2>/dev/null
import json, os, sys
path = sys.argv[1]
args = sys.argv[2:]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
for i in range(0, len(args) - 2, 3):
    k, t, v = args[i], args[i + 1], args[i + 2]
    if t == "i":
        d[k] = int(v)
    elif t == "b":
        d[k] = (v == "true")
    else:
        d[k] = v
with open(path + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
os.replace(path + ".tmp", path)
os.chmod(path, 0o600)
PYEOF
    return 0
}

watchdog_get_peer_gre() {
    local PEER=""
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER
        INNER=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        if [[ -n "$INNER" ]]; then
            if [[ "$INNER" == "$IRAN_GRE_IP" ]]; then
                PEER="$FOREIGN_GRE_IP"
            elif [[ "$INNER" == "$FOREIGN_GRE_IP" ]]; then
                PEER="$IRAN_GRE_IP"
            else
                local a b c d
                IFS=. read -r a b c d <<< "$INNER"
                if (( d % 2 == 0 )); then
                    PEER="$a.$b.$c.$((d - 1))"
                else
                    PEER="$a.$b.$c.$((d + 1))"
                fi
            fi
        fi
    fi
    if [[ -z "$PEER" && -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        PEER=$(python3 -c '
import json
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
        peers = d.get("peers", [])
        if peers and "peer_gre" in peers[0]:
            print(peers[0]["peer_gre"])
except Exception:
    pass
' 2>/dev/null)
    fi
    echo "$PEER"
}

watchdog_check() {
    init_watchdog_json
    autotune_tick
    local PEER_GRE
    PEER_GRE=$(watchdog_get_peer_gre)
    local GRE_OK=0
    if [[ -n "$PEER_GRE" ]] && ping -c 1 -W 2 "$PEER_GRE" >/dev/null 2>&1; then
        GRE_OK=1
    fi

    local FRP_NAME=""
    local FRP_OK=0
    if [[ -f /etc/frp/frpc.toml ]] || systemctl list-unit-files 2>/dev/null | grep -q "^frpc\.service"; then
        FRP_NAME="frpc"
        systemctl is-active --quiet frpc 2>/dev/null && FRP_OK=1
    elif [[ -f /etc/frp/frps.toml ]] || systemctl list-unit-files 2>/dev/null | grep -q "^frps\.service"; then
        FRP_NAME="frps"
        systemctl is-active --quiet frps 2>/dev/null && FRP_OK=1
    else
        if systemctl list-units --type=service 2>/dev/null | grep -q 'frps'; then
            FRP_NAME="frps"
            FRP_OK=1
        fi
    fi

    local FAILS=0
    if [[ -f "$WATCHDOG_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        FAILS=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        print(int(json.load(f).get("consec_fails", 0)))
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    fi

    local STATUS="down"
    local DETAIL=""
    if [[ $GRE_OK -eq 1 && $FRP_OK -eq 1 ]]; then
        STATUS="up"
        DETAIL="GRE ping OK ($PEER_GRE), FRP $FRP_NAME active"
    else
        local ERR_PARTS=()
        if [[ $GRE_OK -ne 1 ]]; then
            if [[ -z "$PEER_GRE" ]]; then
                ERR_PARTS+=("GRE interface missing/down")
            else
                ERR_PARTS+=("GRE ping $PEER_GRE failed")
            fi
        fi
        if [[ $FRP_OK -ne 1 ]]; then
            ERR_PARTS+=("FRP ${FRP_NAME:-service} inactive")
        fi
        DETAIL=$(IFS="; "; echo "${ERR_PARTS[*]}")
    fi

    echo "WATCHDOG status=$STATUS fails=$FAILS detail=$DETAIL"
    return 0
}

watchdog_send() {
    local TEXT="$1"
    [[ -z "$TEXT" ]] && return 1
    init_watchdog_json

    local CFG
    CFG=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        d = json.load(f)
        tok = d.get("tg_bot_token", "").strip()
        cid = str(d.get("tg_chat_id", "")).strip()
        route = d.get("tg_route", "direct").strip()
        port = str(d.get("tg_tunnel_port", 0)).strip()
        print(f"{tok}\t{cid}\t{route}\t{port}")
except Exception:
    pass
' 2>/dev/null)

    local TG_TOKEN TG_CHAT_ID TG_ROUTE TG_PORT
    IFS=$'\t' read -r TG_TOKEN TG_CHAT_ID TG_ROUTE TG_PORT <<< "$CFG"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo -e "${YELLOW}[!] Telegram bot token or chat ID not configured in ${WATCHDOG_FILE}.${NC}" >&2
        return 1
    fi

    local HOST
    HOST="$(hostname 2>/dev/null || echo 'server')"
    local FULL_MSG="[Hashem ${HOST}] ${TEXT}"

    local CURL_ARGS=(-sS -f)
    if [[ "$TG_ROUTE" == "tunnel" ]]; then
        if [[ -z "$TG_PORT" || "$TG_PORT" -le 0 ]]; then
            echo -e "${RED}[!] Telegram route is set to tunnel but tunnel port is not configured.${NC}" >&2
            return 1
        fi
        CURL_ARGS+=(--max-time 20 --socks5-hostname "127.0.0.1:${TG_PORT}")
    else
        CURL_ARGS+=(--max-time 15)
    fi

    local CURL_OUT
    CURL_OUT=$(curl "${CURL_ARGS[@]}" -d "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${FULL_MSG}" "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" 2>&1)
    local RET=$?

    if [[ $RET -ne 0 ]]; then
        local REDACTED_ERR
        REDACTED_ERR=$(echo "$CURL_OUT" | sed "s/${TG_TOKEN}/[REDACTED]/g")
        echo -e "${RED}[!] Telegram send failed: ${REDACTED_ERR}${NC}" >&2
        return 1
    fi
    return 0
}

watchdog_test() {
    echo -e "${CYAN}[*] Testing Telegram alerts...${NC}"
    if watchdog_send "✅ Hashem watchdog test OK"; then
        echo -e "${GREEN}[✔️] Telegram test message sent successfully.${NC}"
        return 0
    else
        echo -e "${RED}[!] Telegram test message failed. Check token, chat ID, and route.${NC}"
        return 1
    fi
}

restart_all_lite() {
    local u
    for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-tunnel.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service; do
        [[ -f "$u" ]] || continue
        systemctl restart "$(basename "$u")" >/dev/null 2>&1
    done
}

autotune_tick() {
    [[ ! -f "$PERF_FILE" ]] && return 0
    local DO_TUNE
    DO_TUNE=$(python3 -c "import json; print(json.load(open('$PERF_FILE')).get('auto_tune', False))" 2>/dev/null || echo "False")
    [[ "$DO_TUNE" != "True" && "$DO_TUNE" != "true" ]] && return 0

    local CONN RAM
    CONN=$(ss -tn state established 2>/dev/null | wc -l)
    RAM=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$RAM" ]] && RAM=1024

    local TARGET_POOL=50
    if [[ "$CONN" -gt 300 ]]; then TARGET_POOL=150; fi
    if [[ "$CONN" -gt 800 ]]; then TARGET_POOL=300; fi
    if [[ "$CONN" -gt 2000 ]]; then TARGET_POOL=500; fi
    if [[ "$RAM" -lt 1000 && "$TARGET_POOL" -gt 150 ]]; then TARGET_POOL=150; fi

    local CUR_POOL
    CUR_POOL=$(perf_get_max_pool)
    if [[ "$CUR_POOL" != "$TARGET_POOL" ]]; then
        perf_set_val "frp_max_pool" "$TARGET_POOL" 1
        # Apply the new max pool
        perf_apply >/dev/null 2>&1
        echo "$(date) - AutoTune: Adjusted FRP maxPoolCount to $TARGET_POOL (Conns: $CONN, RAM: $RAM)" >> /var/log/hashem_autotune.log
    fi
}

watchdog_tick() {
    local LOCKFILE="/var/lock/hashem-watchdog.lock"
    mkdir -p /var/lock 2>/dev/null || true
    exec 200>"$LOCKFILE" 2>/dev/null || exec 200>/tmp/hashem-watchdog.lock
    if ! flock -n 200; then
        echo "watchdog_tick: another instance running, exiting"
        return 0
    fi

    init_watchdog_json

    local TICK_ACTION
    TICK_ACTION=$(python3 -c '
import json, time
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        d = json.load(f)
    enabled = d.get("enabled", False)
    backup_every = int(d.get("backup_every_hours", 0))
    backup_daily = d.get("backup_daily_at", "").strip()
    last_backup = int(d.get("last_backup", 0))
    last_bdate = d.get("last_backup_date", "")
    now = int(time.time())
    do_backup = False
    if backup_every > 0:
        if (now - last_backup) >= (backup_every * 3600):
            do_backup = True
    elif backup_daily:
        cur_hm = time.strftime("%H:%M")
        cur_date = time.strftime("%Y-%m-%d")
        if cur_hm == backup_daily and last_bdate != cur_date:
            do_backup = True
    print(f"{enabled} {do_backup}")
except Exception as e:
    print("False False")
' 2>/dev/null)

    local IS_ENABLED="False"
    local DO_BACKUP="False"
    read -r IS_ENABLED DO_BACKUP <<< "$TICK_ACTION"

    if [[ "$IS_ENABLED" == "True" || "$IS_ENABLED" == "true" ]]; then
        local CHECK_OUT
        CHECK_OUT=$(watchdog_check)
        local STATUS DETAIL
        STATUS=$(echo "$CHECK_OUT" | sed -n 's/.*status=\([^ ]*\).*/\1/p')
        DETAIL=$(echo "$CHECK_OUT" | sed -n 's/.*detail=\(.*\)/\1/p')

        local DECISION
        DECISION=$(CHECK_STATUS="$STATUS" CHECK_DETAIL="$DETAIL" python3 -c '
import json, os, time

path = "'"$WATCHDOG_FILE"'"
st = os.environ.get("CHECK_STATUS", "down")
detail = os.environ.get("CHECK_DETAIL", "")
now = int(time.time())
now_str = time.strftime("%Y-%m-%d %H:%M:%S")

try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {"enabled": True, "fail_threshold": 2, "consec_fails": 0, "last_alert": ""}

threshold = int(d.get("fail_threshold", 2))
consec = int(d.get("consec_fails", 0))
last_alert = d.get("last_alert", "")
down_since = int(d.get("down_since", 0))

action = "NONE"

if st == "up":
    if last_alert == "down":
        down_min = max(1, int((now - down_since + 59) / 60))
        action = f"RECOVERED {down_min}"
        d["last_alert"] = "up"
        d["down_since"] = 0
    d["consec_fails"] = 0
else:
    consec += 1
    d["consec_fails"] = consec
    if consec >= threshold:
        if last_alert != "down":
            action = "DOWN"
            d["last_alert"] = "down"
            d["down_since"] = now
        elif consec % 2 == 0:
            action = "DOWN_RETRY"

d["last_check"] = now_str

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
print(action)
' 2>/dev/null)

        if [[ "$DECISION" == DOWN* ]]; then
            local CMODE
            CMODE=$(carrier_get_mode)
            if [[ "$CMODE" == "auto" ]]; then
                local OLD_C NEW_C
                OLD_C=$(carrier_get_active)
                NEW_C=$(carrier_cycle_next)
                sleep 2
                local PGRE
                PGRE=$(watchdog_get_peer_gre)
                if [[ -n "$PGRE" ]] && ping -c 1 -W 2 "$PGRE" >/dev/null 2>&1; then
                    watchdog_send "⚡ Auto-Failover: Switched carrier from ${OLD_C} to ${NEW_C} — Tunnel link restored!" || true
                    wd_set consec_fails i 0 last_alert s up down_since i 0
                    DECISION="RECOVERED 0"
                fi
            fi

            if [[ "$DECISION" == DOWN* ]]; then
                if [[ "$DECISION" == "DOWN" ]]; then
                    watchdog_send "🔴 Tunnel DOWN: ${DETAIL} (attempting tunnel restart)" || true
                fi
                restart_all_lite
            fi
        elif [[ "$DECISION" == RECOVERED* ]]; then
            local DMIN
            DMIN=$(echo "$DECISION" | awk '{print $2}')
            watchdog_send "🟢 Tunnel RECOVERED (was down ${DMIN}m)" || true
        fi
    fi

    if [[ "$DO_BACKUP" == "True" || "$DO_BACKUP" == "true" ]]; then
        backup_now >/dev/null 2>&1 || true
        wd_set last_backup i "$(date +%s)" last_backup_date s "$(date +%Y-%m-%d)"
    fi

    return 0
}

# ---- encrypted backups (openssl AES-256-CBC, key file in STATE_DIR) ----
ensure_backup_key() {
    mkdir -p "$STATE_DIR"
    if [[ ! -s "$BACKUP_KEY" ]]; then
        if [[ -s "${STATE_DIR}/panel.pass" ]]; then
            cp -p "${STATE_DIR}/panel.pass" "$BACKUP_KEY"      # keeps old backups restorable
        else
            gen_token32 > "$BACKUP_KEY"
        fi
        chmod 600 "$BACKUP_KEY"
        echo -e "${YELLOW}[!] Backup key created: ${BACKUP_KEY} — copy it somewhere safe; backups cannot be decrypted on another server without it.${NC}" >&2
    fi
}

backup_now() {
    local OUTDIR="$BACKUP_DIR"
    local KEEP=7
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep) KEEP="$2"; shift 2 ;;
            *)
                if [[ "$1" != --* ]]; then
                    OUTDIR="$1"
                fi
                shift
                ;;
        esac
    done

    mkdir -p "$OUTDIR"
    chmod 700 "$OUTDIR" 2>/dev/null || true
    ensure_backup_key

    local DATE_STR
    DATE_STR=$(date +%Y%m%d-%H%M%S)
    local OUT_FILE="${OUTDIR}/hashem-backup-${DATE_STR}.enc"

    local FILES=()
    local f
    for f in /etc/frp/*.toml "${STATE_DIR}/peers.json" "${STATE_DIR}/watchdog.json" \
             "${STATE_DIR}/perf.json" "${STATE_DIR}/carrier.json" \
             /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service \
             /etc/systemd/system/frpc*.service /etc/systemd/system/gre-chaff*.service; do
        [[ -f "$f" ]] && FILES+=("$f")
    done

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo -e "${RED}[!] No configuration or unit files found to back up.${NC}" >&2
        return 1
    fi

    if ! tar -czf - "${FILES[@]}" 2>/dev/null | openssl enc -aes-256-cbc -pbkdf2 -pass "file:${BACKUP_KEY}" -out "$OUT_FILE"; then
        echo -e "${RED}[!] Failed to create encrypted backup.${NC}" >&2
        rm -f "$OUT_FILE"
        return 1
    fi

    chmod 600 "$OUT_FILE" 2>/dev/null || true
    local SIZE
    SIZE=$(stat -c%s "$OUT_FILE" 2>/dev/null || echo 0)
    local HSIZE
    HSIZE=$(du -h "$OUT_FILE" 2>/dev/null | cut -f1)

    echo "BACKUP path=${OUT_FILE} size=${SIZE}"
    echo -e "${GREEN}[✔️] Backup created: ${OUT_FILE} (${HSIZE})${NC}"

    if [[ "$KEEP" -gt 0 ]]; then
        local OLD_FILES
        OLD_FILES=$(ls -1t "$OUTDIR"/hashem-backup-*.enc 2>/dev/null | tail -n +$((KEEP + 1)))
        if [[ -n "$OLD_FILES" ]]; then
            echo "$OLD_FILES" | xargs -r rm -f
            echo -e "${CYAN}[*] Pruned old backups (kept latest ${KEEP}).${NC}"
        fi
    fi
    return 0
}

backup_restore() {
    local FILE=""
    local DRY_RUN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            *) FILE="$1"; shift ;;
        esac
    done

    if [[ -z "$FILE" || ! -f "$FILE" ]]; then
        echo -e "${RED}[!] Backup file not found: '${FILE}'${NC}" >&2
        return 1
    fi

    local TMP_D
    TMP_D=$(mktemp -d)

    echo -e "${CYAN}[*] Decrypting backup archive...${NC}"
    local K OK=0
    for K in "$BACKUP_KEY" "${STATE_DIR}/panel.pass"; do
        [[ -s "$K" ]] || continue
        if openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${K}" -in "$FILE" -out "$TMP_D/backup.tar.gz" 2>/dev/null; then
            OK=1
            break
        fi
    done
    if [[ "$OK" -ne 1 ]]; then
        echo -e "${RED}[!] Decryption failed: backup key missing/wrong or file corrupted (key file: ${BACKUP_KEY}).${NC}" >&2
        rm -rf "$TMP_D"
        return 1
    fi

    echo -e "${CYAN}[*] Verifying archive contents...${NC}"
    if ! tar -ztf "$TMP_D/backup.tar.gz" >"$TMP_D/list.txt" 2>/dev/null; then
        echo -e "${RED}[!] Archive verification failed: invalid tar archive.${NC}" >&2
        rm -rf "$TMP_D"
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${GREEN}[✔️] Archive verified OK. Files inside:${NC}"
        cat "$TMP_D/list.txt"
        rm -rf "$TMP_D"
        return 0
    fi

    echo -e "${CYAN}[*] Restoring configuration files and systemd units...${NC}"
    tar -xzf "$TMP_D/backup.tar.gz" -C /
    chmod 600 "${STATE_DIR}"/*.json 2>/dev/null || true
    echo -e "${GREEN}[✔️] Files restored:${NC}"
    cat "$TMP_D/list.txt"
    rm -rf "$TMP_D"

    echo -e "${CYAN}[*] Reloading systemd daemon...${NC}"
    systemctl daemon-reload

    echo -e "${CYAN}[*] Restarting tunnel services...${NC}"
    restart_all

    echo -e "${GREEN}[✔️] Restore completed successfully.${NC}"
    return 0
}

install_watchdog_units() {
    [[ -x "$HASHEM_BIN" ]] || { cp "$0" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN"; } || true
    cat << 'EOF' > /etc/systemd/system/hashem-watchdog.service
[Unit]
Description=Hashem Watchdog and Scheduled Backup Tick
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hashem watchdog tick
EOF

    cat << 'EOF' > /etc/systemd/system/hashem-watchdog.timer
[Unit]
Description=Run Hashem Watchdog every minute
After=network.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
}

watchdog_on() {
    init_watchdog_json
    install_watchdog_units
    systemctl enable --now hashem-watchdog.timer >/dev/null 2>&1
    wd_set enabled b true
    echo -e "${GREEN}[✔️] Watchdog enabled (systemd timer active, checks every 1 min).${NC}"
}

watchdog_off() {
    init_watchdog_json
    systemctl stop hashem-watchdog.timer hashem-watchdog.service >/dev/null 2>&1 || true
    systemctl disable hashem-watchdog.timer >/dev/null 2>&1 || true
    wd_set enabled b false
    echo -e "${YELLOW}[*] Watchdog disabled (systemd timer stopped).${NC}"
}

watchdog_status_full() {
    init_watchdog_json
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${CYAN}                 Hashem Watchdog Status                   ${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local INFO
    INFO=$(python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    en = "Enabled" if d.get("enabled", False) else "Disabled"
    tok = d.get("tg_bot_token", "").strip()
    if tok:
        masked = tok[:6] + "..." + tok[-4:] if len(tok) > 10 else "******"
    else:
        masked = "(not configured)"
    cid = str(d.get("tg_chat_id", "")) or "(not configured)"
    route = d.get("tg_route", "direct")
    port = str(d.get("tg_tunnel_port", 0))
    fails = str(d.get("consec_fails", 0))
    thresh = str(d.get("fail_threshold", 2))
    last_c = d.get("last_check", "") or "(none yet)"
    last_a = d.get("last_alert", "") or "(none)"
    be = int(d.get("backup_every_hours", 0))
    bd = d.get("backup_daily_at", "")
    if be > 0:
        sched = f"Every {be} hours"
    elif bd:
        sched = f"Daily at {bd}"
    else:
        sched = "Disabled"
    print(f"{en}\t{masked}\t{cid}\t{route}\t{port}\t{fails}\t{thresh}\t{last_c}\t{last_a}\t{sched}")
except Exception as e:
    print(f"Error\t-\t-\t-\t-\t0\t2\t-\t-\tDisabled")
' 2>/dev/null)

    local EN TOK CID ROUTE PORT FAILS THRESH LAST_C LAST_A SCHED
    IFS=$'\t' read -r EN TOK CID ROUTE PORT FAILS THRESH LAST_C LAST_A SCHED <<< "$INFO"

    local TIMER_ACTIVE="inactive"
    if systemctl is-active --quiet hashem-watchdog.timer 2>/dev/null; then
        TIMER_ACTIVE="active (every 1 min)"
    fi

    echo -e "Watchdog State:     ${CYAN}${EN}${NC} (systemd timer: ${TIMER_ACTIVE})"
    echo -e "Consecutive Fails:  ${FAILS} / ${THRESH}"
    echo -e "Last Check:         ${LAST_C}"
    echo -e "Last Alert:         ${LAST_A}"
    echo ""
    echo -e "${YELLOW}── Telegram Alerts ──${NC}"
    echo -e "Bot Token:          ${TOK}"
    echo -e "Chat ID:            ${CID}"
    if [[ "$ROUTE" == "tunnel" ]]; then
        echo -e "Route:              tunnel (SOCKS5 127.0.0.1:${PORT})"
    else
        echo -e "Route:              direct"
    fi
    echo ""
    echo -e "${YELLOW}── Backup Schedule & Files ──${NC}"
    echo -e "Schedule:           ${SCHED}"
    local BC=0
    if [[ -d "$BACKUP_DIR" ]]; then
        BC=$(ls -1 "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null | wc -l)
    fi
    echo -e "Stored Backups:     ${BC} in ${BACKUP_DIR}"
    if [[ "$BC" -gt 0 ]]; then
        ls -lh "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null | awk '{print "  " $9 " (" $5 ", " $6 " " $7 " " $8 ")"}' | tail -n 5
    fi
    echo ""
    echo -e "${YELLOW}── Live Health Check ──${NC}"
    watchdog_check
    echo -e "${CYAN}==========================================================${NC}"
}

find_live_proxy_ports() {
    local PORTS=() p f
    if [[ -f /etc/frp/frpc.toml ]]; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^(remotePort|localPort)\s*=' /etc/frp/frpc.toml 2>/dev/null | awk -F= '{print $2}' | tr -d ' "')
    fi
    for f in /etc/frp/frps*.toml; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^(remotePort|localPort)\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "')
    done
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(python3 -c '
import json
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
        for peer in d.get("peers", []):
            for port in peer.get("ports", []):
                print(port)
except Exception:
    pass
' 2>/dev/null)
    fi
    if [[ ${#PORTS[@]} -gt 0 ]]; then
        printf "%s\n" "${PORTS[@]}" | sort -n -u
    fi
}

menu_watchdog() {
    local SUBOPT W_EN INPUT_TOKEN INPUT_CID ROUTE_CHOICE CHOSEN_PORT PIDX S_CHOICE N_HOURS DAILY_T
    local PORTS idx p BAKS bidx b bsz PICK_B SELECTED CONFIRM_R MAN_FILE
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}==========================================================${NC}"
        echo -e "${CYAN}              Watchdog & Encrypted Backup                 ${NC}"
        echo -e "${CYAN}==========================================================${NC}"
        echo ""
        init_watchdog_json
        W_EN=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        print("ENABLED" if json.load(f).get("enabled", False) else "DISABLED")
except Exception:
    print("DISABLED")
' 2>/dev/null)
        if [[ "$W_EN" == "ENABLED" ]]; then
            echo -e "Watchdog Status: ${GREEN}● ENABLED${NC} (checks every 1 min)"
        else
            echo -e "Watchdog Status: ${RED}○ DISABLED${NC}"
        fi
        echo ""
        echo "  1) Enable / Disable Watchdog"
        echo "  2) Set Telegram (Bot Token & Chat ID)"
        echo "  3) Test Telegram Alert"
        echo "  4) Route Direct vs Tunnel (+pick tunnel socks port)"
        echo "  5) Backup Now (OpenSSL AES-256-CBC Encrypted)"
        echo "  6) Schedule Backup (Every-N-Hours OR Daily at HH:MM)"
        echo "  7) Restore from Encrypted Backup"
        echo "  8) View Full Status & Stored Backups"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-8]: " SUBOPT || return 1
        case "$SUBOPT" in
            1)
                if [[ "$W_EN" == "ENABLED" ]]; then
                    watchdog_off
                else
                    watchdog_on
                fi
                read -p "Press Enter to continue..." _ || return 1
                ;;
            2)
                echo -e "\n${CYAN}── Configure Telegram Alerts ──${NC}"
                read -p "Enter Telegram Bot Token: " INPUT_TOKEN || return 1
                read -p "Enter Telegram Chat ID: " INPUT_CID || return 1
                if [[ -n "$INPUT_TOKEN" ]]; then wd_set tg_bot_token s "$INPUT_TOKEN"; fi
                if [[ -n "$INPUT_CID" ]]; then wd_set tg_chat_id s "$INPUT_CID"; fi
                if [[ -n "$INPUT_TOKEN" || -n "$INPUT_CID" ]]; then
                    echo -e "${GREEN}[✔️] Telegram settings saved.${NC}"
                else
                    echo -e "${YELLOW}[*] No changes made.${NC}"
                fi
                read -p "Press Enter to continue..." _ || return 1
                ;;
            3)
                watchdog_test
                read -p "Press Enter to continue..." _ || return 1
                ;;
            4)
                echo -e "\n${CYAN}── Telegram Delivery Route ──${NC}"
                echo "  1) Direct (curl direct to Telegram API)"
                echo "  2) Via Tunnel (SOCKS5 through tunnel port)"
                read -p "Choose route [1-2]: " ROUTE_CHOICE || return 1
                if [[ "$ROUTE_CHOICE" == "1" ]]; then
                    wd_set tg_route s direct
                    echo -e "${GREEN}[✔️] Route set to Direct.${NC}"
                elif [[ "$ROUTE_CHOICE" == "2" ]]; then
                    PORTS=()
                    mapfile -t PORTS < <(find_live_proxy_ports)
                    CHOSEN_PORT=0
                    if [[ ${#PORTS[@]} -gt 0 ]]; then
                        echo -e "\nDetected live tunnel ports:"
                        idx=1
                        for p in "${PORTS[@]}"; do
                            echo "  $idx) Port $p"
                            idx=$((idx + 1))
                        done
                        echo "  $idx) Enter custom port manually"
                        read -p "Select port [1-$idx]: " PIDX || return 1
                        if [[ "$PIDX" =~ ^[0-9]+$ ]] && (( PIDX >= 1 && PIDX < idx )); then
                            CHOSEN_PORT="${PORTS[$((PIDX-1))]}"
                        else
                            read -p "Enter SOCKS5 tunnel port (1-65535): " CHOSEN_PORT || return 1
                        fi
                    else
                        read -p "Enter SOCKS5 tunnel port (1-65535): " CHOSEN_PORT || return 1
                    fi
                    if is_valid_port "$CHOSEN_PORT"; then
                        wd_set tg_route s tunnel tg_tunnel_port i "$CHOSEN_PORT"
                        echo -e "${GREEN}[✔️] Route set to Tunnel (127.0.0.1:${CHOSEN_PORT}).${NC}"
                    else
                        echo -e "${RED}[!] Invalid port number.${NC}"
                    fi
                fi
                read -p "Press Enter to continue..." _ || return 1
                ;;
            5)
                echo -e "\n${CYAN}── Creating Encrypted Backup ──${NC}"
                backup_now
                read -p "Press Enter to continue..." _ || return 1
                ;;
            6)
                echo -e "\n${CYAN}── Schedule Encrypted Backup ──${NC}"
                echo "  1) Every N hours"
                echo "  2) Daily at fixed time (HH:MM)"
                echo "  3) Disable scheduled backups"
                read -p "Select schedule mode [1-3]: " S_CHOICE || return 1
                case "$S_CHOICE" in
                    1)
                        read -p "Enter interval in hours (e.g. 6): " N_HOURS || return 1
                        if [[ "$N_HOURS" =~ ^[0-9]+$ ]] && (( N_HOURS >= 1 && N_HOURS <= 168 )); then
                            wd_set backup_every_hours i "$N_HOURS" backup_daily_at s ""
                            echo -e "${GREEN}[✔️] Backup scheduled every ${N_HOURS} hours.${NC}"
                        else
                            echo -e "${RED}[!] Invalid hours (must be 1-168).${NC}"
                        fi
                        ;;
                    2)
                        read -p "Enter daily time in 24h format HH:MM (e.g. 03:00): " DAILY_T || return 1
                        if [[ "$DAILY_T" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                            wd_set backup_every_hours i 0 backup_daily_at s "$DAILY_T"
                            echo -e "${GREEN}[✔️] Backup scheduled daily at ${DAILY_T}.${NC}"
                        else
                            echo -e "${RED}[!] Invalid time format (use HH:MM e.g. 03:00).${NC}"
                        fi
                        ;;
                    3)
                        wd_set backup_every_hours i 0 backup_daily_at s ""
                        echo -e "${GREEN}[✔️] Scheduled backups disabled.${NC}"
                        ;;
                    *)
                        echo -e "${RED}[!] Invalid option.${NC}"
                        ;;
                esac
                read -p "Press Enter to continue..." _ || return 1
                ;;
            7)
                echo -e "\n${CYAN}── Restore Backup ──${NC}"
                BAKS=()
                if [[ -d "$BACKUP_DIR" ]]; then
                    mapfile -t BAKS < <(ls -1t "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null)
                fi
                if [[ ${#BAKS[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}[!] No backups found in ${BACKUP_DIR}.${NC}"
                    read -p "Enter full path to backup file manually (or Enter to cancel): " MAN_FILE || return 1
                    if [[ -n "$MAN_FILE" ]]; then
                        backup_restore "$MAN_FILE"
                    fi
                else
                    echo "Available backups:"
                    bidx=1
                    for b in "${BAKS[@]}"; do
                        bsz=$(du -h "$b" 2>/dev/null | cut -f1)
                        echo "  $bidx) $(basename "$b") ($bsz)"
                        bidx=$((bidx + 1))
                    done
                    read -p "Select backup to restore [1-$((bidx-1))]: " PICK_B || return 1
                    if [[ "$PICK_B" =~ ^[0-9]+$ ]] && (( PICK_B >= 1 && PICK_B < bidx )); then
                        SELECTED="${BAKS[$((PICK_B-1))]}"
                        read -p "Restore $(basename "$SELECTED")? Current configs will be overwritten and services restarted. (y/N): " CONFIRM_R || return 1
                        if [[ "$CONFIRM_R" =~ ^[Yy]$ ]]; then
                            backup_restore "$SELECTED"
                        else
                            echo -e "${YELLOW}[*] Restore cancelled.${NC}"
                        fi
                    else
                        echo -e "${RED}[!] Invalid choice.${NC}"
                    fi
                fi
                read -p "Press Enter to continue..." _ || return 1
                ;;
            8)
                watchdog_status_full
                read -p "Press Enter to continue..." _ || return 1
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

cli_watchdog() {
    local SUB="$1"
    shift || true
    case "$SUB" in
        on) watchdog_on ;;
        off) watchdog_off ;;
        status) watchdog_status_full ;;
        test) watchdog_test ;;
        tick) watchdog_tick ;;
        check) watchdog_check ;;
        *) echo -e "${RED}[!] Unknown watchdog command: '$SUB' (want on|off|status|test|tick)${NC}"; return 1 ;;
    esac
}

cli_backup() {
    local SUB="$1"
    shift || true
    case "$SUB" in
        now) backup_now "$@" ;;
        restore) backup_restore "$@" ;;
        status)
            echo -e "${CYAN}=== Hashem Backups (${BACKUP_DIR}) ===${NC}"
            if [[ -d "$BACKUP_DIR" ]]; then
                ls -lh "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null || echo "(no backups found)"
            else
                echo "(no backup directory)"
            fi
            ;;
        schedule)
            local MODE="" HOURS=0 DAILY=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --every|every) HOURS="$2"; MODE="interval"; shift 2 ;;
                    --daily|daily) DAILY="$2"; MODE="daily"; shift 2 ;;
                    --off|off) MODE="off"; shift ;;
                    *) shift ;;
                esac
            done
            init_watchdog_json
            if [[ "$MODE" == "interval" ]]; then
                if [[ "$HOURS" =~ ^[0-9]+$ ]] && (( HOURS >= 1 && HOURS <= 168 )); then
                    wd_set backup_every_hours i "$HOURS" backup_daily_at s ""
                    echo -e "${GREEN}[✔️] Backup scheduled every ${HOURS} hours.${NC}"
                else
                    echo -e "${RED}[!] Invalid interval hours: '$HOURS' (1-168)${NC}"; return 1
                fi
            elif [[ "$MODE" == "daily" ]]; then
                if [[ "$DAILY" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    wd_set backup_every_hours i 0 backup_daily_at s "$DAILY"
                    echo -e "${GREEN}[✔️] Backup scheduled daily at ${DAILY}.${NC}"
                else
                    echo -e "${RED}[!] Invalid daily time format: '$DAILY' (HH:MM e.g. 03:00)${NC}"; return 1
                fi
            elif [[ "$MODE" == "off" ]]; then
                wd_set backup_every_hours i 0 backup_daily_at s ""
                echo -e "${GREEN}[✔️] Scheduled backups disabled.${NC}"
            else
                echo -e "${RED}[!] Usage: hashem backup schedule [--every N | --daily HH:MM | --off]${NC}"; return 1
            fi
            ;;
        *)
            echo -e "${RED}[!] Unknown backup command: '$SUB' (want now|restore|schedule|status)${NC}"
            return 1
            ;;
    esac
}

cli_carrier() {
    init_carrier_json
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            local MODE ACT P1 P2
            MODE=$(carrier_get_mode)
            ACT=$(carrier_get_active)
            read -r P1 P2 <<< "$(carrier_get_fou_ports)"
            local PGRE PING_OUT="no peer"
            PGRE=$(watchdog_get_peer_gre 2>/dev/null)
            if [[ -n "$PGRE" ]]; then
                if ping -c 1 -W 2 "$PGRE" >/dev/null 2>&1; then
                    local RTT
                    RTT=$(ping -c 1 -W 2 "$PGRE" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\) *ms.*/\1/p' | head -n1)
                    PING_OUT="${GREEN}OK (${RTT}ms to ${PGRE})${NC}"
                else
                    PING_OUT="${RED}FAIL (no reply from ${PGRE})${NC}"
                fi
            fi

            echo -e "\n${CYAN}==========================================================${NC}"
            echo -e "${CYAN}         Tunnel Carrier & Multi-Protocol Failover         ${NC}"
            echo -e "${CYAN}==========================================================${NC}"
            echo -e "Failover Mode:    ${YELLOW}${MODE}${NC} (auto / direct / manual)"
            echo -e "Active Carrier:   ${GREEN}${ACT}${NC}"
            echo -e "FOU Listeners:    UDP ${P1} / UDP ${P2} (Kernel FOU / ipproto 47)"
            echo -e "Tunnel Health:    ${PING_OUT}"
            python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
    cands = ", ".join(d.get("candidates", []))
    sc = d.get("switch_count", 0)
    last = d.get("last_switch", "") or "never"
    print("Candidates:       " + cands)
    print("Total Switches:   " + str(sc))
    print("Last Switch:      " + last)
except Exception:
    pass
' 2>/dev/null
            echo -e "${CYAN}==========================================================${NC}\n"
            ;;
        mode|set-mode)
            local TARGET="${2:-auto}"
            carrier_set_mode "$TARGET"
            echo -e "${GREEN}[✔️] Carrier mode set to: ${TARGET}${NC}"
            if [[ "$TARGET" != "auto" ]]; then
                carrier_apply "$TARGET"
                echo -e "${GREEN}[✔️] Active carrier applied: ${TARGET}${NC}"
            fi
            ;;
        set|set-active|apply)
            local TARGET="${2:-direct}"
            carrier_apply "$TARGET"
            echo -e "${GREEN}[✔️] Switched active carrier to: ${TARGET}${NC}"
            ;;
        next|cycle)
            local NEW_C
            NEW_C=$(carrier_cycle_next)
            echo -e "${GREEN}[✔️] Cycled carrier to: ${NEW_C}${NC}"
            ;;
        set-ports)
            local P1="${2:-443}" P2="${3:-55555}"
            carrier_set_fou_ports "$P1" "$P2"
            carrier_init_kernel
            echo -e "${GREEN}[✔️] FOU ports updated: ${P1} and ${P2}${NC}"
            ;;
        kernel-init)
            carrier_init_kernel
            ;;
        *)
            echo "Usage: hashem carrier [status|mode <auto|direct|fou:PORT>|set <direct|fou:PORT>|next|cycle|set-ports <P1> <P2>]"
            return 1
            ;;
    esac
}

menu_carrier() {
    cli_carrier status
    echo -e "${YELLOW}Select an action:${NC}"
    echo "  1) Set Mode to Auto (Automatic Round-Robin on failure: Direct -> FOU -> WSS)"
    echo "  2) Force Direct GRE (Raw Protocol 47)"
    echo "  3) Force FOU UDP (Port 443)"
    echo "  4) Force FOU UDP (Port 55555)"
    echo "  5) Force WSS Obfuscated Carrier (WebSocket over TLS / Port 8443)"
    echo "  6) Cycle to Next Candidate Now"
    echo "  0) Back to Main Menu"
    echo ""
    local C_OPT
    read -p "Select an option [0-6]: " C_OPT || return 1
    case "$C_OPT" in
        1) cli_carrier mode auto ;;
        2) cli_carrier set direct ;;
        3) cli_carrier set fou:443 ;;
        4) cli_carrier set fou:55555 ;;
        5) cli_carrier set wss:8443 ;;
        6) cli_carrier next ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] Invalid option.${NC}" ;;
    esac
}

load_gre_modules() {
    echo -e "${CYAN}[*] Ensuring GRE kernel modules are loaded...${NC}"
    if modprobe ip_gre 2>/dev/null && modprobe fou 2>/dev/null; then
        echo -e "${GREEN}[✔️] GRE & FOU modules loaded.${NC}"
    else
        echo -e "${RED}[!] Failed to load modules.${NC}"
        return 1
    fi
}

# ==============================================================================
#   MENU FRAMEWORK — designed so that NOTHING can close the menu by accident
#   * every action runs in its own subshell: an `exit`, an error or Ctrl+C
#     inside it only ends that action, you land back in the menu
#   * Ctrl+C in a menu just redraws it (leave with option 0 / 7)
#   * closed terminal / Ctrl+D leaves cleanly instead of looping forever
# ==============================================================================
pause_prompt() {
    echo ""
    read -r -p "Press Enter to return to menu..." _dummy || true
}

# menu_read VAR "prompt" — empty VAR on Ctrl+C, clean exit on EOF (Ctrl+D)
menu_read() {
    local __rc
    IFS= read -r -p "$2" "$1"
    __rc=$?
    if (( __rc == 1 )); then echo; exit 0; fi
    if (( __rc > 128 )); then printf -v "$1" '%s' ""; fi
    return 0
}

# one action: Ctrl+C aborts just this action
run_action() {
    ( trap - INT; "$@" )
    return $?
}

# one (sub)menu loop: Ctrl+C redraws, never exits
run_menu() {
    ( trap 'echo' INT; "$@" )
    return $?
}

menu_banner() { # $1 = title
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}                   $1"
    echo -e "${CYAN}==============================================================${NC}"
}

menu_installation() {
    local IN_OPT
    while true; do
        clear 2>/dev/null || true
        menu_banner "INSTALLATION MENU"
        echo "  1) Setup IRAN Server    (GRE + FRP Server)"
        echo "  2) Setup FOREIGN Server (GRE + FRP Client — via Bundle or Manual)"
        echo "  3) Install FRP Binaries (frps & frpc)"
        echo "  4) Load GRE Kernel Modules"
        echo "  5) Install Missing System Dependencies Only"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read IN_OPT "Select an option [0-5]: "
        case "$IN_OPT" in
            1) run_action setup_iran_server; pause_prompt ;;
            2) run_action setup_foreign_server; pause_prompt ;;
            3) run_action install_frp_binaries; pause_prompt ;;
            4) run_action load_gre_modules; pause_prompt ;;
            5) run_action ensure_dependencies_smart; pause_prompt ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

menu_tunnel() {
    local T_OPT
    while true; do
        clear 2>/dev/null || true
        menu_banner "TUNNEL MANAGEMENT"
        echo "  1) Create / Setup IRAN Tunnel (GRE + FRPS)"
        echo "  2) Create / Setup FOREIGN Tunnel (GRE + FRPC / via Bundle or Manual)"
        echo "  3) Add Peer Tunnel (Multi-peer Foreign servers on Iran)"
        echo "  4) List Peer Tunnels"
        echo "  5) Remove Peer Tunnel"
        echo "  6) Restart Tunnel Services (systemctl restart gre + frp)"
        echo "  7) Delete / Teardown Tunnel (GRE + FRP)"
        echo "  8) Tunnel Status & GRE Ping Test"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read T_OPT "Select an option [0-8]: "
        case "$T_OPT" in
            1) run_action setup_iran_server; pause_prompt ;;
            2) run_action setup_foreign_server; pause_prompt ;;
            3) run_action menu_add_peer; pause_prompt ;;
            4) run_action peer_list_pretty; pause_prompt ;;
            5) run_action menu_remove_peer; pause_prompt ;;
            6) run_action restart_all; pause_prompt ;;
            7) run_action remove_tunnel; pause_prompt ;;
            8) run_action check_status; pause_prompt ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

menu_server() {
    local S_OPT
    while true; do
        clear 2>/dev/null || true
        menu_banner "SERVER & SYSTEM MANAGEMENT"
        echo "  1) Network Optimization (BBR + sysctl buffers + MTU clamp)"
        echo "  2) Restore Network Tuning (pre-optimize sysctl backup)"
        echo "  3) Tuning Status"
        echo "  4) Free RAM (cap journald 16MB + drop cache + 1GB swapfile)"
        echo "  5) Carrier & Failover (Direct GRE ↔ FOU UDP: auto/manual/status)"
        echo "  6) Traffic Chaff / Obfuscation (idle-gap filler: on/off/status)"
        echo "  7) DPI Shield (rate-limit reverse ports against flood: on/off/status)"
        echo "  8) Watchdog, Alerting & Encrypted Backup (Telegram, failover)"
        echo "  9) Performance & Obfuscation Toggles (proxy crypto/comp, forced TLS)"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read S_OPT "Select an option [0-9]: "
        case "$S_OPT" in
            1) run_action tune_apply; pause_prompt ;;
            2) run_action tune_restore; pause_prompt ;;
            3) run_action tune_status; pause_prompt ;;
            4) run_action free_ram; pause_prompt ;;
            5) run_action menu_carrier; pause_prompt ;;
            6) run_action menu_chaff; pause_prompt ;;
            7) run_action menu_dpi_shield; pause_prompt ;;
            8) run_action menu_watchdog ;;
            9) run_action menu_perf ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

menu_bundle() {
    local B_OPT IP_IRAN BIND_PORT TOKEN
    while true; do
        clear 2>/dev/null || true
        menu_banner "BUNDLE MANAGEMENT"
        echo "  1) Generate / Show Setup Bundle for This Iran Server"
        echo "  2) Inspect Setup Bundle (hashem bundle inspect <bundle>)"
        echo "  3) Import & Apply Bundle on This Server (Foreign Role)"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read B_OPT "Select an option [0-3]: "
        case "$B_OPT" in
            1)
                IP_IRAN=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
                BIND_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
                TOKEN=$(awk -F'=' '/auth\.token/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
                if [[ -n "$IP_IRAN" && -n "$BIND_PORT" && -n "$TOKEN" ]]; then
                    echo -e "\n${GREEN}=== Iran Server Setup Bundle ===${NC}"
                    echo -e "BUNDLE: ${CYAN}$(bundle_make "$IP_IRAN" "$BIND_PORT" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP" "$TOKEN")${NC}\n"
                else
                    echo -e "${YELLOW}[!] IRAN tunnel is not configured yet on this host.${NC}"
                fi
                pause_prompt
                ;;
            2) run_action cli_bundle_inspect; pause_prompt ;;
            3) run_action setup_foreign_server; pause_prompt ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

diag_gre_details() {
    echo -e "\n${CYAN}=== GRE Interface Details ===${NC}"
    ip -d link show "$TUNNEL_NAME" 2>/dev/null || ip link show "$TUNNEL_NAME" 2>/dev/null || echo "No interface $TUNNEL_NAME"
    ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null || true
}

diag_frp_services() {
    echo -e "\n${CYAN}=== FRP Service Status ===${NC}"
    systemctl status frps --no-pager 2>/dev/null || systemctl status frpc --no-pager 2>/dev/null || echo "No FRP service active"
}

diag_listening_ports() {
    echo -e "\n${CYAN}=== Listening Ports (FRP) ===${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn | grep -E "frps|frpc" || ss -tulpn | head -15
    else
        netstat -tulpn 2>/dev/null | grep -E "frps|frpc" || true
    fi
}

diag_routes() {
    echo -e "\n${CYAN}=== Routing Table ===${NC}"
    ip route show
    echo -e "\n${CYAN}IP Forwarding:${NC} $(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
}

menu_diagnostics() {
    local D_OPT
    while true; do
        clear 2>/dev/null || true
        menu_banner "DIAGNOSTICS & HEALTH CHECK"
        echo "  1) Full Health Check (Doctor: PASS / WARN / FAIL table)"
        echo "  2) Check GRE Interface & Internal Link"
        echo "  3) Check FRP Services (frps / frpc)"
        echo "  4) Check Listening Ports & Port Conflicts"
        echo "  5) Check Routes & IP Forwarding"
        echo "  6) View Live FRP Logs (journalctl — Ctrl+C returns here)"
        echo "  7) Advanced Latency & Speed Benchmark"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read D_OPT "Select an option [0-7]: "
        case "$D_OPT" in
            1) run_action doctor_health_check; pause_prompt ;;
            2) run_action diag_gre_details; pause_prompt ;;
            3) run_action diag_frp_services; pause_prompt ;;
            4) run_action diag_listening_ports; pause_prompt ;;
            5) run_action diag_routes; pause_prompt ;;
            6) run_action show_logs; pause_prompt ;;
            7) run_action doctor_diagnostics; pause_prompt ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

remove_frp_only() {
    local CONFIRM u units=()
    read -p "Are you sure you want to remove FRP services? [y/N]: " CONFIRM || return 1
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        for u in /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service; do
            [[ -f "$u" ]] && units+=("$(basename "$u")")
        done
        [[ ${#units[@]} -gt 0 ]] && remove_units "${units[@]}"
        rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}[✔️] FRP uninstalled.${NC}"
    fi
}

remove_gre_only() {
    local CONFIRM u units=()
    read -p "Are you sure you want to teardown the GRE interfaces? [y/N]: " CONFIRM || return 1
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        for u in /etc/systemd/system/gre-tunnel.service /etc/systemd/system/gre-t[0-9]*.service /etc/systemd/system/gre-chaff*.service; do
            [[ -f "$u" ]] && units+=("$(basename "$u")")
        done
        [[ ${#units[@]} -gt 0 ]] && remove_units "${units[@]}"
        remove_gre_interfaces
        echo -e "${GREEN}[✔️] GRE uninstalled.${NC}"
    fi
}

revert_system_tweaks_confirm() {
    local CONFIRM
    read -p "Revert sysctl tuning, MSS rule, DPI shield, ufw rules added by Hashem, journald cap and swapfile? [y/N]: " CONFIRM || return 1
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && revert_system_tweaks
    return 0
}

remove_legacy_panel_confirm() {
    local CONFIRM
    read -p "Remove the old web panel (service, binary, panel config) from this server? [y/N]: " CONFIRM || return 1
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && remove_legacy_panel
    return 0
}

menu_uninstall() {
    local UN_OPT rc
    while true; do
        clear 2>/dev/null || true
        echo -e "${RED}==============================================================${NC}"
        echo -e "${RED}                   UNINSTALLATION MENU                        ${NC}"
        echo -e "${RED}==============================================================${NC}"
        echo "  1) FULL UNINSTALL — revert EVERYTHING (tunnel, services, firewall,"
        echo "                      tuning, configs, backups and the 'hashem' command)"
        echo "  2) Remove Tunnel Only (GRE + FRP, keeps tuning/watchdog)"
        echo "  3) Remove FRP Only (frps/frpc services, binaries and configs)"
        echo "  4) Remove GRE Only (GRE interfaces and their systemd units)"
        echo "  5) Revert System Tweaks Only (sysctl, MSS rule, DPI shield, ufw, journald, swap)"
        echo "  6) Remove Old Web Panel Leftovers (from previous versions)"
        echo "  0) Back to Main Menu"
        echo ""
        menu_read UN_OPT "Select an option [0-6]: "
        case "$UN_OPT" in
            1)
                run_action uninstall_all
                rc=$?
                if (( rc == 99 )); then exit 99; fi
                pause_prompt
                ;;
            2) run_action remove_tunnel; pause_prompt ;;
            3) run_action remove_frp_only; pause_prompt ;;
            4) run_action remove_gre_only; pause_prompt ;;
            5) run_action revert_system_tweaks_confirm; pause_prompt ;;
            6) run_action remove_legacy_panel_confirm; pause_prompt ;;
            0) return 0 ;;
            "") ;;
            *) echo -e "${RED}[!] Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

menu_loop() {
    # Ctrl+C can never close the script — it only interrupts the running action.
    trap 'echo' INT
    local MAIN_OPT rc
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}"
        echo "=========================================================="
        echo "       GRE + FRP Reverse Tunnel Manager (Iran <-> Kharej)"
        echo "     Layer 3 GRE Tunnel + Encrypted TLS FRP Reverse Relay"
        echo "=========================================================="
        echo -e "${NC}"
        if [[ -f /etc/systemd/system/gre-panel.service || -x /usr/local/bin/gre-panel ]]; then
            echo -e "${YELLOW}[!] An old web panel is still installed here — remove it: Uninstall → option 6${NC}\n"
        fi
        echo "MAIN MENU"
        echo "  1) Installation"
        echo "  2) Tunnel Management"
        echo "  3) Server Management"
        echo "  4) Bundle Management"
        echo "  5) Diagnostics"
        echo "  6) Uninstall  (full uninstall / revert everything)"
        echo "  7) Exit (or 0)"
        echo ""
        menu_read MAIN_OPT "Select an option [1-7]: "
        case "$MAIN_OPT" in
            1) run_menu menu_installation ;;
            2) run_menu menu_tunnel ;;
            3) run_menu menu_server ;;
            4) run_menu menu_bundle ;;
            5) run_menu menu_diagnostics ;;
            6)
                run_menu menu_uninstall
                rc=$?
                if (( rc == 99 )); then
                    echo -e "${CYAN}Uninstall finished. Goodbye!${NC}"
                    exit 0
                fi
                ;;
            7|0|exit|q)
                echo -e "${CYAN}Exiting Hashem Manager. Goodbye!${NC}"
                exit 0
                ;;
            "") ;;
            *)
                echo -e "${RED}[!] Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# The menu needs a real terminal (e.g. `curl ... | bash` leaves stdin as the pipe).
ensure_tty() {
    [[ -t 0 ]] && return 0
    if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
        exec </dev/tty
        return 0
    fi
    echo -e "${RED}[!] The interactive menu needs a terminal. Download the script and run:  bash hashem.sh${NC}"
    exit 1
}

main_menu() {
    ensure_tty
    menu_loop
}

# Non-interactive CLI: hashem.sh setup-iran|setup-foreign with flags.
# The setup_*_noninteractive + _setup_foreign_full functions above are the
# SINGLE source of truth — menu and CLI run the same steps.
usage_cli() {
    cat <<EOF
Usage:
  hashem                                    # interactive menu
  hashem setup-iran    --local-pub IP --remote-pub IP [--frp-port N] [--local-gre IP] [--peer-gre IP] [--token T] [--chaff low|mid|off] [--force]
  hashem setup-foreign --local-pub IP --remote-pub IP [--frp-port N] --token T --ports "443, 2083" [--local-gre IP] [--peer-gre IP] [--chaff low|mid|off] [--force]
                       # ... or: hashem setup-foreign --bundle hsh1_...  (fills everything; explicit flags win)
  hashem status | remove-tunnel [--force]
  hashem uninstall [--force]                   # FULL UNINSTALL: reverts every change (tunnel, services, firewall,
                                               # tuning, configs, backups) and removes the 'hashem' command
  hashem revert-system                         # only undo system tweaks (sysctl, MSS rule, DPI shield, ufw, journald, swap)
  hashem remove-panel                          # remove leftovers of the old web panel
  hashem add-peer --local-pub IP --remote-pub IP [--frp-port N] --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL] [--bundle hsh1_...] [--chaff low|mid|off]
  hashem remove-peer --id N [--force] | peer-list | peer-token --id N
  hashem logs | restart
  hashem optimize | restore | tune-status
  hashem carrier [status|mode auto|direct|fou:P|wss:P|set direct|fou:P|wss:P|next] # multi-carrier failover
  hashem perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|dpi on|off|apply
  hashem chaff on|off|status                   # traffic obfuscation (idle-gap filler)
  hashem dpi-shield on|off|status              # rate-limit reverse ports against DPI flood
  hashem watchdog on|off|status|test|tick      # tunnel watchdog monitoring & alerts
  hashem backup now [--keep N] | restore <f> | schedule ... | status
  hashem tgsend "msg"                          # send Telegram alert manually
  hashem doctor [server|stop-server|fix]       # full latency, jitter, MTU & speed diagnostics
  hashem free-ram                              # cap journald + drop cache + 1GB swap

Setup bundle (one string with everything foreign needs):
  hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]
  e.g. hsh1_85.1.2.3_34567_10.10.10.2_10.10.10.1_AbCdEf1234567890AbCdEf1234567890_443-2083
  Printed as BUNDLE:... by setup-iran / add-peer / peer-token; paste it as
  --bundle (CLI) or at the bundle prompt of the menu.
EOF
}

cli_setup_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="$IRAN_GRE_IP" PEER_GRE="$FOREIGN_GRE_IP" TOKEN="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] Unknown chaff profile '${CHAFF_PROFILE}', defaulting to low.${NC}"; CHAFF_PROFILE="low" ;;
    esac
    LOCAL_PUB=${LOCAL_PUB:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}
    [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] Invalid peer GRE IP: '$PEER_GRE'${NC}"; return 1; }
    if [[ -z "$TOKEN" ]]; then
        TOKEN=$(gen_token32)
        echo -e "${CYAN}[*] Generated token: ${TOKEN}${NC}"
    fi
    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] Tunnel already exists — pass --force to overwrite.${NC}"
        return 1
    fi
    setup_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE"
}

cli_setup_foreign() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="" PEER_GRE="" TOKEN="" PORTS="" FORCE=0 BUNDLE=""
    local FOREIGN_GRE_DEF="$FOREIGN_GRE_IP" IRAN_GRE_DEF="$IRAN_GRE_IP"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] Unknown chaff profile '${CHAFF_PROFILE}', defaulting to low.${NC}"; CHAFF_PROFILE="low" ;;
    esac
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || { echo -e "${RED}[!] Bad --bundle (want hsh1_<IRAN_PUB>_<PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]).${NC}"; return 1; }
        TOKEN=$B_TOKEN
        REMOTE_PUB=$B_IRAN_PUB
        # Bundle FRP server port is the absolute source of truth
        FRP_PORT=$B_FRP_PORT
        LOCAL_GRE=$B_FOREIGN_GRE
        PEER_GRE=$B_IRAN_GRE
        # Only take ports from the bundle if not already provided via --ports
        [[ -z "$PORTS" && -n "$B_PORTS" ]] && PORTS=$B_PORTS
        carrier_set_fou_ports "$B_FOU_P1" "$B_FOU_P2" 2>/dev/null || true
        carrier_init_kernel 2>/dev/null || true
        echo -e "${CYAN}[*] Bundle applied: Source of Truth enforced (Iran ${REMOTE_PUB}, FRP port ${FRP_PORT}).${NC}"
    fi
    LOCAL_PUB=${LOCAL_PUB:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}
    [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    LOCAL_GRE=${LOCAL_GRE:-$FOREIGN_GRE_DEF}
    PEER_GRE=${PEER_GRE:-$IRAN_GRE_DEF}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] Invalid peer GRE IP: '$PEER_GRE'${NC}"; return 1; }
    [[ -n "$TOKEN" ]] || { echo -e "${RED}[!] --token is required (copy it from the Iran side).${NC}"; return 1; }
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do
        is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"
    done
    CLEANED=$(echo "$CLEANED" | xargs)
    if [[ -z "$CLEANED" ]]; then
        echo -e "${RED}[!] --ports needs at least one valid port (e.g. \"443, 2083\"). The bundle did not include ports — pass --ports explicitly.${NC}"
        return 1
    fi

    # FRP control port: warn but continue non-interactively (frpc reports a
    # start failure in the summary if it truly cannot bind).
    FRP_PORT=$(ensure_port_available "$FRP_PORT" "FRP Control Port" ${BUNDLE:+1}) || return 1

    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] Tunnel already exists — pass --force to overwrite.${NC}"
        return 1
    fi
    setup_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$CLEANED"
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help|help) usage_cli; exit 0 ;;
        bundle)
            shift
            case "${1:-}" in
                inspect) shift; cli_bundle_inspect "$@" ;;
                *) echo "Usage: hashem bundle inspect <bundle> [--show-token]"; exit 1 ;;
            esac
            exit $?
            ;;
    esac

    check_root
    case "$1" in
        setup-iran) shift; cli_setup_iran "$@" ;;
        setup-foreign) shift; cli_setup_foreign "$@" ;;
        add-peer) shift; cli_add_peer "$@" ;;
        remove-peer) shift; cli_remove_peer "$@" ;;
        peer-list) peer_list ;;
        logs) show_logs ;;
        restart) restart_all ;;
        perf) shift; cli_perf "$@" ;;
        chaff) shift; cli_chaff "$@" ;;
        dpi-shield|dpi_shield|dpishield) shift; cli_dpi_shield "$@" ;;
        watchdog) shift; cli_watchdog "$@" ;;
        backup) shift; cli_backup "$@" ;;
        tgsend) shift; watchdog_send "$1" ;;
        peer-token)
            shift; ID=""
            while [[ $# -gt 0 ]]; do case "$1" in --id) ID="$2"; shift 2 ;; *) shift ;; esac; done
            peer_token "$ID" ;;
        status) check_status ;;
        doctor|test|diagnose) shift; cli_doctor "$@" ;;
        carrier) shift; cli_carrier "$@" ;;
        carrier-kernel-init) carrier_init_kernel ;;
        carrier-apply-active) shift; carrier_apply_active "$1" ;;
        optimize) tune_apply ;;
        restore) tune_restore ;;
        tune-status) tune_status ;;
        free-ram|optimize-ram) free_ram ;;
        revert-system) revert_system_tweaks ;;
        remove-panel) remove_legacy_panel ;;
        remove-tunnel)
            if [[ "${2:-}" == "--force" ]]; then remove_tunnel_force; else remove_tunnel; fi ;;
        uninstall|revert|full-uninstall)
            if [[ "${2:-}" == "--force" ]]; then uninstall_all_force; UN_RC=$?; else uninstall_all; UN_RC=$?; fi
            [[ "$UN_RC" -eq 99 ]] && UN_RC=0
            exit "$UN_RC" ;;
        *) echo -e "${RED}[!] Unknown command: $1${NC}"; usage_cli; exit 1 ;;
    esac
    exit $?
fi

check_root
main_menu
