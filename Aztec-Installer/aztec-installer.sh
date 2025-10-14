#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec /usr/bin/env bash "$0" "$@"

# ======================================================
#  Aztec Network Node Sequencer & RPC (Docker) - Manager v5.2.1
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
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

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
  local width=40
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
  local width=40
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
  run_cmd_with_bar "Installing base packages" "apt-get install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ufw ca-certificates gnupg lsb-release dnsutils"
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

ensure_ufw_seq() {
  run_cmd_with_bar "Adding UFW rules for Sequencer" "
    apt-get install -y ufw >/dev/null 2>&1 || true; \
    ufw allow 22; ufw allow ssh; ufw allow 40400/tcp; ufw allow 40400/udp; ufw allow 8080/tcp; ufw --force enable; ufw reload"
}
ensure_ufw_rpc() {
  run_cmd_with_bar "Adding UFW rules for RPC" "
    apt-get install -y ufw >/dev/null 2>&1 || true; \
    ufw allow 30303/tcp; ufw allow 30303/udp; ufw allow 8545/tcp; ufw allow 8546/tcp; ufw allow 8551/tcp; ufw allow 4000/tcp; ufw allow 3500/tcp; ufw reload"
}

is_ufw_port_allowed() { ufw status | grep -E -q "[[:space:]]$1(/tcp|/udp)?[[:space:]]"; }

ensure_aztec_cli() {
  if command -v aztec >/dev/null 2>&1; then
    quick_bar "aztec CLI already installed" 1
  else
    run_cmd_with_bar "Installing aztec CLI" "bash -i <(curl -s https://install.aztec.network)"
    export PATH="$HOME/.aztec/bin:$PATH"
    quick_bar "Validated aztec executable (added to PATH for this session)" 1
  fi
}

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
  cat > "${AZTEC_ENV}" <<EOF
ETHEREUM_RPC_URL=${ETH_RPC}
CONSENSUS_BEACON_URL=${BEACON_RPC}
VALIDATOR_PRIVATE_KEY=${VALKEY}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}
LOG_LEVEL=debug
EOF
  quick_bar "Wrote ${AZTEC_ENV}" 1
}

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
      LOG_LEVEL: ${LOG_LEVEL:-debug}
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
    image: gcr.io/offchainlabs/prysm/beacon-chain:stable
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
    logging:
      driver: "json-file"
      options: { max-size: "10m", max-file: "3" }
YAML
  quick_bar "Wrote ${ETH_COMPOSE}" 1
}

run_rpc_compose() {
  (cd "${ETH_DIR}" && run_cmd_with_bar "Starting RPC (docker compose up -d)" "docker compose up -d")
}

print_containers_table() {
  local n1="Aztec Sequencer"; local id1="${AZTEC_CONTAINER}"; local s1
  local n2="Beacon-chain";    local id2="prysm";            local s2
  local n3="Sepolia";         local id3="geth";             local s3

  s1=$(docker ps -a --filter "name=^/${id1}$" --format "{{.Status}}")
  s2=$(docker ps -a --filter "name=^/${id2}$" --format "{{.Status}}")
  s3=$(docker ps -a --filter "name=^/${id3}$" --format "{{.Status}}")
  [[ -z "$s1" ]] && s1="-"
  [[ -z "$s2" ]] && s2="-"
  [[ -z "$s3" ]] && s3="-"

  printf "%s\n" "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "No." "Container Name" "Status"
  printf "%s\n" "----------------------------------------------------------------"
  printf "%-6s | %-18s | %s\n" "1" "$n1" "$s1"
  printf "%-6s | %-18s | %s\n" "2" "$n2" "$s2"
  printf "%-6s | %-18s | %s\n" "3" "$n3" "$s3"
  printf "%s\n" "----------------------------------------------------------------"
}

show_running_containers() {
  printf "%s\n" "----------------------------------------------------------------"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  printf "%s\n" "----------------------------------------------------------------"
}

