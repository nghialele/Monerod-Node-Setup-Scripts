#!/usr/bin/env bash
# Monerod Node Setup v2.0 — full rewrite.
# Installs a public Monero node on Debian with a website on your server's IP,
# optional TLS via a domain, optional Tor, and a heartbeat that never sleeps.
set -euo pipefail

readonly VERSION="2.0"
readonly REPO_URL="https://github.com/nghialele/Monerod-Node-Setup-Scripts"
readonly MONERO_DATA_DIR="/var/lib/monero"
readonly MONERO_LOG_DIR="/var/log/monero"
readonly MONERO_CONF_DIR="/etc/monero"
readonly SITE_DIR="/srv/monero-node"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly TMP_WORK="$(mktemp -d)"
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT

# ── log helpers (colors only when attached to a TTY) ─────────────────────────
if [[ -t 1 ]]; then
	C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
	C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi
log_info() { printf '%s\n' "${C_BLUE}→${C_RESET} $*"; }
log_ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
log_warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
log_err()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
section()  { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
die()      { log_err "$*"; exit 1; }

# ── configuration (all defaults; flags override) ─────────────────────────────
DOMAIN="" LOCATION="" OWNER_NAME="" OWNER_EMAIL="" BANDWIDTH=""
TOR=false PRUNE=false ZMQ=false IPV6=false NO_IPV4=false
BANLIST=true HEARTBEAT=true FULL_MEM_SET=""   # "" auto | "on" | "off"
DRY_RUN=false ASSUME_YES=false
RELEASE="" FULL_MEM=false ONION_ADDRESS="" DETECTED_IP="" PUBLIC_NODE=false

usage() {
	cat <<EOF
Monerod Node Setup v${VERSION}

This turns your server into a public Monero node.
Your server will now have neighbors. They're polite.

Usage: sudo ./setup_monerod.sh [options]

Run with no options for a sensible default node (one confirmation prompt).

Options:
  --domain <host>        Real TLS: Let's Encrypt cert for this host + RPC over TLS.
                         Without it, the site is served on your IP (self-signed 443,
                         plain 80) and RPC stays plain http://.
  --location <text>      Shown on the node website.
  --owner-name <text>    Site contact name.
  --owner-email <addr>   Site contact email (mailto link).
  --bandwidth <text>     Free-text bandwidth claim for the site.
  --tor                  Tor hidden service (P2P 18084, RPC 18089, ZMQ 18083 if --zmq, website 80).
  --prune                Pruned blockchain (saves ~2/3 of the disk. Not magic, just math).
  --full-mem             Force RandomX full-memory mode (needs ~2.8 GiB RAM).
  --no-full-mem          Force RandomX full-memory mode OFF.
                         (Default: auto — on if the server has >= 2861 MiB RAM.)
  --zmq                  Publish ZMQ on tcp://0.0.0.0:18083.
  --ipv6                 Enable IPv6 P2P + RPC binds.
  --no-ipv4              Disable IPv4 binds (requires --ipv6).
  --no-banlist           Skip downloading the Boog900 ban list.
  --no-heartbeat         Skip the heartbeat timer that restarts a sulking node.
  --yes                  Skip the confirmation prompt (for robots and CI).
  --dry-run              Print everything that would be done/generated. Changes nothing.
  -h, --help             This screen.

Ports used: 18080 (P2P), 18089 (RPC), 80/443 (website), 18083 (ZMQ, optional),
18084 (Tor P2P, if --tor).
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--domain)      [[ $# -ge 2 ]] || die "--domain needs a value"; DOMAIN="$2"; shift 2 ;;
			--location)    [[ $# -ge 2 ]] || die "--location needs a value"; LOCATION="$2"; shift 2 ;;
			--owner-name)  [[ $# -ge 2 ]] || die "--owner-name needs a value"; OWNER_NAME="$2"; shift 2 ;;
			--owner-email) [[ $# -ge 2 ]] || die "--owner-email needs a value"; OWNER_EMAIL="$2"; shift 2 ;;
			--bandwidth)   [[ $# -ge 2 ]] || die "--bandwidth needs a value"; BANDWIDTH="$2"; shift 2 ;;
			--tor)         TOR=true; shift ;;
			--prune)       PRUNE=true; shift ;;
			--zmq)         ZMQ=true; shift ;;
			--ipv6)        IPV6=true; shift ;;
			--no-ipv4)     NO_IPV4=true; shift ;;
			--full-mem)    FULL_MEM_SET="on"; shift ;;
			--no-full-mem) FULL_MEM_SET="off"; shift ;;
			--no-banlist)  BANLIST=false; shift ;;
			--no-heartbeat) HEARTBEAT=false; shift ;;
			--yes)         ASSUME_YES=true; shift ;;
			--dry-run)     DRY_RUN=true; shift ;;
			-h|--help)     usage; exit 0 ;;
			--)            shift; break ;;
			*)             die "unknown flag: $1 (see --help)" ;;
		esac
	done
}

