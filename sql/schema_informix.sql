-- IBM Informix schema for perl5-mt-shop
-- Uses IBM Informix features:
--   * DECIMAL(32,4) exact fixed-point monetary arithmetic (zero binary float drift)
--   * DATETIME YEAR TO FRACTION(5) high-resolution audit timestamps
--   * Audit history tables (products_audit, orders_audit) populated via SPL + CREATE TRIGGER
--   * Database-enforced CHECK constraints (stock >= 0, price >= 0, qty > 0)
--   * PII-masked order view (v_orders_masked)
--   * Static SPL Stored Procedures (sql/procs_informix.sql) with INFORMIX_SP_ONLY=1 lockdown

CREATE TABLE products (
    sku         VARCHAR(32)                   NOT NULL PRIMARY KEY,
    name        VARCHAR(128)                  NOT NULL,
    category    VARCHAR(64)                   NOT NULL,
    description LVARCHAR(1024)                NOT NULL,
    ascii_art   LVARCHAR(2048)                NOT NULL,
    price       DECIMAL(32,4)                 NOT NULL,
    stock       INTEGER         DEFAULT 0     NOT NULL,
    active      SMALLINT        DEFAULT 1     NOT NULL,
    updated_at  DATETIME YEAR TO FRACTION(5)  DEFAULT CURRENT YEAR TO FRACTION(5) NOT NULL,
    CHECK (stock >= 0) CONSTRAINT chk_products_stock,
    CHECK (price >= 0) CONSTRAINT chk_products_price
);

CREATE TABLE products_audit (
    audit_id    SERIAL                        NOT NULL PRIMARY KEY,
    sku         VARCHAR(32)                   NOT NULL,
    name        VARCHAR(128)                  NOT NULL,
    category    VARCHAR(64)                   NOT NULL,
    price       DECIMAL(32,4)                 NOT NULL,
    stock       INTEGER                       NOT NULL,
    active      SMALLINT                      NOT NULL,
    op          CHAR(1)                       NOT NULL,
    sys_start   DATETIME YEAR TO FRACTION(5)  NOT NULL,
    sys_end     DATETIME YEAR TO FRACTION(5)  NOT NULL
);

CREATE TABLE users (
    fingerprint            VARCHAR(128)                  NOT NULL PRIMARY KEY,
    username               VARCHAR(64)                   NOT NULL,
    email                  VARCHAR(128)    DEFAULT ''    NOT NULL,
    pubkey_type            VARCHAR(64)     DEFAULT ''    NOT NULL,
    is_admin               SMALLINT        DEFAULT 0     NOT NULL,
    stripe_customer_id     VARCHAR(128)    DEFAULT ''    NOT NULL,
    default_payment_method VARCHAR(128)    DEFAULT ''    NOT NULL,
    default_payment_last4  VARCHAR(8)      DEFAULT ''    NOT NULL,
    created_at             DATETIME YEAR TO FRACTION(5)  DEFAULT CURRENT YEAR TO FRACTION(5) NOT NULL
);

CREATE TABLE addresses (
    id          VARCHAR(64)                 NOT NULL PRIMARY KEY,
    user_fp     VARCHAR(128)                NOT NULL,
    label       VARCHAR(64)                 NOT NULL,
    recipient   VARCHAR(128)                NOT NULL,
    line1       VARCHAR(255)                NOT NULL,
    line2       VARCHAR(255)  DEFAULT ''    NOT NULL,
    city        VARCHAR(128)                NOT NULL,
    state       VARCHAR(64)                 NOT NULL,
    postal_code VARCHAR(32)                 NOT NULL,
    country     VARCHAR(8)    DEFAULT 'US'  NOT NULL,
    is_default  SMALLINT      DEFAULT 0     NOT NULL
);