repeat_char() { local n=$1 ch="$2"; for ((i=0;i<n;i++)); do printf "%s" "$ch"; done; }
bar() {
  local pct=$1 width=${2:-30}
  local filled=$(( pct*width/100 ))
  printf "%s" "["; repeat_char "$filled" "█"; repeat_char "$((width-filled))" "░"; printf "] %3d%%" "$pct"
}

get_cpu_pct() {
  local idle
  idle=$(LC_ALL=C top -bn1 | awk -F',' '/Cpu\(s\)/{print $4}' | awk '{print int($1)}')
  if [[ -z "$idle" ]]; then echo 0; return; fi
  echo $((100 - idle))
}

get_mem_pct() {
  local total_mb used_mb
  total_mb=$(free -m | awk '/^Mem:/{print $2}')
  used_mb=$(free -m | awk '/^Mem:/{print $3}')
  if [[ -z "$total_mb" || "$total_mb" -eq 0 ]]; then echo 0; return; fi
  echo $(( used_mb * 100 / total_mb  ))
}

get_disk_pct() {
  df -P / | awk 'NR==2{gsub("%","",$5); print $5}'
}

docker_stats_table() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not available."
    return
  fi
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || true
}

dashboard() {
  while true; do
    clear
    echo -e "===================== Node Performance ====================="
    local cpu mem disk
    cpu=$(get_cpu_pct); mem=$(get_mem_pct); disk=$(get_disk_pct)
    printf "CPU Usage    : "; bar "${cpu}" 40; printf "\n"
    printf "Memory Usage : "; bar "${mem}" 40; printf "\n"
    printf "Disk Usage   : "; bar "${disk}" 40; printf "\n"
    echo "------------------------------------------------------------"
    echo "Docker Container Usage:"
    docker_stats_table
    echo "------------------------------------------------------------"
    echo "Running Containers:"
    show_running_containers
    echo "------------------------------------------------------------"
    echo "Press 'q' to quit, any other key to refresh..."
    read -rsn1 -t 2 key || true
    [[ "${key:-}" == "q" ]] && break
  done
}

print_env() {
  printf "%s\n" "======================================================"
  printf "%s\n" "                    View .env"
  printf "%s\n" "======================================================"
  if [[ -f "${AZTEC_ENV}" ]]; then
    cat "${AZTEC_ENV}"
  else
    printf "%s\n" "File ${AZTEC_ENV} not found."
  fi
  printf "\n"
}

reconfigure_env() {
  if [[ ! -f "${AZTEC_ENV}" ]]; then
    echo "ENV not found. Creating a new one..."
    write_aztec_env
    return
  fi
  echo "Edit values (Enter to keep current)."
  local ETH_RPC BEACON_RPC VALKEY COINBASE P2P LOGLEVEL
  ETH_RPC=$(grep -E '^ETHEREUM_RPC_URL=' "${AZTEC_ENV}" | cut -d= -f2- || echo "")
  BEACON_RPC=$(grep -E '^CONSENSUS_BEACON_URL=' "${AZTEC_ENV}" | cut -d= -f2- || echo "")
  VALKEY=$(grep -E '^VALIDATOR_PRIVATE_KEY=' "${AZTEC_ENV}" | cut -d= -f2- || echo "")
  COINBASE=$(grep -E '^COINBASE=' "${AZTEC_ENV}" | cut -d= -f2- || echo "")
  P2P=$(grep -E '^P2P_IP=' "${AZTEC_ENV}" | cut -d= -f2- || echo "")
  LOGLEVEL=$(grep -E '^LOG_LEVEL=' "${AZTEC_ENV}" | cut -d= -f2- || echo "debug")

  read -rp "ETHEREUM_RPC_URL [${ETH_RPC}]: " in1 || true; [[ -n "${in1:-}" ]] && ETH_RPC="$in1"
  read -rp "CONSENSUS_BEACON_URL [${BEACON_RPC}]: " in2 || true; [[ -n "${in2:-}" ]] && BEACON_RPC="$in2"
  read -rp "VALIDATOR_PRIVATE_KEY [${VALKEY}]: " in3 || true; [[ -n "${in3:-}" ]] && VALKEY="$in3"
  read -rp "COINBASE [${COINBASE}]: " in4 || true; [[ -n "${in4:-}" ]] && COINBASE="$in4"
  read -rp "P2P_IP [${P2P}]: " in5 || true; [[ -n "${in5:-}" ]] && P2P="$in5"
  read -rp "LOG_LEVEL [${LOGLEVEL}]: " in6 || true; [[ -n "${in6:-}" ]] && LOGLEVEL="$in6"

  cat > "${AZTEC_ENV}" <<EOF
ETHEREUM_RPC_URL=${ETH_RPC}
CONSENSUS_BEACON_URL=${BEACON_RPC}
VALIDATOR_PRIVATE_KEY=${VALKEY}
COINBASE=${COINBASE}
P2P_IP=${P2P}
LOG_LEVEL=${LOGLEVEL}
EOF
  quick_bar "Saved ${AZTEC_ENV}" 1
}