validate_args() {
	if [[ -n "$DOMAIN" ]]; then
		[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]] \
			|| die "'$DOMAIN' does not look like a domain name. (Example: node.example.com)"
	fi
	if $NO_IPV4 && ! $IPV6; then
		die "--no-ipv4 requires --ipv6 — otherwise nobody could reach the node at all."
	fi
	if [[ -n "$FULL_MEM_SET" && "$FULL_MEM_SET" != "on" && "$FULL_MEM_SET" != "off" ]]; then
		die "--full-mem/--no-full-mem are mutually exclusive."  # unreachable; both flags overwrite, never combine
	fi
}

# ── preflight: are we allowed, able, and sensible? ────────────────────────────
preflight() {
	if [[ ${EUID:-$(id -u)} -ne 0 && "$DRY_RUN" != true ]]; then
		die "This script needs root (sudo) to install packages and write configs. Re-run with: sudo $0"
	fi
	if command -v apt-get >/dev/null 2>&1; then
		PKG="apt"
	elif command -v dnf >/dev/null 2>&1; then
		PKG="dnf"
		log_warn "Fedora/RHEL detected. This should work, but SELinux may have opinions."
	else
		die "Neither apt-get nor dnf found. This script needs one of them to exist."
	fi
	local arch
	arch="$(uname -m)"
	case "$arch" in
		x86_64)          RELEASE="linux64" ;;
		i686|i386)       RELEASE="linux32" ;;
		armv7*)          RELEASE="linuxarm7" ;;
		aarch64|arm64)   RELEASE="linuxarm8" ;;
		*)               die "Unsupported architecture: $arch. Monero hasn't ported to your toaster yet." ;;
	esac

	local mem_kib
	mem_kib=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	if [[ "$FULL_MEM_SET" == "on" ]]; then
		FULL_MEM=true
	elif [[ "$FULL_MEM_SET" == "off" ]]; then
		FULL_MEM=false
	else
		FULL_MEM=$(( mem_kib >= 2861 * 1024 ? 1 : 0 ))
		[[ $FULL_MEM == 1 ]] && FULL_MEM=true || FULL_MEM=false
	fi
	[[ -n "$DOMAIN" ]] && PUBLIC_NODE=true || PUBLIC_NODE=false
}

# ── HTML escaping and template rendering ─────────────────────────────────────
html_escape() {
	local s="$1"
	s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; s="${s//\'/&#39;}"
	printf '%s' "$s"
}

strip_block() {
	awk -v b="$1" '
		index($0, "<!-- BEGIN:" b " -->") { skip = 1; next }
		index($0, "<!-- END:" b " -->")   { skip = 0; next }
		!skip
	'
}

render_index() {
	# Renders the template to stdout with all conditions applied.
	local tpl="$SCRIPT_DIR/config-base/index.html"
	local out
	out="$(cat "$tpl")"
	$ZMQ || out=$(printf '%s' "$out" | strip_block "zmq")
	{ $ZMQ && $TOR; } || out=$(printf '%s' "$out" | strip_block "zmq_tor")
	$TOR || out=$(printf '%s' "$out" | strip_block "tor")
	[[ -n "$LOCATION" ]] || out=$(printf '%s' "$out" | strip_block "location")
	[[ -n "$BANDWIDTH" ]] || out=$(printf '%s' "$out" | strip_block "bandwidth")
	[[ -n "$OWNER_EMAIL" ]] || out=$(printf '%s' "$out" | strip_block "contact")
	# Substitute placeholders (values are already escaped by the caller).
	out="${out//@@NODE_NAME@@/$NODE_NAME_ESC}"
	out="${out//@@P2P_ADDRESS@@/$P2P_ADDR_ESC}"
	out="${out//@@RPC_ADDRESS@@/$RPC_ADDR_ESC}"
	out="${out//@@ZMQ_ADDRESS@@/$ZMQ_ADDR_ESC}"
	out="${out//@@ONION_ADDRESS@@/$ONION_ADDR_ESC}"
	out="${out//@@NODE_TYPE@@/$NODE_TYPE}"
	out="${out//@@LOCATION@@/$LOCATION_ESC}"
	out="${out//@@BANDWIDTH@@/$BANDWIDTH_ESC}"
	out="${out//@@OWNER_NAME@@/$OWNER_NAME_ESC}"
	out="${out//@@OWNER_EMAIL@@/$OWNER_EMAIL_ESC}"
	out="${out//@@REPO_URL@@/$REPO_URL}"
	printf '%s' "$out"
}

