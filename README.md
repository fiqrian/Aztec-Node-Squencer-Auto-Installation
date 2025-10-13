<img width="1862" height="928" alt="image" src="https://github.com/user-attachments/assets/ffb2581f-5066-435f-9074-a3deb3449bbe" />

# Aztec-Node-Squencer-Auto-Installation
## Hardware Requirements
<table>
  <tr>
    <th colspan="3"> Sequencer Node & RPC Requirements </th>
  </tr>
  <tr>
    <td>RAM</td>
    <td>CPU</td>
    <td>Disk</td>
  </tr>
  <tr>
    <td><code>8-16 GB</code></td>
    <td><code>4-9 cores</code></td>
    <td><code>1+ TB SSD</code></td>
  </tr>
</table>

---

## 🚀 Quick Start
Run this single command:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fiqrian/Aztec-Node-Squencer-Auto-Installation/refs/heads/main/Aztec-Installer/aztec-installer.sh)
```
---

## 🧭 Main Menu Map

```
======================================================
      Aztec Network Node Sequencer & RPC (Docker)
                 Created by 0xfix
======================================================
        MENU OPERATION SEQUENCER NODE
======================================================
1. Check Tools
2. Run Node
3. Run RPC
4. View & Reconfigure .env
5. Update Node
6. Restart Node & RPC
7. Stop Node & RPC
8. Delete Node & RPC
9. Exit
======================================================
```

---

## 🔧 Feature Guide

### 1) Check Tools
A small toolbox with 4 sub‑features:

- **Check Ports** — Shows a table of ports, protocol, whether a service is listening, UFW rule, and the owning process.
- **Check Peer ID** — Runs an external checker script (`Port_cheaker.sh`) and prints your peer info. The script is fetched on demand from the author’s GitHub.
- **Check Logs (Node & RPC)** — Interactive selector to tail recent logs from:
  - `aztec-sequencer` (Aztec node)
  - `prysm` (beacon chain)
  - `geth` (execution client)
- **Node Performance** — A lightweight full‑screen **live dashboard** showing:
  - CPU / Memory / Disk usage as filled bars
  - `docker stats` table (CPU%, Mem, IO per container)
  - `docker ps` table (running containers)
  - Press **`q`** to exit

### 2) Run Node (Aztec Sequencer)
- Installs prerequisite packages
- Installs/configures **Docker + Compose**
- Opens UFW **sequencer** ports
- Installs **Aztec CLI** (adds to PATH for this session)
- Prompts to create **`.env`** for the sequencer with **three modes**:
  1. Guided prompts (one-by-one)
  2. **Paste mode** (paste a full `.env` block, finish with **Ctrl+D**)
  3. Edit in `nano`
- Generates `~/aztec/docker-compose.yml`
- Starts the `aztec-sequencer` container

**Data directory**: `~/.aztec/testnet/data` (mounted into the container)

### 3) Run RPC (Geth + Prysm, Sepolia)
- Creates directories: `~/ethereum/execution`, `~/ethereum/consensus`
- Generates `~/ethereum/jwt.hex` (JWT secret for engine API)
- Generates `~/ethereum/docker-compose.yml` for **Geth** + **Prysm**
- Opens UFW **RPC** ports
- Starts **geth** and **prysm**

### 4) View & Reconfigure `.env`
- Prints the current `~/aztec/.env`
- Choose to:
  - Guided edit (keep existing values by pressing Enter)
  - **Paste mode** (paste block and finish with Ctrl+D)
  - Edit in `nano`

**Keys used by the sequencer compose file**:
```
ETHEREUM_RPC_URL=...            # L1 execution RPC URL (e.g., http://127.0.0.1:8545)
CONSENSUS_BEACON_URL=...        # Beacon chain API URL (e.g., http://127.0.0.1:4000)
VALIDATOR_PRIVATE_KEY=0x...     # Your validator private key
COINBASE=0x...                  # Your Ethereum address that receives fees
P2P_IP=...                      # Public IP for P2P
LOG_LEVEL=debug                 # (default: debug)
```

### 5) Update Node
- Pulls the latest `aztecprotocol/aztec:latest` image
- Recreates the sequencer container with `docker compose up -d --pull always --force-recreate`

### 6) Restart Node & RPC
A four‑option submenu:
1. Restart **Node & RPC** (aztec‑sequencer, prysm, geth)
2. Restart **Node** only (aztec‑sequencer)
3. Restart **RPC** only (prysm + geth)
4. Exit

### 7) Stop Node & RPC
- Choose which container to stop: **Node**, **Prysm**, or **Geth**

### 8) Delete Node & RPC
Destructive actions with confirmation prompts:
- **Delete Node & RPC** — stops and removes everything (compose projects, data folders)
- **Delete Node** — removes Aztec sequencer + data
- **Delete RPC** — removes Geth/Prysm + data

> **Paths removed** (when applicable):
> - `~/.aztec/testnet/data/`
> - `~/aztec/`
> - `~/ethereum/execution/`, `~/ethereum/consensus/`, `~/ethereum/jwt.hex`, `~/ethereum/`

---

## 📁 File & Directory Layout

```
~/aztec/
  ├─ .env                     # Sequencer environment
  └─ docker-compose.yml       # Sequencer compose

