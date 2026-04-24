# Monerod Node Setup Scripts

Structured documentation for the `Monerod-Node-Setup-Scripts` project.

This file is intentionally organized for easy migration into a static site generator later. Sections are written as standalone content blocks so they can be split into pages, collections, or navigation groups.

---

## Project Summary

`Monerod-Node-Setup-Scripts` automates the deployment of a public Monero node on Debian-based systems, with optional support for:

- HTTPS for public RPC and a landing page
- Tor hidden service access
- ZMQ for P2Pool or related tooling
- Blockchain pruning
- RandomX full memory mode
- Automatic TLS certificate sync between Caddy and `monerod`

The repository provides a single main installer script plus configuration templates for `monerod`, `systemd`, a static landing page, and certificate monitoring.

---

## Goals

The project is designed to help you:

1. Install and configure a public `monerod` node quickly
2. Expose Monero P2P and restricted RPC services
3. Optionally publish a simple status/instructions website
4. Optionally provide Tor access for RPC and P2P
5. Keep the deployment manageable using systemd services and plain configuration files

---

## Intended Audience

This project is for:

- Operators who want to host a public Monero node
- Self-hosters comfortable running scripts as `root`
- Administrators deploying on Debian or Debian-like systems
- Users who want a practical bootstrap instead of a fully abstracted orchestration stack

This project is not aimed at:

- One-click desktop users
- Large-scale clustered deployment scenarios
- Container-first infrastructure
- Advanced multi-node orchestration

---

## Repository Structure

### Root Files

#### `setup_monerod.sh`

Main installation and configuration script.  
This script:

- Detects architecture
- Selects a Monero binary release
- Detects package manager support
- Collects interactive configuration answers
- Installs required packages
- Creates users and directories
- Configures `monerod`
- Sets up Caddy when HTTPS is enabled
- Configures Tor hidden services when enabled
- Enables systemd services

#### `README.md`

Current top-level introduction.  
Its purpose is brief onboarding, but the long-form documentation should live in `DOCS.md`.

#### `LICENSE`

Project license file.

---

### `config-base/`

Template assets copied and customized by the setup script.

#### `config-base/monerod.conf`

Base `monerod` configuration template.  
Contains commented options that are selectively enabled by the installer.

#### `config-base/monerod.service`

Systemd unit file for `monerod`.

#### `config-base/index.html`

Template for the public node landing page served by Caddy.

#### `config-base/watch_certificates_xmr.sh`

Script that monitors Caddy-managed TLS certificates and copies them into the Monero certificate directory when changes occur.

#### `config-base/cert-watcher-xmr.service`

Systemd unit for the certificate watcher script.

---

### `docs/`

Currently contains image assets/screenshots.

#### `docs/config.png`

Screenshot or visual asset related to configuration.

#### `docs/site.png`

Screenshot or visual asset related to the generated website.

---

## How the Project Works

## High-Level Flow

The deployment process follows this rough sequence:

1. Confirm the script is running as `root`
2. Detect system architecture
3. Choose the matching Monero binary release
4. Detect package manager availability
5. Inspect available RAM to decide whether full RandomX mode is practical
6. Ask the operator a series of configuration questions
7. Install dependencies
8. Copy template configuration files into a working location
9. Download and install Monero binaries
10. Create the `monero` system user and required directories
11. Optionally configure Tor
12. Customize `monerod.conf`
13. Optionally fetch and install the community ban list
14. Install and enable the `monerod` systemd service
15. Optionally configure Caddy and the public landing page
16. Optionally install the certificate watcher service
17. Start services and print completion instructions

---

## Installation Modes

The script supports multiple deployment combinations.

### Supported Combinations

- HTTPS enabled, Tor enabled
- HTTPS enabled, Tor disabled
- HTTPS disabled, Tor enabled
- HTTPS disabled, Tor disabled

### Optional Features

- Blockchain pruning
- Full RandomX memory mode
- Community ban list
- ZMQ
- IPv4 binding
- IPv6 binding

---

## Interactive Configuration Inputs

During setup, the script asks for the following values.

### Required Confirmation

Before installation begins, the operator is reminded to open the required ports and confirm they want to continue.

### HTTPS Inputs

When HTTPS is enabled, the script asks for:

- DNS record or domain name of the server
- Physical or descriptive server location
- Owner/contact name
- Owner/contact email

These values are used to customize the landing page and TLS-related configuration.

### Tor Input

- Whether Tor hidden service access should be enabled

### Pruning Input

- Whether the blockchain should be pruned

### Full RandomX Dataset Input

Only asked when the script detects sufficient RAM.

- Whether to enable the full RandomX memory mode

