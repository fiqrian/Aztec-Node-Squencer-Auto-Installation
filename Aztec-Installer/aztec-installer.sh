#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec /usr/bin/env bash "$0" "$@"

# ======================================================
#  Aztec Network Node Sequencer & RPC (Docker) - Manager v5.2.1-revB
#  Created by 0xfix
#  Language: English (US)
#  Target: Ubuntu 22.04/24.04 (run as root with BASH)
# ======================================================
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

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

header() {
  clear
  printf "%s\n" "======================================================"
  printf "%s\n" "      Aztec Network Node Sequencer & RPC (Docker)      "
  printf "%s\n" "                 Created by 0xfix                      "
  printf "%s\n" "======================================================"
}

pause() { read -rp "Press Enter to return to the main menu..."; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must be run as root (sudo).${NC}"; exit 1
  fi
}

draw_bar() {
  local p=$1 w=$2; local filled=$(( p*w/100 ))
  printf "%s" "["
  for ((i=0;i<filled;i++));   do printf "%s" "█"; done
  for ((i=filled;i<w;i++));   do printf "%s" "░"; done
  printf "] %3d%%" "$p"
}

run_cmd_with_bar() {
  local desc="$1"; shift
  local cmd="$*"
  echo -e "${CYAN}${desc}${NC}"
  echo "[$(date '+%F %T')] $desc :: $cmd" >> "$LOG"
  bash -c "$cmd" >>"$LOG" 2>&1 &
  local pid=$!
  local width=42
  local percent=0
  while kill -0 "$pid" 2>/dev/null; do
    percent=$(( (percent+2) ))
    (( percent > 99 )) && percent=99
    printf "\r"; draw_bar "$percent" "$width"
    sleep 0.2
  done
  wait "$pid"; local rc=$?
  printf "\r"
  draw_bar 100 "$width"
  if (( rc == 0 )); then
    printf "  %b\n" "${GREEN}OK${NC}"
  else
    printf "  %b\n" "${RED}FAIL (see log: $LOG)${NC}"
    return $rc
  fi
}

quick_bar() {
  local msg="$1"; local dur="${2:-2}"
  echo -e "${CYAN}${msg}${NC}"
  local width=42
  local steps=$(( dur * 5 ))
  for ((i=0;i<=steps;i++)); do
    local p=$(( i*100/steps ))
    printf "\r"; draw_bar "$p" "$width"
    sleep 0.2
  done
  printf "  %b\n" "${GREEN}OK${NC}"
}

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
      echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list && \
      apt-get update -y"
    run_cmd_with_bar "Installing Docker Engine & Compose" "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    run_cmd_with_bar "Enable & start Docker" "systemctl enable --now docker"
  fi
}

# --- Port helpers (consider UFW + actual listeners) ---
is_ufw_port_allowed() {
  local needle="$1" # ex: 40400/tcp
  ufw status | tr -s ' ' | grep -E -i "^[[:space:]]*${needle}[[:space:]]+ALLOW" >/dev/null 2>&1
}
is_listening() {
  local port="$1" proto="$2"
  if [[ "$proto" == "tcp" ]]; then
    ss -lnt | awk -v p=":${port}" '$0 ~ p {found=1} END{exit found?0:1}'
  else
    ss -lnu | awk -v p=":${port}" '$0 ~ p {found=1} END{exit found?0:1}'
  fi
}

ensure_ufw_seq() {
  run_cmd_with_bar "Adding UFW rules for Sequencer" "
    apt-get install -y ufw >/dev/null 2>&1 || true; \
    ufw allow 22; ufw allow ssh; \
    ufw allow 40400/tcp; ufw allow 40400/udp; \
    ufw allow 8080/tcp; ufw allow 8880/tcp; \
    ufw --force enable; ufw reload"
}
ensure_ufw_rpc() {
  run_cmd_with_bar "Adding UFW rules for RPC" "
    apt-get install -y ufw >/dev/null 2>&1 || true; \
    ufw allow 30303/tcp; ufw allow 30303/udp; \
    ufw allow 8545/tcp; ufw allow 8546/tcp; ufw allow 8551/tcp; \
    ufw allow 4000/tcp; ufw allow 3500/tcp; \
    ufw reload"
}

