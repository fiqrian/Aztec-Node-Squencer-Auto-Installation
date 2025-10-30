#!/usr/bin/env bash
# Aztec Network Node Sequencer & RPC (Docker)
# Manager v5.2.1 – Reth build
# Created by 0xfix

# run with: sudo bash aztec_node_manager_v5.2.1_reth.sh

# ------------------------------------------
# GLOBALS
# ------------------------------------------
set -eo pipefail

AZTEC_IMAGE="aztecprotocol/aztec:latest"
AZTEC_CONTAINER="aztec-sequencer"

AZTEC_DIR="${HOME}/aztec"
AZTEC_ENV="${AZTEC_DIR}/.env"
AZTEC_COMPOSE="${AZTEC_DIR}/docker-compose.yml"
AZTEC_DATA_DIR="${HOME}/.aztec/testnet/data"

ETH_DIR="${HOME}/ethereum"
ETH_EXEC_DIR="${ETH_DIR}/execution"
ETH_CONS_DIR="${ETH_DIR}/consensus"
ETH_JWT="${ETH_DIR}/jwt.hex"
ETH_COMPOSE="${ETH_DIR}/docker-compose.yml"

LOG="/tmp/aztec_node_manager.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ------------------------------------------
# UTIL
# ------------------------------------------
header() {
  clear
  printf "%s\n" "======================================================"
  printf "%s\n" "      Aztec Network Node Sequencer & RPC (Docker)      "
  printf "%s\n" "                 Created by 0xfix                      "
  printf "%s\n" "======================================================"
}

pause() {
  read -rp "Press Enter to return to the main menu..." _
}

need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Must be run as root (sudo).${NC}"
    exit 1
  fi
}

draw_bar() {
  local p=$1
  local w=$2
  local filled=$(( p * w / 100 ))
  printf "["
  for ((i=0; i<filled; i++)); do printf "█"; done
  for ((i=filled; i<w; i++)); do printf "░"; done
  printf "] %3d%%" "$p"
}

run_cmd_with_bar() {
  local desc="$1"
  shift
  local cmd="$*"
  echo -e "${CYAN}${desc}${NC}"
  echo "[$(date '+%F %T')] $desc :: $cmd" >> "$LOG"
  bash -c "$cmd" >>"$LOG" 2>&1 &
  local pid=$!
  local width=42
  local percent=0
  while kill -0 "$pid" 2>/dev/null; do
    percent=$(( percent + 2 ))
    [ "$percent" -gt 99 ] && percent=99
    printf "\r"
    draw_bar "$percent" "$width"
    sleep 0.2
  done
  wait "$pid"
  local rc=$?
  printf "\r"
  draw_bar 100 "$width"
  if [ $rc -eq 0 ]; then
    printf "  %b\n" "${GREEN}OK${NC}"
  else
    printf "  %b\n" "${RED}FAIL (see $LOG)${NC}"
  fi
  return $rc
}

quick_bar() {
  local msg="$1"
  local dur="${2:-2}"
  echo -e "${CYAN}${msg}${NC}"
  local width=42
  local steps=$(( dur * 5 ))
  local i
  for ((i=0; i<=steps; i++)); do
    local p=$(( i * 100 / steps ))
    printf "\r"
    draw_bar "$p" "$width"
    sleep 0.2
  done
  printf "  %b\n" "${GREEN}OK${NC}"
}

# ------------------------------------------
# APT / DOCKER / UFW
# ------------------------------------------
pkg_install_base() {
  run_cmd_with_bar "Updating packages" "apt-get update -y && apt-get upgrade -y"
  run_cmd_with_bar "Installing base packages" "apt-get install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ufw ca-certificates gnupg lsb-release dnsutils openssl"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    quick_bar "Docker already installed (skip)" 1
  else
    run_cmd_with_bar "Setting up Docker repo" "
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list && \
      apt-get update -y"
    run_cmd_with_bar "Installing Docker" "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    run_cmd_with_bar "Enable docker" "systemctl enable --now docker"
  fi
}

# check if specific port is allowed in ufw
is_ufw_port_allowed() {
  local spec="$1"     # 40400/tcp
  ufw status | tr -s ' ' | grep -E -i "^[[:space:]]*${spec}[[:space:]]+ALLOW" >/dev/null 2>&1
}