# ── decide what the site will show ───────────────────────────────────────────
compute_site_addresses() {
	NODE_TYPE=$($PRUNE && echo Pruned || echo Full)
	if [[ -z "$DOMAIN" ]]; then
		DETECTED_IP="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
		if [[ "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			DOMAIN_OR_IP="$DETECTED_IP"
		else
			DOMAIN_OR_IP="SERVER-IP"
			log_warn "couldn't detect your public IP — replace SERVER-IP in ${SITE_DIR}/index.html"
		fi
	fi
	LOCATION_ESC=$(html_escape "$LOCATION")
	BANDWIDTH_ESC=$(html_escape "$BANDWIDTH")
	OWNER_NAME_ESC=$(html_escape "$OWNER_NAME")
	OWNER_EMAIL_ESC=$(html_escape "$OWNER_EMAIL")
	NODE_NAME_ESC=$(html_escape "$DOMAIN_OR_IP")
	P2P_ADDR_ESC=$(html_escape "tcp://${DOMAIN_OR_IP}:18080")
	RPC_ADDR_ESC=$(html_escape "http://${DOMAIN_OR_IP}:18089")
	if [[ -n "$DOMAIN" ]]; then
		RPC_ADDR_ESC=$(html_escape "https://${DOMAIN}:18089")
	fi
	ZMQ_ADDR_ESC=$(html_escape "tcp://${DOMAIN_OR_IP}:18083")
	ONION_ADDR_ESC=$(html_escape "tcp://${ONION_ADDRESS:-your-onion-address.onion}:18084")
}

# ── summary + confirmation ────────────────────────────────────────────────────
summary_and_confirm() {
	section "Configuration summary"
	echo "  Domain        : ${DOMAIN:-(none — site served on the server IP)}"
	echo "  Location      : ${LOCATION:-(hidden)}"
	echo "  Owner         : ${OWNER_NAME:-(hidden)}${OWNER_EMAIL:+ <$OWNER_EMAIL>}"
	echo "  Bandwidth     : ${BANDWIDTH:-(hidden)}"
	echo "  Tor           : $($TOR && echo yes || echo no)"
	echo "  Pruned        : $($PRUNE && echo yes || echo no)"
	echo "  ZMQ           : $($ZMQ && echo yes || echo no)"
	echo "  IPv6          : $($IPV6 && echo yes || echo no)$($NO_IPV4 && echo ' (IPv4 disabled)' || echo '')"
	echo "  Ban list      : $($BANLIST && echo yes || echo no)"
	echo "  Heartbeat     : $($HEARTBEAT && echo yes || echo no)"
	echo "  RandomX full mem: $($FULL_MEM && echo yes || echo no)"
	echo "  Dry run       : $($DRY_RUN && echo yes || echo no)"
	section "Ports to open in your firewall"
	cat <<EOF
  18080/tcp   P2P (always)
  18089/tcp   RPC (always)
  80, 443/tcp Website (always)
EOF
	if $ZMQ; then echo "  18083/tcp   ZMQ (because you asked for --zmq)"; fi
	if $TOR; then
		cat <<'EOF'
  Tor         : ports above also available via the onion address (website on 80).
EOF
	fi
	if $DRY_RUN; then
		printf '\n%s\n' "dry run: nothing will be changed."
		return 0
	fi
	if ! $ASSUME_YES; then
		read -r -p "Proceed? [Y/n] " answer
		case "$answer" in
			[Nn]*) die "Aborted. The blockchain will have to manage without you." ;;
			*) : ;;
		esac
	fi
}

