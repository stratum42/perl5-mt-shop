-- IBM Db2 Community Edition schema for perl5-mt-shop
-- Uses IBM Db2 features:
--   * DECFLOAT(34) (IEEE 754-2008 decimal128, exact parity with MT::Decimal)
--   * System-Period Temporal Tables (SYSTEM_TIME) with automatic history tables
--   * Adaptive Row Compression (COMPRESS YES ADAPTIVE)
--   * Database-enforced CHECK constraints
--   * OLAP ROLLUP + Window Function analytics view (v_category_olap)
--   * PII-masked order view (v_orders_masked)

CREATE TABLE products (
    sku         VARCHAR(32)    NOT NULL PRIMARY KEY,
    name        VARCHAR(128)   NOT NULL,
    category    VARCHAR(64)    NOT NULL,
    description VARCHAR(1024)  NOT NULL,
    ascii_art   VARCHAR(2048)  NOT NULL,
    price       DECFLOAT(34)   NOT NULL,
    stock       INTEGER        NOT NULL DEFAULT 0,
    active      SMALLINT       NOT NULL DEFAULT 1,
    updated_at  TIMESTAMP      NOT NULL DEFAULT CURRENT TIMESTAMP,
    sys_start   TIMESTAMP(12)  GENERATED ALWAYS AS ROW BEGIN NOT NULL,
    sys_end     TIMESTAMP(12)  GENERATED ALWAYS AS ROW END NOT NULL,
    trans_start TIMESTAMP(12)  GENERATED ALWAYS AS TRANSACTION START ID IMPLICITLY HIDDEN,
    PERIOD SYSTEM_TIME (sys_start, sys_end),
    CONSTRAINT chk_products_stock CHECK (stock >= 0),
    CONSTRAINT chk_products_price CHECK (price >= 0)
);

CREATE TABLE products_history LIKE products;
ALTER TABLE products_history COMPRESS YES ADAPTIVE;
ALTER TABLE products ADD VERSIONING USE HISTORY TABLE products_history;

CREATE TABLE users (
    fingerprint            VARCHAR(128)   NOT NULL PRIMARY KEY,
    username               VARCHAR(64)    NOT NULL,
    email                  VARCHAR(128)   NOT NULL DEFAULT '',
    pubkey_type            VARCHAR(64)    NOT NULL DEFAULT '',
    is_admin               SMALLINT       NOT NULL DEFAULT 0,
    stripe_customer_id     VARCHAR(128)   NOT NULL DEFAULT '',
    default_payment_method VARCHAR(128)   NOT NULL DEFAULT '',
    default_payment_last4  VARCHAR(8)     NOT NULL DEFAULT '',
    created_at             TIMESTAMP      NOT NULL DEFAULT CURRENT TIMESTAMP
);

CREATE TABLE addresses (
    id          VARCHAR(64)    NOT NULL PRIMARY KEY,
    user_fp     VARCHAR(128)   NOT NULL,
    label       VARCHAR(64)    NOT NULL,
    recipient   VARCHAR(128)   NOT NULL,
    line1       VARCHAR(255)   NOT NULL,
    line2       VARCHAR(255)   NOT NULL DEFAULT '',
    city        VARCHAR(128)   NOT NULL,
    state       VARCHAR(64)    NOT NULL,
    postal_code VARCHAR(32)    NOT NULL,
    country     VARCHAR(8)     NOT NULL DEFAULT 'US',
    is_default  SMALLINT       NOT NULL DEFAULT 0
);

CREATE TABLE promo_codes (
    code         VARCHAR(32)  NOT NULL PRIMARY KEY,
    kind         VARCHAR(16)  NOT NULL,
    value        DECFLOAT(34) NOT NULL,
    min_subtotal DECFLOAT(34) NOT NULL DEFAULT 0.0000,
    active       SMALLINT     NOT NULL DEFAULT 1
);

