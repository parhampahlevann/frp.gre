#!/bin/bash

# ==============================================================================
#   GRE + FRP Reverse Tunnel Automated Setup Script
#   Architecture: GRE Layer 3 Tunnel + FRP Reverse TLS Tunnel
#   Features: Auto Arch Detect, Systemd Auto-start on boot, MTU Clamping, TCP/UDP
# ==============================================================================

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

# ---- input validation (IPv4 format, port range 1-65535) ----
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
prompt_ip() { # $1=varname $2=label $3=default (empty = required)
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        if [[ -n "$__def" ]]; then
            read -p "$__label [Default: $__def]: " __in
            __in=${__in:-$__def}
        else
            read -p "$__label: " __in
        fi
        if is_valid_ip "$__in"; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] Invalid IPv4 address: '${__in}'. Example: 203.0.113.10${NC}"
    done
}

prompt_port() { # $1=varname $2=label $3=default
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -p "$__label [Default: $__def]: " __in
        __in=${__in:-$__def}
        if is_valid_port "$__in"; then printf -v "$__var" '%s' "$((10#$__in))"; return 0; fi
        echo -e "${RED}[!] Invalid port: '${__in}'. Must be 1-65535.${NC}"
    done
}

prompt_required() { # $1=varname $2=label — must be non-empty
    local __var=$1 __label=$2 __in
    while true; do
        read -p "$__label: " __in
        if [[ -n "$__in" ]]; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] This field is required and cannot be empty.${NC}"
    done
}

prompt_token() { # $1=varname $2=label $3=default (empty accepts default)
    local __var=$1 __label=$2 __def=$3 __in
    read -p "$__label [Press Enter for: $__def]: " __in
    printf -v "$__var" '%s' "${__in:-$__def}"
}

prompt_ports() { # $1=varname $2=label — at least one valid port
    local __var=$1 __label=$2 __in __ok p
    while true; do
        read -p "$__label (e.g. 443, 2083, 8080): " __in
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
    ip tunnel show 2>/dev/null | grep -q "$TUNNEL_NAME" && return 0
    [[ -f "${CONFIG_DIR}/frps.toml" || -f "${CONFIG_DIR}/frpc.toml" ]] && return 0
    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
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
            exit 1
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

install_frp_binaries() {
    # already installed → reuse (add-peer must not re-download FRP per peer,
    # and must never exit the caller if the network is slow — peers 2..5
    # would otherwise fail with E-INSTALL-02 on a healthy machine).
    if [[ -x "${INSTALL_DIR}/frps" && -x "${INSTALL_DIR}/frpc" ]]; then
        return 0
    fi
    detect_arch
    get_latest_frp_version
    echo -e "${CYAN}[*] Downloading FRP v${FRP_VERSION} (${FRP_ARCH})...${NC}"

    mkdir -p "$CONFIG_DIR"
    TMP_DIR=$(mktemp -d)
    TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TAR_FILE}"

    if ! curl -fsSL --max-time 90 -o "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL"; then
        echo -e "${RED}[!] Failed to download FRP from GitHub.${NC}"
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
    setup_gre_iface "$TUNNEL_NAME" "$1" "$2" "$3"
}

# Generalized GRE interface setup: $1=ifname $2=local_pub $3=remote_pub $4=inner_ip.
# setup_gre_systemd() above is the legacy single-tunnel wrapper; peers call this
# directly with gre-tN names so every tunnel is the same GRE, just N of them.
setup_gre_iface() {
    local IFNAME=$1
    local LOCAL_IP=$2
    local REMOTE_IP=$3
    local GRE_INTERNAL_IP=$4

    echo -e "${CYAN}[*] Configuring persistent GRE tunnel service (${IFNAME})...${NC}"

    # Tear down existing if present
    ip tunnel del "$IFNAME" >/dev/null 2>&1 || true

    # Create systemd service for GRE
    cat <<EOF > /etc/systemd/system/${IFNAME}.service
[Unit]
Description=GRE Tunnel Interface
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/ip tunnel del ${IFNAME}
ExecStart=/bin/sh -c "/sbin/ip tunnel add ${IFNAME} mode gre local ${LOCAL_IP} remote ${REMOTE_IP} ttl 255 && /sbin/ip link set dev ${IFNAME} up mtu 1448 && /sbin/ip addr add ${GRE_INTERNAL_IP}/30 dev ${IFNAME}"
ExecStop=-/sbin/ip tunnel del ${IFNAME}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${IFNAME}.service" >/dev/null 2>&1
    if ! systemctl restart "${IFNAME}.service"; then
        echo -e "${RED}[!] GRE interface ${IFNAME} failed to start — check: ip tunnel show; journalctl -u ${IFNAME}.service${NC}"
        return 1
    fi

    # Enable packet forwarding & MSS clamping to avoid fragmentation
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    echo -e "${GREEN}[✔️] GRE Tunnel service active with IP ${GRE_INTERNAL_IP}.${NC}"
}