# check if port is listening
is_listening() {
  local port="$1"
  local proto="$2"
  if [ "$proto" = "tcp" ]; then
    ss -lnt | grep -q ":$port "
  else
    ss -lnu | grep -q ":$port "
  fi
}

ensure_ufw_seq() {
  run_cmd_with_bar "Adding UFW rules for Sequencer" "
    apt-get install -y ufw >/dev/null 2>&1 || true
    ufw allow 22
    ufw allow ssh
    ufw allow 40400/tcp
    ufw allow 40400/udp
    ufw allow 8080/tcp
    ufw allow 8880/tcp
    ufw --force enable
    ufw reload"
}

ensure_ufw_rpc() {
  run_cmd_with_bar "Adding UFW rules for RPC" "
    apt-get install -y ufw >/dev/null 2>&1 || true
    ufw allow 30303/tcp
    ufw allow 30303/udp
    ufw allow 8545/tcp
    ufw allow 8551/tcp
    ufw allow 4000/tcp
    ufw allow 3500/tcp
    ufw reload"
}

# ------------------------------------------
# AZTEC CLI
# ------------------------------------------
ensure_aztec_cli() {
  if command -v aztec >/dev/null 2>&1; then
    quick_bar "aztec CLI already installed" 1
  else
    run_cmd_with_bar "Installing aztec CLI" "bash -i <(curl -s https://install.aztec.network)"
    export PATH="$HOME/.aztec/bin:$PATH"
  fi
}

# ------------------------------------------
# ENV HANDLING
# ------------------------------------------
write_aztec_env() {
  mkdir -p "$AZTEC_DIR"
  if [ -f "$AZTEC_ENV" ]; then
    quick_bar "ENV exists: $AZTEC_ENV (skip)" 1
    return
  fi
  echo -e "${YELLOW}Enter values for .env (leave blank to fill later).${NC}"
  read -rp "ETHEREUM_RPC_URL (Sepolia RPC): " ETH_RPC
  read -rp "CONSENSUS_BEACON_URL (Beacon RPC): " BEACON_RPC
  read -rp "VALIDATOR_PRIVATE_KEY (0x...): " VALKEY
  read -rp "COINBASE (wallet 0x...): " COINBASE
  read -rp "P2P_IP (public IP): " P2P_IP
  read -rp "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS [0xDCd9DdeAbEF70108cE02576df1eB333c4244C666]: " GPP
  [ -z "$GPP" ] && GPP="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"

  umask 077
  cat > "$AZTEC_ENV" <<EOF
ETHEREUM_RPC_URL=$ETH_RPC
CONSENSUS_BEACON_URL=$BEACON_RPC
VALIDATOR_PRIVATE_KEY=$VALKEY
COINBASE=$COINBASE
P2P_IP=$P2P_IP
LOG_LEVEL=debug
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=$GPP
EOF
  quick_bar "Wrote $AZTEC_ENV" 1
}

reconfigure_env() {
  mkdir -p "$AZTEC_DIR"
  if [ ! -f "$AZTEC_ENV" ]; then
    echo "ENV not found. Creating a new one..."
    write_aztec_env
    return
  fi

  local ETH_RPC BEACON_RPC VALKEY COINBASE P2P LOGLEVEL GPP in
  ETH_RPC=$(grep '^ETHEREUM_RPC_URL=' "$AZTEC_ENV" | cut -d= -f2-)
  BEACON_RPC=$(grep '^CONSENSUS_BEACON_URL=' "$AZTEC_ENV" | cut -d= -f2-)
  VALKEY=$(grep '^VALIDATOR_PRIVATE_KEY=' "$AZTEC_ENV" | cut -d= -f2-)
  COINBASE=$(grep '^COINBASE=' "$AZTEC_ENV" | cut -d= -f2-)
  P2P=$(grep '^P2P_IP=' "$AZTEC_ENV" | cut -d= -f2-)
  LOGLEVEL=$(grep '^LOG_LEVEL=' "$AZTEC_ENV" | cut -d= -f2-)
  GPP=$(grep '^GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=' "$AZTEC_ENV" | cut -d= -f2-)

  echo "Leave blank to keep current."
  read -rp "ETHEREUM_RPC_URL [$ETH_RPC]: " in; [ -n "$in" ] && ETH_RPC="$in"
  read -rp "CONSENSUS_BEACON_URL [$BEACON_RPC]: " in; [ -n "$in" ] && BEACON_RPC="$in"
  read -rp "VALIDATOR_PRIVATE_KEY [$VALKEY]: " in; [ -n "$in" ] && VALKEY="$in"
  read -rp "COINBASE [$COINBASE]: " in; [ -n "$in" ] && COINBASE="$in"
  read -rp "P2P_IP [$P2P]: " in; [ -n "$in" ] && P2P="$in"
  read -rp "LOG_LEVEL [${LOGLEVEL:-debug}]: " in; [ -n "$in" ] && LOGLEVEL="$in"
  read -rp "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS [${GPP:-0xDCd9DdeAbEF70108cE02576df1eB333c4244C666}]: " in; [ -n "$in" ] && GPP="$in"

  umask 077
  cat > "$AZTEC_ENV" <<EOF
ETHEREUM_RPC_URL=$ETH_RPC
CONSENSUS_BEACON_URL=$BEACON_RPC
VALIDATOR_PRIVATE_KEY=$VALKEY
COINBASE=$COINBASE
P2P_IP=$P2P
LOG_LEVEL=${LOGLEVEL:-debug}
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=${GPP:-0xDCd9DdeAbEF70108cE02576df1eB333c4244C666}
EOF
  quick_bar "Saved $AZTEC_ENV" 1
}

