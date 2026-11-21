#!/usr/bin/env python3
"""
Lightweight HTTP/1.1 keep-alive JSON transactional bridge to IBM Informix
over DRDA (port 9089) via ibm_db.
- SP_ONLY runtime lockdown (INFORMIX_SP_ONLY=1 by default): blocks ad-hoc SQL on
  /query, /tx/query, /tx/exec with 403 SQL_INJECTION_BLOCKED.
- Runtime access goes exclusively through allowlisted static Informix SPL Stored
  Procedures via POST /sp/call and POST /tx/sp/call.
- Admin-key-gated POST /admin/ddl is reserved for init-informix.sh bootstrap only.
- Always serializes DECIMAL(32,4) / NUMERIC / DATETIME as exact strings
  (never float or scientific notation drift).
- Normalizes column names to lowercase for parity with SQLite & Db2.
- Supports gzip request/response compression for minimal egress.
"""

import datetime
import decimal
import gzip
import hmac
import http.server
import json
import os
import queue
import threading
import time
import uuid
import ibm_db

INFORMIX_HOST = os.environ.get("INFORMIX_HOST", "informix")
INFORMIX_PORT = os.environ.get("INFORMIX_PORT", "9089")
INFORMIX_DATABASE = os.environ.get("INFORMIX_DATABASE", "shopdb")
INFORMIX_USER = os.environ.get("INFORMIX_USER", "informix")
INFORMIX_PASSWORD = os.environ.get("INFORMIX_PASSWORD", "in4mix")
GATEWAY_HOST = os.environ.get("GATEWAY_HOST", "0.0.0.0")
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "50051"))
POOL_SIZE = int(os.environ.get("POOL_SIZE", "8"))
TX_TTL_SEC = int(os.environ.get("TX_TTL_SEC", "60"))
INFORMIX_SP_ONLY = os.environ.get("INFORMIX_SP_ONLY", "1").strip() not in ("0", "false", "False", "no")
INFORMIX_ADMIN_KEY = os.environ.get("INFORMIX_ADMIN_KEY", "shop-informix-admin-bootstrap")

# IEEE 754-2008 decimal128 context matching Perl MT::Decimal & Informix DECIMAL(32,4)
DEC34_CTX = decimal.Context(prec=34)

# Strict allowlist of static Informix SPL stored procedures and their exact arity.
ALLOWED_PROCS = {
    "SHOP_SP_CURRENT_TIMESTAMP":    0,
    "SHOP_SP_LIST_PRODUCTS":        0,
    "SHOP_SP_GET_PRODUCT":          1,
    "SHOP_SP_UPSERT_PRODUCT":       8,
    "SHOP_SP_DECREMENT_STOCK":      2,
    "SHOP_SP_UPDATE_PRODUCT_STOCK": 2,
    "SHOP_SP_GET_PROMO":            1,
    "SHOP_SP_GET_USER":             1,
    "SHOP_SP_UPSERT_USER":          8,
    "SHOP_SP_SAVE_PAYMENT_METHOD":  4,
    "SHOP_SP_LIST_ADDRESSES":       1,
    "SHOP_SP_SAVE_ADDRESS":        11,
    "SHOP_SP_DELETE_ADDRESS":       2,
    "SHOP_SP_CREATE_ORDER":        15,
    "SHOP_SP_ADD_ORDER_ITEM":       7,
    "SHOP_SP_LIST_ORDERS":          1,
    "SHOP_SP_LIST_ORDERS_MASKED":   1,
    "SHOP_SP_GET_ORDER":            1,
    "SHOP_SP_GET_ORDER_ITEMS":      1,
    "SHOP_SP_GET_ORDER_BY_REF":     1,
    "SHOP_SP_UPDATE_ORDER_STATUS":  2,
    "SHOP_SP_UPDATE_ORDER_RECEIPT": 3,
    "SHOP_SP_GMV_SUMMARY":          0,
    "SHOP_SP_PRODUCT_HISTORY":      2,
    "SHOP_SP_CATALOG_AS_OF":        1,
    "SHOP_SP_ORDER_HISTORY":        1,
    "SHOP_SP_CATEGORY_OLAP":        0,
    "SHOP_SP_LIST_WAREHOUSES":      0,
    "SHOP_SP_LIST_WAREHOUSE_STOCK": 1,
    "SHOP_SP_CREATE_PO":            4,
    "SHOP_SP_ADD_PO_LINE":          5,
    "SHOP_SP_LIST_POS":             0,
    "SHOP_SP_GET_PO_LINES":         1,
    "SHOP_SP_RECEIVE_PO_LINE":      2,
    "SHOP_SP_CREATE_SHIPMENT":      9,
    "SHOP_SP_UPDATE_SHIPMENT":      4,
    "SHOP_SP_GET_SHIPMENT_BY_ORDER":    1,
    "SHOP_SP_GET_SHIPMENT_BY_TRACKING": 1,
    "SHOP_SP_LIST_SHIPMENTS":       1,
    "SHOP_SP_GET_TAX_NEXUS":        1,
    "SHOP_SP_LIST_TAX_NEXUS":       0,
    "SHOP_SP_TAX_NEXUS_REPORT":     0,
    "SHOP_SP_LIST_MEMBERSHIP_TIERS": 0,
    "SHOP_SP_GET_MEMBERSHIP":       1,
    "SHOP_SP_UPSERT_MEMBERSHIP":    5,
    "SHOP_SP_CREATE_SUBSCRIPTION":  8,
    "SHOP_SP_LIST_SUBSCRIPTIONS":   1,
    "SHOP_SP_GET_SUBSCRIPTION":     1,
    "SHOP_SP_UPDATE_SUBSCRIPTION":  4,
    "SHOP_SP_DUE_SUBSCRIPTIONS":    1,
    "SHOP_SP_SUBSCRIPTION_METRICS": 0,
}