# ---- SINGLE SOURCE OF TRUTH for install logic ----
# setup_iran_server_noninteractive / setup_foreign_server_noninteractive do the
# real work. The interactive menu functions below only prompt + validate, then
# delegate here. The CLI flags at the bottom of this file (setup-iran /
# setup-foreign) call the very same functions, so both paths execute
# identical steps — tunnel-only, no web panel.
# Args: $1=local_pub $2=remote_pub $3=frp_port $4=token [$5=local_gre [$6=peer_gre [$7="cleaned ports"]]]
setup_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$IRAN_GRE_IP} PEER_GRE=${6:-$FOREIGN_GRE_IP}
    setup_gre_systemd "$IP_IRAN" "$IP_FOREIGN" "$LOCAL_GRE"
    install_frp_binaries
    cat <<EOF > "${CONFIG_DIR}/frps.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
transport.tls.force = false
transport.maxPoolCount = 50
EOF
    cat <<EOF > /etc/systemd/system/frps.service
[Unit]
Description=FRP Server Service
After=network.target ${TUNNEL_NAME}.service
Wants=${TUNNEL_NAME}.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable frps >/dev/null 2>&1
    systemctl restart frps
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1
    fi
    echo -e "${GREEN}[✔️] IRAN setup done: GRE ${IP_IRAN} <-> ${IP_FOREIGN} (${LOCAL_GRE} peer ${PEER_GRE}), frps :${BIND_PORT}${NC}"
    echo -e "${YELLOW}Token: ${TOKEN} (copy to the FOREIGN side)${NC}"
}

setup_foreign_server_noninteractive() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$FOREIGN_GRE_IP} PEER_GRE=${6:-$IRAN_GRE_IP}
    local PORTS_CLEANED=${7:-}
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_CLEANED"
}

# shared full foreign path: GRE + ping feedback + frpc binaries/config/service.
# Called by both the interactive menu and the CLI.
_setup_foreign_full() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=$5 PEER_GRE=$6 PORTS_CLEANED=$7
    setup_gre_systemd "$IP_FOREIGN" "$IP_IRAN" "$LOCAL_GRE"
    echo -e "${CYAN}[*] Testing GRE internal ping to Iran (${PEER_GRE})...${NC}"
    if ping -c 3 -W 2 "$PEER_GRE" >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] GRE Tunnel link is UP and reachable!${NC}"
    else
        echo -e "${YELLOW}[!] Warning: Ping to ${PEER_GRE} did not respond yet.${NC}"
    fi
    install_frp_binaries
    cat <<EOF > "${CONFIG_DIR}/frpc.toml"
serverAddr = "${PEER_GRE}"
serverPort = ${SERVER_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
transport.tls.enable = true
transport.poolCount = 10

EOF
    local PORT
    for PORT in $PORTS_CLEANED; do
        cat <<EOF >> "${CONFIG_DIR}/frpc.toml"
[[proxies]]
name = "tcp_${PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${PORT}
remotePort = ${PORT}

[[proxies]]
name = "udp_${PORT}"
type = "udp"
localIP = "127.0.0.1"
localPort = ${PORT}
remotePort = ${PORT}

EOF
    done
    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=FRP Client Reverse Service
After=network.target ${TUNNEL_NAME}.service
Wants=${TUNNEL_NAME}.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable frpc >/dev/null 2>&1
    systemctl restart frpc
    echo -e "${GREEN}[✔️] FOREIGN setup done: GRE ${IP_FOREIGN} <-> ${IP_IRAN} (${LOCAL_GRE} peer ${PEER_GRE}), frpc → ${PEER_GRE}:${SERVER_PORT}${NC}"
    echo -e "${GREEN}Reverse ports: ${PORTS_CLEANED} (TCP & UDP, TLS)${NC}"
}

# ---- Multi-peer tunnels: up to MAX_PEERS foreign servers on one Iran ----
# Peer 1 reuses the legacy names (gre-tunnel, frps.toml, frps.service) so
# existing installs keep working. Peers 2..5 get gre-tN + frps-N.toml +
# frps-N.service, each with its own token and control port (one frps
# understands only one token). Registry: /etc/gre-panel/peers.json.
PEERS_FILE="/etc/gre-panel/peers.json"
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
    peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); print(" ".join(f"{p}:{r["name"]}" for r in d.get("peers",[]) for p in r.get("ports",[])))'
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
}

# write one frps instance: $1=suffix("" for legacy, "-N" for peers) $2=bind_port $3=token
peer_write_frps() {
    local SUF=$1 BIND_PORT=$2 TOKEN=$3
    cat <<EOF > "${CONFIG_DIR}/frps${SUF}.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
transport.tls.force = false
transport.maxPoolCount = 50
EOF
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
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1
    fi
}

