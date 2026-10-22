# Homelab Ansible

Automated provisioning for the entire home infrastructure + OCI.

## Inventory

### HOME (LAN 192.168.8.0/24)

| Host | IP | HW | Key services |
|---|---|---|---|---|---|
| trastero02 | 192.168.8.3 | i5-7400, 8GB | Immich, Duplicati, Hawser |
| trastero03 | offline | Core 2 Duo, 4GB | — |
| trastero04 | offline | Core 2 Duo, 4GB | — |
| rpi4 | 192.168.8.4 | RPi4, 4GB | Home Assistant, Vaultwarden, AdGuard, WireGuard, Uptime Kuma, Linkding, Linkace, Linkwarden, RSSHub, RSS-Bridge, Baserow, Jellystat, Dozzle, Heimdall, DuckDNS, VS Code, Dockhand |
| rpi3 | 192.168.8.5 | RPi3, 1GB | DuckDNS, Hawser |

### PROXMOX

| Host | IP | HW | Ansible Roles |
|---|---|---|---|
| trastero01 | 192.168.8.2 | i7-7700K, 32GB, GTX 1080, 4x SATA drives (9TB pool) | common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs, proxmox-nag-patch, dev-toolchain, rea, opencode-mcp, opencode |

### OCI (Oracle Cloud)

| Host | IP | Region | Shape |
|---|---|---|---|
| oci-madrid | 158.179.209.39 | Madrid | VM.Standard.A1.Flex (4 OCPU, 24GB) |
| oci-frankfurt | 130.61.106.137 | Frankfurt | VM.Standard.A1.Flex (4 OCPU, 24GB) |

## Roles

| Role | Tags | Description |
|---|---|---|---|
| `common` | `common`, `base` | Timezone Europe/Madrid, base + extra packages per group, conditional UFW |
| `ssh-hardening` | `ssh`, `security` | SSH config variable-driven (PermitRootLogin, PasswordAuth), fail2ban |
| `docker` | `docker` | Docker Engine + compose plugin, daemon.json (DNS, NVIDIA runtime) |
| `rclone` | `rclone` | Rclone config + mounts (crypt + raw root) via o2cloud WebDAV; systemd, healthcheck I/O, Jellyfin watchdog, RC exporter dual (crypt/root) |
| `samba` | `samba` | Samba shares from vault (conditional, only when smb_conf_content is present) |
| `scripts` | `scripts` | Clones the `cescm/scripts` repo into /mnt/repos/scripts and deploys the helpers to /mnt/scripts/ (plus their secrets in /etc/script-secrets) |
| `nvidia` | `nvidia` | NVIDIA CUDA repo + cuda-drivers + nvidia-open-dkms + nvidia-container-toolkit |
| `mergerfs` | `mergerfs` | Installs mergerfs, mounts drives by ID, creates pool with mount module (safe fstab) |
| `proxmox-nag-patch` | `proxmox-nag-patch` | Re-applies the Proxmox subscription nag bypass after apt upgrades (script + DPkg::Post-Invoke hook) |
| `dev-toolchain` | `dev`, `toolchain`, `node`, `java`, `engram` | JDK 21, Node.js 24 (checksum pinned), npm global prefix + install-script policy, engram CLI |
| `rea` | `rea`, `reverse-engineering`, `rea-engines` | REA CLI + Ghidra 12.1.4, jadx-headless-mcp bridge JAR and Kuna 1.833 engines, plus the opencode REA skill |
| `opencode-mcp` | `opencode-mcp`, `mcp` | Renders the managed MCP server block (azure, context7, engram, n8n, n8n-official, rea) and merges it into `opencode.json` |
| `opencode` | `opencode`, `tools` | Installs the opencode CLI with the vendored official installer, pinned to an explicit version |

### Developer toolchain, REA engines and MCP servers

`trastero01` is the workstation that runs the opencode agent, so the repo also provisions its
development stack and keeps the agent MCP configuration under version control.