def _make_dsn(dbname):
    return (
        f"DATABASE={dbname};"
        f"HOSTNAME={INFORMIX_HOST};"
        f"PORT={INFORMIX_PORT};"
        f"PROTOCOL=TCPIP;"
        f"UID={INFORMIX_USER};"
        f"PWD={INFORMIX_PASSWORD};"
    )

DSN = _make_dsn(INFORMIX_DATABASE)
SYSMASTER_DSN = _make_dsn("sysmaster")
_DB_ENSURED = False
_DB_ENSURE_LOCK = threading.Lock()


def ensure_database():
    """Ensure the target Informix database exists WITH LOG (ACID transactions)."""
    global _DB_ENSURED
    if _DB_ENSURED:
        return
    with _DB_ENSURE_LOCK:
        if _DB_ENSURED:
            return
        try:
            c = ibm_db.connect(DSN, "", "")
            ibm_db.close(c)
            _DB_ENSURED = True
            return
        except Exception as exc:
            msg = str(exc)
            if not any(tok in msg for tok in ("-329", "30061", "Database not found", "not found")):
                raise
        # Connect to sysmaster and create database WITH LOG
        sc = ibm_db.connect(SYSMASTER_DSN, "", "")
        try:
            ibm_db.exec_immediate(sc, f"CREATE DATABASE {INFORMIX_DATABASE} WITH LOG")
            print(f"Created Informix database '{INFORMIX_DATABASE}' WITH LOG", flush=True)
        except Exception as exc:
            if "already exists" not in str(exc).lower() and "-311" not in str(exc):
                raise
        finally:
            try:
                ibm_db.close(sc)
            except Exception:
                pass
        _DB_ENSURED = True


def connect_informix(autocommit=True):
    ensure_database()
    opts = {
        ibm_db.SQL_ATTR_AUTOCOMMIT: (
            ibm_db.SQL_AUTOCOMMIT_ON if autocommit else ibm_db.SQL_AUTOCOMMIT_OFF
        )
    }
    conn = ibm_db.connect(DSN, "", "", opts)
    try:
        ibm_db.exec_immediate(conn, "SET LOCK MODE TO WAIT 10")
    except Exception:
        pass
    return conn


class ConnPool:
    def __init__(self, size):
        self._q = queue.Queue(maxsize=size)

    def acquire(self):
        try:
            conn = self._q.get_nowait()
            if ibm_db.active(conn):
                return conn
            try:
                ibm_db.close(conn)
            except Exception:
                pass
        except queue.Empty:
            pass
        return connect_informix(autocommit=True)

    def release(self, conn):
        if conn is None:
            return
        try:
            if ibm_db.active(conn):
                self._q.put_nowait(conn)
                return
        except queue.Full:
            pass
        except Exception:
            pass
        try:
            ibm_db.close(conn)
        except Exception:
            pass