menu_view_env() {
  header
  print_env
  read -rp "➡ Do you want to edit values? (y/N): " ans || true
  if [[ "${ans,,}" == "y" ]]; then
    reconfigure_env
  fi
  pause
}

delete_node() {
  run_cmd_with_bar "Stopping aztec container (if any)" "docker rm -f '${AZTEC_CONTAINER}' 2>/dev/null || true"
  if [[ -f "${AZTEC_COMPOSE}" ]]; then
    (cd "${AZTEC_DIR}" && run_cmd_with_bar "Compose down aztec (with volumes)" "docker compose down -v || true")
  fi
  run_cmd_with_bar "Removing aztec data dir" "rm -rf '${AZTEC_DATA_DIR}' || true"
  run_cmd_with_bar "Removing aztec project dir" "rm -rf '${AZTEC_DIR}' || true"
}

delete_rpc() {
  run_cmd_with_bar "Stopping geth/prysm containers (if any)" "docker rm -f 'geth' 'prysm' 2>/dev/null || true"
  if [[ -f "${ETH_COMPOSE}" ]]; then
    (cd "${ETH_DIR}" && run_cmd_with_bar "Compose down RPC (with volumes)" "docker compose down -v || true")
  fi
  run_cmd_with_bar "Removing ethereum data dirs" "rm -rf '${ETH_EXEC_DIR}' '${ETH_CONS_DIR}' '${ETH_JWT}' || true"
  run_cmd_with_bar "Removing ethereum project dir" "rm -rf '${ETH_DIR}' || true"
}

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
      read -rp "Are you sure to delete BOTH Node & RPC? Type YES to continue: " c
      [[ "${c}" == "YES" ]] || { echo "Cancelled."; pause; return; }
      delete_node
      delete_rpc
      echo -e "${GREEN}All deleted.${NC}"; pause
      ;;
    2)
      read -rp "Are you sure to delete Node only? Type YES to continue: " c
      [[ "${c}" == "YES" ]] || { echo "Cancelled."; pause; return; }
      delete_node
      echo -e "${GREEN}Node deleted.${NC}"; pause
      ;;
    3)
      read -rp "Are you sure to delete RPC only? Type YES to continue: " c
      [[ "${c}" == "YES" ]] || { echo "Cancelled."; pause; return; }
      delete_rpc
      echo -e "${GREEN}RPC deleted.${NC}"; pause
      ;;
    4) : ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
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
    1)
      restart_container "${AZTEC_CONTAINER}"
      restart_container "prysm"
      restart_container "geth"
      pause
      ;;
    2)
      restart_container "${AZTEC_CONTAINER}"
      pause
      ;;
    3)
      restart_container "prysm"
      restart_container "geth"
      pause
      ;;
    4) : ;;
    *) echo "Invalid choice"; sleep 1 ;;
  esac
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