menu_view_reconfigure_env() {
  header
  echo "======================================================"
  echo "                    View .env"
  echo "======================================================"
  if [ -f "$AZTEC_ENV" ]; then
    cat "$AZTEC_ENV"
  else
    echo "File $AZTEC_ENV not found."
  fi
  echo
  read -rp "➡ Do you want to edit values? (y/N): " ans
  if [ "${ans,,}" = "y" ]; then
    reconfigure_env
  fi
  pause
}

# ------------------------------------------
# AZTEC COMPOSE
# ------------------------------------------
write_aztec_compose() {
  cat > "$AZTEC_COMPOSE" <<'YAML'
services:
  aztec-node:
    container_name: aztec-sequencer
    network_mode: host
    image: aztecprotocol/aztec:latest
    restart: unless-stopped
    environment:
      ETHEREUM_HOSTS: ${ETHEREUM_RPC_URL}
      L1_CONSENSUS_HOST_URLS: ${CONSENSUS_BEACON_URL}
      DATA_DIRECTORY: /data
      VALIDATOR_PRIVATE_KEY: ${VALIDATOR_PRIVATE_KEY}
      COINBASE: ${COINBASE}
      P2P_IP: ${P2P_IP}
      LOG_LEVEL: ${LOG_LEVEL:-debug}
      GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS: ${GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS}
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js
      start --network testnet --node --archiver --sequencer'
    ports:
      - 40400:40400/tcp
      - 40400:40400/udp
      - 8080:8080
      - 8880:8880
    volumes:
      - ${HOME}/.aztec/testnet/data/:/data
YAML
  quick_bar "Wrote $AZTEC_COMPOSE" 1
}

run_aztec_compose() {
  (cd "$AZTEC_DIR" && run_cmd_with_bar "Starting Aztec Sequencer" "docker compose up -d")
}

# ------------------------------------------
# RETH + PRYSM COMPOSE
# ------------------------------------------
ensure_rpc_dirs() {
  run_cmd_with_bar "Creating RPC directories" "mkdir -p '$ETH_EXEC_DIR' '$ETH_CONS_DIR'"
  if [ ! -f "$ETH_JWT" ]; then
    run_cmd_with_bar "Generating JWT secret" "openssl rand -hex 32 > '$ETH_JWT'"
  else
    quick_bar "JWT exists (skip)" 1
  fi
}