| Piece | Version | Location |
|---|---|---|
| Node.js | 24.22.1 | `/usr/local/lib/node24` (symlinked in `/usr/local/bin`) |
| JDK | 21 | `/usr/lib/jvm/java-21-openjdk-amd64` |
| REA CLI (`rea-agents`) | 6.7.0 | `/usr/local/bin/rea` |
| Ghidra | 12.1.4 | `/opt/ghidra_12.1.4_PUBLIC` |
| jadx-headless-mcp | 0.7.1 | `/opt/rea-engines/jadx-headless-mcp-0.7.1-all.jar` |
| Kuna | 1.833 | `/opt/rea-engines/kuna-v1.833-linux-x86_64/kuna` |
| engram CLI | v1.16.1 | `/usr/local/bin/engram` |
| opencode CLI | 1.19.2 | `/root/.opencode/bin/opencode` |

The opencode CLI is installed with the official installer vendored in `roles/opencode/files/install.sh`
(pinned to `opencode_version`), not with `go install`: the Go module `github.com/anomalyco/opencode`
is no longer published in the Go checksum database, so the Go path fails with a 404 on
`sum.golang.org`. PATH is managed declaratively (`/etc/profile.d/opencode.sh` and `/root/.bashrc`)
instead of by the installer itself.

Engine locations are exported by `/etc/profile.d/rea-engines.sh` (sourced from `/root/.bashrc`).

The MCP block is rendered from `group_vars/proxmox/vars.yml` plus the vaulted credentials in
`group_vars/proxmox/vault.yml` (`n8n_api_key`, `n8n_mcp_access_token`, `n8n_official_auth_token`).
`roles/opencode-mcp` merges it into `~/.config/opencode/opencode.json` (backing up the previous
version) and removes the duplicated `mcp` section from `opencode.jsonc`. Restart opencode after a
run so the agent reloads the server definitions.

```bash
# Provision the agent stack only
ansible-playbook playbook.yml --tags opencode,dev,rea,opencode-mcp

# Verify the REA engines are detected
rea doctor
```

## opencode Migration

trastero01 is the current machine (Ubuntu) and also the future Proxmox host. Before installing Proxmox, do a full backup:

```bash
# Backup BEFORE formatting (SATA drives will be physically moved)
tar czf /mnt/storage/opencode-backup-$(date +%F).tar.gz \
  -C /root .config/opencode .local/share/opencode .opencode .engram .gentle-ai .local/bin/rtk .bashrc .ssh \
  /usr/local/bin/engram /usr/local/bin/gentle-ai /mnt/scripts/infra/ansible

# Restore AFTER Proxmox + ansible-playbook
cd /root
tar xzf /mnt/storage/opencode-backup-YYYY-MM-DD.tar.gz

# The binaries in /usr/local/bin/ need -C / — extract with:
tar xzf /mnt/storage/opencode-backup-YYYY-MM-DD.tar.gz \
  -C / usr/local/bin/engram usr/local/bin/gentle-ai
# Or simply copy them manually:
cp /mnt/storage/opencode-backup-*.tar.gz /root/backup.tar.gz
tar xzf /root/backup.tar.gz -C /root .config/opencode .local/share/opencode .opencode .engram .gentle-ai .local/bin/rtk .bashrc .ssh
tar xzf /root/backup.tar.gz -C / usr/local/bin/engram usr/local/bin/gentle-ai
tar xzf /root/backup.tar.gz -C /mnt/scripts/infra/ ansible
```

### Post-restore notes

| Risk | Detail |
|---|---|
| **Ollama** | opencode points to `http://192.168.8.2:11434`. That IP will be the new Proxmox host — no Ollama until you deploy Docker. Local models will not work until then. The remote model `opencode/big-pickle` (opencode.ai) works at all times. |
| **Bun** | The `engram.ts` and `background-agents.ts` plugins use the Bun API. If opencode does not bundle it, those plugins will fail. Verify after restore. |
| **SSH keys** | The keys in `~/.ssh/` authorized on other hosts (Pi3, OCI) are restored from the backup. |
| **Ansible vault** | `.vault_pass` is not committed to the repo (it is gitignored); recreate it from your password manager (the password is deliberately not stored in this repo). Without it, the encrypted variables cannot be decrypted. |

