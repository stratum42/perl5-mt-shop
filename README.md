# perl5-mt-shop

An SSH storefront written in `perl5-mt`.

Users connect with a standard OpenSSH client, browse a catalog, manage a cart,
place orders, inspect receipts, and (with an authorized admin key) operate
inventory, purchase orders, outbound shipments, and database audit views from a
terminal UI.

## Features

- Native SSHv2 transport (`Shop::SSH::*`) with `mlkem768x25519-sha256` and
  `curve25519-sha256` key exchange, `kex-strict-s-v00@openssh.com`,
  `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com` AEAD ciphers,
  and delayed `zlib@openssh.com` compression.
- Public-key authentication (`ssh-ed25519`, `ecdsa-sha2-nistp256`,
  `rsa-sha2-256`, `rsa-sha2-512`) plus optional guest login.
- Double-buffered 2D cell ANSI diff renderer (`Shop::TUI::Screen`) with SGR
  mouse support, Unicode grapheme width handling, and automatic color
  degradation (`truecolor`, `256`, `16`).
- In-process lock-free inventory reservations using `MT::Cell` compare-and-swap
  (`MT::SharedHash` + per-SKU `MT::Cell`), periodic `MT::Checkpoint` snapshots,
  and cross-worker notifications over `MT::Channel`.
- Exact decimal financial arithmetic via `MT::Decimal` (IEEE 754-2008
  decimal128, `ROUND_HALF_UP`).
- Signed order receipts (SHA-256 over canonical JSON, signed with the server's
  Ed25519 host key).
- Three storage drivers: SQLite (default local mode), IBM Db2 Community Edition
  (51 static SQL PL stored procedures), and IBM Informix (67 static SPL
  procedures and triggers, including 51 `shop_sp_*` procedures), plus optional
  KeyDB for cart leases, session resume, and rate/quote caching.
- Multi-warehouse fulfillment routing (`DAL1`, `NYC1`, `SFO1`), inbound
  purchase order receiving, Shippo carrier rate quotes and labels, and
  state-level tax nexus calculation.
- Memberships (`FREE`, `PRO`, `FOUNDER`) with automatic `MT::Decimal` member
  discounts and free shipping, plus recurring product subscriptions with
  idempotent scheduled renewals and Admin MRR reporting.
- Embedded HTTP ops and webhook worker (`Shop::Web::App` on `mojolicious-mt`
  with `Mojo::Server::Daemon`, `Mojo::Reactor::MT`, and `Mojo::MT::Accel`)
  serving `GET /healthz`, Prometheus `GET /metrics`, `GET /api/catalog`,
  `GET /api/memberships`, `GET /api/cluster`, `POST /webhooks/stripe`, and
  `POST /webhooks/shippo`.
- Optional cooperative multi-node SSH clustering (`Shop::Cluster::Wavefunction`,
  `Shop::Cluster::Mesh`) over KeyDB with deterministic load-repulsive routing
  and raw L4 TCP splice forwarding (disabled by default), plus a pre-fiber O(1)
  DoS blackhole (`Shop::Cluster::Blackhole`) that shunts banned peers with
  `SO_LINGER {1, 0}` and zero egress bytes.

## Requirements

- A built `perl5-mt` interpreter (defaults to `PERL5_MT_ROOT=../perl5-mt` or
  `perl5-mt` on `PATH`).
- Optional `mojolicious-mt` checkout (defaults to
  `MOJOLICIOUS_MT_ROOT=../mojolicious-mt`) for the embedded `Shop::Web::App`
  HTTP ops and webhook server (falls back to a raw-socket HTTP/1.1 listener if
  absent).
- `libsodium`, OpenSSL 3/4 (`libcrypto`), `zlib`, and `pkg-config` for building
  the `xs/Shop-SSH-Crypto` extension.
- OpenSSH (`ssh`, `ssh-keygen`) for host key generation and connecting.
- Docker with Compose if running IBM Db2, IBM Informix, or KeyDB.

## Quick Start

### SQLite (Local)

```sh
# Build the XS crypto/zlib extension and generate config/host_ed25519_key
make crypto hostkey

# Run the test suite (t/01_crypto.t through t/15_ssh_fuzz.t)
make test

# Run the AFL++ persistent-mode C/XS crypto fuzzer + ASan/UBSan corpus replay (default 60s)
make fuzz-afl

# Start the SSH storefront (:2222) and ops HTTP server (:8088)
make run

# Connect in another terminal
ssh -C -p 2222 localhost
```

### IBM Db2 Community Edition + KeyDB (Docker)

```sh
make docker-up
make init-db2
SHOP_DB_DRIVER=db2 make run
```

### IBM Informix (Docker)

```sh
docker compose -f docker/docker-compose.yml up -d --build informix informix-gateway
make init-informix
SHOP_DB_DRIVER=informix make run
```