ensure_aztec_cli() {
  if command -v aztec >/dev/null 2>&1; then
    quick_bar "aztec CLI already installed" 1
  else
    run_cmd_with_bar "Installing aztec CLI" "bash -i <(curl -s https://install.aztec.network)"
    export PATH="$HOME/.aztec/bin:$PATH"
    quick_bar "Validated aztec executable (added to PATH for this session)" 1
  fi
}

# ---------- .ENV creation/edit (guided only) ----------
write_aztec_env() {
  mkdir -p "${AZTEC_DIR}"
  if [[ -f "${AZTEC_ENV}" ]]; then
    quick_bar "ENV exists: ${AZTEC_ENV} (skip)" 1
    return
  fi
  echo -e "${YELLOW}Enter values for .env (leave blank to fill later).${NC}"
  read -rp "ETHEREUM_RPC_URL (Sepolia RPC): " ETH_RPC || true
  read -rp "CONSENSUS_BEACON_URL (Beacon RPC): " BEACON_RPC || true
  read -rp "VALIDATOR_PRIVATE_KEY (0x...): " VALKEY || true
  read -rp "COINBASE (wallet 0x...): " COINBASE || true
  read -rp "P2P_IP (public IP address): " P2P_IP || true
  read -rp "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS [0x9d8869d17af6b899aff1d93f23f863ff41ddc4fa]: " GPPADDR || true
  [[ -z "${GPPADDR:-}" ]] && GPPADDR="0x9d8869d17af6b899aff1d93f23f863ff41ddc4fa"
  umask 077
  cat > "${AZTEC_ENV}" <<EOF
ETHEREUM_RPC_URL=${ETH_RPC}
CONSENSUS_BEACON_URL=${BEACON_RPC}
VALIDATOR_PRIVATE_KEY=${VALKEY}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}
LOG_LEVEL=info
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=${GPPADDR}
EOF
  quick_bar "Wrote ${AZTEC_ENV}" 1
}