### Ban List Input

- Whether to download and use the Boog900 ban list

### ZMQ Input

- Whether to enable ZMQ for tools such as P2Pool

### Network Binding Inputs

- Whether to bind to IPv4
- Whether to bind to IPv6

At least one of IPv4 or IPv6 must be enabled.

---

## System Requirements

## Operating System

Primary target:

- Debian-based Linux systems

The script also has limited package manager branching for Fedora-like systems, but that path is explicitly not fully implemented.

## Permissions

You must run the installer as `root`.

## Network Requirements

For a basic public node:

- TCP `18080` for P2P
- TCP `18089` for restricted RPC

For HTTPS deployments:

- TCP `80`
- TCP `443`

For ZMQ:

- TCP `18083`

## DNS Requirements

If HTTPS is enabled, a valid domain name must point to your server.

---

## Architecture Detection

The installer selects a Monero download target based on the result of `uname -m`.

### Mappings

- `x86_64` -> `linux64`
- `i686` or `i386` -> `linux32`
- `aarch32`, `arm32`, `armv7*` -> `linuxarm7`
- `aarch64`, `arm64`, `armv8*` -> `linuxarm8`

Unsupported architectures cause the script to exit.

---

## Package Dependencies

The script installs or expects the following packages depending on chosen features.

### Base Packages

- `wget`
- `bzip2`

### HTTPS Mode

- `caddy`

### Tor Mode

- `tor`

Additional runtime tools may also be expected to exist in the OS environment, such as:

- `systemctl`
- `sed`
- `cp`
- `cmp`
- `tee`
- `tar`

---

## Files and Directories Created

## Runtime Directories

The script creates and manages these directories:

- `/var/lib/monero`
- `/var/log/monero`
- `/etc/monero`

When HTTPS is enabled:

- `/var/lib/monero/certificates`

When a website is enabled:

- `/srv/<domain>`

## Ownership Model

The `monero` system user and group are created if they do not already exist.  
Ownership is then assigned so the service can read and write the correct files without running as `root`.

---

## Services Installed

## `monerod.service`

Runs `monerod` under systemd.

Responsibilities:

- Start the daemon using `/etc/monero/monerod.conf`
- Maintain a PID file
- Restart on failure
- Run with a set of filesystem and privilege hardening controls

## `cert-watcher-xmr.service`

Installed only when HTTPS is enabled.

Responsibilities:

- Watch the Caddy certificate directory
- Detect new or changed certificate files
- Copy them into the Monero certificate directory
- Restart `monerod` after certificate updates

---

## monerod Configuration Behavior

The base configuration in `config-base/monerod.conf` includes defaults and commented options. The installer selectively enables lines depending on the chosen setup.

### Core Defaults

The template defines:

- Log file location
- Log level
- Data directory
- DNS checkpointing
- DNS blocklist
- P2P and RPC ports
- Peer limits
- Rate limits
- Restricted RPC mode
- CORS setting
- Disabled ZMQ by default

### IPv4

If enabled, the script uncomment lines for:

- `p2p-bind-ip=0.0.0.0`
- `rpc-bind-ip=0.0.0.0`

### IPv6

If enabled, the script uncomment lines for:

- `p2p-use-ipv6=true`
- `p2p-bind-ipv6-address=::`
- `rpc-use-ipv6=true`
- `rpc-bind-ipv6-address=::`

### Pruning

If pruning is enabled, the script enables:

- `prune-blockchain=true`

### Ban List

If enabled, the script enables:

- `ban-list=/etc/monero/ban_list.txt`

It then downloads the ban list from the community-maintained source.

### ZMQ

If enabled, the script:

- Enables `zmq-pub=tcp://0.0.0.0:18083`
- Disables the `no-zmq=true` line

### HTTPS/TLS

If HTTPS is enabled, the script configures:

- `rpc-ssl-private-key=/var/lib/monero/certificates/<domain>.key`
- `rpc-ssl-certificate=/var/lib/monero/certificates/<domain>.crt`

### Tor

If Tor is enabled, the script configures:

- `tx-proxy=tor,127.0.0.1:9050,disable_noise`
- `anonymous-inbound=<onion>:18084,127.0.0.1:18084`
- `pad-transactions=true`

---

## Tor Integration

When Tor is enabled, the script appends hidden service settings to `/etc/tor/torrc`.

### Exposed Tor Ports

- `18084` -> P2P
- `18089` -> RPC
- `18083` -> ZMQ, when enabled
- `80` -> Website, when HTTPS mode is also enabled

After configuring Tor, the script starts and restarts the Tor service to allow the hidden service hostname to be created.

