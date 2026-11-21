#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_URL="${DB2_GATEWAY_URL:-http://127.0.0.1:50050}"
ADMIN_KEY="${DB2_ADMIN_KEY:-shop-db2-admin-bootstrap}"
MAX_WAIT="${DB2_WAIT_SECONDS:-300}"
RESET_MODE=0

for arg in "$@"; do
    case "$arg" in
        --reset) RESET_MODE=1 ;;
        *)
            echo "Usage: $0 [--reset]" >&2
            exit 2
            ;;
    esac
done

echo "Waiting for db2-gateway health at ${GATEWAY_URL}/health (up to ${MAX_WAIT}s)..."
elapsed=0
while ! curl -fsS "${GATEWAY_URL}/health" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: db2-gateway did not become healthy within ${MAX_WAIT}s" >&2
        exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
echo "db2-gateway is healthy (${elapsed}s)."

python3 - "$GATEWAY_URL" "$ADMIN_KEY" "$RESET_MODE" \
    "$ROOT_DIR/sql/schema_db2.sql" \
    "$ROOT_DIR/sql/procs_db2.sql" \
    "$ROOT_DIR/sql/seed.sql" <<'PY'
import json, sys, urllib.request, urllib.error

url = sys.argv[1].rstrip("/") + "/admin/ddl"
admin_key = sys.argv[2]
reset_mode = sys.argv[3] == "1"
files = sys.argv[4:]

def split_sql(text):
    term = ";"
    lines = text.splitlines(True)
    cleaned = []
    for line in lines:
        stripped = line.strip()
        if stripped.upper().startswith("--#SET TERMINATOR "):
            term = stripped.split()[-1]
            continue
        cleaned.append(line)
    text = "".join(cleaned)

    stmts = []
    cur = []
    in_sq = False
    i = 0
    n = len(text)
    tlen = len(term)
    while i < n:
        ch = text[i]
        if not in_sq and ch == '-' and i + 1 < n and text[i+1] == '-':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if ch == "'":
            if in_sq and i + 1 < n and text[i+1] == "'":
                cur.append("''")
                i += 2
                continue
            in_sq = not in_sq
            cur.append(ch)
        elif not in_sq and text[i:i+tlen] == term:
            s = "".join(cur).strip()
            if s:
                stmts.append(s)
            cur = []
            i += tlen
            continue
        else:
            cur.append(ch)
        i += 1
    tail = "".join(cur).strip()
    if tail:
        stmts.append(tail)
    return stmts

def exec_ddl(sql, ignore_tokens=()):
    data = json.dumps({"sql": sql, "params": []}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-Admin-Key": admin_key,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        if any(tok in body for tok in ignore_tokens):
            return False
        print(f"ERROR on SQL:\n{sql}\nResponse: {body}", file=sys.stderr)
        sys.exit(1)

if reset_mode:
    print("Resetting SHOPDB objects (--reset)...")
    reset_stmts = [
        "DROP VIEW v_category_olap",
        "DROP VIEW v_orders_masked",
        "ALTER TABLE products DROP VERSIONING",
        "ALTER TABLE orders DROP VERSIONING",
        "ALTER TABLE shipments DROP VERSIONING",
        "ALTER TABLE subscriptions DROP VERSIONING",
        "DROP TABLE subscriptions",
        "DROP TABLE subscriptions_history",
        "DROP TABLE memberships",
        "DROP TABLE membership_tiers",
        "DROP TABLE tax_nexus",
        "DROP TABLE shipments",
        "DROP TABLE shipments_history",
        "DROP TABLE po_lines",
        "DROP TABLE purchase_orders",
        "DROP TABLE warehouse_stock",
        "DROP TABLE warehouses",
        "DROP TABLE order_items",
        "DROP TABLE orders",
        "DROP TABLE orders_history",
        "DROP TABLE products",
        "DROP TABLE products_history",
        "DROP TABLE promo_codes",
        "DROP TABLE addresses",
        "DROP TABLE users",
    ]
    for s in reset_stmts:
        exec_ddl(s, ignore_tokens=("SQL0204N", "42704", "SQL20490N", "SQL20491N", "SQL20525N", "428HZ", "42893", "55019"))
    print("  reset complete.")

# Idempotent ignore tokens:
#   SQL0601N / 42710: object already exists
#   SQL0803N / 23505: duplicate key (seed rows)
#   SQL20491N / 42893 / 55019: versioning already enabled
IDEMPOTENT_TOKENS = ("SQL0601N", "42710", "SQL0605W", "01550", "SQL0803N", "23505", "SQL20490N", "SQL20491N", "428HM", "42893")

for path in files:
    print(f"Applying {path}...")
    with open(path, "r", encoding="utf-8") as f:
        stmts = split_sql(f.read())
    applied = 0
    skipped = 0
    for s in stmts:
        if exec_ddl(s, ignore_tokens=IDEMPOTENT_TOKENS):
            applied += 1
        else:
            skipped += 1
    print(f"  done: {applied} applied, {skipped} already present.")
PY

echo "Db2 SHOPDB initialization complete."