CREATE TABLE orders (
    id               VARCHAR(64)   NOT NULL PRIMARY KEY,
    user_fp          VARCHAR(128)  NOT NULL,
    username         VARCHAR(64)   NOT NULL,
    status           VARCHAR(32)   NOT NULL DEFAULT 'paid',
    subtotal         DECFLOAT(34)  NOT NULL,
    discount         DECFLOAT(34)  NOT NULL,
    tax              DECFLOAT(34)  NOT NULL,
    shipping         DECFLOAT(34)  NOT NULL,
    total            DECFLOAT(34)  NOT NULL,
    promo_code       VARCHAR(32)   NOT NULL DEFAULT '',
    payment_method   VARCHAR(32)   NOT NULL,
    payment_ref      VARCHAR(128)  NOT NULL DEFAULT '',
    shipping_address VARCHAR(1024) NOT NULL,
    receipt_sig      VARCHAR(256)  NOT NULL DEFAULT '',
    receipt_hash     VARCHAR(128)  NOT NULL DEFAULT '',
    created_at       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    sys_start        TIMESTAMP(12) GENERATED ALWAYS AS ROW BEGIN NOT NULL,
    sys_end          TIMESTAMP(12) GENERATED ALWAYS AS ROW END NOT NULL,
    trans_start      TIMESTAMP(12) GENERATED ALWAYS AS TRANSACTION START ID IMPLICITLY HIDDEN,
    PERIOD SYSTEM_TIME (sys_start, sys_end)
) COMPRESS YES ADAPTIVE;

CREATE TABLE orders_history LIKE orders;
ALTER TABLE orders_history COMPRESS YES ADAPTIVE;
ALTER TABLE orders ADD VERSIONING USE HISTORY TABLE orders_history;

CREATE TABLE order_items (
    id         VARCHAR(64)  NOT NULL PRIMARY KEY,
    order_id   VARCHAR(64)  NOT NULL,
    sku        VARCHAR(32)  NOT NULL,
    name       VARCHAR(128) NOT NULL,
    qty        INTEGER      NOT NULL,
    unit_price DECFLOAT(34) NOT NULL,
    line_total DECFLOAT(34) NOT NULL,
    CONSTRAINT chk_order_items_qty CHECK (qty > 0)
) COMPRESS YES ADAPTIVE;

CREATE INDEX idx_addresses_user     ON addresses (user_fp);
CREATE INDEX idx_orders_user        ON orders (user_fp);
CREATE INDEX idx_order_items_order  ON order_items (order_id);
CREATE INDEX idx_products_hist_sku  ON products_history (sku, sys_start DESC);
CREATE INDEX idx_orders_hist_id     ON orders_history (id, sys_start DESC);

-- Analytics view: GROUP BY ROLLUP + window functions (RANK & revenue share %)
CREATE OR REPLACE VIEW v_category_olap AS
WITH ord_cat AS (
    SELECT
        p.category                             AS category,
        o.id                                   AS order_id,
        SUM(oi.qty)                            AS qty,
        SUM(CAST(oi.line_total AS DECIMAL(31,4))) AS rev
    FROM order_items oi
    JOIN orders o   ON o.id = oi.order_id AND LOWER(o.status) <> 'cancelled'
    JOIN products p ON p.sku = oi.sku
    GROUP BY p.category, o.id
),
cat_agg AS (
    SELECT
        COALESCE(category, 'ALL CATEGORIES') AS category,
        GROUPING(category)                   AS is_total,
        COUNT(order_id)                      AS order_count,
        COALESCE(SUM(qty), 0)                AS units_sold,
        COALESCE(SUM(rev), DECIMAL(0, 31, 4)) AS revenue
    FROM ord_cat
    GROUP BY ROLLUP(category)
)
SELECT
    category,
    is_total,
    order_count,
    units_sold,
    CAST(revenue AS DECFLOAT(34)) AS revenue,
    CASE
        WHEN SUM(CASE WHEN is_total = 0 THEN revenue ELSE DECIMAL(0, 31, 4) END) OVER () > 0
        THEN ROUND(
            (CAST(revenue AS DECFLOAT(34)) * CAST(100 AS DECFLOAT(34)))
            / CAST(SUM(CASE WHEN is_total = 0 THEN revenue ELSE DECIMAL(0, 31, 4) END) OVER () AS DECFLOAT(34)),
            2
        )
        ELSE CAST(0 AS DECFLOAT(34))
    END AS share_pct,
    CASE
        WHEN is_total = 1 THEN 0
        ELSE RANK() OVER (PARTITION BY is_total ORDER BY revenue DESC, category ASC)
    END AS rank
FROM cat_agg;

-- Masked view for non-admin order inspection (masks shipping_address PII)
CREATE OR REPLACE VIEW v_orders_masked AS
SELECT
    id,
    user_fp,
    username,
    status,
    subtotal,
    discount,
    tax,
    shipping,
    total,
    promo_code,
    payment_method,
    payment_ref,
    CASE
        WHEN LENGTH(shipping_address) > 8
        THEN SUBSTR(shipping_address, 1, 4) || '***MASKED***' || SUBSTR(shipping_address, LENGTH(shipping_address) - 3, 4)
        WHEN LENGTH(shipping_address) > 0
        THEN '***MASKED***'
        ELSE ''
    END AS shipping_address,
    receipt_hash,
    created_at