# add a peer tunnel on the Iran side.
# Flags: --name --local-pub --remote-pub --frp-port --token --local-gre --peer-gre --ports "443, 2083" [--force]
cli_add_peer() {
    local NAME="" LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="7000" TOKEN="" LOCAL_GRE="" PEER_GRE="" PORTS="" FORCE=0
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
            --force) FORCE=1; shift ;;
            -h|--help) echo 'Usage: gre.sh add-peer --local-pub IP --remote-pub IP --frp-port N --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL] [--force]'; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; return 1 ;;
        esac
    done
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
    if [[ "$ID" -eq 1 ]] && ! tunnel_present; then
        # first tunnel keeps legacy names (gre-tunnel, frps) — old setups untouched
        setup_gre_systemd "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE"
        peer_write_frps "" "$FRP_PORT" "$TOKEN"
        GRE_IF="$TUNNEL_NAME"; FRPS_SVC="frps"; LEGACY=true
    else
        GRE_IF="gre-t${ID}"; FRPS_SVC="frps-${ID}"; LEGACY=false
        setup_gre_iface "$GRE_IF" "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE"
        peer_write_frps "-${ID}" "$FRP_PORT" "$TOKEN"
        # point the new unit at the right interface
        sed -i "s/After=network.target/After=network.target ${GRE_IF}.service/" /etc/systemd/system/${FRPS_SVC}.service
        systemctl daemon-reload; systemctl restart "$FRPS_SVC"
    fi
    # registry record (ports as JSON array)
    local PORTS_JSON
    PORTS_JSON=$(echo "$CLEANED" | python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.stdin.read().split()]))')
    PEERS_F="$PEERS_FILE" python3 - "$ID" "$NAME" "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_JSON" "$GRE_IF" "$FRPS_SVC" "$LEGACY" <<'PYEOF'
import json, os, sys
f = os.environ["PEERS_F"]
iid, name, lip, rip, fport, tok, lgre, pgre, pjson, gif, svc, leg = sys.argv[1:]
d = json.load(open(f))
d.setdefault("peers", []).append({"id": int(iid), "name": name, "local_pub": lip,
  "remote_pub": rip, "frp_port": int(fport), "token": tok, "local_gre": lgre,
  "peer_gre": pgre, "ports": json.loads(pjson), "gre_if": gif, "frps_svc": svc,
  "legacy": leg == "true"})
json.dump(d, open(f, "w"), indent=2)
PYEOF
    echo -e "${GREEN}[✔️] Peer '${NAME}' (id ${ID}) added: GRE ${LOCAL_PUB} <-> ${REMOTE_PUB} (${LOCAL_GRE} peer ${PEER_GRE} on ${GRE_IF}), ${FRPS_SVC} :${FRP_PORT}${NC}"
    echo -e "${YELLOW}Token for '${NAME}': ${TOKEN} (enter it on the FOREIGN side with ports: ${CLEANED})${NC}"
    echo -e "${CYAN}Foreign side: frpc server ${LOCAL_GRE}:${FRP_PORT}${NC}"
}

# remove one peer ($1=id). Legacy peer 1 also drops the old single tunnel.
cli_remove_peer() {
    local ID="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --id) ID="$2"; shift 2 ;; --force) FORCE=1; shift ;;
            -h|--help) echo 'Usage: gre.sh remove-peer --id N [--force]'; return 0 ;;
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
        read -p "Remove peer '${NAME}' (id ${ID})? GRE + its frps go away. (y/N): " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[*] Aborted.${NC}"; return 0; }
    fi
    if [[ "$LEG" == "1" ]]; then
        remove_tunnel_force
    else
        systemctl stop "$SVC" "${GIF}.service" >/dev/null 2>&1
        systemctl disable "$SVC" "${GIF}.service" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${GIF}.service" "/etc/frp/frps-${ID}.toml"
        systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1 || true
        ip tunnel del "$GIF" >/dev/null 2>&1 || true
    fi
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" python3 -c \
'import json,os; f=os.environ["PEERS_F"]; d=json.load(open(f)); d["peers"]=[p for p in d.get("peers",[]) if p["id"]!=int(os.environ["PEER_ID"])]; json.dump(d,open(f,"w"),indent=2)'
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

    # Prefer the local interface IP (what GRE must bind to) over the egress IP
    # an external service sees (often different behind NAT, e.g. ipify).
    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    prompt_ip IP_IRAN "Enter IRAN Server Public IP" "$MY_PUBLIC_IP"
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" ""

    prompt_port BIND_PORT "Enter FRP Bind Port" "7000"

    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Enter Secret Auth Token" "$AUTO_TOKEN"

    # single source of truth: GRE + frps all happen inside
    setup_iran_server_noninteractive "$IP_IRAN" "$IP_FOREIGN" "$BIND_PORT" "$TOKEN" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP"

    echo -e "\n${GREEN}=================================================================${NC}"
    echo -e "${GREEN}[✔️] IRAN SERVER CONFIGURATION COMPLETE!${NC}"
    echo -e "GRE Public Link:      ${CYAN}${IP_IRAN} <--> ${IP_FOREIGN}${NC}"
    echo -e "IRAN GRE Internal IP: ${CYAN}${IRAN_GRE_IP}${NC}"
    echo -e "FRP Bind Port:        ${CYAN}${BIND_PORT}${NC}"
    echo -e "Secret Token:         ${CYAN}${TOKEN}${NC}"
    echo -e "\n${YELLOW}>>> Now run this script on FOREIGN server and provide:${NC}"
    echo -e "1. IRAN Public IP: ${CYAN}${IP_IRAN}${NC}"
    echo -e "2. Port:           ${CYAN}${BIND_PORT}${NC}"
    echo -e "3. Token:          ${CYAN}${TOKEN}${NC}"
    echo -e "${GREEN}=================================================================${NC}\n"
}

