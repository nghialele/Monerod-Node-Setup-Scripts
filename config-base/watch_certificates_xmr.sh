#!/bin/bash
# Keeps monerod's TLS files in sync with whatever Caddy got from Let's Encrypt.
# If the cert changes, it updates the copy and restarts monerod.
# If monerod is stopped but the certs are fine, it starts monerod.
# Basically: a very diligent personal assistant for your node.

set -u

# The Domain Name of the Server
DOMAIN_NAME="@@DOMAIN@@"
# Directory where Caddy stores certificates
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN_NAME}"
# Directory where monero stores certificates
MONERO_DIR="/var/lib/monero/certificates"
# Interval in seconds to check for changes
POLL_INTERVAL=60

while true; do
    # Paths to certificate and key files
    CERT_KEY="$CERT_DIR/${DOMAIN_NAME}.key"
    MONERO_KEY="$MONERO_DIR/${DOMAIN_NAME}.key"
    CERT_CRT="$CERT_DIR/${DOMAIN_NAME}.crt"
    MONERO_CRT="$MONERO_DIR/${DOMAIN_NAME}.crt"

    UPDATE_NEEDED=false

    # New or changed key?
    if [ -s "$CERT_KEY" ]; then
        if [ ! -s "$MONERO_KEY" ] || ! cmp -s "$CERT_KEY" "$MONERO_KEY"; then
            UPDATE_NEEDED=true
        fi
    fi

    # New or changed certificate?
    if [ -s "$CERT_CRT" ]; then
        if [ ! -s "$MONERO_CRT" ] || ! cmp -s "$CERT_CRT" "$MONERO_CRT"; then
            UPDATE_NEEDED=true
        fi
    fi

    if [ "$UPDATE_NEEDED" = true ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") certificate changed: syncing to $MONERO_DIR and restarting monerod."
        systemctl stop monerod 2>/dev/null || true
        cp "$CERT_KEY" "$MONERO_KEY"
        cp "$CERT_CRT" "$MONERO_CRT"
        chown -R monero:monero "$MONERO_DIR"
        systemctl start monerod
    elif [ -s "$CERT_KEY" ] && [ -s "$CERT_CRT" ] \
         && ! systemctl is-active --quiet monerod; then
        # Certs are current but monerod is sitting in the dark. Turn the lights on.
        echo "$(date +"%Y-%m-%d %H:%M:%S") certificates up to date but monerod is not running: starting it."
        systemctl start monerod
    fi

    sleep "$POLL_INTERVAL"
done