# Guided reconfigure (with the exact messages you asked)
reconfigure_env() {
  mkdir -p "${AZTEC_DIR}"
  if [[ ! -f "${AZTEC_ENV}" ]]; then
    echo "ENV not found. Creating a new one..."
    write_aztec_env
    return
  fi
  local ETH_RPC BEACON_RPC VALKEY COINBASE P2P LOGLEVEL GPPADDR in
  ETH_RPC=$(grep -E '^ETHEREUM_RPC_URL=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  BEACON_RPC=$(grep -E '^CONSENSUS_BEACON_URL=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  VALKEY=$(grep -E '^VALIDATOR_PRIVATE_KEY=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  COINBASE=$(grep -E '^COINBASE=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  P2P=$(grep -E '^P2P_IP=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  LOGLEVEL=$(grep -E '^LOG_LEVEL=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  GPPADDR=$(grep -E '^GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=' "${AZTEC_ENV}" 2>/dev/null | cut -d= -f2-)
  echo "Leave blank to keep current."
  read -rp "ETHEREUM_RPC_URL [${ETH_RPC}]: " in; [[ -n "${in:-}" ]] && ETH_RPC="$in"
  read -rp "CONSENSUS_BEACON_URL [${BEACON_RPC}]: " in; [[ -n "${in:-}" ]] && BEACON_RPC="$in"
  read -rp "VALIDATOR_PRIVATE_KEY [${VALKEY}]: " in; [[ -n "${in:-}" ]] && VALKEY="$in"
  read -rp "COINBASE [${COINBASE}]: " in; [[ -n "${in:-}" ]] && COINBASE="$in"
  read -rp "P2P_IP [${P2P}]: " in; [[ -n "${in:-}" ]] && P2P="$in"
  read -rp "LOG_LEVEL [${LOGLEVEL}]: " in; [[ -n "${in:-}" ]] && LOGLEVEL="$in"
  read -rp "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS [${GPPADDR:-0x9d8869d17af6b899aff1d93f23f863ff41ddc4fa}]: " in; [[ -n "${in:-}" ]] && GPPADDR="$in"
  umask 077
  cat > "${AZTEC_ENV}" <<EOF
ETHEREUM_RPC_URL=${ETH_RPC}
CONSENSUS_BEACON_URL=${BEACON_RPC}
VALIDATOR_PRIVATE_KEY=${VALKEY}
COINBASE=${COINBASE}
P2P_IP=${P2P}
LOG_LEVEL=${LOGLEVEL}
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=${GPPADDR:-0x9d8869d17af6b899aff1d93f23f863ff41ddc4fa}
EOF
  quick_bar "Saved ${AZTEC_ENV}" 1
}

print_env() {
  printf "%s\n" "======================================================"
  printf "%s\n" "                    View .env"
  printf "%s\n" "======================================================"
  if [[ -f "${AZTEC_ENV}" ]]; then
    cat "${AZTEC_ENV}"
  else
    echo "File ${AZTEC_ENV} not found."
  fi
  printf "\n"
}

menu_view_reconfigure_env() {
  header
  print_env
  read -rp "➡ Do you want to edit values? (y/N): " ans || true
  if [[ "${ans,,}" == "y" ]]; then
    reconfigure_env
  fi
  pause
}

# ---------- Compose writers ----------
write_aztec_compose() {
  cat > "${AZTEC_COMPOSE}" <<'YAML'
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
      LOG_LEVEL: ${LOG_LEVEL}
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
  quick_bar "Wrote ${AZTEC_COMPOSE}" 1
}
run_aztec_compose() {
  (cd "${AZTEC_DIR}" && run_cmd_with_bar "Starting Aztec Sequencer (docker compose up -d)" "docker compose up -d")
}

ensure_rpc_dirs() {
  run_cmd_with_bar "Creating RPC directories" "mkdir -p '${ETH_EXEC_DIR}' '${ETH_CONS_DIR}'"
  if [[ ! -f "${ETH_JWT}" ]]; then
    run_cmd_with_bar "Generating JWT secret" "openssl rand -hex 32 > '${ETH_JWT}'"
  else
    quick_bar "JWT secret exists (skip)" 1
  fi
}
write_rpc_compose() {
  cat > "${ETH_COMPOSE}" <<'YAML'
services:
  geth:
    image: ethereum/client-go:stable
    container_name: geth
    network_mode: host
    restart: unless-stopped
    ports:
      - 30303:30303
      - 30303:30303/udp
      - 8545:8545
      - 8546:8546
      - 8551:8551
    volumes:
      - ${HOME}/ethereum/execution:/data
      - ${HOME}/ethereum/jwt.hex:/data/jwt.hex
    command:
      - --sepolia
      - --http
      - --http.api=eth,net,web3
      - --http.addr=0.0.0.0
      - --authrpc.addr=0.0.0.0
      - --authrpc.vhosts=*
      - --authrpc.jwtsecret=/data/jwt.hex
      - --authrpc.port=8551
      - --syncmode=snap
      - --datadir=/data
    logging:
      driver: "json-file"
      options: { max-size: "10m", max-file: "3" }

  prysm:
    image: gcr.io/prysmaticlabs/prysm/beacon-chain:v6.1.2  
    container_name: prysm
    network_mode: host
    restart: unless-stopped
    depends_on: [geth]
    ports:
      - 4000:4000
      - 3500:3500
    volumes:
      - ${HOME}/ethereum/consensus:/data
      - ${HOME}/ethereum/jwt.hex:/data/jwt.hex
    command:
      - --sepolia
      - --accept-terms-of-use
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
      options: { max-size: "10m", max-file: "3" }
YAML
  quick_bar "Wrote ${ETH_COMPOSE}" 1
}
run_rpc_compose() { (cd "${ETH_DIR}" && run_cmd_with_bar "Starting RPC (docker compose up -d)" "docker compose up -d"); }

# ---------- Diagnostics, Logs, Restart, Stop ----------
print_containers_table() {
  local n1="Aztec Sequencer"; local id1="${AZTEC_CONTAINER}"; local s1
  local n2="Beacon-chain";    local id2="prysm";            local s2
  local n3="Sepolia";         local id3="geth";             local s3

  s1=$(docker ps -a --filter "name=^/${id1}$" --format "{{.Status}}")
  s2=$(docker ps -a --filter "name=^/${id2}$" --format "{{.Status}}")
  s3=$(docker ps -a --filter "name=^/${id3}$" --format "{{.Status}}")
  [[ -z "$s1" ]] && s1="-"; [[ -z "$s2" ]] && s2="-"; [[ -z "$s3" ]] && s3="-"

  printf "%s\n" "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "No." "Container Name" "Status"
  printf "%s\n" "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "1" "$n1" "$s1"
  printf "%-6s | %-18s | %s\n" "2" "$n2" "$s2"
  printf "%-6s | %-18s | %s\n" "3" "$n3" "$s3"
  printf "%s\n" "----------------------------------------------------------------"
}

menu_logs() {
  while true; do
    header
    echo -e "                  Check Logs (Node & RPC)"
    echo -e "======================================================"
    print_containers_table
    echo -e "Choose (1-3) to tail logs, x to exit :"
    read -rp "> " ch
    case "$ch" in
      1) docker logs -f --since 10m "${AZTEC_CONTAINER}" ;;
      2) docker logs -f --since 10m "prysm" ;;
      3) docker logs -f --since 10m "geth" ;;
      x|X) break ;;
      *) echo "Unknown choice" ; sleep 1 ;;
    esac
  done
}