The generated onion hostname is then inserted into:

- `monerod.conf`
- the landing page, when applicable

---

## Caddy and Website Behavior

When HTTPS is enabled, the project uses Caddy to serve a simple website and provision TLS automatically.

### Landing Page Purpose

The generated site communicates:

- Node address
- P2P endpoint
- RPC endpoint
- Optional ZMQ endpoint
- Optional Tor endpoints
- Node type
- Location
- Contact details

### Website Root

The site is placed in:

- `/srv/<domain>`

### Caddyfile Behavior

The installer:

1. Moves the existing `/etc/caddy/Caddyfile` to `/etc/caddy/Caddyfile.old`
2. Writes a new Caddy configuration for the site
3. Enables file serving from the site directory
4. Adds an HTTP-to-HTTPS redirect
5. Adds an internal `:8080` site binding when Tor website access is enabled

### Important Operational Note

If the target machine already had a custom Caddy configuration, it must be merged manually after setup.

---

## Certificate Sync Behavior

Monero RPC TLS expects certificate files in the Monero-owned certificate directory, while Caddy stores issued certificates in its own directory structure.

To bridge that gap, the project includes a watcher script.

### Watcher Responsibilities

The certificate watcher:

- Polls the Caddy certificate directory
- Compares the current `.key` and `.crt` files with Monero's local copies
- Stops `monerod` if changes are detected
- Copies fresh certificate files
- Fixes ownership
- Starts `monerod` again
- Sleeps for the configured interval before checking again

### Poll Interval

Default polling interval:

- `300` seconds

---

## Public Website Template Data Model

For future static site generator migration, the current `index.html` should be treated as a rendered template with a simple content model.

### Current Template Variables

- `DOMAINNAME`
- `ONIONADDRESS`
- `NODETYPE`
- `LOCATION`
- `OWNERNAME`
- `OWNEREMAIL`

### Optional Content Blocks

These blocks may be conditionally rendered:

- Public ZMQ endpoint
- Tor P2P endpoint
- Tor RPC endpoint
- Tor ZMQ endpoint

### Suggested Future Front Matter Model

A future static site generator page could use data like:

- `title`
- `domain`
- `location`
- `contact_name`
- `contact_email`
- `node_type`
- `public_endpoints`
- `tor_endpoints`
- `zmq_enabled`
- `https_enabled`
- `tor_enabled`

Example conceptual model:

- `domain`: public DNS name
- `node_type`: `Full` or `Pruned`
- `public_endpoints.p2p`: `tcp://example.com:18080`
- `public_endpoints.rpc`: `https://example.com:18089`
- `tor_endpoints.rpc`: `http://exampleonionaddress.onion:18089`

---

## Suggested Static Site Generator Content Split

To migrate this documentation into a static site generator later, the following page structure is recommended.

### Section: Getting Started

Suggested pages:

- Overview
- Requirements
- Quick Start
- Supported Configurations

### Section: Installation

Suggested pages:

- Running the Installer
- Interactive Questions
- Package Installation
- Service Setup

### Section: Configuration

Suggested pages:

- `monerod.conf`
- systemd service
- Tor integration
- HTTPS and Caddy
- ZMQ
- Ban list
- Pruning

### Section: Operations

Suggested pages:

- Starting and stopping services
- Checking logs
- Certificate rotation
- Upgrades
- Troubleshooting

### Section: Website

Suggested pages:

- Landing page template
- Template variables
- Styling customization
- Moving to a static site generator

### Section: Reference

Suggested pages:

- Ports
- Paths
- Services
- File reference
- Feature matrix

---

## Feature Matrix

| Feature | Supported | Notes |
| --- | --- | --- |
| Debian-based install | Yes | Primary target |
| Fedora-based install | Partial | Warning present in script |
| Public P2P node | Yes | Port `18080` |
| Public restricted RPC | Yes | Port `18089` |
| HTTPS website | Yes | Uses Caddy |
| TLS for RPC | Yes | Certificate sync required |
| Tor hidden service | Yes | Configured through `torrc` |
| ZMQ | Yes | Optional |
| Blockchain pruning | Yes | Optional |
| Full RandomX memory mode | Yes | Only prompted when RAM is sufficient |
| Existing Caddy config preservation | Partial | Old file is backed up, merge is manual |

---

## Common Paths Reference

| Path | Purpose |
| --- | --- |
| `/etc/monero/monerod.conf` | Active Monero node configuration |
| `/etc/systemd/system/monerod.service` | Installed Monero systemd unit |
| `/etc/systemd/system/cert-watcher-xmr.service` | Certificate watcher systemd unit |
| `/var/lib/monero` | Monero data directory |
| `/var/lib/monero/certificates` | Monero TLS certificate storage |
| `/var/log/monero` | Monero logs |
| `/srv/<domain>` | Static landing page root |
| `/etc/caddy/Caddyfile` | Active Caddy configuration |
| `/etc/caddy/Caddyfile.old` | Backed up previous Caddy configuration |