CREATE TABLE promo_codes (
    code         VARCHAR(32)                   NOT NULL PRIMARY KEY,
    kind         VARCHAR(16)                   NOT NULL,
    value        DECIMAL(32,4)                 NOT NULL,
    min_subtotal DECIMAL(32,4)  DEFAULT 0.0000 NOT NULL,
    active       SMALLINT       DEFAULT 1      NOT NULL
);

CREATE TABLE orders (
    id               VARCHAR(64)                   NOT NULL PRIMARY KEY,
    user_fp          VARCHAR(128)                  NOT NULL,
    username         VARCHAR(64)                   NOT NULL,
    status           VARCHAR(32)    DEFAULT 'paid' NOT NULL,
    subtotal         DECIMAL(32,4)                 NOT NULL,
    discount         DECIMAL(32,4)                 NOT NULL,
    tax              DECIMAL(32,4)                 NOT NULL,
    shipping         DECIMAL(32,4)                 NOT NULL,
    total            DECIMAL(32,4)                 NOT NULL,
    promo_code       VARCHAR(32)    DEFAULT ''     NOT NULL,
    payment_method   VARCHAR(32)                   NOT NULL,
    payment_ref      VARCHAR(128)   DEFAULT ''     NOT NULL,
    shipping_address LVARCHAR(1024)                NOT NULL,
    receipt_sig      LVARCHAR(256)  DEFAULT ''     NOT NULL,
    receipt_hash     VARCHAR(128)   DEFAULT ''     NOT NULL,
    created_at       DATETIME YEAR TO FRACTION(5)  DEFAULT CURRENT YEAR TO FRACTION(5) NOT NULL
);

CREATE TABLE orders_audit (
    audit_id    SERIAL                        NOT NULL PRIMARY KEY,
    id          VARCHAR(64)                   NOT NULL,
    status      VARCHAR(32)                   NOT NULL,
    total       DECIMAL(32,4)                 NOT NULL,
    payment_ref VARCHAR(128)                  NOT NULL,
    op          CHAR(1)                       NOT NULL,
    sys_start   DATETIME YEAR TO FRACTION(5)  NOT NULL,
    sys_end     DATETIME YEAR TO FRACTION(5)  NOT NULL
);

CREATE TABLE order_items (
    id         VARCHAR(64)    NOT NULL PRIMARY KEY,
    order_id   VARCHAR(64)    NOT NULL,
    sku        VARCHAR(32)    NOT NULL,
    name       VARCHAR(128)   NOT NULL,
    qty        INTEGER        NOT NULL,
    unit_price DECIMAL(32,4)  NOT NULL,
    line_total DECIMAL(32,4)  NOT NULL,
    CHECK (qty > 0) CONSTRAINT chk_order_items_qty
);

CREATE INDEX idx_addresses_user     ON addresses (user_fp);
CREATE INDEX idx_orders_user        ON orders (user_fp);
CREATE INDEX idx_orders_payref      ON orders (payment_ref);
CREATE INDEX idx_order_items_order  ON order_items (order_id);
CREATE INDEX idx_products_aud_sku   ON products_audit (sku, sys_start);
CREATE INDEX idx_orders_aud_id      ON orders_audit (id, sys_start);

-- Masked view for non-admin order inspection (masks shipping_address PII)
CREATE VIEW v_orders_masked (
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
    shipping_address,
    receipt_hash,
    created_at
) AS
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
    END,
    receipt_hash,
    created_at
FROM orders;

-- Logistics, Warehouses, Purchase Orders, Shipments (+ SPL audit), and Tax Nexus

CREATE TABLE warehouses (
    code        VARCHAR(16)                NOT NULL PRIMARY KEY,
    name        VARCHAR(128)               NOT NULL,
    city        VARCHAR(128)               NOT NULL,
    state       VARCHAR(16)                NOT NULL,
    postal_code VARCHAR(32)                NOT NULL,
    active      SMALLINT       DEFAULT 1   NOT NULL
);

