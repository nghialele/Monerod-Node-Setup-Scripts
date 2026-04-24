#!/bin/bash

set -u

SCRIPT_VERSION="1.0.1"

TITLE="Monerod setup script for Debian-based systems"
AUTHOR="Jack Doggett"
AUTHOR_EMAIL="jack@doggett.tech"

MONERO_USER="monero"
MONERO_GROUP="monero"
MONERO_HOME="/var/lib/monero"
MONERO_LOG_DIR="/var/log/monero"
MONERO_ETC_DIR="/etc/monero"
MONERO_CERT_DIR="${MONERO_HOME}/certificates"
MONERO_BIN_DIR="/usr/local/bin"

ROOT_DIR="$(pwd)"
CONFIG_DIR="${ROOT_DIR}/config-base"

MONEROD_CONF_TEMPLATE="${CONFIG_DIR}/monerod.conf"
MONEROD_SERVICE_TEMPLATE="${CONFIG_DIR}/monerod.service"
INDEX_TEMPLATE="${CONFIG_DIR}/index.html"
CERT_WATCHER_TEMPLATE="${CONFIG_DIR}/watch_certificates_xmr.sh"
CERT_WATCHER_SERVICE_TEMPLATE="${CONFIG_DIR}/cert-watcher-xmr.service"

WORK_MONEROD_CONF="${ROOT_DIR}/monerod.conf"
WORK_MONEROD_SERVICE="${ROOT_DIR}/monerod.service"
WORK_INDEX_HTML="${ROOT_DIR}/index.html"
WORK_CERT_WATCHER="${ROOT_DIR}/watch_certificates_xmr.sh"

HTTP_PORT=80
HTTPS_PORT=443
P2P_PORT=18080
RPC_PORT=18089
ZMQ_PORT=18083
TOR_P2P_PORT=18084

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
MAGENTA="$(printf '\033[35m')"
CYAN="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
DIM="$(printf '\033[2m')"
RESET="$(printf '\033[0m')"

if [ ! -t 1 ]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    BOLD=""
    DIM=""
    RESET=""
fi

https=false
tor=false
prune=false
full_mem=false
banlist=false
zmq=false
ipv4=true
ipv6=false
high_memory=false

dns_name=""
server_location=""
owner_name=""
owner_email=""
onion_address=""
release=""
download_url=""
install_command=""

# Global return value for ask_text
ASK_RESULT=""

cleanup() {
    :
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

banner() {
    printf "\n${BOLD}${MAGENTA}╔════════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}${MAGENTA}║${RESET} ${BOLD}%-56s${RESET} ${BOLD}${MAGENTA}║${RESET}\n" "$TITLE"
    printf "${BOLD}${MAGENTA}║${RESET} ${DIM}%-56s${RESET} ${BOLD}${MAGENTA}║${RESET}\n" "Author: ${AUTHOR} <${AUTHOR_EMAIL}>"
    printf "${BOLD}${MAGENTA}║${RESET} ${DIM}%-56s${RESET} ${BOLD}${MAGENTA}║${RESET}\n" "Version: ${SCRIPT_VERSION}"
    printf "${BOLD}${MAGENTA}╚════════════════════════════════════════════════════════════╝${RESET}\n\n"
}

log_info() {
    printf "${CYAN}▶${RESET} %s\n" "$1"
}

log_ok() {
    printf "${GREEN}✔${RESET} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}⚠${RESET} %s\n" "$1"
}

log_error() {
    printf "${RED}✖${RESET} %s\n" "$1" >&2
}

section() {
    printf "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${BOLD}${BLUE}  %s${RESET}\n" "$1"
    printf "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

die() {
    log_error "$1"
    exit 1
}

run_cmd() {
    local description="$1"
    shift

    log_info "$description"
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        die "Failed: $description"
    fi
    log_ok "$description"
}

spinner_wait() {
    local seconds="$1"
    local message="$2"
    local i=0
    local frames='|/-\'
    while [ $i -lt "$seconds" ]; do
        local frame_index=$((i % 4))
        local frame
        frame="$(printf '%s' "$frames" | cut -c $((frame_index + 1)))"
        printf "${MAGENTA}%s${RESET} %s ${DIM}(%ss / %ss)${RESET}\r" "$frame" "$message" "$((i + 1))" "$seconds"
        sleep 1
        i=$((i + 1))
    done
    printf "                                                                                \r"
}

# Ask a yes/no question; returns 0 for yes, 1 for no.
# Usage:  confirm "Prompt text" [default Y|N]
confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local reply=""

    while true; do
        if [ "$default" = "Y" ]; then
            printf "%s ${DIM}[Y/n]${RESET}: " "$prompt"
        else
            printf "%s ${DIM}[y/N]${RESET}: " "$prompt"
        fi

        read -r reply || exit 1

        if [ -z "$reply" ]; then
            reply="$default"
        fi

        case "$reply" in
            Y|y|Yes|yes) return 0 ;;
            N|n|No|no)   return 1 ;;
            *) log_warn "Please answer Y or N." ;;
        esac
    done
}

