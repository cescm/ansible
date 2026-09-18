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
| trastero01 | 192.168.8.2 | i7-7700K, 32GB, GTX 1080, 4x SATA drives (9TB pool) | common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs |

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
| `rclone` | `rclone` | Build rclone with Movistar Cloud backend (PR#9191), vault config, systemd + healthcheck |
| `samba` | `samba` | Samba shares from vault (conditional, only when smb_conf_content is present) |
| `scripts` | `scripts` | Copies management scripts to /mnt/scripts/ |
| `nvidia` | `nvidia` | NVIDIA CUDA repo + cuda-drivers + nvidia-open-dkms + nvidia-container-toolkit |
| `mergerfs` | `mergerfs` | Installs mergerfs, mounts drives by ID, creates pool with mount module (safe fstab) |

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
| **Ansible vault** | The `.vault_pass` is restored with the project. Without it, `smb_conf_content` and `rclone_config_content` cannot be decrypted. |

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
#   common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs, opencode
```

## Ansible Vault

Machine passwords are encrypted with `ansible-vault`.

### Vault password

`J3sc0b0sA_1976`

### Protected files

```
host_vars/
├── trastero01.yml    🔒  Jescobosa_2
├── trastero02.yml    🔒  Jescobosa_2
├── rpi4.yml          🔒  Jescobosa_2
└── rpi3.yml          🔒  J3sc0b0sA_1976
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

## Structure

```
/mnt/scripts/infra/ansible/
├── ansible.cfg              # General config (forks=10, vault, etc.)
├── inventory/
│   └── hosts.yml            # Inventory (groups: home, proxmox, oci)
├── host_vars/               # 🔒 Encrypted passwords (per host)
├── group_vars/              # Shared variables per group
│   └── proxmox/
│       ├── vars.yml         # Packages, docker_daemon_json, mergerfs_config
│       └── vault.yml        # 🔒 rclone.conf + smb.conf (AES256)
├── playbook.yml             # Main playbook (8 roles)
├── .vault_pass              # 🔒 Vault password (do not commit)
└── roles/
    ├── common/              # Base + extra packages, conditional UFW
    ├── ssh-hardening/       # SSH config variable-driven
    ├── docker/              # Docker Engine + daemon.json
    ├── rclone/              # Build PR#9191 + vault config + systemd
    ├── samba/               # Samba from vault
    ├── scripts/             # Management scripts
    ├── nvidia/              # CUDA drivers + container toolkit
    └── mergerfs/            # mergerfs + drives by ID
```


