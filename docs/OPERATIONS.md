# Operations

This guide covers configuration, CLI flags, environment variables, admin key
setup, HTTP ops and webhook endpoints, warehouse receiving, and running the
test and benchmark suites.

## Configuration (`config/shop.json`)

Default settings in `config/shop.json`:

```json
{
  "ssh": {
    "host": "0.0.0.0",
    "port": 2222,
    "host_key": "config/host_ed25519_key",
    "allow_guest": true,
    "compression_level": 5,
    "rate_limit_per_min": 60
  },
  "ops": {
    "host": "127.0.0.1",
    "port": 8088,
    "webhook_secret": "whsec_dev_perl5_mt_shop"
  },
  "workers": {
    "session_workers": 4,
    "db_pool_workers": 2,
    "checkpoint_interval_sec": 30,
    "lease_ttl_sec": 900
  },
  "db": {
    "driver": "sqlite",
    "sqlite_path": "var/shop.db",
    "gateway_url": "http://127.0.0.1:50050",
    "informix_gateway_url": "http://127.0.0.1:50051",
    "schema_db2": "sql/schema_db2.sql",
    "schema_informix": "sql/schema_informix.sql",
    "schema_sqlite": "sql/schema_sqlite.sql",
    "seed_sql": "sql/seed.sql"
  },
  "keydb": {
    "host": "127.0.0.1",
    "port": 6379,
    "prefix": "s:"
  },
  "checkpoint": {
    "path": "var/inventory.mtck"
  },
  "stripe": {
    "secret_key": "",
    "webhook_secret": "whsec_dev_perl5_mt_shop"
  },
  "tax_rate": "0.0825",
  "admin_fingerprints": []
}
```

## CLI Flags (`bin/shop-server`)

```sh
bin/shop-server \
  [--config path] \
  [--host addr] \
  [--port N] \
  [--db-driver sqlite|db2|informix] \
  [--ops-host addr] \
  [--ops-port N] \
  [--no-ops]
```

- `--config`: Path to JSON config file (default `config/shop.json`).
- `--host`, `--port`: Override `ssh.host` and `ssh.port`.
- `--db-driver`: Override `db.driver` (`sqlite`, `db2`, or `informix`).
- `--ops-host`, `--ops-port`: Override the HTTP ops/webhook bind address and
  port.
- `--no-ops`: Disable the embedded HTTP ops/webhook worker (equivalent to
  `--ops-port 0`).

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `PERL5_MT_ROOT` | Path to the `perl5-mt` build tree (used by `Makefile`) | `../perl5-mt` |
| `MOJOLICIOUS_MT_ROOT` | Path to the `mojolicious-mt` checkout (used by `Makefile` and `bin/shop-server`) | `../mojolicious-mt` |
| `SHOP_DB_DRIVER` | Override `db.driver` (`sqlite`, `db2`, `informix`) | From config |
| `SHOP_ADMIN_FP` | Comma-separated SSH key fingerprints (`SHA256:...` or `*`) | From config |
| `MT_FIBER_STACK` | Per-fiber C/Perl stack size in bytes (e.g. `32768`) | `perl5-mt` default |
| `STRIPE_SECRET_KEY` | Live/test Stripe API secret key; unset uses local mock | Unset (mock) |
| `STRIPE_WEBHOOK_SECRET` | HMAC-SHA256 secret for `POST /webhooks/stripe` | `ops.webhook_secret` |
| `SHIPPO_API_TOKEN` | Shippo API token; unset uses deterministic local quotes/labels | Unset (sandbox) |
| `SHIPPO_WEBHOOK_SECRET` | HMAC-SHA256 secret for `POST /webhooks/shippo` | Unset |
| `KEYDB_HOST` | KeyDB hostname override | `127.0.0.1` |
| `KEYDB_PORT` | KeyDB port override (also used by `docker-compose.yml`) | `6379` |
| `DB2_GATEWAY_URL` | Db2 gateway URL for `docker/init-db2.sh` | `http://127.0.0.1:50050` |
| `DB2_ADMIN_KEY` | Admin key for Db2 `/admin/ddl` bootstrap | `shop-db2-admin-bootstrap` |
| `DB2_SP_ONLY` | Enforce stored-procedure-only mode in `db2-gateway` | `1` |
| `INFORMIX_GATEWAY_URL` | Informix gateway URL for `docker/init-informix.sh` | `http://127.0.0.1:50051` |
| `INFORMIX_ADMIN_KEY` | Admin key for Informix `/admin/ddl` bootstrap | `shop-informix-admin-bootstrap` |
| `INFORMIX_SP_ONLY` | Enforce stored-procedure-only mode in `informix-gateway` | `1` |
| `SHOP_TEST_DOCKER` | Set to `1` to enable live Docker tests in `t/*.t` | `0` |

## Admin SSH Key Setup

1. Print your public key's SHA-256 fingerprint:
   ```sh
   ssh-keygen -lf ~/.ssh/id_ed25519.pub
   ```
