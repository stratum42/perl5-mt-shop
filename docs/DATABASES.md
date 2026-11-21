# Databases and Caching

`perl5-mt-shop` supports three relational storage drivers behind `Shop::DB`
(`sqlite`, `db2`, and `informix`) plus optional KeyDB caching
(`Shop::Cache::KeyDB`).

## Driver Overview

| Driver | Module | Schema | Stored Procedures | Transport |
|---|---|---|---|---|
| `sqlite` | `Shop::DB::SQLite` | `sql/schema_sqlite.sql` | N/A (local embedded) | Direct SQLite file (`var/shop.db`) |
| `db2` | `Shop::DB::Db2` | `sql/schema_db2.sql` | `sql/procs_db2.sql` (42 SQL PL procs) | HTTP gateway (`127.0.0.1:50050`) -> Db2 (`:50000`) |
| `informix` | `Shop::DB::Informix` | `sql/schema_informix.sql` | `sql/procs_informix.sql` (42 SPL procs) | HTTP gateway (`127.0.0.1:50051`) -> Informix DRDA (`:9089`) |

All three schemas share the same core tables:
`products`, `users`, `addresses`, `promo_codes`, `orders`, `order_items`,
`warehouses`, `warehouse_stock`, `purchase_orders`, `po_lines`, `shipments`,
and `tax_nexus`.

Select the driver in `config/shop.json` (`db.driver`), via `--db-driver
sqlite|db2|informix`, or with the `SHOP_DB_DRIVER` environment variable.

## Stored-Procedure-Only Gateways (`db2` and `informix`)

On macOS arm64, IBM does not distribute native arm64 CLI/ODBC client libraries.
Both Db2 and Informix therefore run in `linux/amd64` Docker containers
(`docker/docker-compose.yml`) behind small Python `ibm_db` HTTP/1.1 keep-alive
gateways (`docker/db2-gateway/server.py` and
`docker/informix-gateway/server.py`). On Linux `x86_64`/`ppc64le` or AIX, a
native CLI/ODBC driver could talk to the database directly without the HTTP
hop.

Both gateways enforce stored-procedure-only execution at runtime by default:

- `DB2_SP_ONLY=1` (default) on `db2-gateway`
- `INFORMIX_SP_ONLY=1` (default) on `informix-gateway`

When enabled:

- Ad-hoc SQL endpoints (`/query`, `/tx/query`, `/tx/exec`) return HTTP `403`
  (`SQL_INJECTION_BLOCKED`).
- All runtime reads and writes go through `POST /sp/call` and
  `POST /tx/sp/call` against an explicit allowlist of 42 static `SHOP_SP_*`
  procedures with checked parameter arity. None of the procedures use dynamic
  SQL (`PREPARE` / `EXECUTE IMMEDIATE`).
- Schema bootstrap (`POST /admin/ddl`) is gated by `X-Admin-Key`
  (`DB2_ADMIN_KEY` / `INFORMIX_ADMIN_KEY`) and is used only by the init
  scripts.
- Both gateways support gzip request/response compression and normalize column
  names to lowercase for parity with SQLite.

## Exact Decimal Types

All monetary and tax-rate calculations in Perl use `MT::Decimal` (IEEE 754-2008
decimal128, 34 digits of precision, `ROUND_HALF_UP`). Each backend preserves
exact decimal values without binary floating-point conversion:

- **SQLite**: Monetary columns (`price`, `subtotal`, `discount`, `tax`,
  `shipping`, `total`, `unit_price`, `line_total`, `total_cost`, `unit_cost`,
  `rate_amount`, `rate`, `threshold_sales`) are stored as `TEXT`.
- **IBM Db2**: Monetary and rate columns use native `DECFLOAT(34)`. The
  gateway uses a 34-digit Python `decimal.Context` and serializes `DECFLOAT`
  and `TIMESTAMP(12)` values as strings.
- **IBM Informix**: Monetary columns use `DECIMAL(32,4)` and `tax_nexus.rate`
  uses `DECIMAL(16,5)`. Timestamps use `DATETIME YEAR TO FRACTION(5)`. The
  gateway serializes all decimal and datetime columns as strings.