restart_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
    docker restart "$name" >/dev/null 2>&1 \
      && echo -e "${GREEN}Restarted ${name}.${NC}" \
      || echo -e "${YELLOW}Failed to restart ${name}.${NC}"
  else
    echo -e "${YELLOW}${name} not found.${NC}"
  fi
}
menu_restart() {
  header
  echo -e "                       Restart Node"
  echo -e "======================================================"
  echo -e "1) Restart Node & RPC"
  echo -e "2) Restart Node"
  echo -e "3) Restart RPC"
  echo -e "4) Exit"
  echo -e "======================================================"
  read -rp "Choose (1-4): " ch
  case "$ch" in
    1) restart_container "${AZTEC_CONTAINER}"; restart_container "prysm"; restart_container "geth"; pause ;;
    2) restart_container "${AZTEC_CONTAINER}"; pause ;;
    3) restart_container "prysm"; restart_container "geth"; pause ;;
    4) : ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
}

menu_stop() {
  header
  echo -e "                    Stop Node & RPC"
  echo -e "======================================================"
  print_containers_table
  echo -e "Choose Option & input x to exit :"
  read -rp "> " ch
  case "$ch" in
    1) docker stop "${AZTEC_CONTAINER}" && echo -e "${GREEN}Stopped ${AZTEC_CONTAINER}.${NC}" ;;
    2) docker stop "prysm" && echo -e "${GREEN}Stopped prysm.${NC}" ;;
    3) docker stop "geth" && echo -e "${GREEN}Stopped geth.${NC}" ;;
    x|X) : ;;
    *) echo -e "${YELLOW}Unknown choice.${NC}" ;;
  esac
  pause
}

# ---------- Performance Dashboard ----------
repeat_char() { local n=$1 ch="$2"; for ((i=0;i<n;i++)); do printf "%s" "$ch"; done; }
bar() { local pct=$1 width=${2:-40}; local filled=$(( pct*width/100 )); printf "["; repeat_char "$filled" "█"; repeat_char "$((width-filled))" "░"; printf "] %3d%%" "$pct"; }
get_cpu_pct() { local idle; idle=$(LC_ALL=C top -bn1 | awk -F',' '/Cpu\(s\)/{print $4}' | awk '{print int($1)}'); [[ -z "$idle" ]] && echo 0 || echo $((100 - idle)); }
get_mem_pct() { local t u; t=$(free -m | awk '/^Mem:/{print $2}'); u=$(free -m | awk '/^Mem:/{print $3}'); [[ -z "$t" || "$t" -eq 0 ]] && echo 0 || echo $(( u * 100 / t )); }
get_disk_pct() { df -P / | awk 'NR==2{gsub("%","",$5); print $5}'; }
docker_stats_table() { command -v docker >/dev/null 2>&1 && docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || echo "Docker not available."; }
dashboard() {
  while true; do
    clear
    echo -e "===================== Node Performance ====================="
    local cpu mem disk; cpu=$(get_cpu_pct); mem=$(get_mem_pct); disk=$(get_disk_pct)
    printf "CPU Usage    : "; bar "${cpu}" 40; printf "\n"
    printf "Memory Usage : "; bar "${mem}" 40; printf "\n"
    printf "Disk Usage   : "; bar "${disk}" 40; printf "\n"
    echo "------------------------------------------------------------"
    echo "Docker Container Usage:"; docker_stats_table
    echo "------------------------------------------------------------"
    echo "Running Containers:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    echo "------------------------------------------------------------"
    echo "Press 'q' to quit, any other key to refresh..."
    read -rsn1 -t 2 key || true; [[ "${key:-}" == "q" ]] && break
  done
}
menu_perf() { header; echo -e "                   Node Performance"; echo -e "======================================================"; echo -e "(Press 'q' to quit live view)"; sleep 1; dashboard; }