---

## Common Ports Reference

| Port | Protocol | Purpose |
| --- | --- | --- |
| `18080` | TCP | Monero P2P |
| `18089` | TCP | Restricted Monero RPC |
| `18083` | TCP | ZMQ |
| `80` | TCP | HTTP for Caddy / ACME / redirect |
| `443` | TCP | HTTPS for Caddy |
| `8080` | TCP | Local site binding for Tor website exposure |
| `9050` | TCP | Tor proxy used by `monerod` |

---

## Operational Notes

## Logs

The Monero log file is configured at:

- `/var/log/monero/monero.log`

## Service Management

Typical service operations include:

- enable `monerod`
- start `monerod`
- restart `monerod`
- inspect service status through systemd
- inspect logs through standard Linux logging workflows

## Caddy Merge Warning

If the machine already had a populated Caddy configuration, the generated Caddyfile will not preserve custom routing automatically. The original configuration is only backed up.

## Certificate Rotation

When HTTPS is enabled, Caddy handles certificate issuance and renewal. The watcher service is what keeps `monerod` aligned with renewed certificates.

---

## Limitations and Caveats

- The installer is interactive, so it is not yet ideal for fully automated provisioning pipelines
- Fedora-like support is incomplete
- Existing Caddy setups require manual merging
- The certificate sync uses polling instead of event-driven monitoring
- The landing page is a static template rather than a reusable data-driven site structure
- No formal test suite or validation layer is documented in the current repository contents
- The setup assumes direct execution on the target host rather than containerized deployment

---

## Improvement Opportunities

Potential future enhancements include:

1. Non-interactive CLI flags
2. Safer templating rather than raw in-place substitution
3. Better validation for domain and email inputs
4. More resilient Caddy config merging
5. Event-driven certificate synchronization
6. Support for more distributions
7. Richer node status page with health metrics
8. Split documentation into modular pages
9. Formal release/versioning notes
10. A migration path to static-site-based docs and website generation

---

## Suggested Documentation Front Matter for Future Migration

If this file is migrated into a static site generator, a front matter block like this may be useful:

```/dev/null/example.yml#L1-10
title: Monerod Node Setup Scripts
description: Deploy and manage a public Monero node with optional HTTPS and Tor support
sidebar:
  label: Project Documentation
tags:
  - monero
  - monerod
  - self-hosting
  - debian
  - tor
```

---

## Suggested Future Navigation Tree

- Overview
- Requirements
- Quick Start
- Installation Flow
- Configuration Options
- File Reference
- Service Reference
- Website Template
- Tor and HTTPS
- Operations
- Troubleshooting
- Roadmap

---

## Maintainer Notes

This documentation is written to support two goals:

1. Explain the repository in its current script-driven form
2. Provide clean content boundaries for future migration into a static site generator

When expanding this file later, prefer:

- one concept per section
- stable headings
- reusable terminology
- tables for operational references
- explicit path and port references
- template/data-model thinking for generated assets

---

## Quick Start Summary

If you only need the shortest operational summary:

1. Run `setup_monerod.sh` as `root`
2. Answer the interactive questions
3. Open the required ports
4. Ensure DNS is pointed correctly if using HTTPS
5. Let the script install packages, configure files, and enable services
6. Check:
   - `/etc/monero/monerod.conf`
   - `/var/log/monero`
   - `/srv/<domain>/index.html` when HTTPS is enabled
   - `/etc/caddy/Caddyfile.old` if you had a previous Caddy setup

---

## Glossary

### `monerod`

The Monero node daemon.

### Restricted RPC

A public RPC mode intended to expose safer public access without granting full administrative control.

### Pruned Node

A node that stores a reduced form of blockchain data to save disk space.

### Full Node

A node that stores the full blockchain data set.

### ZMQ

ZeroMQ-based publisher interface often used by related Monero ecosystem tools such as P2Pool.

### Hidden Service

A Tor service reachable through an `.onion` address.

### Caddy

A web server used here for HTTPS site hosting and automatic certificate management.

---

## Final Notes

`DOCS.md` should be treated as the authoritative long-form project documentation moving forward.

If this repository later adopts a static site generator, this document can be split into:

- overview pages
- setup guides
- reference pages
- operational runbooks
- website/template documentation

That split should require minimal rewriting because the structure here is already page-oriented.