## Temporal Tables, Trigger Audit, and Constraints

- **Db2 System-Period Temporal Tables**: `products`, `orders`, and `shipments`
  define `PERIOD SYSTEM_TIME (sys_start, sys_end)` with `TIMESTAMP(12)`
  generated columns, an implicitly hidden `trans_start` column, and paired
  history tables (`products_history`, `orders_history`, `shipments_history`)
  with `COMPRESS YES ADAPTIVE`. History queries use `FOR SYSTEM_TIME` via
  `SHOP_SP_PRODUCT_HISTORY`, `SHOP_SP_CATALOG_AS_OF`, and
  `SHOP_SP_ORDER_HISTORY`. Atomic updates use `SELECT FROM FINAL TABLE` and
  upserts use `MERGE INTO`.
- **Informix SPL Audit Triggers**: `products_audit`, `orders_audit`, and
  `shipments_audit` are populated by `CREATE TRIGGER` + SPL routines in
  `sql/procs_informix.sql`, exposing the same history query shapes to
  `Shop::DB`.
- **SQLite**: Provides fallback implementations of the history and OLAP
  methods so the TUI and test suite run locally without Docker.
- **Database Constraints**: `CHECK` constraints enforce `stock >= 0`,
  `price >= 0`, `qty > 0` on `order_items`, `qty >= 0` on `warehouse_stock`,
  and `qty_ordered > 0` / `qty_received >= 0` on `po_lines`.

## OLAP Rollup and Masked Views

- **Category OLAP (`v_category_olap` / `SHOP_SP_CATEGORY_OLAP`)**: Computes
  per-category order count, units sold, exact revenue, revenue share
  percentage, and `RANK() OVER (...)` alongside a grand-total `ALL CATEGORIES`
  row via `GROUP BY ROLLUP(category)`. Displayed in the Admin `[T]` sub-tab.
- **Masked Orders View (`v_orders_masked` / `SHOP_SP_LIST_ORDERS_MASKED`)**:
  Masks `shipping_address` values for non-admin inspection.

## Schema and Seed Initialization

`sql/seed.sql` is shared across all three backends and seeds:

- 12 catalog products across Terminals, Keyboards, Apparel, Security, Books,
  Hardware, and Accessories.
- 2 promo codes (`PERLMT20` for 20% off, `SSH10` for $10 off orders >= $50).
- 3 warehouses (`DAL1` Dallas, `NYC1` Newark, `SFO1` Oakland) with per-hub
  stock splits matching `products.stock`.
- 2 sample inbound purchase orders (`PO-2026-001`, `PO-2026-002`).
- 6 state tax nexus rows (`TX`, `CA`, `NY` registered; `WA`, `FL`, `IL`
  monitored).

### Initializing Each Backend

- **SQLite**: Automatic on first start of `bin/shop-server` if `products` is
  empty.
- **IBM Db2**:
  ```sh
  make docker-up
  make init-db2
  # Pass --reset to drop and recreate all tables, views, and procedures:
  ./docker/init-db2.sh --reset
  ```
- **IBM Informix**:
  ```sh
  docker compose -f docker/docker-compose.yml up -d --build informix informix-gateway
  make init-informix
  # Pass --reset for a clean rebuild:
  ./docker/init-informix.sh --reset
  ```

Both init scripts wait for gateway `/health`, apply schema, procedures, and
seed SQL idempotently through `/admin/ddl`, and exit non-zero on failure.

## KeyDB

`lib/Shop/Cache/KeyDB.pm` is a pure-Perl RESP2 client with pipelining, key
prefixing (default `s:`), and Lua `EVALSHA` (with automatic `NOSCRIPT`
fallback). KeyDB is optional; if unreachable at startup, the server continues
in-process without it. When available, KeyDB is used for:

- Cart reservation leases with TTL (`workers.lease_ttl_sec`, default 900 s).
- Session state resume on reconnect.
- Caching Shippo carrier rate quotes (6-hour TTL) and `tax_nexus` lookups
  (24-hour TTL).
- Sliding/fixed-window rate limiting and pub/sub helpers.