# interactive wrapper for cli_add_peer: prompts for one more foreign server.
menu_add_peer() {
    echo -e "\n${YELLOW}=== Add Peer Tunnel (connect ANOTHER foreign server to this Iran) ===${NC}"
    peer_init
    USED=$(peer_ports_used 2>/dev/null)
    [[ -n "$USED" ]] && echo -e "${CYAN}Already claimed reverse ports: ${USED}${NC}"
    local MYIP
    MYIP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    local NAME IP_FOREIGN PORT CPORT TOKEN LGRE PGRE PPORTS
    read -p "Peer name (e.g. germany-1) [Enter for auto]: " NAME
    prompt_ip LOCAL_IRAN "Enter IRAN Server Public IP" "$MYIP"
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" ""
    # suggest next free control port + GRE pair
    local NEXT_ID SU_FP SU_LG SU_PG
    NEXT_ID=$(peer_next_id 2>/dev/null || echo 2)
    SU_FP=$((7000 + NEXT_ID - 1)); is_valid_port "$SU_FP" || SU_FP=7000
    SU_LG="10.1${NEXT_ID}.0.2"; SU_PG="10.1${NEXT_ID}.0.1"
    prompt_port CPORT "Enter FRP Control Port (unique per peer)" "$SU_FP"
    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Peer token (each peer gets its own)" "$AUTO_TOKEN"
    prompt_ip LGRE "Local GRE IP (unique per peer)" "$SU_LG"
    prompt_ip PGRE "Peer GRE IP" "$SU_PG"
    prompt_ports PPORTS "Ports to Reverse-Tunnel"
    cli_add_peer --name "$NAME" --local-pub "$LOCAL_IRAN" --remote-pub "$IP_FOREIGN" \
        --frp-port "$CPORT" --token "$TOKEN" --local-gre "$LGRE" --peer-gre "$PGRE" --ports "$PPORTS"
    echo -e "\n${GREEN}=== On the FOREIGN server, run this script option 2 with: ===${NC}"
    echo -e "IRAN Public IP: ${CYAN}${LOCAL_IRAN}${NC} | Port: ${CYAN}${CPORT}${NC} | Token: ${CYAN}${TOKEN}${NC}"
    echo -e "GRE: local ${CYAN}${PGRE}${NC} peer ${CYAN}${LGRE}${NC} | Ports: ${CYAN}${PPORTS}${NC}"
}

menu_remove_peer() {
    echo -e "\n${YELLOW}=== Remove Peer Tunnel ===${NC}"
    peer_list_pretty || return 1
    local ID
    read -p "Peer id to remove: " ID
    cli_remove_peer --id "$ID"
}

setup_foreign_server() {
    echo -e "\n${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}   STEP 2: CONFIGURING FOREIGN SERVER (GRE + FRPC)  ${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "$MY_PUBLIC_IP"
    prompt_ip IP_IRAN "Enter IRAN Server Public IP" ""

    prompt_port SERVER_PORT "Enter FRP Bind Port" "7000"
    prompt_required TOKEN "Enter Secret Auth Token"
    prompt_ports INPUT_PORTS "Enter Ports to Reverse-Tunnel"

    # single source of truth: GRE + ping + frpc all happen inside
    # (frpc reaches Iran's GRE internal IP through the GRE tunnel)
    PORTS_CLEANED=$(echo "$INPUT_PORTS" | tr ',' ' ')
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$FOREIGN_GRE_IP" "$IRAN_GRE_IP" "$PORTS_CLEANED"

    echo -e "\n${GREEN}=================================================================${NC}"
    echo -e "${GREEN}[✔️] FOREIGN SERVER CONFIGURATION COMPLETE!${NC}"
    echo -e "GRE Public Link:      ${CYAN}${IP_FOREIGN} <--> ${IP_IRAN}${NC}"
    echo -e "FOREIGN GRE IP:       ${CYAN}${FOREIGN_GRE_IP}${NC}"
    echo -e "FRP Connecting to:    ${CYAN}${IRAN_GRE_IP}:${SERVER_PORT}${NC} (Inside GRE Tunnel)"
    echo -e "Reverse Ports:        ${CYAN}${PORTS_CLEANED}${NC} (TCP & UDP)"
    echo -e "FRP TLS Encryption:   ${GREEN}Enabled${NC}"
    echo -e "${GREEN}=================================================================${NC}\n"
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
    echo -e "\n${YELLOW}=== Live Service Logs (Ctrl+C to exit) ===${NC}"
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
    for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-tunnel.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service; do
        [[ -f "$u" ]] || continue
        systemctl restart "$(basename "$u")" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] $(basename "$u") restarted.${NC}"
    done
    echo -e "${GREEN}[✔️] All services restarted.${NC}"
}