# Prompt for a non-empty string.  Result is stored in global $ASK_RESULT.
# Usage:  ask_text "Prompt text"
ask_text() {
    local prompt="$1"
    ASK_RESULT=""

    while true; do
        printf "%s: " "$prompt"
        read -r ASK_RESULT || exit 1
        if [ -n "$ASK_RESULT" ]; then
            return 0
        fi
        log_warn "This value cannot be empty."
    done
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

require_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "You must run this installer as root."
}

require_templates() {
    [ -f "$MONEROD_CONF_TEMPLATE" ]         || die "Missing template: $MONEROD_CONF_TEMPLATE"
    [ -f "$MONEROD_SERVICE_TEMPLATE" ]      || die "Missing template: $MONEROD_SERVICE_TEMPLATE"
    [ -f "$INDEX_TEMPLATE" ]                || die "Missing template: $INDEX_TEMPLATE"
    [ -f "$CERT_WATCHER_TEMPLATE" ]         || die "Missing template: $CERT_WATCHER_TEMPLATE"
    [ -f "$CERT_WATCHER_SERVICE_TEMPLATE" ] || die "Missing template: $CERT_WATCHER_SERVICE_TEMPLATE"
}

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

detect_architecture() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64)              release="linux64"   ;;
        i686|i386)           release="linux32"   ;;
        aarch32|arm32|armv7*) release="linuxarm7" ;;
        aarch64|arm64|armv8*) release="linuxarm8" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac

    download_url="https://downloads.getmonero.org/${release}"

    log_ok "Detected architecture : ${arch}"
    log_ok "Monero release channel: ${release}"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        install_command="apt-get"
        log_ok "Package manager detected: apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        install_command="dnf"
        log_warn "Package manager detected: dnf"
        log_warn "Fedora-based setups may need manual SELinux adjustments."
    else
        die "Neither apt-get nor dnf was found."
    fi
}

detect_memory_profile() {
    local memory_count
    memory_count="$(awk '/MemTotal/ { printf "%.0f", $2/1024 }' /proc/meminfo)"

    log_info "Memory detected: ${memory_count} MiB"

    if [ "$memory_count" -ge 2861 ]; then
        high_memory=true
        log_ok "High-memory profile available — full RandomX dataset is an option."
    else
        high_memory=false
        log_warn "Standard-memory profile. Full RandomX dataset will stay disabled."
    fi
}

# ---------------------------------------------------------------------------
# Interactive wizard
# ---------------------------------------------------------------------------

preflight_notice() {
    section "Preflight"
    printf "${DIM}Before you continue, make sure your firewall and DNS are ready.${RESET}\n\n"
    printf "  ${CYAN}•${RESET} P2P port  : ${BOLD}%s${RESET}\n"   "$P2P_PORT"
    printf "  ${CYAN}•${RESET} RPC port  : ${BOLD}%s${RESET}\n"   "$RPC_PORT"
    printf "  ${CYAN}•${RESET} ZMQ port  : ${BOLD}%s${RESET} ${DIM}(optional)${RESET}\n" "$ZMQ_PORT"
    printf "  ${CYAN}•${RESET} HTTP      : ${BOLD}%s${RESET} ${DIM}(needed for HTTPS cert provisioning)${RESET}\n" "$HTTP_PORT"
    printf "  ${CYAN}•${RESET} HTTPS     : ${BOLD}%s${RESET} ${DIM}(needed for TLS website / RPC)${RESET}\n" "$HTTPS_PORT"
    printf "\n"
    printf "If you want HTTPS, your domain must already point to this server.\n\n"

    confirm "Continue with installation?" "N" || {
        log_info "Installer exited by user."
        exit 0
    }
}

