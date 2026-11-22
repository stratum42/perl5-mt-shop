# How-To Guide

This guide walks through installing `perl5-mt-shop`, starting the storefront,
navigating the terminal UI, enabling admin access, running a 2-node cluster,
and executing tests, benchmarks, and fuzzers.

## 1. Install with `install.pl`

`install.pl` runs on stock system Perl (`/usr/bin/perl`) with core modules
only. It detects your OS, CPU architecture, compiler, PGO tooling, and package
manager (`brew`, `apt-get`, `dnf`, `yum`, `pacman`, or `apk`), installs missing
system libraries (`libsodium`, `openssl`, `zlib`, `pkg-config`, `sqlite3`,
`git`, `make`), clones `perl5-mt` and `mojolicious-mt` if absent, builds all
XS extensions, configures `config/shop.json`, writes `./bin/start-shop`, and
runs `make test`.

### Interactive Install

```sh
perl install.pl
```

The interactive prompt asks for your database backend (`sqlite`, `db2`,
`informix`, or `both`) and whether to enable Profile-Guided Optimization
(`--pgo`) and native CPU tuning (`--native`).

### Non-Interactive Installs

```sh
# Local SQLite (fastest way to get started)
perl install.pl --db sqlite --yes

# IBM Db2 Community Edition + KeyDB with PGO enabled
perl install.pl --db db2 --pgo --yes

# IBM Informix + KeyDB
perl install.pl --db informix --yes

# Build libsodium, OpenSSL 3.5.0 (for ML-KEM-768), and zlib from GitHub source
# into <prefix>/deps (also used automatically if no package manager is present)
perl install.pl --db sqlite --deps-from-source --yes

# Preview the full plan and exact commands without modifying files or Docker
perl install.pl --dry-run --yes --db db2 --pgo
```

If port `127.0.0.1:6379` is already in use, `install.pl` automatically assigns
`KEYDB_PORT=6380` in Docker Compose, `config/shop.json`, and `bin/start-shop`.

## 2. Start the Server and Connect

Start the SSH storefront (default port `2222`) and embedded HTTP ops server
(default port `8088`):

```sh
./bin/start-shop
```

Connect from another terminal with OpenSSH (`-C` enables delayed
`zlib@openssh.com` compression):

```sh
ssh -C -p 2222 localhost
```

Verify the HTTP ops endpoints:

```sh
curl -s http://127.0.0.1:8088/healthz
curl -s http://127.0.0.1:8088/metrics | head -n 20
```

## 3. Storefront Terminal UI Walkthrough

Navigation works with keyboard shortcuts and SGR mouse clicks/scroll wheel:

- **Catalog (`1`)**: Browse products by category (`Tab` or `[` / `]`), move
  selection (`Up`/`Down`, `j`/`k`, or scroll wheel), and press `/` to search
  by name or SKU.
- **Product Detail (`Enter`)**: Inspect full SKU details, warehouse stock, and
  pricing. Press `a` to add to cart, or press `S` to create a 30-day recurring
  subscription for that item.
- **Cart (`2`) and Promo Codes**: Adjust item quantities with `+` / `-`, apply
  promo codes such as `PERLMT20` (20% off) or `SSH10` ($10 off), and proceed
  to checkout.
- **Checkout**: Cycle Shippo carrier rate quotes (`s` or `Left`/`Right`), view
  state-level tax nexus calculation (computed with exact `MT::Decimal`
  decimal128 arithmetic), and confirm the order.
- **Orders (`3`)**: Review completed orders, shipping labels, and Ed25519
  signed order receipts. Press `R` or `f` for express reorder using your saved
  payment method and default address.
- **Account (`4`)**: View your SSH key fingerprint, saved addresses, and
  payment methods.