POOL = ConnPool(POOL_SIZE)
TX_LOCK = threading.Lock()
TX_MAP = {}  # tx_id -> {"conn": conn, "ts": float, "lock": Lock}


def _reap_expired_tx():
    while True:
        time.sleep(15)
        now = time.time()
        expired = []
        with TX_LOCK:
            for tid, entry in list(TX_MAP.items()):
                if now - entry["ts"] > TX_TTL_SEC:
                    expired.append(TX_MAP.pop(tid))
        for entry in expired:
            try:
                ibm_db.rollback(entry["conn"])
            except Exception:
                pass
            try:
                ibm_db.close(entry["conn"])
            except Exception:
                pass


def _format_dec(v):
    try:
        d = v if isinstance(v, decimal.Decimal) else DEC34_CTX.create_decimal(str(v).strip())
        if d.is_finite():
            return format(d, "f")
        return str(d)
    except Exception:
        return str(v)


def normalize_val(v, field_type=""):
    if v is None:
        return None
    ft = (field_type or "").lower()
    if ft in ("decfloat", "decimal", "numeric", "real", "double", "float", "money") or isinstance(v, decimal.Decimal):
        return _format_dec(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="replace")
    return v


def run_sql(conn, sql, params, fetch=True):
    if params:
        stmt = ibm_db.prepare(conn, sql)
        ok = ibm_db.execute(stmt, tuple(params))
        if not ok:
            err = ibm_db.stmt_errormsg(stmt) or "ibm_db execute failed"
            ibm_db.free_stmt(stmt)
            raise RuntimeError(err)
    else:
        stmt = ibm_db.prepare(conn, sql)
        ok = ibm_db.execute(stmt)
        if not ok:
            err = ibm_db.stmt_errormsg(stmt) or "ibm_db execute failed"
            ibm_db.free_stmt(stmt)
            raise RuntimeError(err)

    rows = []
    num_fields = ibm_db.num_fields(stmt)
    if fetch and num_fields > 0:
        col_types = {}
        for i in range(num_fields):
            cname = ibm_db.field_name(stmt, i)
            ctype = ibm_db.field_type(stmt, i) or ""
            if cname:
                col_types[cname] = ctype
                col_types[cname.lower()] = ctype
        row = ibm_db.fetch_assoc(stmt)
        while row:
            rows.append({
                k.lower(): normalize_val(v, col_types.get(k, col_types.get(k.lower(), "")))
                for k, v in row.items()
            })
            row = ibm_db.fetch_assoc(stmt)
    rc = ibm_db.num_rows(stmt)
    if rc is None or rc < 0:
        rc = len(rows)
    ibm_db.free_stmt(stmt)
    return rows, rc


def build_sp_call(proc, params):
    if not isinstance(proc, str):
        raise PermissionError("SQL_INJECTION_BLOCKED: procedure name must be a string")
    pname = proc.strip().upper()
    if pname not in ALLOWED_PROCS:
        raise PermissionError(f"SQL_INJECTION_BLOCKED: procedure '{proc}' is not allowlisted")
    if not isinstance(params, list):
        raise ValueError("params must be a list")
    expected = ALLOWED_PROCS[pname]
    if len(params) != expected:
        raise ValueError(f"procedure {pname} expects {expected} params, got {len(params)}")
    placeholders = ", ".join(["?"] * expected)
    return f"EXECUTE PROCEDURE {pname.lower()}({placeholders})", params


class GatewayHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("DEBUG"):
            super().log_message(fmt, *args)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        if self.headers.get("Content-Encoding", "").lower() == "gzip":
            raw = gzip.decompress(raw)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        use_gzip = (
            len(body) > 512
            and "gzip" in self.headers.get("Accept-Encoding", "").lower()
        )
        if use_gzip:
            body = gzip.compress(body, compresslevel=5)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        if use_gzip:
            self.send_header("Content-Encoding", "gzip")
        self.end_headers()
        self.wfile.write(body)

    def _check_admin_key(self):
        supplied = self.headers.get("X-Admin-Key", "")
        return bool(INFORMIX_ADMIN_KEY) and hmac.compare_digest(supplied, INFORMIX_ADMIN_KEY)

    def do_GET(self):
        if self.path == "/health":
            conn = None
            try:
                conn = POOL.acquire()
                rows, _ = run_sql(conn, "SELECT FIRST 1 1 AS ok FROM systables", [], fetch=True)
                POOL.release(conn)
                self._send_json(200, {
                    "ok": True,
                    "engine": "IBM Informix",
                    "db": INFORMIX_DATABASE,
                    "sp_only": INFORMIX_SP_ONLY,
                    "rows": rows,
                })
            except Exception as exc:
                if conn is not None:
                    try:
                        ibm_db.close(conn)
                    except Exception:
                        pass
                self._send_json(503, {"ok": False, "error": str(exc)})
            return
        self._send_json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        try:
            req = self._read_json()
        except Exception as exc:
            self._send_json(400, {"ok": False, "error": f"bad json: {exc}"})
            return

        path = self.path

        # --- Stored-Procedure-Only runtime endpoints ---
        if path == "/sp/call":
            if "sql" in req:
                self._send_json(403, {
                    "ok": False,
                    "code": "SQL_INJECTION_BLOCKED",
                    "error": "SQL_INJECTION_BLOCKED: raw sql field forbidden on /sp/call",
                })
                return
            try:
                call_sql, params = build_sp_call(req.get("proc"), req.get("params") or [])
            except PermissionError as exc:
                self._send_json(403, {"ok": False, "code": "SQL_INJECTION_BLOCKED", "error": str(exc)})
                return
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
                return

            conn = None
            try:
                conn = POOL.acquire()
                rows, rc = run_sql(conn, call_sql, params, fetch=True)
                POOL.release(conn)
                self._send_json(200, {"ok": True, "rows": rows, "rowcount": rc})
            except Exception as exc:
                if conn is not None:
                    try:
                        ibm_db.close(conn)
                    except Exception:
                        pass
                self._send_json(500, {"ok": False, "error": str(exc)})
            return

        if path == "/tx/sp/call":
            if "sql" in req:
                self._send_json(403, {
                    "ok": False,
                    "code": "SQL_INJECTION_BLOCKED",
                    "error": "SQL_INJECTION_BLOCKED: raw sql field forbidden on /tx/sp/call",
                })
                return
            tid = req.get("tx_id")
            with TX_LOCK:
                entry = TX_MAP.get(tid)
            if not entry:
                self._send_json(404, {"ok": False, "error": "unknown tx_id"})
                return
            try:
                call_sql, params = build_sp_call(req.get("proc"), req.get("params") or [])
            except PermissionError as exc:
                self._send_json(403, {"ok": False, "code": "SQL_INJECTION_BLOCKED", "error": str(exc)})
                return
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
                return

            with entry["lock"]:
                entry["ts"] = time.time()
                try:
                    rows, rc = run_sql(entry["conn"], call_sql, params, fetch=True)
                    self._send_json(200, {"ok": True, "rows": rows, "rowcount": rc})
                except Exception as exc:
                    self._send_json(500, {"ok": False, "error": str(exc)})
            return

        # --- Admin-key-gated DDL/bootstrap endpoint (init-informix.sh only) ---
        if path == "/admin/ddl":
            if not self._check_admin_key():
                self._send_json(403, {
                    "ok": False,
                    "code": "SQL_INJECTION_BLOCKED",
                    "error": "SQL_INJECTION_BLOCKED: valid X-Admin-Key required for /admin/ddl",
                })
                return
            conn = None
            try:
                conn = POOL.acquire()
                try:
                    ibm_db.exec_immediate(conn, "EXECUTE PROCEDURE ifx_allow_newline('t')")
                except Exception:
                    pass
                sql = req["sql"]
                params = req.get("params") or []
                if params:
                    rows, rc = run_sql(conn, sql, params, fetch=True)
                else:
                    # Use exec_immediate for DDL (CREATE PROCEDURE / CREATE TRIGGER / CREATE TABLE)
                    stmt = ibm_db.exec_immediate(conn, sql)
                    rows = []
                    rc = ibm_db.num_rows(stmt) if stmt else 0
                    if rc is None or rc < 0:
                        rc = 0
                    if stmt:
                        ibm_db.free_stmt(stmt)
                POOL.release(conn)
                self._send_json(200, {"ok": True, "rows": rows, "rowcount": rc})
            except Exception as exc:
                if conn is not None:
                    try:
                        ibm_db.close(conn)
                    except Exception:
                        pass
                self._send_json(500, {"ok": False, "error": str(exc)})
            return

        # --- Legacy ad-hoc SQL endpoints (blocked when INFORMIX_SP_ONLY=1) ---
        if path == "/query":
            if INFORMIX_SP_ONLY:
                self._send_json(403, {
                    "ok": False,
                    "code": "SQL_INJECTION_BLOCKED",
                    "error": "SQL_INJECTION_BLOCKED: ad-hoc SQL disabled in SP_ONLY mode; use /sp/call",
                })
                return
            conn = None
            try:
                conn = POOL.acquire()
                rows, rc = run_sql(conn, req["sql"], req.get("params") or [], fetch=True)
                POOL.release(conn)
                self._send_json(200, {"ok": True, "rows": rows, "rowcount": rc})
            except Exception as exc:
                if conn is not None:
                    try:
                        ibm_db.close(conn)
                    except Exception:
                        pass
                self._send_json(500, {"ok": False, "error": str(exc)})
            return

        if path == "/tx/begin":
            try:
                conn = connect_informix(autocommit=False)
                tid = uuid.uuid4().hex
                with TX_LOCK:
                    TX_MAP[tid] = {"conn": conn, "ts": time.time(), "lock": threading.Lock()}
                self._send_json(200, {"ok": True, "tx_id": tid})
            except Exception as exc:
                self._send_json(500, {"ok": False, "error": str(exc)})
            return

        if path in ("/tx/query", "/tx/exec"):
            if INFORMIX_SP_ONLY:
                self._send_json(403, {
                    "ok": False,
                    "code": "SQL_INJECTION_BLOCKED",
                    "error": "SQL_INJECTION_BLOCKED: ad-hoc SQL disabled in SP_ONLY mode; use /tx/sp/call",
                })
                return
            tid = req.get("tx_id")
            with TX_LOCK:
                entry = TX_MAP.get(tid)
            if not entry:
                self._send_json(404, {"ok": False, "error": "unknown tx_id"})
                return
            with entry["lock"]:
                entry["ts"] = time.time()
                try:
                    rows, rc = run_sql(
                        entry["conn"],
                        req["sql"],
                        req.get("params") or [],
                        fetch=(path == "/tx/query"),
                    )
                    self._send_json(200, {"ok": True, "rows": rows, "rowcount": rc})
                except Exception as exc:
                    self._send_json(500, {"ok": False, "error": str(exc)})
            return

        if path in ("/tx/commit", "/tx/rollback"):
            tid = req.get("tx_id")
            with TX_LOCK:
                entry = TX_MAP.pop(tid, None)
            if not entry:
                self._send_json(404, {"ok": False, "error": "unknown tx_id"})
                return
            with entry["lock"]:
                try:
                    if path == "/tx/commit":
                        ok = ibm_db.commit(entry["conn"])
                    else:
                        ok = ibm_db.rollback(entry["conn"])
                    ibm_db.close(entry["conn"])
                    if not ok:
                        self._send_json(500, {"ok": False, "error": "tx finalize failed"})
                    else:
                        self._send_json(200, {"ok": True})
                except Exception as exc:
                    try:
                        ibm_db.close(entry["conn"])
                    except Exception:
                        pass
                    self._send_json(500, {"ok": False, "error": str(exc)})
            return

        self._send_json(404, {"ok": False, "error": "not found"})


class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    reaper = threading.Thread(target=_reap_expired_tx, daemon=True)
    reaper.start()
    srv = ReusableThreadingHTTPServer((GATEWAY_HOST, GATEWAY_PORT), GatewayHandler)
    print(
        f"informix-gateway listening on {GATEWAY_HOST}:{GATEWAY_PORT} -> "
        f"{INFORMIX_HOST}:{INFORMIX_PORT}/{INFORMIX_DATABASE} (SP_ONLY={INFORMIX_SP_ONLY})",
        flush=True,
    )
    srv.serve_forever()


if __name__ == "__main__":
    main()
