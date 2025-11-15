#!/usr/bin/env bash
#
# Script from: https://gist.github.com/NorkzYT/14449b247dae9ac81ba4664564669299
#
# proxmox-lxc-cifs-share.sh
#
# Mount a CIFS/SMB share on a Proxmox VE host and bind-mount it into
# one or more unprivileged LXC containers with dynamic UID/GID mapping.
#
# Usage:
#   proxmox-lxc-cifs-share.sh [--config FILE] [--add]
#       [--containers IDS] [--users NAMES] [--noserverino] [--help]
#
# Compatible with Proxmox VE 7–8 on Debian 12+.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]
Options:
  --config FILE      Read all parameters from FILE.
  --add              Only bind into containers; skip host mount.
  --containers IDS   Comma-separated LXC IDs (e.g. 105,106).
  --users NAMES      Comma-separated usernames matching each ID.
  --noserverino      Disable CIFS “serverino” option.
  --help             Show this help and exit.
Examples:
  # Interactive:
  sudo $0
  # Bind into two containers:
  sudo $0 --add --containers 105,106 --users ubuntu,svcuser
  # From config file:
  sudo $0 --config myshare.conf --add
EOF
  exit 0
}

list_lxc_ids() {
  pct list | awk 'NR>1 {print $1}'
}

list_usernames() {
  local id=$1
  pct status "$id" &>/dev/null || error_exit "LXC $id not found"
  pct exec "$id" -- getent passwd | cut -d: -f1
}

validate_prerequisites() {
  (( EUID == 0 )) || error_exit "Run as root or via sudo"
  command -v pct         >/dev/null 2>&1 || error_exit "'pct' not found"
  command -v mount.cifs  >/dev/null 2>&1 || error_exit "Install cifs-utils"
  command -v systemd-escape \
                          >/dev/null 2>&1 || error_exit "Install systemd"
}

load_config() {
  [[ -f $config_file ]] || error_exit "Config file '$config_file' missing"
  source "$config_file"
}

prompt_share_settings() {
  echo "=== Share Settings ==="
  read -rp "Folder under /mnt/lxc_shares (e.g. nas_rwx): " folder_name
  read -rp "CIFS host (IP/DNS): "                          cifs_host
  read -rp "Share name: "                                  share_name
  read -rp "SMB username: "                                smb_username
  read -rs -p "SMB password: "                             smb_password
  echo
}

prompt_containers_and_users() {
  echo "Available LXC IDs:"
  list_lxc_ids
  read -rp "LXC IDs (comma-separated): " containers
  echo

  echo "Usernames in ${containers%%,*}:"
  list_usernames "${containers%%,*}"
  read -rp "Usernames (comma-separated): " users
  echo
}

prompt_generate_config() {
  read -rp "Generate config file? [y/N]: " gen
  if [[ $gen =~ ^[Yy]$ ]]; then
    while true; do
      read -rp "Config path [./share.conf]: " cfg
      cfg=${cfg:-./share.conf}
      if [[ -d $cfg ]]; then
        echo "ERROR: '$cfg' is a directory; please specify a file name."
        continue
      fi
      break
    done
    {
      echo "folder_name=$folder_name"
      echo "cifs_host=$cifs_host"
      echo "share_name=$share_name"
      echo "smb_username=$smb_username"
      echo "smb_password=$smb_password"
      echo "containers=$containers"
      echo "users=$users"
    } >"$cfg"
    echo "Config saved to $cfg"
  fi
}

parse_flags() {
  NOSERVERINO=0
  ADD_MODE=0
  config_file=""
  containers=""
  users=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --noserverino) NOSERVERINO=1; shift ;;
      --add)         ADD_MODE=1;    shift ;;
      --config)      config_file=$2; shift 2 ;;
      --containers)  containers=$2;   shift 2 ;;
      --users)       users=$2;        shift 2 ;;
      --help)        show_help ;;
      *)             error_exit "Unknown option: $1" ;;
    esac
  done
}

parse_lists() {
  IFS=, read -ra CTIDS <<<"$containers"
  IFS=, read -ra USERS <<<"$users"
  (( ${#CTIDS[@]} == ${#USERS[@]} )) \
    || error_exit "Count of containers != count of users"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

validate_prerequisites
parse_flags "$@"

if [[ -n $config_file ]]; then
  load_config
else
  prompt_share_settings
  [[ -n $containers && -n $users ]] \
    || prompt_containers_and_users
  prompt_generate_config
fi

parse_lists

# Primary container for UID/GID mapping
primary_id="${CTIDS[0]}"
primary_user="${USERS[0]}"

pct status "$primary_id" &>/dev/null || error_exit "LXC $primary_id not found"
container_uid=$(pct exec "$primary_id" -- id -u "$primary_user" 2>/dev/null) \
  || error_exit "User $primary_user not in $primary_id"
container_gid=$(pct exec "$primary_id" -- id -g "$primary_user")

idmap_offset=$(pct config "$primary_id" | awk '/^lxc.idmap: u 0 /{print $4; exit}')
idmap_offset=${idmap_offset:-100000}

host_uid=$(( idmap_offset + container_uid ))
host_gid=$(( idmap_offset + container_gid ))

mnt_root="/mnt/lxc_shares/${folder_name}"

if (( ADD_MODE == 0 )); then
  ensure_mount() {
    mkdir -p "$mnt_root"
    opts="_netdev,x-systemd.automount,noatime,nobrl"
    opts+=",uid=${host_uid},gid=${host_gid},dir_mode=0770,file_mode=0770"
    opts+=",username=${smb_username},password=${smb_password},iocharset=utf8"
    (( NOSERVERINO )) && opts+=",noserverino"
    entry="//${cifs_host}/${share_name} ${mnt_root} cifs ${opts} 0 0"

    grep -q "^//${cifs_host}/${share_name} ${mnt_root} " /etc/fstab \
      && sed -i "\|^//${cifs_host}/${share_name} ${mnt_root} .*|d" /etc/fstab

    echo "$entry" >>/etc/fstab
    systemctl daemon-reload
    base=$(systemd-escape --path "$mnt_root")
    systemctl stop "${base}.automount" "${base}.mount" >/dev/null 2>&1 || true
    mount "$mnt_root"
  }

  if grep -q "^//${cifs_host}/${share_name} ${mnt_root} " /etc/fstab; then
    read -rp "Host mount exists; skip host-side work? [Y/n]: " yn
    [[ $yn =~ ^[Nn]$ ]] && ensure_mount
  else
    ensure_mount
  fi
fi

for i in "${!CTIDS[@]}"; do
  id=${CTIDS[i]}

  echo "Stopping LXC $id…"
  pct stop "$id"
  while [[ $(pct status "$id") != "status: stopped" ]]; do sleep 1; done

  echo "Binding into $id → /mnt/$folder_name"
  pct set "$id" --mp0 "${mnt_root},mp=/mnt/${folder_name},backup=0"

  echo "Starting LXC $id…"
  pct start "$id"
done

echo
echo "Verification:"
for id in "${CTIDS[@]}"; do
  if pct exec "$id" -- test -d "/mnt/${folder_name}"; then
    echo "  ↳ $id: OK"
  else
    echo "  ↳ $id: FAILED"
  fi
done

echo
echo "✅  All done."