2. Copy the `SHA256:...` token into `admin_fingerprints` in `config/shop.json`:
   ```json
   "admin_fingerprints": [
     "SHA256:your_key_fingerprint_here"
   ]
   ```
   Alternatively, pass it at launch time for local testing:
   ```sh
   SHOP_ADMIN_FP='SHA256:your_key_fingerprint_here' make run
   ```
   Setting `SHOP_ADMIN_FP='*'` grants admin access to any authenticated session
   and should only be used in local development.
3. Connect with SSH (`ssh -C -p 2222 localhost`) and press `5` to open the
   Admin view.

## HTTP Ops and Webhook Endpoints

When `ops.port > 0` (default `127.0.0.1:8088`), `Shop::Webhook::Server` runs
`Shop::Web::App` on `mojolicious-mt` (`Mojo::Server::Daemon` with
`Mojo::Reactor::MT` and `Mojo::MT::Accel`) and serves:

- `GET /healthz`: Returns `200 OK` with JSON status including engine, active
  reactor, and XS accelerator state
  (`{"ok":true,"engine":"mojolicious-mt","reactor":"Mojo::Reactor::MT","accel":true}`).
- `GET /metrics`: Returns Prometheus exposition format counters and gauges from
  `Shop::Metrics`:
  - `ssh_connections_total`, `ssh_active_sessions`, `ssh_kex_pq_total`,
    `ssh_kex_classic_total`, `ssh_auth_blocked_total`
  - `ssh_egress_full_bytes`, `ssh_egress_diff_bytes`, `ssh_egress_wire_bytes`
  - `inventory_cas_ok_total`, `inventory_cas_conflict_total`
  - `orders_total`, `webhooks_processed_total`, `supervisor_faults_total`
- `GET /api/catalog`: Returns `200 OK` JSON (`{"ok":true,"count":N,"items":[...]}`)
  from the in-process hot `Shop::State::Inventory` (supports optional
  `category` and `q` query parameters).
- `POST /webhooks/stripe`: Verifies the `Stripe-Signature` header
  (`t=<ts>,v1=<hex>`) using constant-time HMAC-SHA256 with a 300-second
  timestamp tolerance, checks an `MT::SharedHash` idempotency store, updates
  order status in the database, and pushes a notification to the buyer's open
  SSH session via `EventBus`.
- `POST /webhooks/shippo`: Verifies the HMAC-SHA256 signature against
  `SHIPPO_WEBHOOK_SECRET`, maps carrier tracking events (`PRE_TRANSIT`,
  `TRANSIT`/`IN_TRANSIT`, `OUT_FOR_DELIVERY`, `DELIVERED`,
  `RETURNED`/`FAILURE`) to shipment and order statuses, updates the database,
  and pushes live tracking updates to active SSH sessions via `EventBus`.

## Warehouse Receiving and Barcode Scanner Workflow

USB or Bluetooth HID barcode scanners emulate keyboard input ending in `Enter`.
In the Admin view (`5`), press `l` or `L` to open the `[L] Logistics` sub-tab:

1. **Inbound Purchase Orders**:
   - Press `[r]` to receive 10 units against the currently highlighted open PO
     line.
   - Press `[/]` to enter SKU scan mode, scan (or type) a SKU barcode followed
     by `Enter`. The server matches the first open PO line for that SKU with
     remaining quantity (`qty_received < qty_ordered`) and receives 10 units.
   - Each receipt atomically updates `po_lines`, `purchase_orders`,
     `warehouse_stock`, and `products.stock` in the database, increments the
     in-process `MT::Cell` stock counter, and broadcasts a restock event over
     `EventBus`.
2. **Outbound Shipments**:
   - Switch panes with `[w]` or arrow keys to select an outbound shipment.
   - Press `[p]` to advance fulfillment state (`PENDING -> PICKED -> PACKED`).
   - Press `[b]` to purchase a Shippo shipping label (moving the shipment to
     `LABEL_CREATED` with a tracking number).
3. **Tax Nexus Monitoring**:
   - The Logistics sub-tab also displays state-level YTD sales and transaction
     counts against `tax_nexus` thresholds (`REGISTERED`, `NEXUS_REQUIRED`,
     `APPROACHING`, `OK`).

## Shutdown and Checkpoints

`bin/shop-server` traps `SIGINT` and `SIGTERM`, sets the shared shutdown
`MT::Cell`, closes the listening socket and connection channel, joins all
worker threads, writes a final `MT::Checkpoint` to `var/inventory.mtck`, and
shuts down the DB worker pool.

## Running Tests and Benchmarks

```sh
# Local test suite (no Docker required; Docker-only checks skip cleanly)
make test

# Full test suite including live Db2, Informix, and KeyDB containers
SHOP_TEST_DOCKER=1 make test
# If KeyDB is mapped to a non-default host port (e.g. 6380):
SHOP_TEST_DOCKER=1 KEYDB_PORT=6380 make test

# Performance and 100-frame egress benchmark
make bench
```

Optional benchmark overrides:

- `BENCH_PRICING_ITERS`: Number of `MT::Decimal` pricing iterations (default
  `10000`).
- `BENCH_CAS_PAIRS`: Reserve+release pairs per worker thread across 8 threads
  (default `5000`, i.e. 80,000 CAS ops).
