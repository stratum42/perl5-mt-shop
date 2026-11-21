-- SQLite schema for perl5-mt-shop (exact column parity with IBM Db2)

CREATE TABLE IF NOT EXISTS products (
    sku         TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    description TEXT NOT NULL,
    ascii_art   TEXT NOT NULL,
    price       TEXT NOT NULL,
    stock       INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS users (
    fingerprint            TEXT PRIMARY KEY,
    username               TEXT NOT NULL,
    email                  TEXT NOT NULL DEFAULT '',
    pubkey_type            TEXT NOT NULL DEFAULT '',
    is_admin               INTEGER NOT NULL DEFAULT 0,
    stripe_customer_id     TEXT NOT NULL DEFAULT '',
    default_payment_method TEXT NOT NULL DEFAULT '',
    default_payment_last4  TEXT NOT NULL DEFAULT '',
    created_at             TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS addresses (
    id          TEXT PRIMARY KEY,
    user_fp     TEXT NOT NULL,
    label       TEXT NOT NULL,
    recipient   TEXT NOT NULL,
    line1       TEXT NOT NULL,
    line2       TEXT NOT NULL DEFAULT '',
    city        TEXT NOT NULL,
    state       TEXT NOT NULL,
    postal_code TEXT NOT NULL,
    country     TEXT NOT NULL DEFAULT 'US',
    is_default  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS promo_codes (
    code         TEXT PRIMARY KEY,
    kind         TEXT NOT NULL,
    value        TEXT NOT NULL,
    min_subtotal TEXT NOT NULL DEFAULT '0.0000',
    active       INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS orders (
    id               TEXT PRIMARY KEY,
    user_fp          TEXT NOT NULL,
    username         TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'paid',
    subtotal         TEXT NOT NULL,
    discount         TEXT NOT NULL,
    tax              TEXT NOT NULL,
    shipping         TEXT NOT NULL,
    total            TEXT NOT NULL,
    promo_code       TEXT NOT NULL DEFAULT '',
    payment_method   TEXT NOT NULL,
    payment_ref      TEXT NOT NULL DEFAULT '',
    shipping_address TEXT NOT NULL,
    receipt_sig      TEXT NOT NULL DEFAULT '',
    receipt_hash     TEXT NOT NULL DEFAULT '',
    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS order_items (
    id         TEXT PRIMARY KEY,
    order_id   TEXT NOT NULL,
    sku        TEXT NOT NULL,
    name       TEXT NOT NULL,
    qty        INTEGER NOT NULL,
    unit_price TEXT NOT NULL,
    line_total TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_addresses_user ON addresses (user_fp);
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders (user_fp);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items (order_id);

-- Logistics, Warehouses, Purchase Orders, Shipments, and Tax Nexus

CREATE TABLE IF NOT EXISTS warehouses (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    city        TEXT NOT NULL,
    state       TEXT NOT NULL,
    postal_code TEXT NOT NULL,
    active      INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS warehouse_stock (
    warehouse_code TEXT NOT NULL,
    sku            TEXT NOT NULL,
    qty            INTEGER NOT NULL DEFAULT 0 CHECK (qty >= 0),
    bin_location   TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (warehouse_code, sku)
);

CREATE TABLE IF NOT EXISTS purchase_orders (
    id             TEXT PRIMARY KEY,
    supplier       TEXT NOT NULL,
    warehouse_code TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'OPEN',
    total_cost     TEXT NOT NULL DEFAULT '0.0000',
    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS po_lines (
    id           TEXT PRIMARY KEY,
    po_id        TEXT NOT NULL,
    sku          TEXT NOT NULL,
    qty_ordered  INTEGER NOT NULL CHECK (qty_ordered > 0),
    qty_received INTEGER NOT NULL DEFAULT 0 CHECK (qty_received >= 0),
    unit_cost    TEXT NOT NULL DEFAULT '0.0000'
);

CREATE TABLE IF NOT EXISTS shipments (
    id              TEXT PRIMARY KEY,
    order_id        TEXT NOT NULL,
    warehouse_code  TEXT NOT NULL,
    carrier         TEXT NOT NULL DEFAULT '',
    service         TEXT NOT NULL DEFAULT '',
    rate_amount     TEXT NOT NULL DEFAULT '0.0000',
    tracking_number TEXT NOT NULL DEFAULT '',
    label_url       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'PENDING',
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tax_nexus (
    state           TEXT PRIMARY KEY,
    rate            TEXT NOT NULL,
    threshold_sales TEXT NOT NULL DEFAULT '0.0000',
    threshold_txns  INTEGER NOT NULL DEFAULT 0,
    registered      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_po_lines_po ON po_lines (po_id);
CREATE INDEX IF NOT EXISTS idx_shipments_order ON shipments (order_id);
CREATE INDEX IF NOT EXISTS idx_shipments_tracking ON shipments (tracking_number);
CREATE INDEX IF NOT EXISTS idx_shipments_status ON shipments (status);

-- Memberships and Recurring Subscriptions

CREATE TABLE IF NOT EXISTS membership_tiers (
    code                 TEXT PRIMARY KEY,
    name                 TEXT NOT NULL,
    monthly_price        TEXT NOT NULL DEFAULT '0.0000',
    discount_pct         TEXT NOT NULL DEFAULT '0.0000',
    free_shipping        INTEGER NOT NULL DEFAULT 0,
    priority_fulfillment INTEGER NOT NULL DEFAULT 0,
    active               INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS memberships (
    user_fp       TEXT PRIMARY KEY,
    tier_code     TEXT NOT NULL DEFAULT 'FREE',
    status        TEXT NOT NULL DEFAULT 'ACTIVE',
    stripe_sub_id TEXT NOT NULL DEFAULT '',
    started_at    TEXT NOT NULL DEFAULT (datetime('now')),
    renews_at     TEXT NOT NULL DEFAULT '',
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id            TEXT PRIMARY KEY,
    user_fp       TEXT NOT NULL,
    sku           TEXT NOT NULL,
    qty           INTEGER NOT NULL CHECK (qty > 0),
    interval_days INTEGER NOT NULL CHECK (interval_days >= 7),
    unit_price    TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'ACTIVE',
    next_bill_at  TEXT NOT NULL DEFAULT '',
    last_order_id TEXT NOT NULL DEFAULT '',
    stripe_sub_id TEXT NOT NULL DEFAULT '',
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions (user_fp);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status_due ON subscriptions (status, next_bill_at);