write_rpc_compose() {
  cat > "$ETH_COMPOSE" <<'YAML'
services:
  reth:
    image: ghcr.io/paradigmxyz/reth:latest
    container_name: reth
    network_mode: host
    restart: unless-stopped
    ports:
      - 30303:30303
      - 30303:30303/udp
      - 8545:8545
      - 8551:8551
    volumes:
      - ${HOME}/ethereum/execution:/data
      - ${HOME}/ethereum/jwt.hex:/data/jwt.hex
    command:
      - node
      - --chain=sepolia
      - --datadir=/data
      - --http
      - --http.addr=0.0.0.0
      - --http.port=8545
      - --http.api=eth,net,web3
      - --authrpc.addr=0.0.0.0
      - --authrpc.port=8551
      - --authrpc.jwtsecret=/data/jwt.hex
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  prysm:
    image: gcr.io/offchainlabs/prysm/beacon-chain:v6.1.2
    container_name: prysm
    network_mode: host
    restart: unless-stopped
    depends_on:
      - reth
    ports:
      - 4000:4000
      - 3500:3500
    volumes:
      - ${HOME}/ethereum/consensus:/data
      - ${HOME}/ethereum/jwt.hex:/data/jwt.hex
    command:
      - --sepolia
      - --datadir=/data
      - --disable-monitoring
      - --rpc-host=0.0.0.0
      - --execution-endpoint=http://127.0.0.1:8551
      - --jwt-secret=/data/jwt.hex
      - --rpc-port=4000
      - --grpc-gateway-corsdomain=*
      - --grpc-gateway-host=0.0.0.0
      - --grpc-gateway-port=3500
      - --min-sync-peers=3
      - --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io
      - --genesis-beacon-api-url=https://checkpoint-sync.sepolia.ethpandaops.io
      - --subscribe-all-data-subnets
      - --accept-terms-of-use
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
YAML
  quick_bar "Wrote $ETH_COMPOSE" 1
}

run_rpc_compose() {
  (cd "$ETH_DIR" && run_cmd_with_bar "Starting RPC (Reth + Prysm)" "docker compose up -d")
}

# ------------------------------------------
# TABLE (for logs / stop / restart)
# ------------------------------------------
print_containers_table() {
  local s1 s2 s3
  s1=$(docker ps -a --filter "name=^/${AZTEC_CONTAINER}$" --format "{{.Status}}")
  s2=$(docker ps -a --filter "name=^/prysm$" --format "{{.Status}}")
  s3=$(docker ps -a --filter "name=^/reth$" --format "{{.Status}}")
  [ -z "$s1" ] && s1="-"
  [ -z "$s2" ] && s2="-"
  [ -z "$s3" ] && s3="-"
  echo "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "No." "Container Name" "Status"
  echo "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "1" "Aztec Sequencer" "$s1"
  printf "%-6s | %-18s | %s\n" "2" "Beacon-chain" "$s2"
  printf "%-6s | %-18s | %s\n" "3" "Reth" "$s3"
  echo "----------------------------------------------------------------"
}

menu_logs() {
  while true; do
    header
    echo "                  Check Logs (Node & RPC)"
    echo "======================================================"
    print_containers_table
    echo "Choose (1-3) to tail logs, x to exit :"
    read -rp "> " ch
    case "$ch" in
      1) docker logs -f --since 10m "$AZTEC_CONTAINER" ;;
      2) docker logs -f --since 10m prysm ;;
      3) docker logs -f --since 10m reth ;;
      x|X) break ;;
      *) echo "Unknown choice"; sleep 1 ;;
    esac
  done
}

restart_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
    docker restart "$name" >/dev/null 2>&1 && echo "Restarted $name." || echo "Failed to restart $name."
  else
    echo "$name not found."
  fi
}

menu_restart() {
  header
  echo "                     Restart Node"
  echo "======================================================"
  echo "1) Restart Node & RPC"
  echo "2) Restart Node"
  echo "3) Restart RPC"
  echo "4) Exit"
  echo "======================================================"
  read -rp "Choose (1-4): " ch
  case "$ch" in
    1) restart_container "$AZTEC_CONTAINER"; restart_container prysm; restart_container reth; pause ;;
    2) restart_container "$AZTEC_CONTAINER"; pause ;;
    3) restart_container prysm; restart_container reth; pause ;;
    4) : ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
}

menu_stop() {
  header
  echo "                    Stop Node & RPC"
  echo "======================================================"
  print_containers_table
  read -rp "Choose Option (1-3) or x to exit: " ch
  case "$ch" in
    1) docker stop "$AZTEC_CONTAINER" ;;
    2) docker stop prysm ;;
    3) docker stop reth ;;
    x|X) : ;;
    *) echo "Unknown choice" ;;
  esac
  pause
}