# ── render everything to stdout (dry-run mode) ────────────────────────────────
render_and_print_all() {
	section "── /etc/monero/monerod.conf ──"
	render_monerod_conf
	section "── /etc/systemd/system/monerod.service ──"
	render_monerod_service
	section "── ${CADDYFILE} ──"
	render_caddyfile
	section "── ${SITE_DIR}/index.html ──"
	render_index
	if [[ -n "$DOMAIN" ]]; then
		section "── /usr/local/bin/watch_certificates_xmr.sh (first 15 lines) ──"
		sed -n '1,15p' "$SCRIPT_DIR/config-base/watch_certificates_xmr.sh" | sed "s/@@DOMAIN@@/$DOMAIN/"
	fi
	section "── end of dry run ──"
}

# ── conf / service / caddyfile generation (heredocs; no sed) ──────────────────
render_monerod_conf() {
	local ipv4_lines="" ipv6_lines="" zmq_lines="" banlist_lines="" ssl_lines="" tor_lines="" prune_lines=""
	$IPV6 && ! $NO_IPV4 && ipv4_lines=$'p2p-bind-ip=0.0.0.0\nrpc-bind-ip=0.0.0.0'
	$NO_IPV4 && ipv4_lines=""
	$IPV6 && ipv6_lines=$'p2p-use-ipv6=true\np2p-bind-ipv6-address=::\nrpc-use-ipv6=true\nrpc-bind-ipv6-address=::'
	if $ZMQ; then
		zmq_lines="zmq-pub=tcp://0.0.0.0:18083"
	else
		zmq_lines="no-zmq=true"
	fi
	$BANLIST && banlist_lines="ban-list=/etc/monero/ban_list.txt"
	[[ -n "$DOMAIN" ]] && ssl_lines=$'rpc-ssl-private-key=/var/lib/monero/certificates/'"$DOMAIN"$'.key\nrpc-ssl-certificate=/var/lib/monero/certificates/'"$DOMAIN"$'.crt'
	$TOR && tor_lines=$'tx-proxy=tor,127.0.0.1:9050,disable_noise\nanonymous-inbound='"${ONION_ADDRESS}"$':18084,127.0.0.1:18084\npad-transactions=true'
	$PRUNE && prune_lines="prune-blockchain=true"

	cat <<EOF
log-file=/var/log/monero/monero.log
log-level=0
data-dir=/var/lib/monero
no-igd=true
enforce-dns-checkpointing=true
enable-dns-blocklist=true
p2p-bind-port=18080
p2p-external-port=18080
out-peers=25
in-peers=25
limit-rate-up=6250
limit-rate-down=6250
rpc-bind-port=18089
public-node=true
confirm-external-bind=true
restricted-rpc=true
rpc-access-control-origins=*
${ipv4_lines}${ipv6_lines}${zmq_lines}
${banlist_lines}
${ssl_lines}${tor_lines}${prune_lines}
EOF
}

render_monerod_service() {
	local full_mem_line=""
	$FULL_MEM && full_mem_line='Environment="MONERO_RANDOMX_FULL_MEM=1"'
	cat <<EOF
[Unit]
Description=Monero Daemon (monerod)
After=network.target

[Service]
User=monero
Group=monero
Type=forking
PIDFile=/run/monero/monerod.pid
RuntimeDirectory=monero
RuntimeDirectoryMode=0710
StateDirectory=monero
StateDirectoryMode=0710
LogsDirectory=monero
LogsDirectoryMode=0710
ConfigurationDirectory=monero
ConfigurationDirectoryMode=0710
ExecStart=/usr/local/bin/monerod --config-file=/etc/monero/monerod.conf --pidfile=/run/monero/monerod.pid --detach
Restart=on-failure
RestartSec=30
Environment="DNS_PUBLIC=tcp://8.8.8.8"
${full_mem_line}
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

render_caddyfile() {
	if [[ -n "$DOMAIN" ]]; then
		cat <<EOF
# Managed by Monerod-Node-Setup-Scripts. Edits will be overwritten.

# The domain: real Let's Encrypt cert, automatic.
${DOMAIN} {
	root * ${SITE_DIR}
	file_server
}

# Plain HTTP on the domain → HTTPS.
http://${DOMAIN} {
	redir https://${DOMAIN}{uri}
}

# Everything else (IPs, other hostnames): self-signed TLS, still serves the index.
http://, https:// {
	tls internal
	root * ${SITE_DIR}
	file_server
}
EOF
	else
		cat <<EOF
