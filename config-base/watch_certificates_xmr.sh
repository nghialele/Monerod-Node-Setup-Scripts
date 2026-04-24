#!/bin/bash

set -u

# The Domain Name of the Server
DOMAIN_NAME="DOMAINNAME"

# Directory where Caddy stores certificates
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN_NAME}"

# Directory where monero stores certificates
MONERO_DIR="/var/lib/monero/certificates"

# Interval in seconds to check for changes
POLL_INTERVAL=300

CERT_KEY="${CERT_DIR}/${DOMAIN_NAME}.key"
CERT_CRT="${CERT_DIR}/${DOMAIN_NAME}.crt"
MONERO_KEY="${MONERO_DIR}/${DOMAIN_NAME}.key"
MONERO_CRT="${MONERO_DIR}/${DOMAIN_NAME}.crt"

COLOR_RESET='\033[0m'
COLOR_DIM='\033[2m'
COLOR_RED='\033[31m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_BLUE='\033[34m'
COLOR_CYAN='\033[36m'

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_info() {
    printf "%b[%s] [INFO]%b %s\n" "$COLOR_BLUE" "$(timestamp)" "$COLOR_RESET" "$1"
}

log_ok() {
    printf "%b[%s] [ OK ]%b %s\n" "$COLOR_GREEN" "$(timestamp)" "$COLOR_RESET" "$1"
}

log_warn() {
    printf "%b[%s] [WARN]%b %s\n" "$COLOR_YELLOW" "$(timestamp)" "$COLOR_RESET" "$1"
}

log_error() {
    printf "%b[%s] [FAIL]%b %s\n" "$COLOR_RED" "$(timestamp)" "$COLOR_RESET" "$1" >&2
}

log_detail() {
    printf "%b           %s%b\n" "$COLOR_DIM" "$1" "$COLOR_RESET"
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "This service must run as root."
        exit 1
    fi
}

ensure_directory() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        log_info "Creating missing directory: $dir_path"
        mkdir -p "$dir_path"
    fi
}

wait_for_source_files() {
    log_info "Waiting for certificate source files to become available."
    log_detail "Watching ${CERT_DIR}"

    while true; do
        if [ -s "$CERT_KEY" ] && [ -s "$CERT_CRT" ]; then
            log_ok "Source certificate files detected."
            return 0
        fi

        if [ ! -d "$CERT_DIR" ]; then
            log_warn "Source certificate directory not found yet: $CERT_DIR"
        else
            [ ! -s "$CERT_KEY" ] && log_warn "Missing or empty private key: $CERT_KEY"
            [ ! -s "$CERT_CRT" ] && log_warn "Missing or empty certificate: $CERT_CRT"
        fi

        sleep "$POLL_INTERVAL"
    done
}

files_differ() {
    local source_file="$1"
    local target_file="$2"

    if [ ! -s "$source_file" ]; then
        return 1
    fi

    if [ ! -s "$target_file" ]; then
        return 0
    fi

    if ! cmp -s "$source_file" "$target_file"; then
        return 0
    fi

    return 1
}

sync_file() {
    local source_file="$1"
    local target_file="$2"
    local label="$3"

    if [ ! -s "$source_file" ]; then
        log_warn "Skipping ${label}; source file missing or empty: $source_file"
        return 1
    fi

    install -m 640 "$source_file" "$target_file"
    log_ok "Synced ${label}."
    log_detail "${source_file} -> ${target_file}"
    return 0
}

restart_monerod() {
    log_info "Restarting monerod to load updated TLS material."

    if systemctl restart monerod; then
        log_ok "monerod restarted successfully."
    else
        log_error "Failed to restart monerod."
        return 1
    fi

    return 0
}

main_loop() {
    local update_needed=false

    while true; do
        update_needed=false

        if files_differ "$CERT_KEY" "$MONERO_KEY"; then
            log_info "Private key update detected."
            update_needed=true
        fi

        if files_differ "$CERT_CRT" "$MONERO_CRT"; then
            log_info "Certificate update detected."
            update_needed=true
        fi

        if [ "$update_needed" = true ]; then
            log_info "Synchronizing certificate assets for ${DOMAIN_NAME}."

            if ! sync_file "$CERT_KEY" "$MONERO_KEY" "private key"; then
                log_warn "Private key sync did not complete."
            fi

            if ! sync_file "$CERT_CRT" "$MONERO_CRT" "certificate"; then
                log_warn "Certificate sync did not complete."
            fi

            chown monero:monero "$MONERO_KEY" "$MONERO_CRT" 2>/dev/null || {
                log_error "Failed to set ownership on synced certificate files."
                sleep "$POLL_INTERVAL"
                continue
            }

            log_ok "Ownership updated for Monero certificate files."

            if ! restart_monerod; then
                sleep "$POLL_INTERVAL"
                continue
            fi
        else
            log_info "No certificate changes detected."
        fi

        sleep "$POLL_INTERVAL"
    done
}

require_root
ensure_directory "$MONERO_DIR"

log_info "Monero certificate watcher started."
log_detail "Domain: ${DOMAIN_NAME}"
log_detail "Source: ${CERT_DIR}"
log_detail "Target: ${MONERO_DIR}"
log_detail "Poll interval: ${POLL_INTERVAL}s"

wait_for_source_files
main_loop