To grant admin access to an SSH key, add its `SHA256:...` fingerprint to
`admin_fingerprints` in `config/shop.json` or set `SHOP_ADMIN_FP`.

## Controls

| Key / Input | Action |
|---|---|
| `1`..`5`, `8` or Mouse Click | Switch views: Shop, Cart, Orders, Account, Admin, Subscriptions |
| `Up`/`Down`, `j`/`k`, Wheel | Move selection in lists |
| `/` | Catalog search (or SKU scan in Admin Logistics) |
| `Tab` / `[` `]` | Switch category or Admin sub-tabs |
| `Enter` | Open product detail or confirm action |
| `a` | Add selected item to cart |
| `S` (Product Detail) | Create a 30-day recurring subscription for the item |
| `1`/`2`/`3`, `u`, `x` (Subscriptions) | Enroll/upgrade membership tier or cancel membership |
| `p`, `k`, `c` (Subscriptions) | Pause/resume, skip next delivery, or cancel selected subscription |
| `R` / `f` | Express reorder using saved payment method and default address |
| `+` / `-` | Adjust quantity or stock |
| `s` / `Left` `Right` (Checkout) | Cycle shipping carrier rates |
| `t` / `T` (Admin) | Open Time-Travel and OLAP sub-tab |
| `l` / `L` (Admin) | Open Logistics and Nexus sub-tab |
| `Ctrl-L` | Force full screen redraw |
| `q` / `Ctrl-C` | Disconnect cleanly |

## Measured Numbers

Measured on Apple Silicon (macOS arm64) using `make bench`
(`bin/bench-egress-and-perf`) and a standalone 1,000-fiber RSS check:

### 100-Frame 80x24 TUI Egress (`bin/bench-egress-and-perf`)

| Mode | Bytes / 100 frames | Reduction vs full-frame |
|---|---:|---:|
| Full-frame ANSI (uncompressed) | 516,690 | 0.0% |
| Line-diff ANSI (uncompressed) | 66,718 | 87.1% |
| Cell-diff ANSI (raw) | 30,400 | 94.1% |
| Cell-diff ANSI + `zlib@openssh.com` | 2,548 | 99.5% |

### Throughput (`bin/bench-egress-and-perf`)

- `MT::Decimal` checkout pricing (10,000 iterations, 3 items + promo + tax):
  37,226 calculations/sec (268.63 ms).
- 8-worker `MT::Cell` CAS inventory (80,000 ops: 40,000 reserve + 40,000
  release across 8 `MT::Worker` OS threads): 645,885 CAS ops/sec (123.86 ms),
  zero stock drift.

### 1,000-Fiber Memory Footprint (`MT_FIBER_STACK=32768`)

- 1,000 concurrent idle fibers: 20.0 MiB RSS delta (20.5 KiB per fiber).
- 1,000 concurrent fibers each holding an allocated 80x24 `Shop::TUI::Screen`:
  130.9 MiB RSS delta (134.0 KiB per fiber).

Numbers vary with CPU, OS allocator, terminal dimensions, and frame entropy.

## Limitations

- **Custom SSHv2 transport**: `Shop::SSH::*` works with current OpenSSH clients
  and passes its own security test suite (`t/07_ssh_security.t`), including
  strict-KEX, rekeying, and zip-bomb caps. It has not been fuzzed at internet
  scale and should not be exposed directly to untrusted public traffic without
  further auditing and hardening.
- **Db2 and Informix HTTP gateways on macOS arm64**: IBM does not distribute an
  arm64 macOS CLI/ODBC client library. In this setup, Db2 and Informix run in
  `linux/amd64` Docker containers behind small Python `ibm_db` HTTP gateways
  (`127.0.0.1:50050` and `127.0.0.1:50051`). On Linux `x86_64`/`ppc64le` or
  AIX, a native CLI/ODBC driver would remove that extra hop.
- **Payment, shipping, and tax defaults**: When `STRIPE_SECRET_KEY` or
  `SHIPPO_API_TOKEN` are unset, Stripe and Shippo fall back to deterministic
  local sandboxes. Sales tax is driven by the `tax_nexus` table (state-level
  rates and thresholds) rather than a full multi-jurisdiction tax engine.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): Process model, concurrency,
  SSHv2 + XS crypto, ANSI diff renderer, hot-tier state, and measurement setup.
- [docs/DATABASES.md](docs/DATABASES.md): SQLite, IBM Db2, IBM Informix, and
  KeyDB setup, stored-procedure gateways, decimal types, history tables, and
  OLAP views.
- [docs/OPERATIONS.md](docs/OPERATIONS.md): Configuration, CLI flags,
  environment variables, admin keys, HTTP ops/webhooks, warehouse receiving,
  and tests/benchmarks.
- [docs/IBM_CLOUD.md](docs/IBM_CLOUD.md): Low-cost single-instance IBM Cloud
  VPC deployment guide (sizing, `ibmcloud is` provisioning, `systemd`, Caddy
  TLS, and cost controls).