# Managed by Monerod-Node-Setup-Scripts. Edits will be overwritten.

# No domain configured: serve the index on IP / hostname access.
http://, https:// {
	tls internal
	root * ${SITE_DIR}
	file_server
}
EOF
	fi
}

render_heartbeat_units() {
	cat <<'EOF'
# /etc/systemd/system/monerod-heartbeat.service
[Unit]
Description=Monerod RPC heartbeat check
After=monerod.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/monerod-heartbeat.sh

# /etc/systemd/system/monerod-heartbeat.timer
[Unit]
Description=Run monerod heartbeat every minute

[Timer]
OnUnitActiveSec=1min
AccuracySec=5s
Unit=monerod-heartbeat.service

[Install]
WantedBy=timers.target
EOF
}

# ── the actual work ───────────────────────────────────────────────────────────
install_packages() {
	section "Installing packages"
	log_info "Downloading Monero's dependencies… yes, it's that big. Grab a coffee."
	local base="wget bzip2 curl"   # curl added for the heartbeat (it was missing. Oops.)
	if [[ "$PKG" == "apt" ]]; then
		local pkgs="$base caddy"
		$TOR && pkgs="$pkgs tor"
		apt-get update -y
		DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs \
			|| die "apt-get install failed. Check your network / mirrors and retry."
	else
		local pkgs="$base caddy"
		$TOR && pkgs="$pkgs tor"
		dnf install -y $pkgs || die "dnf install failed."
	fi
	log_ok "Packages installed: caddy, wget, bzip2, curl — yes, curl, it matters later."
}

download_monero() {
	section "Downloading Monero"
	local release="${RELEASE}"
	local url="https://downloads.getmonero.org/${release}"
	log_info "Fetching from $url — the official domain, a redirect to the versioned tarball."
	wget -q -O "$TMP_WORK/monero.tar.bz2" "$url" || die "Download failed. Network feeling shy?"
	tar -xjf "$TMP_WORK/monero.tar.bz2" -C "$TMP_WORK" || die "Extraction failed. The tarball may be corrupt."
	local extracted_dir
	extracted_dir="$(find "$TMP_WORK" -maxdepth 1 -type d -name 'monero-*' | head -n1)"
	[[ -n "$extracted_dir" ]] || die "Couldn't find the extracted monero directory."
	install -m 755 "$extracted_dir/monerod"             /usr/local/bin/monerod
	install -m 755 "$extracted_dir/monero-wallet-rpc"   /usr/local/bin/monero-wallet-rpc
	install -m 755 "$extracted_dir/monero-cli"          /usr/local/bin/monero-cli 2>/dev/null || true
	log_ok "Monero installed to /usr/local/bin."
}

setup_user_and_dirs() {
	section "Creating user and directories"
	getent group monero >/dev/null || groupadd --system monero
	getent passwd monero >/dev/null || useradd --system --gid monero --home-dir "$MONERO_DATA_DIR" \
		--no-create-home --shell /usr/sbin/nologin monero
	usermod -L monero 2>/dev/null || true
	mkdir -p "$MONERO_DATA_DIR" "$MONERO_LOG_DIR" "$MONERO_CONF_DIR"
	[[ -n "$DOMAIN" ]] && mkdir -p "$MONERO_DATA_DIR/certificates"
	chown -R monero:monero "$MONERO_DATA_DIR" "$MONERO_LOG_DIR" "$MONERO_CONF_DIR"
	chmod 710 "$MONERO_DATA_DIR" "$MONERO_LOG_DIR" "$MONERO_CONF_DIR"
	log_ok "monero user and directories ready."
}