menu_perf() {
  header
  echo -e "                   Node Performance"
  echo -e "======================================================"
  echo -e "(Press 'q' to quit live view)"
  sleep 1
  dashboard
}

check_ports_table() {
  printf "%s\n" "----------------------------------------------------------------"
  printf "%-10s | %-10s | %-10s | %-8s | %-8s\n" "Port" "Proto" "Listen" "UFW" "Proc"
  printf "%s\n" "----------------------------------------------------------------"
  for port in 22 40400 8080 30303 8545 8546 8551 4000 3500; do
    for proto in tcp udp; do
      local listen="No"; local ufw="DENY"; local proc="-"
      if ss -lntup | grep -q ":${port} "; then
        listen="Yes"
        proc=$(ss -lntup | awk -v p=":${port}" '$0 ~ p {print $NF; exit}')
      fi
      if is_ufw_port_allowed "${port}/${proto}"; then ufw="ALLOW"; fi
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
    ok_ports=0
    for p in 22 40400 8080; do
      if is_ufw_port_allowed "${p}/tcp" || is_ufw_port_allowed "${p}/udp"; then
        ok_ports=$((ok_ports+1))
      fi
    done
    if [[ ${ok_ports} -ge 3 ]]; then
      echo -e "${GREEN}✅ Ports (22, 40400, 8080) open.${NC}"
    else
      echo -e "${YELLOW}⚠️ Some ports are not open (22, 40400, 8080).${NC}"
    fi
    echo -e "======================================================"
    echo -e "1) Check Ports"
    echo -e "2) Check Peer ID"
    echo -e "3) Check Logs (Node & RPC)"
    echo -e "4) Node Performance"
    echo -e "5) Back to Main Menu"
    echo -e "======================================================"
    read -rp "Choose (1-5): " c
    case "$c" in
      1) check_ports_table; pause ;;
      2) check_peer_id_external; pause ;;
      3) menu_logs ;;
      4) menu_perf ;;
      5) break ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

menu_run_node() {
  header
  echo -e "                      Run Node"
  echo -e "======================================================\n"
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
  echo -e "======================================================\n"
  echo -e " Press enter to return"
  read -rp "" _x
}

menu_install_rpc() {
  header
  echo -e "                      Install RPC"
  echo -e "======================================================\n"
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
  echo -e "======================================================\n"
  echo -e " Press enter to return"
  read -rp "" _x
}

menu_update_node() {
  header
  echo -e "                      Update Node"
  echo -e "======================================================"
  echo -e "1) Continue update"
  echo -e "2) Exit"
  echo -e "======================================================"
  read -rp "Choose (1/2): " c
  case "$c" in
    1)
      : > "$LOG"
      run_cmd_with_bar "Pulling latest Aztec image" "docker pull ${AZTEC_IMAGE}"
      (cd "${AZTEC_DIR}" && run_cmd_with_bar "docker compose up -d (recreate)" "docker compose up -d --pull always --force-recreate")
      quick_bar "Update finished"
      ;;
    2) ;;
    *) echo "Invalid choice";;
  esac
  pause
}

need_root
while true; do
  header
  echo -e "        MENU OPERATION SEQUENCER NODE"
  echo -e "======================================================"
  echo -e "1. Check Tools"
  echo -e "2. Run Node"
  echo -e "3. Run RPC"
  echo -e "4. View .env"
  echo -e "5. Update Node"
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
    4) menu_view_env ;;
    5) menu_update_node ;;
    6) menu_restart ;;
    7) menu_stop ;;
    8) menu_delete ;;
    9) echo "Bye!"; exit 0 ;;
    *) echo -e "${YELLOW}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
