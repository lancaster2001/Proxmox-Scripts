#!/bin/env bash

set -e # Exit on error

# Colors for output
YELLOW="\e[33m"
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

log() {
    echo -e "${YELLOW}[LOG]${NC} $1"
}
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
error() {
    echo -e "${RED}$1${NC}"
}

log "This script will bind an SMB share into your Plex LXC container on Proxmox and ensure the SMB mount is ready before the container starts."

# Step 1: Get Plex container ID
while [ -z "$plex_ctid" ]; do
    log "Please enter your Plex LXC container ID (e.g., 101):"
    read plex_ctid
done

# Step 2: Get path to mounted SMB share
default_smb_path="/mnt/SMB/Movies"
log "Enter the Proxmox path where the SMB share is mounted (Default: $default_smb_path):"
read smb_path
if [ -z "$smb_path" ]; then
    smb_path="$default_smb_path"
fi

# Step 3: Get desired mount point in the Plex container
default_plex_mount="/mnt/Movies"
log "Enter the path inside the Plex container where the SMB share should be mounted (Default: $default_plex_mount):"
read plex_mount
if [ -z "$plex_mount" ]; then
    plex_mount="$default_plex_mount"
fi

# Step 4: Create systemd mount unit
unit_name="$(echo "$smb_path" | sed 's|^/||; s|/|-|g').mount"
unit_path="/etc/systemd/system/$unit_name"

log "Creating systemd mount unit: $unit_path"

cat <<EOF > "$unit_path"
[Unit]
Description=Mount SMB share $smb_path
After=network-online.target
Before=container@${plex_ctid}.service
Wants=network-online.target

[Mount]
What=//192.168.55.121/Movies
Where=$smb_path
Type=cifs
Options=credentials=/root/.smbcredentials_Movies,vers=3.1.1,iocharset=utf8,_netdev,nofail

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$smb_path"

# Reload systemd and enable the mount
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now "$unit_name"
success "Systemd mount unit created and enabled."

# Step 5: Stop the container
log "Stopping Plex container $plex_ctid..."
pct stop "$plex_ctid"

# Step 6: Add mount point to container config
config_file="/etc/pve/lxc/$plex_ctid.conf"
mp_entry="mp0: $smb_path,mp=$plex_mount"

if grep -q "^mp0:" "$config_file"; then
    log "An mp0 entry already exists in $config_file. Skipping config change."
else
    log "Adding mount point to $config_file:"
    echo "$mp_entry"
    echo "$mp_entry" >> "$config_file"
    success "Mount point added to container config."
fi

# Step 7: Start the container
log "Starting Plex container $plex_ctid..."
pct start "$plex_ctid"

# Step 8: Verify the mount
log "Checking if the mount exists inside the container..."
if pct exec "$plex_ctid" -- ls "$plex_mount"; then
    success "Mount verified inside the container."
else
    error "Mount point $plex_mount not found in container."
fi

success "Done! SMB share is now reliably mounted before the container starts."