setup_tor() {
	section "Setting up Tor hidden service"
	# Idempotent managed block: strip the old one, write the new one. Re-running is safe.
	local rc="/etc/tor/torrc"
	awk 'BEGIN{skip=0}
		/### BEGIN Monerod \(managed by Monerod-Node-Setup-Scripts\) ###/ {skip=1; next}
		/### END Monerod ###/ {skip=0; next}
		!skip' "$rc" > "$TMP_WORK/torrc.tmp"
	{
		echo "### BEGIN Monerod (managed by Monerod-Node-Setup-Scripts) ###"
		echo "HiddenServiceDir /var/lib/tor/monerod"
		echo "HiddenServicePort 18084 127.0.0.1:18084"
		echo "HiddenServicePort 18089 127.0.0.1:18089"
		$ZMQ && echo "HiddenServicePort 18083 127.0.0.1:18083"
		echo "HiddenServicePort 80 127.0.0.1:80"
		echo "### END Monerod ###"
	} >> "$TMP_WORK/torrc.tmp"
	mv "$TMP_WORK/torrc.tmp" "$rc"
	systemctl enable tor >/dev/null 2>&1
	systemctl restart tor
	log_info "Waiting for Tor to publish the onion address…"
	local waited=0
	while [[ ! -s /var/lib/tor/monerod/hostname ]]; do
		sleep 2; waited=$((waited + 2))
		if (( waited >= 30 )); then
			die "Tor didn't publish the onion hostname in time — check 'journalctl -u tor'."
		fi
	done
	ONION_ADDRESS="$(cat /var/lib/tor/monerod/hostname)"
	log_ok "Onion address: $ONION_ADDRESS"
}

write_monerod_conf() {
	section "Writing monerod config"
	render_monerod_conf > "$MONERO_CONF_DIR/monerod.conf"
	chown monero:monero "$MONERO_CONF_DIR/monerod.conf"
	chmod 640 "$MONERO_CONF_DIR/monerod.conf"
	log_ok "Config written to $MONERO_CONF_DIR/monerod.conf"
}

write_monerod_service() {
	section "Writing systemd service"
	render_monerod_service > /etc/systemd/system/monerod.service
	systemctl daemon-reload
	systemctl enable monerod >/dev/null 2>&1
	log_ok "monerod.service installed and enabled — starting comes later, patience."
}

fetch_banlist() {
	section "Downloading ban list"
	wget -q -O "$MONERO_CONF_DIR/ban_list.txt" \
		"https://raw.githubusercontent.com/Boog900/monero-ban-list/main/ban_list.txt" \
		|| die "Ban list download failed."
	chown monero:monero "$MONERO_CONF_DIR/ban_list.txt"
	chmod 640 "$MONERO_CONF_DIR/ban_list.txt"
	log_ok "Ban list installed. Known bad actors: politely declined."
}

setup_website() {
	section "Setting up the node website"
	mkdir -p "$SITE_DIR"
	render_index > "$SITE_DIR/index.html"
	chown -R root:root "$SITE_DIR"
	chmod 755 "$SITE_DIR"
	chmod 644 "$SITE_DIR/index.html"
	log_ok "Website written to $SITE_DIR"
}

setup_caddy_and_start() {
	section "Configuring Caddy"
	if [[ -f "$CADDYFILE" ]]; then
		mv "$CADDYFILE" "$CADDYFILE.old"
		log_warn "Existing Caddyfile moved to $CADDYFILE.old — merge any custom edits manually."
	fi
	mkdir -p /etc/caddy
	render_caddyfile > "$CADDYFILE"
	systemctl enable caddy >/dev/null 2>&1
	systemctl restart caddy

	if [[ -n "$DOMAIN" ]]; then
		start_monerod_with_tls
	else
		start_monerod_plain
	fi
}

start_monerod_plain() {
	log_info "Starting monerod… it will now do the most useful thing it knows: hold the blockchain up."
	systemctl daemon-reload
	systemctl enable --now monerod >/dev/null 2>&1
	log_ok "monerod started."
}

start_monerod_with_tls() {
	local cert_dir="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}"
	log_info "Waiting for Let's Encrypt to sign the paperwork… (up to 120s)"
	local waited=0
	while [[ ! -s "$cert_dir/${DOMAIN}.crt" || ! -s "$cert_dir/${DOMAIN}.key" ]]; do
		sleep 2; waited=$((waited + 2))
		if (( waited >= 120 )); then
			log_warn "Let's Encrypt files not found after 120s at:"
			log_warn "  $cert_dir"
			log_warn "Check 'systemctl status caddy' and your DNS. The cert watcher will start"
			log_warn "monerod automatically once the certificate lands — or run it yourself with:"
			log_warn "  systemctl start monerod"
			return 0
		fi
	done
	install -o monero -g monero -m 640 "$cert_dir/${DOMAIN}.crt" "$MONERO_DATA_DIR/certificates/${DOMAIN}.crt"
	install -o monero -g monero -m 640 "$cert_dir/${DOMAIN}.key" "$MONERO_DATA_DIR/certificates/${DOMAIN}.key"
	log_ok "Certificates synced to $MONERO_DATA_DIR/certificates/"
	systemctl daemon-reload
	systemctl enable --now monerod >/dev/null 2>&1
	log_ok "monerod started with TLS."
}