# ---------- Check Sync RPC ----------
hex_to_dec() { local h="${1#0x}"; printf "%d\n" "0x${h}"; }
check_sync_rpc() {
  header
  echo -e "                 Check Sync Rpc"
  echo -e "======================================================"
  # Geth
  local geth_sync geth_block geth_status
  geth_sync=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
  if [[ "${geth_sync}" == "false" ]]; then geth_status="Sync ✅"; else geth_status="Not Sync ❌"; fi
  local geth_bn_hex geth_bn_dec
  geth_bn_hex=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
  if [[ -n "${geth_bn_hex}" && "${geth_bn_hex}" != "null" ]]; then geth_bn_dec=$(hex_to_dec "${geth_bn_hex}"); else geth_bn_dec="-"; fi

  # Prysm
  local prysm_json prysm_sync prysm_head prysm_status
  prysm_json=$(curl -s --max-time 5 http://127.0.0.1:3500/eth/v1/node/syncing)
  prysm_sync=$(echo "${prysm_json}" | jq -r '.data.is_syncing' 2>/dev/null || echo "null")
  prysm_head=$(echo "${prysm_json}" | jq -r '.data.head_slot' 2>/dev/null || echo "-")
  if [[ "${prysm_sync}" == "false" ]]; then prysm_status="Sync ✅"; elif [[ "${prysm_sync}" == "true" ]]; then prysm_status="Not Sync ❌"; else prysm_status="Unknown"; fi

  echo -e "✅ Sync.\n❌ Not Sync."
  echo -e "======================================================"
  echo -e "Geth"
  echo -e "🔗 Chain Block: ${geth_bn_dec}"
  printf "    %-10s: %s\n" "Status" "${geth_status}"
  echo
  echo -e "Prysm"
  echo -e "🔗 Chain Slot : ${prysm_head}"
  printf "    %-10s: %s\n" "Status" "${prysm_status}"
  echo -e "\n======================================================"
  pause
}

# ---------- Version checks ----------
check_version_node() {
  header
  echo -e "             Aztec CLI Version"
  echo -e "======================================================"
  if command -v aztec >/dev/null 2>&1; then
    aztec --version
  else
    echo "aztec CLI is not installed or not in PATH."
    echo "Run 'Run Node' to install the Aztec CLI first."
  fi
  echo -e "======================================================"
  pause
}
check_version_geth() {
  header; echo -e "             RPC Geth Version"
  echo -e "======================================================"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "geth"; then
    docker exec geth geth version | head -n 5 || true
  else
    echo "Container geth not found."
  fi
  echo -e "======================================================"; pause
}
check_version_prysm() {
  header; echo -e "             RPC Prysm Version"
  echo -e "======================================================"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "prysm"; then
    docker exec prysm /beacon-chain --version || true
  else
    echo "Container prysm not found."
  fi
  echo -e "======================================================"; pause
}
menu_check_versions() {
  while true; do
    header
    echo -e "            Check Version Node & RPC"
    echo -e "======================================================"
    echo -e "1) Check Version Node"
    echo -e "2) Check Version RPC Geth"
    echo -e "3) Check Version RPC Prysm"
    echo -e "4) Back to Main Menu"
    echo -e "======================================================"
    read -rp "Choose (1-4): " ch
    case "$ch" in
      1) check_version_node ;;
      2) check_version_geth ;;
      3) check_version_prysm ;;
      4) break ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- Tools Menu ----------
check_ports_table() {
  printf "%s\n" "----------------------------------------------------------------"
  printf "%-10s | %-10s | %-10s | %-8s | %-8s\n" "Port" "Proto" "Listen" "UFW" "Proc"
  printf "%s\n" "----------------------------------------------------------------"
  for port in 22 40400 8080 8880 30303 8545 8546 8551 4000 3500; do
    for proto in tcp udp; do
      local listen="No" ufw="DENY" proc="-"
      if is_listening "${port}" "${proto}"; then listen="Yes"; fi
      if is_ufw_port_allowed "${port}/${proto}"; then ufw="ALLOW"; fi
      if [[ "${listen}" == "Yes" ]]; then
        proc=$(ss -lntup 2>/dev/null | awk -v p=":${port}" '$0 ~ p {print $NF; exit}')
      fi
      printf "%-10s | %-10s | %-10s | %-8s | %-8s\n" "$port" "$proto" "$listen" "$ufw" "$proc"
      [[ "$port" == "22" && "$proto" == "udp" ]] && break
    done
  done
  printf "%s\n" "----------------------------------------------------------------"
}