## Usage

### Prerequisites

- Ansible installed on trastero01
- `sshpass` installed (for machines with password authentication)
- Python 3 on the target machines

### SSH Key

For Ansible to connect without a password, copy your public key to the target host:

```bash
# Host IP
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.8.X

# If you only have RSA:
ssh-copy-id root@192.168.8.X

# Verify it works without a password
ssh root@192.168.8.X
```

Hosts in the `proxmox` group use `ansible_user: root` and key-based authentication.

## Basic commands

```bash
cd /mnt/scripts/infra/ansible

# Show inventory
ansible-inventory --list

# Ping all machines
ansible all -m ping

# --- deploy.sh (wrapper with automatic vault) ---

# First run on freshly installed Proxmox (all roles):
./deploy.sh --limit trastero01

# Only specific parts:
TAGS=docker LIMIT=trastero01 ./deploy.sh

# --- Direct commands ---

# Provision a specific host
ansible-playbook playbook.yml -l trastero01

# Only a specific role
ansible-playbook playbook.yml -l trastero01 --tags docker

# Full playbook (with vault)
ansible-playbook playbook.yml --vault-password-file .vault_pass

# Available tags:
#   common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs, opencode, proxmox-nag-patch,
#   dev, toolchain, node, java, engram, rea, reverse-engineering, rea-engines, opencode-mcp, mcp
```

## Rclone stack (trastero01)

Movistar MíCloud is served through the `o2cloud-gateway-webdav` gateway and mounted in two layers:

1. **Gateway**: the `o2cloud-webdav` container exposes the Movistar API as a WebDAV server at `http://localhost:8088/dav/`. It needs a valid O2 session, imported via `POST /api/admin/o2/import` and stored in `/config/secrets`.
2. **Remotes** (from `rclone_config_content` in `group_vars/proxmox/vault.yml`):
   - `webdav` → `http://localhost:8088/dav/` (gateway credentials)
   - `movistar_webdav_enc` → crypt remote wrapping `webdav:encrypted`
3. **Mounts** (systemd units):
   - `rclone-movistar-webdav.service`: `movistar_webdav_enc:` → `/mnt/movistar_webdav` (decrypted media; Jellyfin consumes it via `/media3`). RC API on `127.0.0.1:5572`.
   - `rclone-movistar-webdav-root.service`: raw `webdav:` → `/mnt/movistar_webdav_root` (encrypted folders as-is, no crypt). RC API on `127.0.0.1:5573`.

Timers/helpers: `rclone-healthcheck`, `rclone-cache-clean`, `rclone-rc-exporter` (Prometheus textfile), `jellyfin-watchdog`. Logs: `/var/log/rclone-webdav.log` and `/var/log/rclone-webdav-root.log`.