- **Subscriptions & Memberships (`8`)**: Enroll in or upgrade membership tiers
  (`1` Free, `2` Pro, `3` Founder, `u` upgrade, `x` cancel) for automatic
  member discounts and free shipping. Manage active product subscriptions with
  `p` (pause/resume), `k` (skip next delivery), and `c` (cancel).
- **Disconnect**: Press `q` or `Ctrl-C` to close the session cleanly, or
  `Ctrl-L` to force a full screen redraw.

## 4. Becoming an Admin

`install.pl` automatically detects `~/.ssh/id_ed25519.pub` (or
`~/.ssh/id_rsa.pub`), extracts its `SHA256:...` fingerprint via `ssh-keygen`,
and adds it to `admin_fingerprints` in `config/shop.json`.

To register an admin key manually:

```sh
# 1. Print your public key fingerprint
ssh-keygen -lf ~/.ssh/id_ed25519.pub

# 2. Add the SHA256:... token to config/shop.json under "admin_fingerprints"
#    or export it for a single run:
SHOP_ADMIN_FP="SHA256:your_fingerprint_here" ./bin/start-shop
```

Once connected with an authorized admin key, open the **Admin** view (`5` or
`7` depending on active tabs):

- **Inventory & Broadcasts**: Adjust SKU stock levels in real time (persisted
  and propagated across active sessions) and send live broadcast banners to
  connected shoppers.
- **Time-Travel & OLAP (`t` / `T`)**: Query historical inventory/order
  snapshots and OLAP rollups (supported on Db2 and Informix backends).
- **Logistics & Nexus (`l` / `L`)**: Inspect multi-warehouse routing (`DAL1`,
  `NYC1`, `SFO1`), tax nexus thresholds, and inbound purchase orders. Press `/`
  in Logistics to scan SKUs (supports USB/Bluetooth barcode scanners sending
  rapid keystrokes + Enter) to receive inbound inventory.

## 5. Running a 2-Node Cooperative Cluster over KeyDB

Cooperative wavefunction clustering distributes SSH sessions across multiple
`perl5-mt-shop` nodes using KeyDB for load-repulsive routing, L4 TCP splice
forwarding, and shared DoS blackhole bans.

1. Start KeyDB (or reuse the KeyDB container started by `install.pl`):

```sh
KEYDB_PORT=6379 docker compose -f docker/docker-compose.yml up -d keydb
```

2. Launch two nodes on distinct SSH and ops ports:

```sh
# Terminal 1: node-a
./bin/start-shop --cluster --node-id node-a --port 2222 --ops-port 8088 --advertise-host 127.0.0.1

# Terminal 2: node-b
./bin/start-shop --cluster --node-id node-b --port 2223 --ops-port 8089 --advertise-host 127.0.0.1
```

3. Inspect cluster membership, session distribution, and DoS blackhole metrics:

```sh
# Cluster peer table, wavefunction weights, and blackhole counters (JSON)
curl -s http://127.0.0.1:8088/api/cluster

# Prometheus metrics including cluster and blackhole stats
curl -s http://127.0.0.1:8088/metrics | grep -E 'shop_cluster|shop_blackhole|shop_sessions'
```

## 6. Tests, Benchmarks, and Fuzzers

### Test Suite

Runs all 16 test files (`t/01_crypto.t` through `t/16_installer.t`):

```sh
make test
```

To include live Docker tests against Db2, Informix, and KeyDB:

```sh
SHOP_TEST_DOCKER=1 make test
```

### Performance and Egress Benchmarks

Measures 100-frame TUI ANSI diff egress (raw and compressed), `MT::Decimal`
checkout pricing throughput, and 8-worker `MT::Cell` CAS inventory throughput:

```sh
make bench
```

### Fuzzing

```sh
# Extended pure-Perl + XS SSH/Crypto/Wire/TUI/JSON fuzz suite (default 100,000 iters)
make fuzz

# AFL++ persistent-mode C/XS crypto fuzzer + ASan/UBSan corpus replay (default 60s)
make fuzz-afl
```