FROM orders;

-- Logistics, Warehouses, Purchase Orders, Shipments (SYSTEM_TIME), and Tax Nexus

CREATE TABLE warehouses (
    code        VARCHAR(16)   NOT NULL PRIMARY KEY,
    name        VARCHAR(128)  NOT NULL,
    city        VARCHAR(128)  NOT NULL,
    state       VARCHAR(16)   NOT NULL,
    postal_code VARCHAR(32)   NOT NULL,
    active      SMALLINT      NOT NULL DEFAULT 1
);

CREATE TABLE warehouse_stock (
    warehouse_code VARCHAR(16) NOT NULL,
    sku            VARCHAR(32) NOT NULL,
    qty            INTEGER     NOT NULL DEFAULT 0,
    bin_location   VARCHAR(32) NOT NULL DEFAULT '',
    PRIMARY KEY (warehouse_code, sku),
    CONSTRAINT chk_wh_stock_qty CHECK (qty >= 0)
);

CREATE TABLE purchase_orders (
    id             VARCHAR(64)   NOT NULL PRIMARY KEY,
    supplier       VARCHAR(128)  NOT NULL,
    warehouse_code VARCHAR(16)   NOT NULL,
    status         VARCHAR(32)   NOT NULL DEFAULT 'OPEN',
    total_cost     DECFLOAT(34)  NOT NULL DEFAULT 0.0000,
    created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP
) COMPRESS YES ADAPTIVE;

CREATE TABLE po_lines (
    id           VARCHAR(64)  NOT NULL PRIMARY KEY,
    po_id        VARCHAR(64)  NOT NULL,
    sku          VARCHAR(32)  NOT NULL,
    qty_ordered  INTEGER      NOT NULL,
    qty_received INTEGER      NOT NULL DEFAULT 0,
    unit_cost    DECFLOAT(34) NOT NULL DEFAULT 0.0000,
    CONSTRAINT chk_po_lines_ord CHECK (qty_ordered > 0),
    CONSTRAINT chk_po_lines_rcv CHECK (qty_received >= 0)
) COMPRESS YES ADAPTIVE;

CREATE TABLE shipments (
    id              VARCHAR(64)   NOT NULL PRIMARY KEY,
    order_id        VARCHAR(64)   NOT NULL,
    warehouse_code  VARCHAR(16)   NOT NULL,
    carrier         VARCHAR(64)   NOT NULL DEFAULT '',
    service         VARCHAR(64)   NOT NULL DEFAULT '',
    rate_amount     DECFLOAT(34)  NOT NULL DEFAULT 0.0000,
    tracking_number VARCHAR(128)  NOT NULL DEFAULT '',
    label_url       VARCHAR(512)  NOT NULL DEFAULT '',
    status          VARCHAR(32)   NOT NULL DEFAULT 'PENDING',
    updated_at      TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    sys_start       TIMESTAMP(12) GENERATED ALWAYS AS ROW BEGIN NOT NULL,
    sys_end         TIMESTAMP(12) GENERATED ALWAYS AS ROW END NOT NULL,
    trans_start     TIMESTAMP(12) GENERATED ALWAYS AS TRANSACTION START ID IMPLICITLY HIDDEN,
    PERIOD SYSTEM_TIME (sys_start, sys_end)
) COMPRESS YES ADAPTIVE;

CREATE TABLE shipments_history LIKE shipments;
ALTER TABLE shipments_history COMPRESS YES ADAPTIVE;
ALTER TABLE shipments ADD VERSIONING USE HISTORY TABLE shipments_history;

CREATE TABLE tax_nexus (
    state           VARCHAR(8)   NOT NULL PRIMARY KEY,
    rate            DECFLOAT(34) NOT NULL,
    threshold_sales DECFLOAT(34) NOT NULL DEFAULT 0.0000,
    threshold_txns  INTEGER      NOT NULL DEFAULT 0,
    registered      SMALLINT     NOT NULL DEFAULT 0
);

CREATE INDEX idx_po_lines_po        ON po_lines (po_id);
CREATE INDEX idx_shipments_order    ON shipments (order_id);
CREATE INDEX idx_shipments_tracking ON shipments (tracking_number);
CREATE INDEX idx_shipments_status   ON shipments (status);
CREATE INDEX idx_shipments_hist_id  ON shipments_history (id, sys_start DESC);