~/.aztec/testnet/data/        # Sequencer data

~/ethereum/
  ├─ execution/               # Geth data
  ├─ consensus/               # Prysm data
  ├─ jwt.hex                  # Engine API shared secret
  └─ docker-compose.yml       # RPC compose
```

---

## 🔒 Firewall Rules (UFW)

The script adds these rules:
- Base: `allow 22` and `allow ssh`
- Sequencer: `allow 40400/tcp`, `allow 40400/udp`, `allow 8080/tcp`
- RPC: `allow 30303/tcp`, `allow 30303/udp`, `allow 8545/tcp`, `allow 8546/tcp`, `allow 8551/tcp`, `allow 4000/tcp`, `allow 3500/tcp`

You can verify any time via **Check Tools → Check Ports** or manually:
```bash
sudo ufw status
sudo ss -lntup | grep -E ':(40400|8080|30303|8545|8546|8551|4000|3500)\b'
```

---

## 🪪 Example `.env`

Paste this via **Paste mode** (option 2 in `.env` creation or reconfigure):

```
ETHEREUM_RPC_URL=http://127.0.0.1:8545
CONSENSUS_BEACON_URL=http://127.0.0.1:3500
VALIDATOR_PRIVATE_KEY=0xYOUR_PRIVATE_KEY
COINBASE=0xYOUR_WALLET_ADDRESS
P2P_IP=YOUR_SERVER_PUBLIC_IP
LOG_LEVEL=debug
```

---

## 🧰 Useful Docker Commands

```bash
# List containers
docker ps -a

# Tail logs
docker logs -f aztec-sequencer
docker logs -f prysm
docker logs -f geth

# Restart a single container
docker restart aztec-sequencer

# Compose up/down (Sequencer)
(cd ~/aztec && docker compose up -d)
(cd ~/aztec && docker compose down)

# Compose up/down (RPC)
(cd ~/ethereum && docker compose up -d)
(cd ~/ethereum && docker compose down)
```

---

## 🔐 Security Notes

- Keep your `.env` private; it contains sensitive keys. The script writes with restrictive permissions.
- Rotate `VALIDATOR_PRIVATE_KEY` if it may have been exposed.
- Restrict SSH access and consider fail2ban or keys‑only auth.

---

## ♻️ Uninstall

Use **Main Menu → Delete Node & RPC** to cleanly remove containers, images (via compose down), and data directories.

Manual cleanup (if needed):
```bash
docker rm -f aztec-sequencer prysm geth 2>/dev/null || true
(cd ~/aztec && docker compose down -v 2>/dev/null || true)
(cd ~/ethereum && docker compose down -v 2>/dev/null || true)
rm -rf ~/.aztec/testnet/data ~/aztec ~/ethereum
```

gAtztec ☕

Good luck!