setup_cert_watcher() {
	section "Installing certificate watcher"
	sed "s/@@DOMAIN@@/$DOMAIN/" "$SCRIPT_DIR/config-base/watch_certificates_xmr.sh" \
		> /usr/local/bin/watch_certificates_xmr.sh
	chmod 744 /usr/local/bin/watch_certificates_xmr.sh
	install -m 644 "$SCRIPT_DIR/config-base/cert-watcher-xmr.service" /etc/systemd/system/cert-watcher-xmr.service
	systemctl daemon-reload
	systemctl enable --now cert-watcher-xmr >/dev/null 2>&1
	log_ok "Cert watcher installed — monerod will never be left behind by a cert renewal."
}

setup_heartbeat() {
	section "Installing heartbeat"
	install -m 744 "$SCRIPT_DIR/config-base/monerod-heartbeat.sh" /usr/local/sbin/monerod-heartbeat.sh
	render_heartbeat_units | awk '/^# \/etc\/systemd\/system\/monerod-heartbeat\.service$/{f=1;next}
		/^# \/etc\/systemd\/system\/monerod-heartbeat\.timer$/{f=2;next}
		f==1 && NF {print > "/etc/systemd/system/monerod-heartbeat.service"}
		f==2 && NF {print > "/etc/systemd/system/monerod-heartbeat.timer"}'
	systemctl daemon-reload
	systemctl enable --now monerod-heartbeat.timer >/dev/null 2>&1
	log_ok "Heartbeat timer running — a stopped node will be politely nudged back to life."
}

done_screen() {
	clear 2>/dev/null || true
	cat <<'BANNER'
┌────────────────────────────────────────────────────────────┐
│  Monerod Node Setup — done!                                │
│  Your node is live. It will now do the most useful thing   │
│  it knows: hold the blockchain up.                         │
└────────────────────────────────────────────────────────────┘
BANNER
	if [[ -n "$DOMAIN" ]]; then
		echo "  Website       : https://$DOMAIN"
		echo "                  also https://<your-ip> with a self-signed cert"
	else
		echo "  Website       : http://${DOMAIN_OR_IP}/"
	fi
	if $TOR; then echo "  Onion website : http://$ONION_ADDRESS/"; fi
	echo "  Config        : $MONERO_CONF_DIR/monerod.conf"
	echo "  Data          : $MONERO_DATA_DIR"
	echo "  Logs          : $MONERO_LOG_DIR"
	echo
	echo "  Firewall reminder: open 18080/tcp and 18089/tcp, plus 80/443 for the site."
	if $ZMQ; then echo "  Also 18083/tcp for ZMQ. Your router/firewall still thinks it's the boss — check it."; fi
	if [[ -f "$CADDYFILE.old" ]]; then
		echo "  Note: previous Caddyfile saved as $CADDYFILE.old — merge custom edits."
	fi
	echo
	echo "  Thanks for helping the network. Every peer counts."
}

# ── main ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
	parse_args "$@"
	validate_args
	preflight
	DOMAIN_OR_IP="${DOMAIN:-}"
	compute_site_addresses
	summary_and_confirm
	if $DRY_RUN; then
		render_and_print_all
		echo
		log_ok "Dry run complete. Nothing was changed — the blockchain is untouched."
		exit 0
	fi
	echo
	cat <<'BANNER'
┌────────────────────────────────────────────────────────────┐
│  Monerod Node Setup v2.0                                   │
│  This makes your server a public Monero node.              │
│  Your server will now have neighbors. They're polite.      │
└────────────────────────────────────────────────────────────┘
BANNER
	install_packages
	download_monero
	setup_user_and_dirs
	if $TOR; then setup_tor; fi
	write_monerod_conf
	write_monerod_service
	if $BANLIST; then fetch_banlist; fi
	setup_website
	setup_caddy_and_start
	if [[ -n "$DOMAIN" ]]; then setup_cert_watcher; fi
	if $HEARTBEAT; then setup_heartbeat; fi
	echo
	done_screen
}

main "$@"