collect_configuration() {
    while true; do
        section "Configuration Wizard"

        # ---- HTTPS --------------------------------------------------------
        if confirm "Enable HTTPS for monerod RPC and public landing page?" "Y"; then
            https=true

            ask_text "HTTPS: Enter your domain name (DNS record)"
            dns_name="$ASK_RESULT"

            ask_text "HTTPS: Enter your server location (e.g. Frankfurt, DE)"
            server_location="$ASK_RESULT"

            ask_text "HTTPS: Enter contact name"
            owner_name="$ASK_RESULT"

            ask_text "HTTPS: Enter contact email"
            owner_email="$ASK_RESULT"
        else
            https=false
            dns_name=""
            server_location=""
            owner_name=""
            owner_email=""
        fi

        # ---- Tor ----------------------------------------------------------
        if confirm "Enable Tor hidden service access?" "Y"; then
            tor=true
        else
            tor=false
        fi

        # ---- Pruning ------------------------------------------------------
        if confirm "Prune the blockchain?" "Y"; then
            prune=true
        else
            prune=false
        fi

        # ---- RandomX full dataset -----------------------------------------
        full_mem=false
        if [ "$high_memory" = true ]; then
            if confirm "Use full RandomX dataset? (~2080 MiB RAM)" "N"; then
                full_mem=true
            fi
        fi

        # ---- Ban list -----------------------------------------------------
        if confirm "Use Boog900 community ban list? (recommended)" "Y"; then
            banlist=true
        else
            banlist=false
        fi

        # ---- ZMQ ----------------------------------------------------------
        if confirm "Enable ZMQ for P2Pool or external subscribers?" "N"; then
            zmq=true
        else
            zmq=false
        fi

        # ---- Network binding ----------------------------------------------
        if confirm "Bind to IPv4?" "Y"; then
            ipv4=true
        else
            ipv4=false
        fi

        if confirm "Bind to IPv6?" "N"; then
            ipv6=true
        else
            ipv6=false
        fi

        if [ "$ipv4" = false ] && [ "$ipv6" = false ]; then
            log_warn "At least one of IPv4 or IPv6 must be enabled. Please try again."
            continue
        fi

        show_configuration_summary

        if confirm "Does this configuration look correct?" "Y"; then
            break
        fi
    done
}

show_configuration_summary() {
    section "Configuration Summary"
    printf "  HTTPS enabled         : %s\n" "$https"
    if [ "$https" = true ]; then
        printf "  Domain                : %s\n" "$dns_name"
        printf "  Server location       : %s\n" "$server_location"
        printf "  Contact name          : %s\n" "$owner_name"
        printf "  Contact email         : %s\n" "$owner_email"
    fi
    printf "  Tor enabled           : %s\n" "$tor"
    printf "  Pruned blockchain     : %s\n" "$prune"
    printf "  Full RandomX dataset  : %s\n" "$full_mem"
    printf "  Boog900 ban list      : %s\n" "$banlist"
    printf "  ZMQ enabled           : %s\n" "$zmq"
    printf "  Bind IPv4             : %s\n" "$ipv4"
    printf "  Bind IPv6             : %s\n" "$ipv6"
}

# ---------------------------------------------------------------------------
# Installation steps
# ---------------------------------------------------------------------------

install_required_packages() {
    section "Installing Required Packages"

    run_cmd "Installing base dependencies (wget, bzip2)" "$install_command" install -y wget bzip2

    if [ "$https" = true ]; then
        run_cmd "Installing Caddy" "$install_command" install -y caddy
    fi

    if [ "$tor" = true ]; then
        run_cmd "Installing Tor" "$install_command" install -y tor
    fi
}

copy_templates_to_workspace() {
    section "Preparing Working Files"

    run_cmd "Copying monerod.conf template"    cp -f "$MONEROD_CONF_TEMPLATE"    "$WORK_MONEROD_CONF"
    run_cmd "Copying monerod.service template" cp -f "$MONEROD_SERVICE_TEMPLATE" "$WORK_MONEROD_SERVICE"

    if [ "$https" = true ]; then
        run_cmd "Copying index.html template"           cp -f "$INDEX_TEMPLATE"         "$WORK_INDEX_HTML"
        run_cmd "Copying certificate watcher template"  cp -f "$CERT_WATCHER_TEMPLATE"  "$WORK_CERT_WATCHER"
    fi
}

