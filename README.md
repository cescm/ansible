# Homelab Ansible

Provisionamiento automatizado para toda la infraestructura doméstica + OCI.

## Inventario

### HOME (LAN 192.168.8.0/24)

| Host | IP | HW | Servicios destacados |
|---|---|---|---|---|---|
| trastero02 | 192.168.8.3 | i5-7400, 8GB | Immich, Duplicati, Hawser |
| trastero03 | offline | Core 2 Duo, 4GB | — |
| trastero04 | offline | Core 2 Duo, 4GB | — |
| rpi4 | 192.168.8.4 | RPi4, 4GB | Home Assistant, Vaultwarden, AdGuard, WireGuard, Uptime Kuma, Linkding, Linkace, Linkwarden, RSSHub, RSS-Bridge, Baserow, Jellystat, Dozzle, Heimdall, DuckDNS, VS Code, Dockhand |
| rpi3 | 192.168.8.5 | RPi3, 1GB | DuckDNS, Hawser |

### PROXMOX

| Host | IP | HW | Roles Ansible |
|---|---|---|---|
| trastero01 | 192.168.8.2 | i7-7700K, 32GB, GTX 1080, 4x discos SATA (9TB pool) | common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs |

### OCI (Oracle Cloud)

| Host | IP | Región | Shape |
|---|---|---|---|
| oci-madrid | 158.179.209.39 | Madrid | VM.Standard.A1.Flex (4 OCPU, 24GB) |
| oci-frankfurt | 130.61.106.137 | Frankfurt | VM.Standard.A1.Flex (4 OCPU, 24GB) |

## Roles

