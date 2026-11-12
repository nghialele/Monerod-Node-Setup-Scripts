# Monerod Node Setup Scripts

This turns your server into a public Monero node. What does that mean? People
will talk to your computer. Politely, mostly.

One script, one website, zero required questions. Run it, get a node, get a
web page on your server's IP that tells people how to use it.

## Quick start

```bash
git clone https://github.com/nghialele/Monerod-Node-Setup-Scripts
cd Monerod-Node-Setup-Scripts
sudo ./setup_monerod.sh
```

That's it. You now run a public node. One confirmation prompt, then the
script does the rest: Monero binaries, systemd services, a Caddy website on
`http://<your-ip>/` (and `https://<your-ip>/` with a self-signed cert), and a
heartbeat that pokes your node every minute and nudges it back to life if it
stops answering.

## Flags

All optional. Defaults are sane.

| Flag | Default | Effect |
|---|---|---|
| `--network <name>` | `mainnet` | `mainnet`, `stagenet`, or `testnet`. Sets monerod's network flag, the default ports, and the network shown on the website. |
| `--domain <host>` | none | Real TLS: Let's Encrypt cert for the host + RPC over TLS. Without it the site is served on the IP (self-signed on 443, plain on 80) and RPC stays plain `http://`. |
| `--no-website` | off | Do not install or touch Caddy, and do not write the site. For servers that already run a reverse proxy. |
| `--proxy-ip <ip>` | `0.0.0.0` | Bind RPC to this address instead. Use with `--no-website` to keep RPC off the internet (`127.0.0.1`, or a docker bridge IP your proxy can reach). |
| `--proxy-port <port>` | none | With `--no-website`, advertise the proxy's public URL on the site instead of the raw RPC port. |
| `--location <text>` | hidden | Shown on the node website. |
| `--owner-name <text>` | hidden | Site contact name. |
| `--owner-email <addr>` | hidden | Site contact `mailto:` link. |
| `--bandwidth <text>` | hidden | Free-text bandwidth claim for the site. |
| `--tor` | off | Tor hidden service (P2P, RPC, ZMQ if `--zmq`, website 80) + `tx-proxy`. |
| `--prune` | off | `prune-blockchain=true` — saves about two thirds of the disk. Not magic, just math. |
| `--full-mem` / `--no-full-mem` | auto | RandomX full-memory mode; on by default when the server has ≥ 2861 MiB RAM. |
| `--zmq` | off | Publish ZMQ on `tcp://0.0.0.0:<zmq port>`. |
| `--ipv6` | off | IPv6 P2P + RPC binds. |
| `--no-ipv4` | off | Disable IPv4 binds (requires `--ipv6`, or nobody can reach you). |
| `--port <svc>=<n>` | network defaults | Override one port: `p2p`, `rpc`, `zmq`, `torchp2p`. Repeatable. |
| `--no-banlist` | banlist on | Skip the Boog900 ban list download. |
| `--no-heartbeat` | heartbeat on | Skip the liveness timer. |
| `--yes` | off | Skip the confirmation prompt. For robots and CI. |
| `--dry-run` | off | Print every file that would be generated, change nothing. |
| `-h` / `--help` | — | Usage + this table. Works without root. |

## Examples

Plain default node:

```bash
sudo ./setup_monerod.sh
```

Domain with site details:

```bash
sudo ./setup_monerod.sh --domain node.example.com \
  --location "Berlin, DE" --owner-name "Ada" --owner-email ada@example.com
```

The full works:

```bash
sudo ./setup_monerod.sh --domain node.example.com --tor --zmq --prune \
  --ipv6 --yes
```

Stagenet node (ports 38080/38089, shown as Stagenet on the site):

```bash
sudo ./setup_monerod.sh --network stagenet --location "Berlin, DE"
```

Node behind the reverse proxy you already run (no Caddy installed, RPC kept
local):

```bash
sudo ./setup_monerod.sh --no-website --proxy-ip 127.0.0.1
```