check_peer_id_external() {
  local tmp="/tmp/Port_cheaker.sh"
  run_cmd_with_bar "Downloading Peer ID checker" "curl -fsSL -o '${tmp}' 'http://raw.githubusercontent.com/fiqrian/Aztec-tools/refs/heads/main/PeerIDStatus' && chmod +x '${tmp}'"
  echo "=== Peer ID Checker Output ==="
  bash "${tmp}" || true
  echo "=============================="
}

menu_tools_submenu() {
  while true; do
    header
    echo -e "                       Check Tools"
    echo -e "======================================================"
    if command -v docker >/dev/null 2>&1; then echo -e "${GREEN}✅ Docker.${NC}"; else echo -e "${RED}❌ Docker not installed.${NC}"; fi
    # Summary: OK if UFW allows or listener exists
    local ok=0
    for spec in "22/tcp" "40400/tcp" "40400/udp" "8080/tcp" "8880/tcp"; do
      port="${spec%/*}"; proto="${spec#*/}"
      if is_ufw_port_allowed "$spec" || is_listening "$port" "$proto"; then ok=$((ok+1)); fi
    done
    if [[ ${ok} -ge 4 ]]; then
      echo -e "${GREEN}✅ Required ports look open (22, 40400, 8080, 8880).${NC}"
    else
      echo -e "${YELLOW}⚠️ Some ports are not open (22, 40400, 8080, 8880).${NC}"
    fi
    echo -e "======================================================"
    echo -e "1) Check Ports"
    echo -e "2) Check Peer ID"
    echo -e "3) Check Logs (Node & RPC)"
    echo -e "4) Check Sync RPC"
    echo -e "5) Check Version Node & RPC"
    echo -e "6) Node Performance"
    echo -e "7) Back to Main Menu"
    echo -e "======================================================"
    read -rp "Choose (1-7): " c
    case "$c" in
      1) check_ports_table; pause ;;
      2) check_peer_id_external; pause ;;
      3) menu_logs ;;
      4) check_sync_rpc ;;
      5) menu_check_versions ;;
      6) menu_perf ;;
      7) break ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}


# ---------- Install/Run/Update ----------
menu_run_node() {
  header
  echo -e "                      Run Node"
  echo -e "======================================================"
  echo -e "Press Enter to start installing & running the sequencer"
  read -rp "" _
  : > "$LOG"
  pkg_install_base
  ensure_docker
  ensure_ufw_seq
  ensure_aztec_cli
  write_aztec_env
  write_aztec_compose
  run_aztec_compose
  echo -e "\n======================================================"
  echo -e "                       Run Node"
  echo -e "======================================================"
  echo -e " Press enter to return"
  read -rp "" _x
}

menu_install_rpc() {
  header
  echo -e "                      Install RPC"
  echo -e "======================================================"
  echo -e "Press Enter to install & run RPC (Geth + Prysm, Sepolia)"
  read -rp "" _
  : > "$LOG"
  pkg_install_base
  ensure_docker
  ensure_ufw_rpc
  ensure_rpc_dirs
  write_rpc_compose
  run_rpc_compose
  echo -e "\n======================================================"
  echo -e "                      Install RPC"
  echo -e "======================================================"
  echo -e " Press enter to return"
  read -rp "" _x
}