# ------------------------------------------
# PERFORMANCE (simple)
# ------------------------------------------
get_cpu_pct() {
  local idle
  idle=$(LC_ALL=C top -bn1 | awk -F',' '/Cpu\(s\)/{print $4}' | awk '{print int($1)}')
  [ -z "$idle" ] && echo 0 || echo $((100 - idle))
}
get_mem_pct() {
  local t u
  t=$(free -m | awk '/^Mem:/{print $2}')
  u=$(free -m | awk '/^Mem:/{print $3}')
  [ -z "$t" ] && echo 0 || echo $(( u * 100 / t ))
}
get_disk_pct() {
  df -P / | awk 'NR==2{gsub("%","",$5); print $5}'
}
menu_perf() {
  while true; do
    clear
    echo "===================== Node Performance ====================="
    local cpu mem disk
    cpu=$(get_cpu_pct)
    mem=$(get_mem_pct)
    disk=$(get_disk_pct)
    printf "CPU Usage    : %s%%\n" "$cpu"
    printf "Memory Usage : %s%%\n" "$mem"
    printf "Disk Usage   : %s%%\n" "$disk"
    echo "------------------------------------------------------------"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo "------------------------------------------------------------"
    echo "Press q to quit..."
    read -rsn1 -t 2 k || true
    [ "$k" = "q" ] && break
  done
}

# ------------------------------------------
# CHECK SYNC (RETH + PRYSM)
# ------------------------------------------
hex_to_dec() {
  local h="${1#0x}"
  printf "%d\n" "0x$h"
}

check_sync_rpc() {
  header
  echo "                 Check Sync Rpc"
  echo "======================================================"
  # Reth
  local el_sync el_status bn_hex bn_dec
  el_sync=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
  if [ "$el_sync" = "false" ]; then el_status="Sync ✅"; else el_status="Not Sync ❌"; fi
  bn_hex=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
  if [ -n "$bn_hex" ] && [ "$bn_hex" != "null" ]; then
    bn_dec=$(hex_to_dec "$bn_hex")
  else
    bn_dec="-"
  fi

  # Prysm
  local pj ps ph
  pj=$(curl -s --max-time 5 http://127.0.0.1:3500/eth/v1/node/syncing)
  ps=$(echo "$pj" | jq -r '.data.is_syncing' 2>/dev/null || echo "null")
  ph=$(echo "$pj" | jq -r '.data.head_slot' 2>/dev/null || echo "-")
  local pr_status
  if [ "$ps" = "false" ]; then pr_status="Sync ✅"
  elif [ "$ps" = "true" ]; then pr_status="Not Sync ❌"
  else pr_status="Unknown"
  fi

  echo "Reth"
  echo "  Chain Block: $bn_dec"
  echo "  Status     : $el_status"
  echo
  echo "Prysm"
  echo "  Head Slot  : $ph"
  echo "  Status     : $pr_status"
  echo "======================================================"
  pause
}

# ------------------------------------------
# VERSION CHECKS
# ------------------------------------------
check_version_node() {
  header
  echo "             Aztec CLI Version"
  echo "======================================================"
  if command -v aztec >/dev/null 2>&1; then
    aztec --version
  else
    echo "aztec not installed."
  fi
  echo "======================================================"
  pause
}

check_version_reth() {
  header
  echo "             RPC Reth Version"
  echo "======================================================"
  if docker ps -a --format '{{.Names}}' | grep -Fxq reth; then
    docker exec reth reth --version || true
  else
    echo "reth container not found."
  fi
  echo "======================================================"
  pause
}

check_version_prysm() {
  header
  echo "             RPC Prysm Version"
  echo "======================================================"
  if docker ps -a --format '{{.Names}}' | grep -Fxq prysm; then
    docker exec prysm /beacon-chain --version || true
  else
    echo "prysm container not found."
  fi
  echo "======================================================"
  pause
}

menu_check_versions() {
  while true; do
    header
    echo "            Check Version Node & RPC"
    echo "======================================================"
    echo "1) Check Version Node"
    echo "2) Check Version RPC Reth"
    echo "3) Check Version RPC Prysm"
    echo "4) Back"
    echo "======================================================"
    read -rp "Choose (1-4): " c
    case "$c" in
      1) check_version_node ;;
      2) check_version_reth ;;
      3) check_version_prysm ;;
      4) break ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
  done
}

