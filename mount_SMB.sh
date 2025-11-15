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

log "This script is for mounting an SMB share"

# Get Proxmox username
while [ -z "$proxmox_username" ]; do
    log "Please enter your Proxmox username:"
    read proxmox_username
done

# Get Proxmox password (hidden input)
while [ -z "$proxmox_password" ]; do
    log "Please enter your Proxmox password:"
    read -s proxmox_password
    echo
done

#Get SMB version
SMB_version_default="3.1.1"
log "Please enter your SMB version (Default: $SMB_version_default)\nLeave blank for default"
read SMB_version
if [ -z "$SMB_version" ]; then
    SMB_version="$SMB_version_default"
fi

#get SMB ip
SMB_ip_default="192.168.55.111"
log "Please enter your SMB storage ip (Default: $SMB_ip_default)\nLeave blank for default"
read SMB_ip 
if [ -z "$SMB_ip" ]; then
    SMB_ip="$SMB_ip_default"
fi

#get SMB Name
SMB_dir_default="Movies"
log "Please enter your SMB Name (Default: $SMB_dir_default)\nLeave blank for default"
read SMB_dir
if [ -z "$SMB_dir" ]; then
    SMB_dir="$SMB_dir_default"
fi

#Get proxmox destination location
proxmox_dir_default="/mnt/SMB/$SMB_dir"
log "Please enter the location in proxmox where you SMB will be mounted (Default: $proxmox_dir_default)\nLeave blank for default"
read proxmox_dir
if [ -z "$proxmox_dir" ]; then
    proxmox_dir="$proxmox_dir_default"
fi

# Create mount directory if it doesn't exist
mkdir -p "$proxmox_dir"

# Create .smbcredentials file
credentials_file="/root/.smbcredentials_$SMB_dir"
echo "username=$proxmox_username" > "$credentials_file"
echo "password=$proxmox_password" >> "$credentials_file"
chmod 600 "$credentials_file"

# Mount Proxmox SMB location to Plex
mount -t cifs -o credentials="$credentials_file",vers="$SMB_version" "\\\\$SMB_ip\\$SMB_dir" "$proxmox_dir"

# Check mount result
if mountpoint -q "$proxmox_dir"; then
    success "SMB share mounted successfully at $proxmox_dir"
else
    error "Failed to mount SMB share"
fi

# Add to /etc/fstab if not already present
fstab_entry="//${SMB_ip}/${SMB_dir} ${proxmox_dir} cifs credentials=${credentials_file},vers=${SMB_version},iocharset=utf8,_netdev,x-systemd.automount,nofail 0 0"

if ! grep -Fxq "$fstab_entry" /etc/fstab; then
    echo "$fstab_entry" >> /etc/fstab
    echo "Added to /etc/fstab for persistent mounting on boot"
else
    log "Entry already exists in /etc/fstab"
fi