download_and_install_monero() {
    section "Downloading and Installing Monero"

    local temp_dir
    temp_dir="$(mktemp -d)" || die "Unable to create a temporary directory."

    log_info "Temporary working directory: $temp_dir"

    run_cmd "Downloading Monero binaries ($release)" \
        sh -c "cd '$temp_dir' && wget -O '$release' '$download_url'"

    run_cmd "Extracting archive" \
        sh -c "cd '$temp_dir' && tar -xjf '$release'"

    run_cmd "Removing downloaded archive" \
        rm -f "$temp_dir/$release"

    run_cmd "Installing Monero executables to ${MONERO_BIN_DIR}" \
        sh -c "cp -v '$temp_dir'/monero-*/monero* '$MONERO_BIN_DIR/'"

    run_cmd "Removing temporary directory" \
        rm -rf "$temp_dir"

    log_ok "Monero binaries are installed."
}

ensure_monerod_user() {
    section "Creating Monero System User and Directories"

    if ! getent group "$MONERO_GROUP" >/dev/null 2>&1; then
        run_cmd "Creating system group: ${MONERO_GROUP}" groupadd --system "$MONERO_GROUP"
    else
        log_info "System group '${MONERO_GROUP}' already exists — skipping."
    fi

    if ! id -u "$MONERO_USER" >/dev/null 2>&1; then
        run_cmd "Creating system user: ${MONERO_USER}" \
            useradd --system --home-dir "$MONERO_HOME" --gid "$MONERO_GROUP" "$MONERO_USER"
    else
        log_info "System user '${MONERO_USER}' already exists — skipping."
    fi

    run_cmd "Disabling interactive shell for ${MONERO_USER}" usermod -s /sbin/nologin "$MONERO_USER"
    run_cmd "Locking password for ${MONERO_USER}"            usermod -p '!' "$MONERO_USER"

    run_cmd "Creating ${MONERO_HOME}"     mkdir -p "$MONERO_HOME"
    run_cmd "Creating ${MONERO_LOG_DIR}"  mkdir -p "$MONERO_LOG_DIR"
    run_cmd "Creating ${MONERO_ETC_DIR}"  mkdir -p "$MONERO_ETC_DIR"

    if [ "$https" = true ]; then
        run_cmd "Creating ${MONERO_CERT_DIR}" mkdir -p "$MONERO_CERT_DIR"
    fi

    run_cmd "Setting ownership on ${MONERO_HOME}"    chown -R "${MONERO_USER}:${MONERO_GROUP}" "$MONERO_HOME"
    run_cmd "Setting permissions on ${MONERO_HOME}"  chmod 710 "$MONERO_HOME"

    if [ "$https" = true ]; then
        run_cmd "Setting permissions on ${MONERO_CERT_DIR}" chmod 710 "$MONERO_CERT_DIR"
    fi

    run_cmd "Setting ownership on ${MONERO_LOG_DIR}"   chown -R "${MONERO_USER}:${MONERO_GROUP}" "$MONERO_LOG_DIR"
    run_cmd "Setting permissions on ${MONERO_LOG_DIR}" chmod 710 "$MONERO_LOG_DIR"
    run_cmd "Setting ownership on ${MONERO_ETC_DIR}"   chown -R "${MONERO_USER}:${MONERO_GROUP}" "$MONERO_ETC_DIR"
    run_cmd "Setting permissions on ${MONERO_ETC_DIR}" chmod 710 "$MONERO_ETC_DIR"
}