| Role | Tags | Descripción |
|---|---|---|---|
| `common` | `common`, `base` | Timezone Europe/Madrid, paquetes base + extra por grupo, UFW condicional |
| `ssh-hardening` | `ssh`, `security` | SSH config variable-driven (PermitRootLogin, PasswordAuth), fail2ban |
| `docker` | `docker` | Docker Engine + compose plugin, daemon.json (DNS, NVIDIA runtime) |
| `rclone` | `rclone` | Build rclone con backend Movistar Cloud (PR#9191), vault config, systemd + healthcheck |
| `samba` | `samba` | Samba shares desde vault (condicional, solo si hay smb_conf_content) |
| `scripts` | `scripts` | Copia scripts de gestión a /mnt/scripts/ |
| `nvidia` | `nvidia` | NVIDIA CUDA repo + cuda-drivers + nvidia-open-dkms + nvidia-container-toolkit |
| `mergerfs` | `mergerfs` | Instala mergerfs, monta discos por ID, crea pool con mount module (fstab seguro) |

## Migración de opencode

trastero01 es la máquina actual (Ubuntu) y también el futuro Proxmox. Antes de instalar Proxmox, haz backup completo:

```bash
# Backup ANTES de formatear (discos SATA se moverán físicamente)
tar czf /mnt/storage/opencode-backup-$(date +%F).tar.gz \
  -C /root .config/opencode .local/share/opencode .opencode .engram .gentle-ai .local/bin/rtk .bashrc .ssh \
  /usr/local/bin/engram /usr/local/bin/gentle-ai /mnt/scripts/infra/ansible

# Restaurar DESPUÉS de Proxmox + ansible-playbook
cd /root
tar xzf /mnt/storage/opencode-backup-YYYY-MM-DD.tar.gz

# Los bins en /usr/local/bin/ necesitan -C / — extraer con:
tar xzf /mnt/storage/opencode-backup-YYYY-MM-DD.tar.gz \
  -C / usr/local/bin/engram usr/local/bin/gentle-ai
# O simplemente copiarlos a mano:
cp /mnt/storage/opencode-backup-*.tar.gz /root/backup.tar.gz
tar xzf /root/backup.tar.gz -C /root .config/opencode .local/share/opencode .opencode .engram .gentle-ai .local/bin/rtk .bashrc .ssh
tar xzf /root/backup.tar.gz -C / usr/local/bin/engram usr/local/bin/gentle-ai
tar xzf /root/backup.tar.gz -C /mnt/scripts/infra/ ansible
```

### Notas post-restauración

| Riesgo | Detalle |
|---|---|
| **Ollama** | opencode apunta a `http://192.168.8.2:11434`. Esa IP será el nuevo Proxmox — sin Ollama hasta que despliegues Docker. Los modelos locales no funcionarán hasta entonces. El modelo remoto `opencode/big-pickle` (opencode.ai) funciona siempre. |
| **Bun** | Los plugins `engram.ts` y `background-agents.ts` usan API de Bun. Si opencode no lo trae embebido, esos plugins fallarán. Verificar post-restauración. |
| **SSH keys** | Las llaves de `~/.ssh/` autorizadas en otros hosts (Pi3, OCI) se restauran del backup. |
| **Ansible vault** | El `.vault_pass` se restaura con el proyecto. Sin él, no se pueden descifrar `smb_conf_content` ni `rclone_config_content`. |

## Uso

### Requisitos

- Ansible instalado en trastero01
- `sshpass` instalado (para máquinas con autenticación por contraseña)
- Python 3 en las máquinas destino

### SSH Key

Para que Ansible conecte sin contraseña, copia tu clave pública al host destino:

```bash
# IP del host
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.8.X

# Si solo tienes RSA:
ssh-copy-id root@192.168.8.X

# Verificar que funciona sin contraseña
ssh root@192.168.8.X
```

Los hosts del grupo `proxmox` usan `ansible_user: root` y autenticación por clave.

## Comandos básicos

```bash
cd /mnt/scripts/infra/ansible

# Ver inventario
ansible-inventory --list

# Ping a todas las máquinas
ansible all -m ping

# --- deploy.sh (wrapper con vault automático) ---

# Primera vez en Proxmox recién instalado (todos los roles):
./deploy.sh --limit trastero01

# Solo partes específicas:
TAGS=docker LIMIT=trastero01 ./deploy.sh

# --- Comandos directos ---

# Provisionar un host concreto
ansible-playbook playbook.yml -l trastero01

# Solo un rol específico
ansible-playbook playbook.yml -l trastero01 --tags docker

# Playbook completo (con vault)
ansible-playbook playbook.yml --vault-password-file .vault_pass

# Tags disponibles:
#   common, ssh, docker, rclone, samba, scripts, nvidia, mergerfs, opencode
```

## Ansible Vault

Las contraseñas de las máquinas están cifradas con `ansible-vault`.

### Password del vault

`J3sc0b0sA_1976`

### Archivos protegidos

```
host_vars/
├── trastero01.yml    🔒  Jescobosa_2
├── trastero02.yml    🔒  Jescobosa_2
├── rpi4.yml          🔒  Jescobosa_2
└── rpi3.yml          🔒  J3sc0b0sA_1976
```

### Comandos vault

```bash
# Ver contenido de un vault
ansible-vault view host_vars/trastero01.yml

# Editar un vault (protegido)
ansible-vault edit host_vars/trastero01.yml

# Cifrar un archivo
ansible-vault encrypt host_vars/nueva-maquina.yml

# Descifrar temporalmente
ansible-vault decrypt host_vars/trastero02.yml
```

### Añadir una máquina nueva

```bash
# 1. Crear host_vars con contraseña
echo "ansible_ssh_pass: MiPassword" > host_vars/nueva-maquina.yml

# 2. Cifrar
ansible-vault encrypt host_vars/nueva-maquina.yml

# 3. Añadir al inventario
# Editar inventory/hosts.yml y agregar bajo home: o similar
```

## Estructura

```
/mnt/scripts/infra/ansible/
├── ansible.cfg              # Config general (forks=10, vault, etc.)
├── inventory/
│   └── hosts.yml            # Inventario (grupos: home, proxmox, oci)
├── host_vars/               # 🔒 Contraseñas cifradas (por host)
├── group_vars/              # Variables compartidas por grupo
│   └── proxmox/
│       ├── vars.yml         # Paquetes, docker_daemon_json, mergerfs_config
│       └── vault.yml        # 🔒 rclone.conf + smb.conf (AES256)
├── playbook.yml             # Playbook principal (8 roles)
├── .vault_pass              # 🔒 Password del vault (no commitear)
└── roles/
    ├── common/              # Base + extra packages, UFW condicional
    ├── ssh-hardening/       # SSH config variable-driven
    ├── docker/              # Docker Engine + daemon.json
    ├── rclone/              # Build PR#9191 + vault config + systemd
    ├── samba/               # Samba desde vault
    ├── scripts/             # Scripts de gestión
    ├── nvidia/              # CUDA drivers + container toolkit
    └── mergerfs/            # mergerfs + discos por ID
```


