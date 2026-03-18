#!/bin/bash

set -e

echo "SETTING UP. This may take a while..."

LOG_FILE = "/var/log/device_setup.log"
STATE_FILE = "/var/log/device_setup.state"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a $LOG_FILE
}

mark_done() {
    echo "$1" >> $STATE_FILE
}

is_done() {
    grep -q "^$1$" $STATE_FILE 2>/dev/null
}

setup_packages() {
    local STEP="INSTALL_PACKAGES"
    if is_done $STEP; then
        log "Packages already installed. Skipping."
        return
    fi

    log "Installing dependencies..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y python3-pip python3-venv nginx postgresql git avahi-daemon
    sudo systemctl enable avahi-daemon
    sudo systemctl start avahi-daemon
}

log "=== Starting Device Setup ==="
setup_packages
log "Device setup completed successfully."