#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_URL="${INFORMIX_GATEWAY_URL:-http://127.0.0.1:50051}"
ADMIN_KEY="${INFORMIX_ADMIN_KEY:-shop-informix-admin-bootstrap}"
MAX_WAIT="${INFORMIX_WAIT_SECONDS:-300}"
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

echo "Waiting for informix-gateway health at ${GATEWAY_URL}/health (up to ${MAX_WAIT}s)..."
elapsed=0
while ! curl -fsS "${GATEWAY_URL}/health" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: informix-gateway did not become healthy within ${MAX_WAIT}s" >&2
        exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
echo "informix-gateway is healthy (${elapsed}s)."

python3 - "$GATEWAY_URL" "$ADMIN_KEY" "$RESET_MODE" \
    "$ROOT_DIR/sql/schema_informix.sql" \
    "$ROOT_DIR/sql/procs_informix.sql" \
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
    print("Resetting Informix shopdb objects (--reset)...")
    reset_stmts = [
        "DROP TRIGGER IF EXISTS trg_products_ins",
        "DROP TRIGGER IF EXISTS trg_products_upd",
        "DROP TRIGGER IF EXISTS trg_orders_ins",
        "DROP TRIGGER IF EXISTS trg_orders_upd",
        "DROP TRIGGER IF EXISTS trg_shipments_ins",
        "DROP TRIGGER IF EXISTS trg_shipments_upd",
        "DROP VIEW IF EXISTS v_orders_masked",
        "DROP PROCEDURE IF EXISTS shop_trg_products_ins",
        "DROP PROCEDURE IF EXISTS shop_trg_products_upd",
        "DROP PROCEDURE IF EXISTS shop_trg_orders_ins",
        "DROP PROCEDURE IF EXISTS shop_trg_orders_upd",
        "DROP PROCEDURE IF EXISTS shop_trg_shipments_ins",
        "DROP PROCEDURE IF EXISTS shop_trg_shipments_upd",
        "DROP PROCEDURE IF EXISTS shop_sp_current_timestamp",
        "DROP PROCEDURE IF EXISTS shop_sp_list_products",
        "DROP PROCEDURE IF EXISTS shop_sp_get_product",
        "DROP PROCEDURE IF EXISTS shop_sp_upsert_product",
        "DROP PROCEDURE IF EXISTS shop_sp_decrement_stock",
        "DROP PROCEDURE IF EXISTS shop_sp_update_product_stock",
        "DROP PROCEDURE IF EXISTS shop_sp_get_promo",
        "DROP PROCEDURE IF EXISTS shop_sp_get_user",
        "DROP PROCEDURE IF EXISTS shop_sp_upsert_user",
        "DROP PROCEDURE IF EXISTS shop_sp_save_payment_method",
        "DROP PROCEDURE IF EXISTS shop_sp_list_addresses",
        "DROP PROCEDURE IF EXISTS shop_sp_save_address",
        "DROP PROCEDURE IF EXISTS shop_sp_delete_address",
        "DROP PROCEDURE IF EXISTS shop_sp_create_order",
        "DROP PROCEDURE IF EXISTS shop_sp_add_order_item",
        "DROP PROCEDURE IF EXISTS shop_sp_list_orders",
        "DROP PROCEDURE IF EXISTS shop_sp_list_orders_masked",
        "DROP PROCEDURE IF EXISTS shop_sp_get_order",
        "DROP PROCEDURE IF EXISTS shop_sp_get_order_items",
        "DROP PROCEDURE IF EXISTS shop_sp_get_order_by_ref",
        "DROP PROCEDURE IF EXISTS shop_sp_update_order_status",
        "DROP PROCEDURE IF EXISTS shop_sp_update_order_receipt",
        "DROP PROCEDURE IF EXISTS shop_sp_gmv_summary",
        "DROP PROCEDURE IF EXISTS shop_sp_product_history",
        "DROP PROCEDURE IF EXISTS shop_sp_catalog_as_of",
        "DROP PROCEDURE IF EXISTS shop_sp_order_history",
        "DROP PROCEDURE IF EXISTS shop_sp_category_olap",
        "DROP PROCEDURE IF EXISTS shop_sp_list_warehouses",
        "DROP PROCEDURE IF EXISTS shop_sp_list_warehouse_stock",
        "DROP PROCEDURE IF EXISTS shop_sp_create_po",
        "DROP PROCEDURE IF EXISTS shop_sp_add_po_line",
        "DROP PROCEDURE IF EXISTS shop_sp_list_pos",
        "DROP PROCEDURE IF EXISTS shop_sp_get_po_lines",
        "DROP PROCEDURE IF EXISTS shop_sp_receive_po_line",
        "DROP PROCEDURE IF EXISTS shop_sp_create_shipment",
        "DROP PROCEDURE IF EXISTS shop_sp_update_shipment",
        "DROP PROCEDURE IF EXISTS shop_sp_get_shipment_by_order",
        "DROP PROCEDURE IF EXISTS shop_sp_get_shipment_by_tracking",
        "DROP PROCEDURE IF EXISTS shop_sp_list_shipments",
        "DROP PROCEDURE IF EXISTS shop_sp_get_tax_nexus",
        "DROP PROCEDURE IF EXISTS shop_sp_list_tax_nexus",
        "DROP PROCEDURE IF EXISTS shop_sp_tax_nexus_report",
        "DROP TABLE IF EXISTS tax_nexus",
        "DROP TABLE IF EXISTS shipments",
        "DROP TABLE IF EXISTS shipments_audit",
        "DROP TABLE IF EXISTS po_lines",
        "DROP TABLE IF EXISTS purchase_orders",
        "DROP TABLE IF EXISTS warehouse_stock",
        "DROP TABLE IF EXISTS warehouses",
        "DROP TABLE IF EXISTS order_items",
        "DROP TABLE IF EXISTS orders",
        "DROP TABLE IF EXISTS orders_audit",
        "DROP TABLE IF EXISTS products",
        "DROP TABLE IF EXISTS products_audit",
        "DROP TABLE IF EXISTS promo_codes",
        "DROP TABLE IF EXISTS addresses",
        "DROP TABLE IF EXISTS users",
    ]
    for s in reset_stmts:
        exec_ddl(s, ignore_tokens=("not found", "-206", "-319", "-674", "-710", "-9700", "42704"))
    print("  reset complete.")

# Idempotent ignore tokens for IBM Informix:
#   -310: Table already exists
#   -316: Index already exists
#   -394 / -959: View / Trigger already exists
#   -239 / -268 / 23505: Duplicate key / Unique constraint violated (seed rows)
#   -673: Routine already exists
IDEMPOTENT_TOKENS = (
    "-310", "-316", "-394", "-959", "-239", "-268", "-673", "-746",
    "already exists", "Duplicate value", "Unique constraint", "23505", "42710",
    "SQL0601N", "SQL0803N",
)

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

echo "Informix shopdb initialization complete."