# ------------------------------------------
# TOOLS MENU
# ------------------------------------------
check_ports_table() {
  echo "----------------------------------------------------------------"
  printf "%-10s | %-6s | %-10s | %-6s\n" "Port" "Proto" "Listen" "UFW"
  echo "----------------------------------------------------------------"
  for p in 22 40400 8080 8880 30303 8545 8551 4000 3500; do
    for proto in tcp udp; do
      [ "$p" -eq 22 ] && [ "$proto" = "udp" ] && continue
      local listen="No"
      local ufw="DENY"
      if is_listening "$p" "$proto"; then listen="Yes"; fi
      if is_ufw_port_allowed "$p/$proto"; then ufw="ALLOW"; fi
      printf "%-10s | %-6s | %-10s | %-6s\n" "$p" "$proto" "$listen" "$ufw"
    done
  done
  echo "----------------------------------------------------------------"
}

check_peer_id_external() {
  local tmp="/tmp/Port_cheaker.sh"
  run_cmd_with_bar "Download Peer ID checker" "curl -fsSL -o '$tmp' 'https://raw.githubusercontent.com/SpeedoWeb3/Testing/refs/heads/main/Port_cheaker.sh' && chmod +x '$tmp'"
  bash "$tmp" || true
}

menu_tools_submenu() {
  while true; do
    header
    echo "                       Check Tools"
    echo "======================================================"
    if command -v docker >/dev/null 2>&1; then
      echo "✅ Docker."
    else
      echo "❌ Docker not installed."
    fi
    # quick ports status
    local ok=0
    for spec in "22/tcp" "40400/tcp" "40400/udp" "8080/tcp" "8880/tcp"; do
      local port=${spec%/*}
      local proto=${spec#*/}
      if is_ufw_port_allowed "$spec" || is_listening "$port" "$proto"; then
        ok=$((ok+1))
      fi
    done
    if [ "$ok" -ge 4 ]; then
      echo "✅ Required ports look open (22, 40400, 8080, 8880)."
    else
      echo "⚠️ Some ports are not open (22, 40400, 8080, 8880)."
    fi
    echo "======================================================"
    echo "1) Check Ports"
    echo "2) Check Peer ID"
    echo "3) Check Logs (Node & RPC)"
    echo "4) Check Sync RPC"
    echo "5) Check Version Node & RPC"
    echo "6) Node Performance"
    echo "7) Back to Main Menu"
    echo "======================================================"
    read -rp "Choose (1-7): " c
    case "$c" in
      1) check_ports_table; pause ;;
      2) check_peer_id_external; pause ;;
      3) menu_logs ;;
      4) check_sync_rpc ;;
      5) menu_check_versions ;;
      6) menu_perf ;;
      7) break ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
  done
}

# ------------------------------------------
# DELETE MENU
# ------------------------------------------
delete_node() {
  run_cmd_with_bar "Stopping Aztec container" "docker rm -f '$AZTEC_CONTAINER' 2>/dev/null || true"
  if [ -f "$AZTEC_COMPOSE" ]; then
    (cd "$AZTEC_DIR" && run_cmd_with_bar "Compose down Aztec" "docker compose down -v || true")
  fi
  run_cmd_with_bar "Remove Aztec data dir" "rm -rf '$AZTEC_DATA_DIR' || true"
  run_cmd_with_bar "Remove Aztec project dir" "rm -rf '$AZTEC_DIR' || true"
}

delete_rpc() {
  run_cmd_with_bar "Stopping reth/prysm" "docker rm -f reth prysm 2>/dev/null || true"
  if [ -f "$ETH_COMPOSE" ]; then
    (cd "$ETH_DIR" && run_cmd_with_bar "Compose down RPC" "docker compose down -v || true")
  fi
  run_cmd_with_bar "Remove ethereum data" "rm -rf '$ETH_EXEC_DIR' '$ETH_CONS_DIR' '$ETH_JWT' || true"
  run_cmd_with_bar "Remove ethereum dir" "rm -rf '$ETH_DIR' || true"
}

menu_delete() {
  header
  echo "                     Delete Node & RPC"
  echo "======================================================"
  echo "1) Delete Node & RPC"
  echo "2) Delete Node"
  echo "3) Delete RPC"
  echo "4) Exit"
  echo "======================================================"
  read -rp "Choose (1-4): " c
  case "$c" in
    1) read -rp "Type YES to delete BOTH: " x; [ "$x" = "YES" ] || { echo "Cancelled."; pause; return; }
       delete_node; delete_rpc; pause ;;
    2) read -rp "Type YES to delete NODE: " x; [ "$x" = "YES" ] || { echo "Cancelled."; pause; return; }
       delete_node; pause ;;
    3) read -rp "Type YES to delete RPC: " x; [ "$x" = "YES" ] || { echo "Cancelled."; pause; return; }
       delete_rpc; pause ;;
    4) : ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
}