Then point your proxy at `http://127.0.0.1:18089`. If your proxy lives in a
container, use the docker bridge address instead, e.g.
`--proxy-ip 172.17.0.1`. If the site is served by your proxy too, add
`--proxy-port 18090` to have the node's page advertise that URL.

## Ports

| Purpose | mainnet | stagenet | testnet |
|---|---|---|---|
| P2P | 18080 | 38080 | 28080 |
| RPC | 18089 | 38089 | 28089 |
| ZMQ (with `--zmq`) | 18083 | 38083 | 28083 |
| Tor P2P (with `--tor`) | 18084 | 38084 | 28084 |
| Website | 80, 443 (unless `--no-website`) | 80, 443 | 80, 443 |

Any of them can be changed with `--port`, e.g. `--port rpc=18081`.

## The node website

The script always installs Caddy and serves a small index page describing
your node. Opening `http://<server-ip>/` in a browser shows it — no domain
needed, no redirect anywhere. `https://<server-ip>/` also works, with a
Caddy-generated self-signed certificate (your browser will warn; that's the
certificate, not the node). If you set `--domain`, that host gets a real
Let's Encrypt certificate and the plain-HTTP visits redirect to HTTPS.

The page lists your P2P/RPC/ZMQ/Tor addresses (one click to copy each), the
node type, and your location/bandwidth/contact rows if you supplied them.
Minimalist on purpose: white background, one card, no analytics, no fonts to
load. Roughly:

```
        PUBLIC MONERO NODE
        node.example.com
  A public Monero node. Feel free to connect —
  every peer keeps the network private.
  ┌──────────────────────────────────────┐
  │ P2P    tcp://node.example.com:18080  │
  │ RPC    https://node.example.com:18089│
  │ ZMQ    tcp://node.example.com:18083  │
  │ Tor P2P tcp://<onion>:18084          │
  │ Network Mainnet                      │
  │ Node   Full Monero node on Mainnet   │
  │ Location  Berlin, DE                 │
  │ Contact   ada@example.com            │
  └──────────────────────────────────────┘
  Self-hosting is the future. This one's already running.
  host your own node →
```

## What's where

| Path | What |
|---|---|
| `/etc/monero/monerod.conf` | Node config |
| `/etc/systemd/system/monerod.service` | Node service |
| `/var/lib/monero` | Blockchain data (+ `certificates/` in domain mode) |
| `/var/log/monero/monero.log` | Node log |
| `/srv/monero-node` | Website files (not written with `--no-website`) |
| `/etc/caddy/Caddyfile` | Web server config (Caddy is not installed with `--no-website`) |
| `/usr/local/bin/watch_certificates_xmr.sh` | Cert sync watcher (domain mode) |
| `/usr/local/sbin/monerod-heartbeat.sh` | RPC liveness check |

## Dry run

Want to see exactly what would be written before trusting a script with sudo?

```bash
sudo ./setup_monerod.sh --dry-run --domain node.example.com --tor --zmq
```

It prints the config, the systemd service, the Caddyfile, and the rendered
website to stdout, then exits having changed nothing.

## Warranty

MIT. The full text is in [LICENSE](LICENSE). The short version: this is
provided "as is", without warranty of any kind. If your server catches fire
tomorrow, that's a voided-warranty event. (It won't. It's a node, not a
fireworks factory.)

Downloads come from `downloads.getmonero.org` — the official domain.

## Uninstall

```bash
sudo systemctl disable --now monerod caddy monerod-heartbeat.timer cert-watcher-xmr 2>/dev/null
sudo rm /etc/systemd/system/monerod.service /etc/systemd/system/monerod-heartbeat.{service,timer} /etc/systemd/system/cert-watcher-xmr.service
sudo systemctl daemon-reload
sudo apt remove caddy tor 2>/dev/null   # if installed by this script
sudo rm -rf /var/lib/monero /var/log/monero /etc/monero /srv/monero-node /usr/local/bin/monerod /usr/local/bin/monero-wallet-rpc /usr/local/sbin/monerod-heartbeat.sh /usr/local/bin/watch_certificates_xmr.sh
```

The blockchain data goes with `/var/lib/monero` — that's ~200 GB of
downloads you're deleting, so delete on purpose.