configure_tor() {
    [ "$tor" = true ] || return 0

    section "Configuring Tor"

    {
        printf "\n## Tor Monero RPC HiddenService\n"
        printf "HiddenServiceDir /var/lib/tor/monerod\n"
        printf "HiddenServicePort 18084 127.0.0.1:18084    # P2P\n"
        printf "HiddenServicePort 18089 127.0.0.1:18089    # RPC\n"
        if [ "$zmq" = true ]; then
            printf "HiddenServicePort 18083 127.0.0.1:18083    # ZMQ\n"
        fi
        if [ "$https" = true ]; then
            printf "HiddenServicePort 80 127.0.0.1:8080        # website\n"
        fi
    } >> /etc/tor/torrc

    log_ok "Hidden service entries appended to /etc/tor/torrc"

    run_cmd "Enabling Tor service"  systemctl enable tor
    run_cmd "Starting Tor service"  systemctl start tor

    log_info "Waiting for Tor to initialise the hidden service…"
    spinner_wait 10 "Generating onion keys"

    run_cmd "Restarting Tor to finalise hidden service" systemctl restart tor

    log_info "Waiting for onion hostname file…"
    spinner_wait 10 "Reading onion hostname"

    if [ -f /var/lib/tor/monerod/hostname ]; then
        onion_address="$(cat /var/lib/tor/monerod/hostname)"
        log_ok "Onion address: ${BOLD}${onion_address}${RESET}"
    else
        die "Tor hostname file was not created. Check Tor logs."
    fi
}

configure_monerod_conf() {
    section "Configuring monerod.conf"

    local config_file="$WORK_MONEROD_CONF"

    if [ "$ipv4" = true ]; then
        sed -i 's/^#\(p2p-bind-ip=0\.0\.0\.0\)/\1/'   "$config_file"
        sed -i 's/^#\(rpc-bind-ip=0\.0\.0\.0\)/\1/'   "$config_file"
    fi

    if [ "$ipv6" = true ]; then
        sed -i 's/^#\(p2p-use-ipv6=true\)/\1/'              "$config_file"
        sed -i 's/^#\(p2p-bind-ipv6-address=::\)/\1/'       "$config_file"
        sed -i 's/^#\(rpc-use-ipv6=true\)/\1/'              "$config_file"
        sed -i 's/^#\(rpc-bind-ipv6-address=::\)/\1/'       "$config_file"
    fi

    if [ "$prune" = true ]; then
        sed -i 's/^#\(prune-blockchain=true\)/\1/' "$config_file"
    fi

    if [ "$banlist" = true ]; then
        sed -i 's/^#\(ban-list=\/etc\/monero\/ban_list.txt\)/\1/' "$config_file"
    fi

    if [ "$zmq" = true ]; then
        sed -i 's/^#\(zmq-pub=tcp:\/\/0.0.0.0:18083\)/\1/' "$config_file"
        sed -i 's/^\(no-zmq=true\)/#\1/'                   "$config_file"
    fi

    if [ "$https" = true ]; then
        sed -i 's/^#\(rpc-ssl-private-key=\/var\/lib\/monero\/certificates\/DOMAINNAME.key\)/\1/' "$config_file"
        sed -i 's/^#\(rpc-ssl-certificate=\/var\/lib\/monero\/certificates\/DOMAINNAME.crt\)/\1/' "$config_file"
        sed -i "s/DOMAINNAME/${dns_name}/g" "$config_file"
    fi

    if [ "$tor" = true ]; then
        sed -i 's/^#\(tx-proxy=tor,127.0.0.1:9050,disable_noise\)/\1/'         "$config_file"
        sed -i 's/^#\(anonymous-inbound=ONIONADDRESS:18084,127.0.0.1:18084\)/\1/' "$config_file"
        sed -i 's/^#\(pad-transactions=true\)/\1/'                              "$config_file"
        sed -i "s/ONIONADDRESS/${onion_address}/g" "$config_file"
    fi

    log_info "Active monerod.conf:"
    cat "$config_file"

    run_cmd "Installing monerod.conf"                  cp -f  "$config_file" "${MONERO_ETC_DIR}/monerod.conf"
    run_cmd "Setting ownership on monerod.conf"        chown "${MONERO_USER}:${MONERO_GROUP}" "${MONERO_ETC_DIR}/monerod.conf"
    run_cmd "Setting permissions on monerod.conf"      chmod 640 "${MONERO_ETC_DIR}/monerod.conf"
}

install_banlist_if_needed() {
    [ "$banlist" = true ] || return 0

    section "Installing Community Ban List"

    run_cmd "Downloading Boog900 ban list" \
        wget -O "${ROOT_DIR}/ban_list.txt" \
             "https://raw.githubusercontent.com/Boog900/monero-ban-list/main/ban_list.txt"

    run_cmd "Installing ban list"              cp -f "${ROOT_DIR}/ban_list.txt" "${MONERO_ETC_DIR}/ban_list.txt"
    run_cmd "Setting ownership on ban list"    chown "${MONERO_USER}:${MONERO_GROUP}" "${MONERO_ETC_DIR}/ban_list.txt"
    run_cmd "Setting permissions on ban list"  chmod 640 "${MONERO_ETC_DIR}/ban_list.txt"
}