uninstall_all() {
    echo -e "\n${RED}=== FULL UNINSTALL — undo every change this script has made ===${NC}"
    echo -e "This removes: GRE tunnel(s), FRP (binaries/configs/services), the peer registry,"
    echo -e "network tuning (sysctl/MTU/MSS), the RAM-saving tweaks (journald/swap/swappiness),"
    echo -e "firewall rules opened for the tunnel, and any leftover web-panel files from an"
    echo -e "older version of this script."
    read -p "Are you sure you want to undo ALL of that? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        uninstall_all_force
    else
        echo -e "${YELLOW}[*] Aborted.${NC}"
    fi
}

# Non-interactive core: full wipe of everything this script can change.
# Called by uninstall_all() after confirm, and by `gre.sh uninstall --force`.
uninstall_all_force() {
        echo -e "${CYAN}[*] Reversing network optimization (if it was ever applied)...${NC}"
        if [[ -f "$TUNE_BACKUP" ]]; then
            tune_restore
        else
            rm -f /etc/sysctl.d/99-gre-tune.conf
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
        fi

        echo -e "${CYAN}[*] Reversing RAM-saving tweaks (if they were ever applied)...${NC}"
        if [[ -f /etc/systemd/journald.conf ]]; then
            sed -i 's/^SystemMaxUse=32M$/#SystemMaxUse=/' /etc/systemd/journald.conf
            sed -i 's/^RuntimeMaxUse=16M$/#RuntimeMaxUse=/' /etc/systemd/journald.conf
            systemctl restart systemd-journald >/dev/null 2>&1
        fi
        rm -f /etc/sysctl.d/99-swappiness.conf
        sysctl -w vm.swappiness=60 >/dev/null 2>&1
        swapoff /swapfile >/dev/null 2>&1
        rm -f /swapfile
        sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab 2>/dev/null

        echo -e "${CYAN}[*] Removing firewall rules opened for the tunnel...${NC}"
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            local f p
            for f in "${CONFIG_DIR}"/frps*.toml; do
                [[ -f "$f" ]] || continue
                p=$(grep -o 'bindPort = [0-9]*' "$f" | grep -o '[0-9]*')
                [[ -n "$p" ]] && ufw delete allow "${p}/tcp" >/dev/null 2>&1
            done
        fi

        echo -e "${CYAN}[*] Removing GRE + FRP tunnel (legacy + all peers)...${NC}"
        systemctl stop frps frpc "${TUNNEL_NAME}.service" >/dev/null 2>&1
        systemctl stop 'frps-*' 'gre-t*.service' >/dev/null 2>&1 || true
        systemctl disable frps frpc "${TUNNEL_NAME}.service" >/dev/null 2>&1 || true

        rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service /etc/systemd/system/${TUNNEL_NAME}.service /etc/systemd/system/gre-t*.service
        systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1 || true

        local gif
        for gif in "$TUNNEL_NAME" $(ip tunnel show 2>/dev/null | grep -o 'gre-t[0-9]*'); do
            ip tunnel del "$gif" >/dev/null 2>&1 || true
        done

        rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
        rm -rf "$CONFIG_DIR"
        rm -f "$PEERS_FILE" "$TUNE_BACKUP"

        # cleanup any leftover web panel from an older version of this script
        # (harmless no-op if it was never installed)
        systemctl stop gre-panel >/dev/null 2>&1
        systemctl disable gre-panel >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/gre-panel.service
        rm -f /usr/local/bin/gre-panel /usr/local/bin/grepanel /usr/local/bin/hashem
        rm -rf /etc/gre-panel /usr/local/gre-panel
        systemctl daemon-reload

        echo -e "${GREEN}[✔️] Full uninstall complete — GRE/FRP, network tuning, RAM tweaks, firewall rules,${NC}"
        echo -e "${GREEN}    and any leftover panel files have all been removed.${NC}"
        echo -e "${YELLOW}[i] A reboot is recommended to make sure no lingering kernel socket-buffer values remain.${NC}"
}

remove_tunnel() {
    echo -e "\n${RED}=== Remove Tunnel Only (GRE + FRP) ===${NC}"
    read -p "Remove the tunnel from THIS server? Network tuning / RAM settings are kept. (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        remove_tunnel_force
    else
        echo -e "${YELLOW}[*] Aborted.${NC}"
    fi
}