menu_update_node() {
  header
  echo -e "                   Update Node & RPC"
  echo -e "======================================================"
  echo -e "1) Update Node"
  echo -e "2) Update RPC Geth"
  echo -e "3) Update RPC Prysm"
  echo -e "4) Exit"
  echo -e "======================================================"
  read -rp "Choose (1-4): " c
  case "$c" in
    1) : > "$LOG"; run_cmd_with_bar "Pulling latest Aztec image" "docker pull ${AZTEC_IMAGE}"; (cd "${AZTEC_DIR}" && run_cmd_with_bar "docker compose up -d (recreate)" "docker compose up -d --pull always --force-recreate"); quick_bar "Node update finished" ;;
    2) : > "$LOG"; run_cmd_with_bar "Pulling latest Geth image" "docker pull ethereum/client-go:stable"; (cd "${ETH_DIR}" && run_cmd_with_bar "docker compose up -d --pull always --force-recreate geth"); quick_bar "Geth update finished" ;;
    3) : > "$LOG"; run_cmd_with_bar "Pulling latest Prysm image" "docker pull gcr.io/prysmaticlabs/prysm/beacon-chain"; (cd "${ETH_DIR}" && run_cmd_with_bar "docker compose up -d --pull always --force-recreate prysm"); quick_bar "Prysm update finished" ;;
    4) ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
  pause
}
# ---------- Delete menus ----------
delete_node() {
  run_cmd_with_bar "Stopping aztec container (if any)" \
    "docker rm -f '${AZTEC_CONTAINER}' 2>/dev/null || true"

  if [[ -f "${AZTEC_COMPOSE}" ]]; then
    ( cd "${AZTEC_DIR}" && \
      run_cmd_with_bar "Compose down aztec (with volumes)" "docker compose down -v || true" )
  fi

  run_cmd_with_bar "Removing aztec data dir" "rm -rf '${AZTEC_DATA_DIR}' || true"
  run_cmd_with_bar "Removing aztec project dir" "rm -rf '${AZTEC_DIR}' || true"
}

delete_rpc() {
  run_cmd_with_bar "Stopping geth/prysm containers (if any)" \
    "docker rm -f geth prysm 2>/dev/null || true"

  if [[ -f "${ETH_COMPOSE}" ]]; then
    ( cd "${ETH_DIR}" && \
      run_cmd_with_bar "Compose down RPC (with volumes)" "docker compose down -v || true" )
  fi

  run_cmd_with_bar "Removing ethereum data dirs" \
    "rm -rf '${ETH_EXEC_DIR}' '${ETH_CONS_DIR}' '${ETH_JWT}' || true"
  run_cmd_with_bar "Removing ethereum project dir" "rm -rf '${ETH_DIR}' || true"
}

# ---------- Delete menus ----------
menu_delete() {
  header
  echo -e "                     Delete Node & RPC"
  echo -e "======================================================"
  echo -e "1) Delete Node & RPC"
  echo -e "2) Delete Node"
  echo -e "3) Delete RPC"
  echo -e "4) Exit"
  echo -e "======================================================"
  read -rp "Choose (1-4): " ch
  case "$ch" in
    1)
      read -rp "Type YES to delete BOTH: " c; [[ $c == YES ]] || { echo "Cancelled."; pause; return; }
      delete_node; delete_rpc
      echo -e "${GREEN}All deleted.${NC}"; pause ;;
    2)
      read -rp "Type YES to delete Node: " c; [[ $c == YES ]] || { echo "Cancelled."; pause; return; }
      delete_node
      echo -e "${GREEN}Node deleted.${NC}"; pause ;;
    3)
      read -rp "Type YES to delete RPC: " c; [[ $c == YES ]] || { echo "Cancelled."; pause; return; }
      delete_rpc
      echo -e "${GREEN}RPC deleted.${NC}"; pause ;;
    4) : ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
}

# ---------- MAIN ----------
need_root
while true; do
  header
  echo -e "        MENU OPERATION SEQUENCER NODE"
  echo -e "======================================================"
  echo -e "1. Check Tools"
  echo -e "2. Run Node"
  echo -e "3. Run RPC"
  echo -e "4. View & Edit .env"
  echo -e "5. Update Node & RPC"
  echo -e "6. Restart Node & RPC"
  echo -e "7. Stop Node & RPC"
  echo -e "8. Delete Node & RPC"
  echo -e "9. Exit"
  echo -e "======================================================"
  read -rp "Choose Option (1-9): " opt
  case "$opt" in
    1) menu_tools_submenu ;;
    2) menu_run_node ;;
    3) menu_install_rpc ;;
    4) menu_view_reconfigure_env ;;
    5) menu_update_node ;;
    6) menu_restart ;;
    7) menu_stop ;;
    8) menu_delete ;;
    9) echo "Bye!"; exit 0 ;;
    *) echo -e "${YELLOW}Invalid choice.${NC}"; sleep 1 ;;
  esac

done