# ------------------------------------------
# RUN / INSTALL MENUS
# ------------------------------------------
menu_run_node() {
  header
  echo "                      Run Node"
  echo "======================================================"
  read -rp "Press Enter to start..." _
  : > "$LOG"
  pkg_install_base
  ensure_docker
  ensure_ufw_seq
  ensure_aztec_cli
  write_aztec_env
  write_aztec_compose
  run_aztec_compose
  pause
}

menu_install_rpc() {
  header
  echo "                      Install RPC (Reth + Prysm)"
  echo "======================================================"
  read -rp "Press Enter to start..." _
  : > "$LOG"
  pkg_install_base
  ensure_docker
  ensure_ufw_rpc
  ensure_rpc_dirs
  write_rpc_compose
  run_rpc_compose
  pause
}

menu_update_node() {
  header
  echo "                   Update Node & RPC"
  echo "======================================================"
  echo "1) Update Node"
  echo "2) Update RPC Reth"
  echo "3) Update RPC Prysm"
  echo "4) Exit"
  echo "======================================================"
  read -rp "Choose (1-4): " c
  case "$c" in
    1) run_cmd_with_bar "Pull Aztec" "docker pull $AZTEC_IMAGE"
       (cd "$AZTEC_DIR" && run_cmd_with_bar "Recreate Aztec" "docker compose up -d --pull always --force-recreate")
       pause ;;
    2) run_cmd_with_bar "Pull Reth" "docker pull ghcr.io/paradigmxyz/reth:latest"
       (cd "$ETH_DIR" && run_cmd_with_bar "Recreate reth" "docker compose up -d --pull always --force-recreate reth")
       pause ;;
    3) run_cmd_with_bar "Pull Prysm" "docker pull gcr.io/prysmaticlabs/prysm/beacon-chain:stable"
       (cd "$ETH_DIR" && run_cmd_with_bar "Recreate prysm" "docker compose up -d --pull always --force-recreate prysm")
       pause ;;
    4) : ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
}
# ------------------------------------------
# RUN / INSTALL BUNDLES MENUS
# ------------------------------------------
menu_install_bundle() {
  header
  echo "               Install & Run Node + RPC (Bundle)"
  echo "======================================================"
  read -rp "Press Enter to start..." _
  : > "$LOG"

  # 1. base deps
  pkg_install_base

  # 2. docker
  ensure_docker

  # 3. UFW untuk dua-duanya
  ensure_ufw_seq
  ensure_ufw_rpc

  # 4. Aztec .env + compose + run
  ensure_aztec_cli
  write_aztec_env
  write_aztec_compose
  run_aztec_compose

  # 5. RPC dirs + compose + run (Reth + Prysm)
  ensure_rpc_dirs
  write_rpc_compose
  run_rpc_compose

  echo "======================================================"
  echo "Bundle install finished (Node + RPC are up)."
  echo "Check: docker ps"
  echo "======================================================"
  pause
}


# ------------------------------------------
# MAIN
# ------------------------------------------
need_root

while true; do
  header
  echo "        MENU OPERATION SEQUENCER NODE"
  echo "======================================================"
  echo "1. Check Tools"
  echo "2. Install Bundle (Node + RPC)"
  echo "3. Run Node"
  echo "4. Run RPC"
  echo "5. View & Reconfigure .env"
  echo "6. Update Node & RPC"
  echo "7. Restart Node & RPC"
  echo "8. Stop Node & RPC"
  echo "9. Delete Node & RPC"
  echo "10.Exit"
  echo "======================================================"
  read -rp "Choose Option (1-10): " opt
  case "$opt" in
    1) menu_tools_submenu ;;
    2) menu_install_bundle ;;
    3) menu_run_node ;;
    4) menu_install_rpc ;;
    5) menu_view_reconfigure_env ;;
    6) menu_update_node ;;
    7) menu_restart ;;
    8) menu_stop ;;
    9) menu_delete ;;
    10) echo "Bye!"; exit 0 ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
done