# Non-interactive core: stop/disable units, drop interface, remove FRP files.
# Network tuning and RAM tweaks are left untouched here — use Full Uninstall
# (option 6) to undo those too.
remove_tunnel_force() {
        # Stop & disable services
        systemctl stop frps frpc "${TUNNEL_NAME}.service" >/dev/null 2>&1
        systemctl disable frps frpc "${TUNNEL_NAME}.service" >/dev/null 2>&1

        # Remove systemd files (legacy + all peer tunnels)
        rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service /etc/systemd/system/${TUNNEL_NAME}.service /etc/systemd/system/gre-t*.service
        systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1 || true

        # Remove GRE interfaces (legacy + all peers)
        local gif
        for gif in "$TUNNEL_NAME" $(ip tunnel show 2>/dev/null | grep -o 'gre-t[0-9]*'); do
            ip tunnel del "$gif" >/dev/null 2>&1 || true
        done

        # Remove binaries & configs (peers registry cleared)
        rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
        rm -rf "$CONFIG_DIR"
        rm -f "$PEERS_FILE"

        echo -e "${GREEN}[✔️] Tunnel removed — GRE interface, FRP services, binaries and configs gone.${NC}"
}

# ---- Network optimization for tunnel throughput ----
# Same on both roles (auto-detects nothing: these are role-independent).
# Backup lives in /etc/gre-panel/tune.bak (key=value snapshot), restored by
# tune_restore(). Idempotent — safe to run twice.
TUNE_BACKUP="/etc/gre-panel/tune.bak"

tune_backup_once() {
    if [[ -f "$TUNE_BACKUP" ]]; then return 0; fi
    mkdir -p "$(dirname "$TUNE_BACKUP")"
    : > "$TUNE_BACKUP"
    local k v
    for k in net.ipv4.ip_forward net.core.rmem_max net.core.wmem_max \
             net.core.netdev_max_backlog net.ipv4.tcp_congestion_control; do
        v=$(sysctl -n "$k" 2>/dev/null) || v=""
        echo "$k=$v" >> "$TUNE_BACKUP"
    done
    if lsmod 2>/dev/null | grep -q "^tcp_bbr"; then echo "tcp_bbr=loaded" >> "$TUNE_BACKUP";
    else echo "tcp_bbr=absent" >> "$TUNE_BACKUP"; fi
    echo "gre_mtu=$(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')" >> "$TUNE_BACKUP"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "mss_clamp=present" >> "$TUNE_BACKUP"
    else
        echo "mss_clamp=absent" >> "$TUNE_BACKUP"
    fi
    echo -e "${CYAN}[*] Current settings backed up to ${TUNE_BACKUP}.${NC}"
}

tune_apply() {
    tune_backup_once
    echo -e "${CYAN}[*] Optimizing network stack for tunnel throughput...${NC}"

    # 1. BBR congestion control (best for high-latency links like IR↔TR)
    if modprobe tcp_bbr >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q "^tcp_bbr"; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 && echo -e "${GREEN}[✔️] TCP congestion control → bbr${NC}" || echo -e "${YELLOW}[!] bbr unavailable — keeping current CC.${NC}"
    else
        echo -e "${YELLOW}[!] tcp_bbr module not available — keeping current CC.${NC}"
    fi

    # 2. Bigger socket buffers (16MB) so fast links don't stall
    sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] Socket buffers → 16MB (rmem_max/wmem_max)${NC}"

    # 3. Deeper NIC queue (packet bursts under load)
    sysctl -w net.core.netdev_max_backlog=5000 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] netdev backlog → 5000${NC}"

    # 4. IP forwarding (tunnel needs it)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] IPv4 forwarding → on${NC}"

    # 5. GRE MTU 1448 (1500 outer − 24 GRE − 28 IP/ICMP headroom:
    # full-size packets pass unfragmented, verified by MTU probe)
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        ip link set dev "$TUNNEL_NAME" mtu 1448 >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ${TUNNEL_NAME} MTU → 1448${NC}" || echo -e "${YELLOW}[!] Could not set GRE MTU.${NC}"
    else
        echo -e "${YELLOW}[*] No ${TUNNEL_NAME} interface yet — MTU will apply on next setup.${NC}"
    fi

    # 6. MSS clamp (idempotent) so TCP never fragments through the tunnel
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    echo -e "${GREEN}[✔️] TCP MSS clamp → on${NC}"

    # 7. Persist across reboots
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-gre-tune.conf <<'EOF'
# Hashem tunnel optimization (applied by Optimize button / tune command)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.ip_forward = 1
EOF
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-gre-tune.conf
    fi
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
                    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
                    echo -e "${GREEN}[✔️] MSS clamp removed${NC}"
                fi ;;
        esac
    done < "$TUNE_BACKUP"
    rm -f /etc/sysctl.d/99-gre-tune.conf
    echo -e "${GREEN}[✔️] Restored — backup kept at ${TUNE_BACKUP} (deleted on next optimize run).${NC}"
    rm -f "$TUNE_BACKUP"
}