> The role previously built the native Movistar backend (PR#9191) and mounted `movistar:`/`movistar_enc`. That stack is gone: everything routes through the WebDAV gateway.

## Ansible Vault

Machine passwords are encrypted with `ansible-vault`.

### Vault password

The vault password is **not stored in this repository**. Keep it in your password manager and recreate `.vault_pass` locally.

> **Note:** `.vault_pass` is not committed (it is gitignored). After a fresh clone, recreate it before running any command that touches the vault, e.g. `printf '<vault-password>' > .vault_pass && chmod 600 .vault_pass`.
>
> **Security:** the previous vault password was leaked in clear text through a public repository and must be considered compromised. Rotate it and re-encrypt the vault (`ansible-vault encrypt_string` for every `!vault` value in `group_vars/proxmox/vault.yml`) before using this repo again.

### Protected files

```
host_vars/
├── trastero01.yml    🔒  ansible_ssh_pass (encrypted)
├── trastero02.yml    🔒  ansible_ssh_pass (encrypted)
├── rpi4.yml          🔒  ansible_ssh_pass (encrypted)
└── rpi3.yml          🔒  ansible_ssh_pass (encrypted)
```

### Vault commands

```bash
# View vault contents
ansible-vault view host_vars/trastero01.yml

# Edit a vault (protected)
ansible-vault edit host_vars/trastero01.yml

# Encrypt a file
ansible-vault encrypt host_vars/nueva-maquina.yml

# Decrypt temporarily
ansible-vault decrypt host_vars/trastero02.yml
```

### Adding a new machine

```bash
# 1. Create host_vars with password
echo "ansible_ssh_pass: MiPassword" > host_vars/nueva-maquina.yml

# 2. Encrypt
ansible-vault encrypt host_vars/nueva-maquina.yml

# 3. Add to inventory
# Edit inventory/hosts.yml and add under home: or similar
```

## Helper scripts

The helper scripts live in their own repository, `cescm/scripts`, and are deployed from there:

| What | Where |
|---|---|
| Source of truth | `https://forgejo.caprichosdelucia.com/cescm/scripts` (cloned read-only by the `scripts` role) |
| Checkout on the host | `/mnt/repos/scripts` — one folder per function: `docker/`, `infra/`, `media/`, `mediaserver/`, `o2/`, `stash/`, plus `templates/` for Ansible templates |
| Runtime copy | `/mnt/scripts/<function>/` — the role copies the folders over and renders `templates/retry-vm.sh.j2` into `/mnt/scripts/infra/retry-vm.sh` |
| Secrets | `/etc/script-secrets/<name>` (root-owned, `0600`), materialised by the role from `group_vars/proxmox/vault.yml` |

**Convention**: every new helper script goes into `cescm/scripts` (locally `/mnt/repos/scripts`), in the
folder that matches its function. Never edit `/mnt/scripts` by hand — it is overwritten on the next run.

**Secrets**: no literal credentials in the repo. Scripts read them from the environment or from
`/etc/script-secrets/<name>`; the role writes those files from the vault.

## Structure

```
/mnt/scripts/infra/ansible/
├── ansible.cfg              # General config (forks=10, vault, etc.)
├── inventory/
│   └── hosts.yml            # Inventory (groups: home, proxmox, oci)
├── host_vars/               # 🔒 Encrypted passwords (per host)
├── group_vars/              # Shared variables per group
│   └── proxmox/
│       ├── vars.yml         # Packages, docker_daemon_json, mergerfs_config, toolchain + MCP vars
│       └── vault.yml        # 🔒 rclone.conf + smb.conf + MCP credentials (AES256)
├── playbook.yml             # Main playbook (13 roles)
├── .vault_pass              # 🔒 Vault password (gitignored; recreate from Vault password section)
└── roles/
    ├── common/              # Base + extra packages, conditional UFW
    ├── ssh-hardening/       # SSH config variable-driven
    ├── docker/              # Docker Engine + daemon.json
    ├── rclone/              # WebDAV via o2cloud-gateway + crypt mount, vault config + systemd
    ├── samba/               # Samba from vault
    ├── scripts/             # Clones cescm/scripts → /mnt/repos/scripts, deploys helpers to /mnt/scripts
    ├── nvidia/              # CUDA drivers + container toolkit
    ├── mergerfs/            # mergerfs + drives by ID
    ├── proxmox-nag-patch/   # Re-applies Proxmox subscription nag bypass after upgrades
    ├── dev-toolchain/       # JDK 21, Node.js 24, npm policy, engram CLI
    ├── rea/                 # REA CLI + Ghidra / jadx-mcp / Kuna engines + opencode skill
    ├── opencode-mcp/        # Managed MCP servers merged into opencode.json
    └── opencode/            # opencode CLI via the vendored official installer (version pinned)
```


