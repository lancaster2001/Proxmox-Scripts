#! /bin/env bash
set -e #exit on error
# Colors for output
YELLOW="\e[33m"
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

log() {
    echo -e "${YELLOW}$1${NC}"
}
success() {
    echo -e "${GREEN}$1${NC}"
}
error() {
    echo -e "${RED}$1${NC}"
}

log "This script will bind an SMB share into your Plex LXC container on Proxmox."

# Step 1: Get Plex container ID
while [ -z "$plex_ctid" ]; do
    log "Please enter your Plex LXC container ID (e.g., 101):"
    read plex_ctid
done

# Step 2: Get path to mounted SMB share
default_smb_path="/mnt/SMB/Movies"
log -e "Enter the Proxmox path where the SMB share is mounted (Default: $default_smb_path):"
read smb_path
if [ -z "$smb_path" ]; then
    smb_path="$default_smb_path"
fi

# Step 3: Get desired mount point in the Plex container
default_plex_mount="/mnt/Movies"
log -e "Enter the path inside the Plex container where the SMB share should be mounted (Default: $default_plex_mount):"
read plex_mount
if [ -z "$plex_mount" ]; then
    plex_mount="$default_plex_mount"
fi

# Step 4: Stop the container
log "Stopping Plex container $plex_ctid..."
pct stop "$plex_ctid"

# Step 5: Add mount point to container config
config_file="/etc/pve/lxc/$plex_ctid.conf"
mp_entry="mp0: $smb_path,mp=$plex_mount"

# Check if mp0 already exists
if grep -q "^mp0:" "$config_file"; then
    log "An mp0 entry already exists in $config_file. Skipping config change."
else
    success "Adding mount point to $config_file:"
    success "$mp_entry"
    echo "$mp_entry" >> "$config_file"
fi

# Step 4: Update /etc/fstab to include x-systemd.requires
echo -e "\nUpdating /etc/fstab to ensure SMB mount is ready before container starts..."

# Extracting fstab fields from the existing line if present
fstab_file="/etc/fstab"
escaped_smb_path=$(echo "$smb_path" | sed 's/\//\\\//g')
current_fstab_line=$(grep "[[:space:]]$escaped_smb_path[[:space:]]" "$fstab_file")

if [ -n "$current_fstab_line" ]; then
    echo "Found existing fstab entry:"
    echo "$current_fstab_line"

    # Modify line with required systemd directive
    updated_fstab_line=$(echo "$current_fstab_line" | sed "s/x-systemd.automount/&,x-systemd.requires=container@${plex_ctid}.service/")

    echo "Updating fstab entry to:"
    echo "$updated_fstab_line"

    # Escape slashes for replacement
    escaped_current_line=$(printf '%s\n' "$current_fstab_line" | sed -e 's/[\/&]/\\&/g')
    escaped_updated_line=$(printf '%s\n' "$updated_fstab_line" | sed -e 's/[\/&]/\\&/g')

    # Replace in /etc/fstab
    sed -i "s/$escaped_current_line/$escaped_updated_line/" "$fstab_file"
else
    echo "No existing fstab entry for $smb_path found. Please manually verify or create it using:"
    echo "//<SMB_IP>/<share> $smb_path cifs credentials=/path/to/creds,vers=3.1.1,iocharset=utf8,_netdev,x-systemd.automount,x-systemd.requires=container@${plex_ctid}.service,nofail 0 0"
fi

# Step 6: Start the container
success "Starting Plex container $plex_ctid..."
pct start "$plex_ctid"

# Step 7: Verify the mount
log "Checking if the mount exists inside the container..."
pct exec "$plex_ctid" -- ls "$plex_mount"

success "Done! If you saw your movie files listed above, the bind was successful."