tune_status() {
    echo -e "${CYAN}=== Tunnel Optimization Status ===${NC}"
    echo "CC:        $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
    echo "rmem_max:  $(sysctl -n net.core.rmem_max 2>/dev/null || echo ?)"
    echo "wmem_max:  $(sysctl -n net.core.wmem_max 2>/dev/null || echo ?)"
    echo "backlog:   $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo ?)"
    echo "forward:   $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)"
    echo "GRE MTU:   $(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}' || echo 'no interface')"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "MSS clamp: on"
    else
        echo "MSS clamp: off"
    fi
    if [[ -f "$TUNE_BACKUP" ]]; then echo "Backup:    $TUNE_BACKUP (restore available)"; else echo "Backup:    none"; fi
    [[ -f /etc/sysctl.d/99-gre-tune.conf ]] && echo "Persisted: yes (/etc/sysctl.d/99-gre-tune.conf)" || echo "Persisted: no"
}

# free_ram: drop page caches + compact memory + journald cap + ensure 1G swap.
# Safe on any Ubuntu host: no service is touched, kernel reclaims only
# discardable cache; swap is created once and reused afterwards.
free_ram() {
    echo -e "${CYAN}[*] Freeing RAM (safe: caches only, no service touched)...${NC}"
    local before
    before=$(free -m | awk '/^Mem:/{print $7}')
    # 1. journald cap (the #1 silent RAM eater on Ubuntu: 100M+ in RAM)
    if [[ -f /etc/systemd/journald.conf ]]; then
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
        if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo -e "${GREEN}[✔️] 1G swap created${NC}"
        else
            echo -e "${YELLOW}[!] Could not create swapfile (disk full?)${NC}"
        fi
    else
        echo -e "${GREEN}[✔️] swap already active${NC}"
    fi
    sysctl -w vm.swappiness=15 >/dev/null 2>&1
    echo 'vm.swappiness=15' > /etc/sysctl.d/99-swappiness.conf 2>/dev/null
    local after
    after=$(free -m | awk '/^Mem:/{print $7}')
    echo -e "${GREEN}[✔️] Available RAM: ${before}M → ${after}M${NC}"
    free -m | head -2
}

# NOTE: this pulls gre.sh from the pdnczone/hashem-panel GitHub repo. Point
# UPDATE_URL at wherever you actually host the panel-free version of this
# script (your own repo/gist) before relying on this option.
UPDATE_URL="https://raw.githubusercontent.com/pdnczone/hashem-panel/main/gre.sh"

update_all() {
    echo -e "${CYAN}[*] Checking for a newer version of gre.sh...${NC}"
    TMP_U="$(mktemp -d)"
    trap 'rm -rf "$TMP_U"' RETURN
    if ! curl -fsSL --max-time 30 "$UPDATE_URL" -o "$TMP_U/gre.sh"; then
        echo -e "${RED}[!] Failed to download the latest gre.sh — nothing changed.${NC}"
        return 1
    fi
    bash -n "$TMP_U/gre.sh" || { echo -e "${RED}[!] Downloaded script failed syntax check — nothing changed.${NC}"; return 1; }
    if cmp -s "$TMP_U/gre.sh" "$0" 2>/dev/null || cmp -s "$TMP_U/gre.sh" ./gre.sh 2>/dev/null; then
        echo -e "${GREEN}[✔️] gre.sh is already the latest version.${NC}"
        return 0
    fi
    cp "$TMP_U/gre.sh" "$0" 2>/dev/null || cp "$TMP_U/gre.sh" ./gre.sh
    chmod +x "$0" 2>/dev/null || true
    echo -e "${GREEN}[✔️] Updated — re-run the script to use the new version.${NC}"
}