configure_monerod_service() {
    section "Configuring monerod Systemd Service"

    local service_file="$WORK_MONEROD_SERVICE"

    if [ "$full_mem" = true ]; then
        sed -i 's/^#\(Environment="MONERO_RANDOMX_FULL_MEM=1"\)/\1/' "$service_file"
        log_ok "Full RandomX memory mode enabled in service unit."
    fi

    run_cmd "Installing monerod.service"  cp -f "$service_file" /etc/systemd/system/monerod.service
    run_cmd "Reloading systemd daemon"    systemctl daemon-reload
    run_cmd "Enabling monerod.service"    systemctl enable monerod.service
}

# ---------------------------------------------------------------------------
# Website + Caddy
# ---------------------------------------------------------------------------

# Toggle an optional HTML block in the working index.html.
# Usage:  _toggle_html_block <MARKER_BASE> <enabled true|false>
#
# The template wraps optional content between two marker lines:
#   MARKER_BASE_START
#   ... html content ...
#   MARKER_BASE_END
#
# When enabled  → marker lines are deleted (content becomes visible).
# When disabled → START marker is replaced with <!--, END with -->
#                 (content becomes an HTML comment, hidden from browser).
_toggle_html_block() {
    local marker_base="$1"
    local enabled="$2"
    local html_file="$WORK_INDEX_HTML"

    if [ "$enabled" = true ]; then
        sed -i "/${marker_base}_START/d"  "$html_file"
        sed -i "/${marker_base}_END/d"    "$html_file"
    else
        sed -i "s/${marker_base}_START/<!--/"  "$html_file"
        sed -i "s/${marker_base}_END/-->/"     "$html_file"
    fi
}

configure_website() {
    [ "$https" = true ] || return 0

    section "Configuring Public Node Website"

    local html_file="$WORK_INDEX_HTML"
    local site_dir="/srv/${dns_name}"

    run_cmd "Creating site directory: ${site_dir}" mkdir -p "$site_dir"

    # Node type
    if [ "$prune" = true ]; then
        sed -i "s/NODETYPE/Pruned/g" "$html_file"
    else
        sed -i "s/NODETYPE/Full/g" "$html_file"
    fi

    # Static placeholders
    sed -i "s/LOCATION/${server_location}/g" "$html_file"
    sed -i "s/OWNERNAME/${owner_name}/g"     "$html_file"
    sed -i "s/OWNEREMAIL/${owner_email}/g"   "$html_file"

    # ZMQ optional blocks (metric tile + endpoint card)
    _toggle_html_block "OPTIONAL_ZMQ_METRIC"   "$zmq"
    _toggle_html_block "OPTIONAL_ZMQ_ENDPOINT" "$zmq"

    # Tor optional blocks
    _toggle_html_block "OPTIONAL_TOR_P2P_ENDPOINT" "$tor"
    _toggle_html_block "OPTIONAL_TOR_RPC_ENDPOINT" "$tor"

    # Tor ZMQ is only shown when BOTH tor and zmq are enabled
    local tor_zmq=false
    if [ "$tor" = true ] && [ "$zmq" = true ]; then
        tor_zmq=true
    fi
    _toggle_html_block "OPTIONAL_TOR_ZMQ_ENDPOINT" "$tor_zmq"

    # Replace onion address if Tor is on
    if [ "$tor" = true ]; then
        sed -i "s/ONIONADDRESS/${onion_address}/g" "$html_file"
    fi

    # Replace domain last so it does not interfere with other substitutions
    sed -i "s/DOMAINNAME/${dns_name}/g" "$html_file"

    run_cmd "Installing landing page"              cp -f "$html_file" "$site_dir/index.html"
    run_cmd "Setting ownership on website files"   chown -R caddy:caddy "$site_dir"

    configure_caddy
    configure_certificate_watcher
}