CREATE TABLE warehouse_stock (
    warehouse_code VARCHAR(16)             NOT NULL,
    sku            VARCHAR(32)             NOT NULL,
    qty            INTEGER     DEFAULT 0   NOT NULL,
    bin_location   VARCHAR(32) DEFAULT ''  NOT NULL,
    PRIMARY KEY (warehouse_code, sku),
    CHECK (qty >= 0) CONSTRAINT chk_wh_stock_qty
);

CREATE TABLE purchase_orders (
    id             VARCHAR(64)                  NOT NULL PRIMARY KEY,
    supplier       VARCHAR(128)                 NOT NULL,
    warehouse_code VARCHAR(16)                  NOT NULL,
    status         VARCHAR(32)   DEFAULT 'OPEN' NOT NULL,
    total_cost     DECIMAL(32,4) DEFAULT 0.0000 NOT NULL,
    created_at     DATETIME YEAR TO FRACTION(5) DEFAULT CURRENT YEAR TO FRACTION(5) NOT NULL
);

CREATE TABLE po_lines (
    id           VARCHAR(64)                  NOT NULL PRIMARY KEY,
    po_id        VARCHAR(64)                  NOT NULL,
    sku          VARCHAR(32)                  NOT NULL,
    qty_ordered  INTEGER                      NOT NULL,
    qty_received INTEGER       DEFAULT 0      NOT NULL,
    unit_cost    DECIMAL(32,4) DEFAULT 0.0000 NOT NULL,
    CHECK (qty_ordered > 0)  CONSTRAINT chk_po_lines_ord,
    CHECK (qty_received >= 0) CONSTRAINT chk_po_lines_rcv
);

CREATE TABLE shipments (
    id              VARCHAR(64)                    NOT NULL PRIMARY KEY,
    order_id        VARCHAR(64)                    NOT NULL,
    warehouse_code  VARCHAR(16)                    NOT NULL,
    carrier         VARCHAR(64)   DEFAULT ''       NOT NULL,
    service         VARCHAR(64)   DEFAULT ''       NOT NULL,
    rate_amount     DECIMAL(32,4) DEFAULT 0.0000   NOT NULL,
    tracking_number VARCHAR(128)  DEFAULT ''       NOT NULL,
    label_url       LVARCHAR(512) DEFAULT ''       NOT NULL,
    status          VARCHAR(32)   DEFAULT 'PENDING' NOT NULL,
    updated_at      DATETIME YEAR TO FRACTION(5)   DEFAULT CURRENT YEAR TO FRACTION(5) NOT NULL
);

CREATE TABLE shipments_audit (
    audit_id        SERIAL                        NOT NULL PRIMARY KEY,
    id              VARCHAR(64)                   NOT NULL,
    order_id        VARCHAR(64)                   NOT NULL,
    warehouse_code  VARCHAR(16)                   NOT NULL,
    carrier         VARCHAR(64)                   NOT NULL,
    tracking_number VARCHAR(128)                  NOT NULL,
    status          VARCHAR(32)                   NOT NULL,
    op              CHAR(1)                       NOT NULL,
    sys_start       DATETIME YEAR TO FRACTION(5)  NOT NULL,
    sys_end         DATETIME YEAR TO FRACTION(5)  NOT NULL
);

CREATE TABLE tax_nexus (
    state           VARCHAR(8)                   NOT NULL PRIMARY KEY,
    rate            DECIMAL(16,5)                NOT NULL,
    threshold_sales DECIMAL(32,4) DEFAULT 0.0000 NOT NULL,
    threshold_txns  INTEGER       DEFAULT 0      NOT NULL,
    registered      SMALLINT      DEFAULT 0      NOT NULL
);

CREATE INDEX idx_po_lines_po        ON po_lines (po_id);
CREATE INDEX idx_shipments_order    ON shipments (order_id);
CREATE INDEX idx_shipments_tracking ON shipments (tracking_number);
CREATE INDEX idx_shipments_status   ON shipments (status);
CREATE INDEX idx_shipments_aud_id   ON shipments_audit (id, sys_start);