main_menu() {
    clear
    echo -e "${CYAN}"
    echo "=========================================================="
    echo "       GRE + FRP Reverse Tunnel Manager (Iran <-> Kharej)"
    echo "     Layer 3 GRE Tunnel + Encrypted TLS FRP Reverse Relay"
    echo "=========================================================="
    echo -e "${NC}"
    echo "1) Setup IRAN Server    (GRE + FRP Server / frps)"
    echo "2) Setup FOREIGN Server (GRE + FRP Client / frpc Reverse)"
    echo "3) Check Connection Status & GRE Ping Test"
    echo "4) View FRP Live Logs"
    echo "5) Restart Tunnel Services"
    echo "6) FULL UNINSTALL (undo everything: tunnel + tuning + RAM tweaks)"
    echo "7) Update Script (pull latest gre.sh)"
    echo "8) Remove Tunnel Only (GRE + FRP, keep tuning/RAM settings)"
    echo "9) Optimize Tunnel (BBR + buffers + MTU/MSS, with backup)"
    echo "10) Restore Pre-Optimize Settings"
    echo "11) Optimization Status"
    echo "12) Add Peer Tunnel (Iran: connect another foreign server)"
    echo "13) List Peer Tunnels"
    echo "14) Remove Peer Tunnel"
    echo "15) CLI help (non-interactive commands)"
    echo "16) Free RAM (journald cap 16M + drop cache + 1GB swap)"
    echo "0) Exit"
    echo ""
    read -p "Select an option [0-16]: " OPTION

    case "$OPTION" in
        1)
            setup_iran_server
            ;;
        2)
            setup_foreign_server
            ;;
        3)
            check_status
            ;;
        4)
            show_logs
            ;;
        5)
            restart_all
            ;;
        6)
            uninstall_all
            ;;
        7)
            update_all
            ;;
        8)
            remove_tunnel
            ;;
        9)
            tune_apply
            ;;
        10)
            tune_restore
            ;;
        11)
            tune_status
            ;;
        12)
            menu_add_peer
            ;;
        13)
            peer_list_pretty
            ;;
        14)
            menu_remove_peer
            ;;
        15)
            usage_cli
            ;;
        16)
            free_ram
            ;;
        0)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}[!] Invalid option.${NC}"
            ;;
    esac
}

check_root
# Non-interactive CLI: gre.sh setup-iran|setup-foreign with flags.
# The setup_*_noninteractive + _setup_foreign_full functions above are the
# SINGLE source of truth — the menu and this CLI run the exact same steps.
usage_cli() {
    cat <<EOF
Usage: sudo bash gre.sh <command> [flags]

  gre.sh                                    # interactive menu
  gre.sh setup-iran    --local-pub IP --remote-pub IP [--frp-port N] [--local-gre IP] [--peer-gre IP] [--token T] [--force]
  gre.sh setup-foreign --local-pub IP --remote-pub IP [--frp-port N] --token T --ports "443, 2083" [--local-gre IP] [--peer-gre IP] [--force]
  gre.sh status | remove-tunnel [--force]
  gre.sh uninstall [--force]                # FULL wipe: tunnel + tuning + RAM tweaks
  gre.sh add-peer --local-pub IP --remote-pub IP --frp-port N --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL]
  gre.sh remove-peer --id N [--force] | peer-list | peer-token --id N
  gre.sh logs | restart
  gre.sh optimize | restore | tune-status
  gre.sh free-ram                           # cap journald + drop cache + 1GB swap
  gre.sh update                             # pull latest gre.sh
EOF
}

cli_setup_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="7000" LOCAL_GRE="$IRAN_GRE_IP" PEER_GRE="$FOREIGN_GRE_IP" TOKEN="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
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
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="7000" LOCAL_GRE="$FOREIGN_GRE_IP" PEER_GRE="$IRAN_GRE_IP" TOKEN="" PORTS="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] Unknown flag: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] Invalid peer GRE IP: '$PEER_GRE'${NC}"; return 1; }
    [[ -n "$TOKEN" ]] || { echo -e "${RED}[!] --token is required (copy it from the Iran side).${NC}"; return 1; }
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do
        is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"
    done
    CLEANED=$(echo "$CLEANED" | xargs)
    [[ -n "$CLEANED" ]] || { echo -e "${RED}[!] --ports needs at least one valid port (e.g. \"443, 2083\").${NC}"; return 1; }
    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] Tunnel already exists — pass --force to overwrite.${NC}"
        return 1
    fi
    setup_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$CLEANED"
}

if [[ $# -gt 0 ]]; then
    check_root
    case "$1" in
        setup-iran) shift; cli_setup_iran "$@" ;;
        setup-foreign) shift; cli_setup_foreign "$@" ;;
        add-peer) shift; cli_add_peer "$@" ;;
        remove-peer) shift; cli_remove_peer "$@" ;;
        peer-list) peer_list ;;
        logs) show_logs ;;
        restart) restart_all ;;
        peer-token)
            shift; ID=""
            while [[ $# -gt 0 ]]; do case "$1" in --id) ID="$2"; shift 2 ;; *) shift ;; esac; done
            peer_token "$ID" ;;
        status) check_status ;;
        optimize) tune_apply ;;
        restore) tune_restore ;;
        tune-status) tune_status ;;
        free-ram|optimize-ram) free_ram ;;
        remove-tunnel)
            if [[ "${2:-}" == "--force" ]]; then remove_tunnel_force; else remove_tunnel; fi ;;
        uninstall)
            if [[ "${2:-}" == "--force" ]]; then uninstall_all_force; else uninstall_all; fi ;;
        update) update_all ;;
        -h|--help|help) usage_cli ;;
        *) echo -e "${RED}[!] Unknown command: $1${NC}"; usage_cli; exit 1 ;;
    esac
    exit $?
fi

# Interactive mode: keep showing the menu after every action instead of
# exiting back to the shell after just one selection (that early exit was
# the "thrown back out to Linux" bug — main_menu used to be called once).
while true; do
    main_menu
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
    echo ""
done