configure_caddy() {
    section "Configuring Caddy"

    local caddy_config="/etc/caddy/Caddyfile"

    if [ -f "$caddy_config" ]; then
        run_cmd "Backing up existing Caddyfile" mv -f "$caddy_config" "${caddy_config}.old"
        log_warn "Previous Caddyfile saved as ${caddy_config}.old — merge any custom rules manually."
    fi

    {
        printf "%s {\n"              "$dns_name"
        printf "\troot * /srv/%s\n" "$dns_name"
        printf "\tfile_server\n"
        printf "}\n"
        printf "http://, https:// {\n"
        printf "\tredir https://%s\n" "$dns_name"
        printf "}\n"
        if [ "$tor" = true ]; then
            printf ":8080 {\n"
            printf "\troot * /srv/%s\n" "$dns_name"
            printf "\tfile_server\n"
            printf "\tbind 127.0.0.1\n"
            printf "}\n"
        fi
    } > "$caddy_config"

    log_info "Caddyfile written:"
    cat "$caddy_config"

    run_cmd "Restarting Caddy" systemctl restart caddy

    log_info "Waiting for Caddy to provision the TLS certificate…"
    spinner_wait 60 "Provisioning certificate via Let's Encrypt"
    log_ok "Certificate provisioning window complete."
}

configure_certificate_watcher() {
    section "Configuring TLS Certificate Watcher"

    sed -i "s/DOMAINNAME/${dns_name}/g" "$WORK_CERT_WATCHER"

    run_cmd "Installing certificate watcher script" \
        cp -f "$WORK_CERT_WATCHER" /usr/local/bin/watch_certificates_xmr.sh

    run_cmd "Installing certificate watcher service" \
        cp -f "$CERT_WATCHER_SERVICE_TEMPLATE" /etc/systemd/system/cert-watcher-xmr.service

    run_cmd "Making certificate watcher executable" \
        chmod +x /usr/local/bin/watch_certificates_xmr.sh

    run_cmd "Reloading systemd daemon"    systemctl daemon-reload
    run_cmd "Enabling certificate watcher"  systemctl enable cert-watcher-xmr.service
    run_cmd "Starting certificate watcher"  systemctl start  cert-watcher-xmr.service
}

# ---------------------------------------------------------------------------
# Final steps
# ---------------------------------------------------------------------------

start_services() {
    section "Starting Services"

    run_cmd "Starting monerod.service" systemctl start monerod.service

    if [ "$https" = true ]; then
        log_ok "Website and certificate watcher are running."
    fi
}

print_final_summary() {
    section "Installation Complete"

    printf "\n${GREEN}${BOLD}  ✦  Your Monero node is live.  ✦${RESET}\n\n"

    printf "  ${DIM}Useful paths${RESET}\n"
    printf "  ${CYAN}•${RESET} Config    : %s/monerod.conf\n"        "$MONERO_ETC_DIR"
    printf "  ${CYAN}•${RESET} Logs      : %s/\n"                    "$MONERO_LOG_DIR"
    printf "  ${CYAN}•${RESET} Data      : %s/\n"                    "$MONERO_HOME"
    printf "  ${CYAN}•${RESET} Service   : /etc/systemd/system/monerod.service\n"

    if [ "$https" = true ]; then
        printf "  ${CYAN}•${RESET} Website   : https://%s\n"         "$dns_name"
        printf "  ${CYAN}•${RESET} Site root : /srv/%s/\n"           "$dns_name"
        printf "  ${CYAN}•${RESET} Caddy bkp : /etc/caddy/Caddyfile.old ${DIM}(if one existed)${RESET}\n"
    fi

    if [ "$tor" = true ]; then
        printf "  ${CYAN}•${RESET} Onion     : %s\n" "$onion_address"
    fi

    printf "\n  ${DIM}Next steps${RESET}\n"
    printf "  1. Check service health  : systemctl status monerod\n"
    printf "  2. Tail logs             : tail -f %s/monero.log\n" "$MONERO_LOG_DIR"
    if [ "$https" = true ]; then
        printf "  3. Merge old Caddy rules from Caddyfile.old if needed.\n"
    fi

    printf "\n${BOLD}${MAGENTA}  Happy syncing. Welcome to the Monero network.${RESET}\n\n"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    banner
    require_root
    require_templates
    detect_architecture
    detect_package_manager
    detect_memory_profile
    preflight_notice
    collect_configuration
    install_required_packages
    copy_templates_to_workspace
    download_and_install_monero
    ensure_monerod_user
    configure_tor
    configure_monerod_conf
    install_banlist_if_needed
    configure_monerod_service
    configure_website
    start_services
    print_final_summary
}

main "$@"
