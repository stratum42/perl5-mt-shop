--#SET TERMINATOR @
-- IBM Informix Static SPL Stored Procedures & Audit Triggers for perl5-mt-shop
-- 100% static compiled SPL inside every procedure (ZERO PREPARE / EXECUTE IMMEDIATE).

-- =========================================================================
-- 1. Automatic Audit Trail SPL Procedures + Triggers (zero application code)
-- =========================================================================

CREATE OR REPLACE PROCEDURE shop_trg_products_ins(
    p_sku      VARCHAR(32),
    p_name     VARCHAR(128),
    p_category VARCHAR(64),
    p_price    DECIMAL(32,4),
    p_stock    INTEGER,
    p_active   SMALLINT
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    INSERT INTO products_audit (sku, name, category, price, stock, active, op, sys_start, sys_end)
    VALUES (p_sku, p_name, p_category, p_price, p_stock, p_active, 'I', v_now, v_max);
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_trg_products_upd(
    p_sku      VARCHAR(32),
    p_name     VARCHAR(128),
    p_category VARCHAR(64),
    p_price    DECIMAL(32,4),
    p_stock    INTEGER,
    p_active   SMALLINT
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    UPDATE products_audit
    SET sys_end = v_now
    WHERE sku = p_sku
      AND sys_end = v_max;

    INSERT INTO products_audit (sku, name, category, price, stock, active, op, sys_start, sys_end)
    VALUES (p_sku, p_name, p_category, p_price, p_stock, p_active, 'U', v_now, v_max);
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_trg_orders_ins(
    p_id          VARCHAR(64),
    p_status      VARCHAR(32),
    p_total       DECIMAL(32,4),
    p_payment_ref VARCHAR(128)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    INSERT INTO orders_audit (id, status, total, payment_ref, op, sys_start, sys_end)
    VALUES (p_id, p_status, p_total, p_payment_ref, 'I', v_now, v_max);
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_trg_orders_upd(
    p_id          VARCHAR(64),
    p_status      VARCHAR(32),
    p_total       DECIMAL(32,4),
    p_payment_ref VARCHAR(128)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    UPDATE orders_audit
    SET sys_end = v_now
    WHERE id = p_id
      AND sys_end = v_max;

    INSERT INTO orders_audit (id, status, total, payment_ref, op, sys_start, sys_end)
    VALUES (p_id, p_status, p_total, p_payment_ref, 'U', v_now, v_max);
END PROCEDURE@

CREATE TRIGGER trg_products_ins
    INSERT ON products
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_products_ins(n.sku, n.name, n.category, n.price, n.stock, n.active)
    )@

CREATE TRIGGER trg_products_upd
    UPDATE ON products
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_products_upd(n.sku, n.name, n.category, n.price, n.stock, n.active)
    )@

CREATE TRIGGER trg_orders_ins
    INSERT ON orders
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_orders_ins(n.id, n.status, n.total, n.payment_ref)
    )@

CREATE TRIGGER trg_orders_upd
    UPDATE ON orders
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_orders_upd(n.id, n.status, n.total, n.payment_ref)
    )@

-- =========================================================================
-- 2. All 27 Static Informix SPL Runtime Stored Procedures (SP_ONLY)
--    All tables store native DECIMAL(32,4); SPL converts to/from VARCHAR(64)
--    at the DRDA boundary so all 32 significant digits cross the wire verbatim.
-- =========================================================================

CREATE OR REPLACE PROCEDURE shop_sp_current_timestamp()
    RETURNING VARCHAR(64) AS ts;
    DEFINE v_ts VARCHAR(64);
    LET v_ts = TO_CHAR(CURRENT YEAR TO FRACTION(5), '%Y-%m-%d %H:%M:%S.%F5');
    RETURN v_ts;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_products()
    RETURNING
        VARCHAR(32)    AS sku,
        VARCHAR(128)   AS name,
        VARCHAR(64)    AS category,
        LVARCHAR(1024) AS description,
        LVARCHAR(2048) AS ascii_art,
        VARCHAR(64)    AS price,
        INTEGER        AS stock,
        SMALLINT       AS active;

    DEFINE v_sku         VARCHAR(32);
    DEFINE v_name        VARCHAR(128);
    DEFINE v_category    VARCHAR(64);
    DEFINE v_description LVARCHAR(1024);
    DEFINE v_ascii_art   LVARCHAR(2048);
    DEFINE v_price       VARCHAR(64);
    DEFINE v_stock       INTEGER;
    DEFINE v_active      SMALLINT;

    FOREACH
        SELECT sku, name, category, description, ascii_art, TRIM(TO_CHAR(price)), stock, active
        INTO v_sku, v_name, v_category, v_description, v_ascii_art, v_price, v_stock, v_active
        FROM products
        WHERE active = 1
        ORDER BY sku

        RETURN v_sku, v_name, v_category, v_description, v_ascii_art, v_price, v_stock, v_active WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_product(p_sku VARCHAR(32))
    RETURNING
        VARCHAR(32)    AS sku,
        VARCHAR(128)   AS name,
        VARCHAR(64)    AS category,
        LVARCHAR(1024) AS description,
        LVARCHAR(2048) AS ascii_art,
        VARCHAR(64)    AS price,
        INTEGER        AS stock,
        SMALLINT       AS active;

    DEFINE v_sku         VARCHAR(32);
    DEFINE v_name        VARCHAR(128);
    DEFINE v_category    VARCHAR(64);
    DEFINE v_description LVARCHAR(1024);
    DEFINE v_ascii_art   LVARCHAR(2048);
    DEFINE v_price       VARCHAR(64);
    DEFINE v_stock       INTEGER;
    DEFINE v_active      SMALLINT;

    FOREACH
        SELECT sku, name, category, description, ascii_art, TRIM(TO_CHAR(price)), stock, active
        INTO v_sku, v_name, v_category, v_description, v_ascii_art, v_price, v_stock, v_active
        FROM products
        WHERE sku = p_sku

        RETURN v_sku, v_name, v_category, v_description, v_ascii_art, v_price, v_stock, v_active WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_upsert_product(
    p_sku         VARCHAR(32),
    p_name        VARCHAR(128),
    p_category    VARCHAR(64),
    p_description LVARCHAR(1024),
    p_ascii_art   LVARCHAR(2048),
    p_price       VARCHAR(64),
    p_stock       INTEGER,
    p_active      SMALLINT
)
    DEFINE v_price DECIMAL(32,4);
    LET v_price = NULL;
    IF p_price IS NOT NULL THEN
        LET v_price = p_price;
    END IF;

    MERGE INTO products AS t
    USING (
        SELECT
            p_sku         AS sku,
            p_name        AS name,
            p_category    AS category,
            p_description AS description,
            p_ascii_art   AS ascii_art,
            v_price       AS price,
            p_stock       AS stock,
            p_active      AS active
        FROM sysmaster:sysdual
    ) AS s
    ON t.sku = s.sku
    WHEN MATCHED THEN
        UPDATE SET
            t.name        = NVL(s.name, t.name),
            t.category    = NVL(s.category, t.category),
            t.description = NVL(s.description, t.description),
            t.ascii_art   = NVL(s.ascii_art, t.ascii_art),
            t.price       = NVL(s.price, t.price),
            t.stock       = NVL(s.stock, t.stock),
            t.active      = NVL(s.active, t.active),
            t.updated_at  = CURRENT YEAR TO FRACTION(5)
    WHEN NOT MATCHED THEN
        INSERT (sku, name, category, description, ascii_art, price, stock, active)
        VALUES (
            s.sku,
            NVL(s.name, s.sku),
            NVL(s.category, 'General'),
            NVL(s.description, ''),
            NVL(s.ascii_art, ''),
            NVL(s.price, 0.0000),
            NVL(s.stock, 0),
            NVL(s.active, 1)
        );
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_decrement_stock(
    p_sku VARCHAR(32),
    p_qty INTEGER
)
    RETURNING
        VARCHAR(32)   AS sku,
        VARCHAR(128)  AS name,
        VARCHAR(64)   AS price,
        INTEGER       AS stock,
        VARCHAR(64)   AS updated_at;

    DEFINE v_sku        VARCHAR(32);
    DEFINE v_name       VARCHAR(128);
    DEFINE v_price      VARCHAR(64);
    DEFINE v_stock      INTEGER;
    DEFINE v_updated_at VARCHAR(64);
    DEFINE v_rc         INTEGER;

    UPDATE products
    SET stock = stock - p_qty,
        updated_at = CURRENT YEAR TO FRACTION(5)
    WHERE sku = p_sku
      AND stock >= p_qty;

    LET v_rc = DBINFO('sqlca.sqlerrd2');
    IF v_rc > 0 THEN
        FOREACH
            SELECT sku, name, TRIM(TO_CHAR(price)), stock, TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_sku, v_name, v_price, v_stock, v_updated_at
            FROM products
            WHERE sku = p_sku

            RETURN v_sku, v_name, v_price, v_stock, v_updated_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_update_product_stock(
    p_sku   VARCHAR(32),
    p_stock INTEGER
)
    RETURNING
        VARCHAR(32)   AS sku,
        VARCHAR(128)  AS name,
        VARCHAR(64)   AS price,
        INTEGER       AS stock,
        VARCHAR(64)   AS updated_at;

    DEFINE v_sku        VARCHAR(32);
    DEFINE v_name       VARCHAR(128);
    DEFINE v_price      VARCHAR(64);
    DEFINE v_stock      INTEGER;
    DEFINE v_updated_at VARCHAR(64);
    DEFINE v_rc         INTEGER;

    UPDATE products
    SET stock = p_stock,
        updated_at = CURRENT YEAR TO FRACTION(5)
    WHERE sku = p_sku;

    LET v_rc = DBINFO('sqlca.sqlerrd2');
    IF v_rc > 0 THEN
        FOREACH
            SELECT sku, name, TRIM(TO_CHAR(price)), stock, TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_sku, v_name, v_price, v_stock, v_updated_at
            FROM products
            WHERE sku = p_sku

            RETURN v_sku, v_name, v_price, v_stock, v_updated_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_promo(p_code VARCHAR(32))
    RETURNING
        VARCHAR(32) AS code,
        VARCHAR(16) AS kind,
        VARCHAR(64) AS value,
        VARCHAR(64) AS min_subtotal,
        SMALLINT    AS active;

    DEFINE v_code         VARCHAR(32);
    DEFINE v_kind         VARCHAR(16);
    DEFINE v_value        VARCHAR(64);
    DEFINE v_min_subtotal VARCHAR(64);
    DEFINE v_active       SMALLINT;

    FOREACH
        SELECT code, kind, TRIM(TO_CHAR(value)), TRIM(TO_CHAR(min_subtotal)), active
        INTO v_code, v_kind, v_value, v_min_subtotal, v_active
        FROM promo_codes
        WHERE UPPER(code) = UPPER(p_code)
          AND active = 1

        RETURN v_code, v_kind, v_value, v_min_subtotal, v_active WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_user(p_fp VARCHAR(128))
    RETURNING
        VARCHAR(128) AS fingerprint,
        VARCHAR(64)  AS username,
        VARCHAR(128) AS email,
        VARCHAR(64)  AS pubkey_type,
        SMALLINT     AS is_admin,
        VARCHAR(128) AS stripe_customer_id,
        VARCHAR(128) AS default_payment_method,
        VARCHAR(8)   AS default_payment_last4,
        VARCHAR(64)  AS created_at;

    DEFINE v_fp          VARCHAR(128);
    DEFINE v_username    VARCHAR(64);
    DEFINE v_email       VARCHAR(128);
    DEFINE v_pubkey_type VARCHAR(64);
    DEFINE v_is_admin    SMALLINT;
    DEFINE v_stripe_cust VARCHAR(128);
    DEFINE v_pm_id       VARCHAR(128);
    DEFINE v_pm_last4    VARCHAR(8);
    DEFINE v_created_at  VARCHAR(64);

    FOREACH
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
             v_stripe_cust, v_pm_id, v_pm_last4, v_created_at
        FROM users
        WHERE fingerprint = p_fp

        RETURN v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
               v_stripe_cust, v_pm_id, v_pm_last4, v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_upsert_user(
    p_fp          VARCHAR(128),
    p_username    VARCHAR(64),
    p_email       VARCHAR(128),
    p_pubkey_type VARCHAR(64),
    p_is_admin    SMALLINT,
    p_stripe_cust VARCHAR(128),
    p_pm_id       VARCHAR(128),
    p_pm_last4    VARCHAR(8)
)
    RETURNING
        VARCHAR(128) AS fingerprint,
        VARCHAR(64)  AS username,
        VARCHAR(128) AS email,
        VARCHAR(64)  AS pubkey_type,
        SMALLINT     AS is_admin,
        VARCHAR(128) AS stripe_customer_id,
        VARCHAR(128) AS default_payment_method,
        VARCHAR(8)   AS default_payment_last4,
        VARCHAR(64)  AS created_at;

    DEFINE v_fp          VARCHAR(128);
    DEFINE v_username    VARCHAR(64);
    DEFINE v_email       VARCHAR(128);
    DEFINE v_pubkey_type VARCHAR(64);
    DEFINE v_is_admin    SMALLINT;
    DEFINE v_stripe_cust VARCHAR(128);
    DEFINE v_pm_id       VARCHAR(128);
    DEFINE v_pm_last4    VARCHAR(8);
    DEFINE v_created_at  VARCHAR(64);

    MERGE INTO users AS t
    USING (
        SELECT
            p_fp          AS fingerprint,
            p_username    AS username,
            p_email       AS email,
            p_pubkey_type AS pubkey_type,
            p_is_admin    AS is_admin,
            p_stripe_cust AS stripe_customer_id,
            p_pm_id       AS default_payment_method,
            p_pm_last4    AS default_payment_last4
        FROM sysmaster:sysdual
    ) AS s
    ON t.fingerprint = s.fingerprint
    WHEN MATCHED THEN
        UPDATE SET
            t.username               = NVL(s.username, t.username),
            t.email                  = NVL(s.email, t.email),
            t.pubkey_type            = NVL(s.pubkey_type, t.pubkey_type),
            t.is_admin               = NVL(s.is_admin, t.is_admin),
            t.stripe_customer_id     = NVL(s.stripe_customer_id, t.stripe_customer_id),
            t.default_payment_method = NVL(s.default_payment_method, t.default_payment_method),
            t.default_payment_last4  = NVL(s.default_payment_last4, t.default_payment_last4)
    WHEN NOT MATCHED THEN
        INSERT (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4)
        VALUES (
            s.fingerprint,
            NVL(s.username, 'guest'),
            NVL(s.email, ''),
            NVL(s.pubkey_type, ''),
            NVL(s.is_admin, 0),
            NVL(s.stripe_customer_id, ''),
            NVL(s.default_payment_method, ''),
            NVL(s.default_payment_last4, '')
        );

    FOREACH
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
             v_stripe_cust, v_pm_id, v_pm_last4, v_created_at
        FROM users
        WHERE fingerprint = p_fp

        RETURN v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
               v_stripe_cust, v_pm_id, v_pm_last4, v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_save_payment_method(
    p_fp          VARCHAR(128),
    p_pm_id       VARCHAR(128),
    p_pm_last4    VARCHAR(8),
    p_stripe_cust VARCHAR(128)
)
    RETURNING
        VARCHAR(128) AS fingerprint,
        VARCHAR(64)  AS username,
        VARCHAR(128) AS email,
        VARCHAR(64)  AS pubkey_type,
        SMALLINT     AS is_admin,
        VARCHAR(128) AS stripe_customer_id,
        VARCHAR(128) AS default_payment_method,
        VARCHAR(8)   AS default_payment_last4,
        VARCHAR(64)  AS created_at;

    DEFINE v_fp          VARCHAR(128);
    DEFINE v_username    VARCHAR(64);
    DEFINE v_email       VARCHAR(128);
    DEFINE v_pubkey_type VARCHAR(64);
    DEFINE v_is_admin    SMALLINT;
    DEFINE v_stripe_cust VARCHAR(128);
    DEFINE v_pm_id       VARCHAR(128);
    DEFINE v_pm_last4    VARCHAR(8);
    DEFINE v_created_at  VARCHAR(64);

    MERGE INTO users AS t
    USING (
        SELECT
            p_fp          AS fingerprint,
            p_pm_id       AS default_payment_method,
            p_pm_last4    AS default_payment_last4,
            p_stripe_cust AS stripe_customer_id
        FROM sysmaster:sysdual
    ) AS s
    ON t.fingerprint = s.fingerprint
    WHEN MATCHED THEN
        UPDATE SET
            t.default_payment_method = NVL(s.default_payment_method, ''),
            t.default_payment_last4  = NVL(s.default_payment_last4, ''),
            t.stripe_customer_id     = NVL(s.stripe_customer_id, t.stripe_customer_id)
    WHEN NOT MATCHED THEN
        INSERT (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4)
        VALUES (
            s.fingerprint,
            'guest',
            '',
            '',
            0,
            NVL(s.stripe_customer_id, ''),
            NVL(s.default_payment_method, ''),
            NVL(s.default_payment_last4, '')
        );

    FOREACH
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
             v_stripe_cust, v_pm_id, v_pm_last4, v_created_at
        FROM users
        WHERE fingerprint = p_fp

        RETURN v_fp, v_username, v_email, v_pubkey_type, v_is_admin,
               v_stripe_cust, v_pm_id, v_pm_last4, v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_addresses(p_user_fp VARCHAR(128))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(64)  AS label,
        VARCHAR(128) AS recipient,
        VARCHAR(255) AS line1,
        VARCHAR(255) AS line2,
        VARCHAR(128) AS city,
        VARCHAR(64)  AS state,
        VARCHAR(32)  AS postal_code,
        VARCHAR(8)   AS country,
        SMALLINT     AS is_default;

    DEFINE v_id          VARCHAR(64);
    DEFINE v_user_fp     VARCHAR(128);
    DEFINE v_label       VARCHAR(64);
    DEFINE v_recipient   VARCHAR(128);
    DEFINE v_line1       VARCHAR(255);
    DEFINE v_line2       VARCHAR(255);
    DEFINE v_city        VARCHAR(128);
    DEFINE v_state       VARCHAR(64);
    DEFINE v_postal_code VARCHAR(32);
    DEFINE v_country     VARCHAR(8);
    DEFINE v_is_default  SMALLINT;

    FOREACH
        SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default
        INTO v_id, v_user_fp, v_label, v_recipient, v_line1, v_line2, v_city, v_state, v_postal_code, v_country, v_is_default
        FROM addresses
        WHERE user_fp = p_user_fp
        ORDER BY is_default DESC, id ASC

        RETURN v_id, v_user_fp, v_label, v_recipient, v_line1, v_line2, v_city, v_state, v_postal_code, v_country, v_is_default WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_save_address(
    p_id          VARCHAR(64),
    p_user_fp     VARCHAR(128),
    p_label       VARCHAR(64),
    p_recipient   VARCHAR(128),
    p_line1       VARCHAR(255),
    p_line2       VARCHAR(255),
    p_city        VARCHAR(128),
    p_state       VARCHAR(64),
    p_postal_code VARCHAR(32),
    p_country     VARCHAR(8),
    p_is_default  SMALLINT
)
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(64)  AS label,
        VARCHAR(128) AS recipient,
        VARCHAR(255) AS line1,
        VARCHAR(255) AS line2,
        VARCHAR(128) AS city,
        VARCHAR(64)  AS state,
        VARCHAR(32)  AS postal_code,
        VARCHAR(8)   AS country,
        SMALLINT     AS is_default;

    DEFINE v_id          VARCHAR(64);
    DEFINE v_user_fp     VARCHAR(128);
    DEFINE v_label       VARCHAR(64);
    DEFINE v_recipient   VARCHAR(128);
    DEFINE v_line1       VARCHAR(255);
    DEFINE v_line2       VARCHAR(255);
    DEFINE v_city        VARCHAR(128);
    DEFINE v_state       VARCHAR(64);
    DEFINE v_postal_code VARCHAR(32);
    DEFINE v_country     VARCHAR(8);
    DEFINE v_is_default  SMALLINT;

    MERGE INTO addresses AS t
    USING (
        SELECT
            p_id          AS id,
            p_user_fp     AS user_fp,
            p_label       AS label,
            p_recipient   AS recipient,
            p_line1       AS line1,
            p_line2       AS line2,
            p_city        AS city,
            p_state       AS state,
            p_postal_code AS postal_code,
            p_country     AS country,
            p_is_default  AS is_default
        FROM sysmaster:sysdual
    ) AS s
    ON t.id = s.id AND t.user_fp = s.user_fp
    WHEN MATCHED THEN
        UPDATE SET
            t.label       = s.label,
            t.recipient   = s.recipient,
            t.line1       = s.line1,
            t.line2       = s.line2,
            t.city        = s.city,
            t.state       = s.state,
            t.postal_code = s.postal_code,
            t.country     = s.country,
            t.is_default  = s.is_default
    WHEN NOT MATCHED THEN
        INSERT (id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default)
        VALUES (s.id, s.user_fp, s.label, s.recipient, s.line1, s.line2, s.city, s.state, s.postal_code, s.country, s.is_default);

    FOREACH
        SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default
        INTO v_id, v_user_fp, v_label, v_recipient, v_line1, v_line2, v_city, v_state, v_postal_code, v_country, v_is_default
        FROM addresses
        WHERE id = p_id

        RETURN v_id, v_user_fp, v_label, v_recipient, v_line1, v_line2, v_city, v_state, v_postal_code, v_country, v_is_default WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_delete_address(
    p_id      VARCHAR(64),
    p_user_fp VARCHAR(128)
)
    DELETE FROM addresses
    WHERE id = p_id
      AND user_fp = p_user_fp;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_create_order(
    p_id               VARCHAR(64),
    p_user_fp          VARCHAR(128),
    p_username         VARCHAR(64),
    p_status           VARCHAR(32),
    p_subtotal         VARCHAR(64),
    p_discount         VARCHAR(64),
    p_tax              VARCHAR(64),
    p_shipping         VARCHAR(64),
    p_total            VARCHAR(64),
    p_promo_code       VARCHAR(32),
    p_payment_method   VARCHAR(32),
    p_payment_ref      VARCHAR(128),
    p_shipping_address LVARCHAR(1024),
    p_receipt_sig      LVARCHAR(256),
    p_receipt_hash     VARCHAR(128)
)
    DEFINE v_subtotal DECIMAL(32,4);
    DEFINE v_discount DECIMAL(32,4);
    DEFINE v_tax      DECIMAL(32,4);
    DEFINE v_shipping DECIMAL(32,4);
    DEFINE v_total    DECIMAL(32,4);

    LET v_subtotal = p_subtotal;
    LET v_discount = p_discount;
    LET v_tax      = p_tax;
    LET v_shipping = p_shipping;
    LET v_total    = p_total;

    INSERT INTO orders (
        id, user_fp, username, status, subtotal, discount, tax, shipping, total,
        promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash
    ) VALUES (
        p_id, p_user_fp, p_username, p_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
        p_promo_code, p_payment_method, p_payment_ref, p_shipping_address, p_receipt_sig, p_receipt_hash
    );
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_add_order_item(
    p_id         VARCHAR(64),
    p_order_id   VARCHAR(64),
    p_sku        VARCHAR(32),
    p_name       VARCHAR(128),
    p_qty        INTEGER,
    p_unit_price VARCHAR(64),
    p_line_total VARCHAR(64)
)
    DEFINE v_unit_price DECIMAL(32,4);
    DEFINE v_line_total DECIMAL(32,4);

    LET v_unit_price = p_unit_price;
    LET v_line_total = p_line_total;

    INSERT INTO order_items (id, order_id, sku, name, qty, unit_price, line_total)
    VALUES (p_id, p_order_id, p_sku, p_name, p_qty, v_unit_price, v_line_total);
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_orders(p_user_fp VARCHAR(128))
    RETURNING
        VARCHAR(64)    AS id,
        VARCHAR(128)   AS user_fp,
        VARCHAR(64)    AS username,
        VARCHAR(32)    AS status,
        VARCHAR(64)    AS subtotal,
        VARCHAR(64)    AS discount,
        VARCHAR(64)    AS tax,
        VARCHAR(64)    AS shipping,
        VARCHAR(64)    AS total,
        VARCHAR(32)    AS promo_code,
        VARCHAR(32)    AS payment_method,
        VARCHAR(128)   AS payment_ref,
        LVARCHAR(1024) AS shipping_address,
        LVARCHAR(256)  AS receipt_sig,
        VARCHAR(128)   AS receipt_hash,
        VARCHAR(64)    AS created_at;

    DEFINE v_id               VARCHAR(64);
    DEFINE v_user_fp          VARCHAR(128);
    DEFINE v_username         VARCHAR(64);
    DEFINE v_status           VARCHAR(32);
    DEFINE v_subtotal         VARCHAR(64);
    DEFINE v_discount         VARCHAR(64);
    DEFINE v_tax              VARCHAR(64);
    DEFINE v_shipping         VARCHAR(64);
    DEFINE v_total            VARCHAR(64);
    DEFINE v_promo_code       VARCHAR(32);
    DEFINE v_payment_method   VARCHAR(32);
    DEFINE v_payment_ref      VARCHAR(128);
    DEFINE v_shipping_address LVARCHAR(1024);
    DEFINE v_receipt_sig      LVARCHAR(256);
    DEFINE v_receipt_hash     VARCHAR(128);
    DEFINE v_created_at       VARCHAR(64);

    IF p_user_fp IS NULL OR p_user_fp = '' THEN
        FOREACH
            SELECT id, user_fp, username, status,
                   TRIM(TO_CHAR(subtotal)), TRIM(TO_CHAR(discount)),
                   TRIM(TO_CHAR(tax)), TRIM(TO_CHAR(shipping)), TRIM(TO_CHAR(total)),
                   promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                 v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
                 v_created_at
            FROM orders
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                   v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
                   v_created_at WITH RESUME;
        END FOREACH;
    ELSE
        FOREACH
            SELECT id, user_fp, username, status,
                   TRIM(TO_CHAR(subtotal)), TRIM(TO_CHAR(discount)),
                   TRIM(TO_CHAR(tax)), TRIM(TO_CHAR(shipping)), TRIM(TO_CHAR(total)),
                   promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                 v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
                 v_created_at
            FROM orders
            WHERE user_fp = p_user_fp
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                   v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
                   v_created_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_orders_masked(p_user_fp VARCHAR(128))
    RETURNING
        VARCHAR(64)    AS id,
        VARCHAR(128)   AS user_fp,
        VARCHAR(64)    AS username,
        VARCHAR(32)    AS status,
        VARCHAR(64)    AS subtotal,
        VARCHAR(64)    AS discount,
        VARCHAR(64)    AS tax,
        VARCHAR(64)    AS shipping,
        VARCHAR(64)    AS total,
        VARCHAR(32)    AS promo_code,
        VARCHAR(32)    AS payment_method,
        VARCHAR(128)   AS payment_ref,
        LVARCHAR(1024) AS shipping_address,
        VARCHAR(128)   AS receipt_hash,
        VARCHAR(64)    AS created_at;

    DEFINE v_id               VARCHAR(64);
    DEFINE v_user_fp          VARCHAR(128);
    DEFINE v_username         VARCHAR(64);
    DEFINE v_status           VARCHAR(32);
    DEFINE v_subtotal         VARCHAR(64);
    DEFINE v_discount         VARCHAR(64);
    DEFINE v_tax              VARCHAR(64);
    DEFINE v_shipping         VARCHAR(64);
    DEFINE v_total            VARCHAR(64);
    DEFINE v_promo_code       VARCHAR(32);
    DEFINE v_payment_method   VARCHAR(32);
    DEFINE v_payment_ref      VARCHAR(128);
    DEFINE v_shipping_address LVARCHAR(1024);
    DEFINE v_receipt_hash     VARCHAR(128);
    DEFINE v_created_at       VARCHAR(64);

    IF p_user_fp IS NULL OR p_user_fp = '' THEN
        FOREACH
            SELECT id, user_fp, username, status,
                   TRIM(TO_CHAR(subtotal)), TRIM(TO_CHAR(discount)),
                   TRIM(TO_CHAR(tax)), TRIM(TO_CHAR(shipping)), TRIM(TO_CHAR(total)),
                   promo_code, payment_method, payment_ref, shipping_address, receipt_hash,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                 v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_hash,
                 v_created_at
            FROM v_orders_masked
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                   v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_hash,
                   v_created_at WITH RESUME;
        END FOREACH;
    ELSE
        FOREACH
            SELECT id, user_fp, username, status,
                   TRIM(TO_CHAR(subtotal)), TRIM(TO_CHAR(discount)),
                   TRIM(TO_CHAR(tax)), TRIM(TO_CHAR(shipping)), TRIM(TO_CHAR(total)),
                   promo_code, payment_method, payment_ref, shipping_address, receipt_hash,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                 v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_hash,
                 v_created_at
            FROM v_orders_masked
            WHERE user_fp = p_user_fp
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
                   v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_hash,
                   v_created_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_order(p_order_id VARCHAR(64))
    RETURNING
        VARCHAR(64)    AS id,
        VARCHAR(128)   AS user_fp,
        VARCHAR(64)    AS username,
        VARCHAR(32)    AS status,
        VARCHAR(64)    AS subtotal,
        VARCHAR(64)    AS discount,
        VARCHAR(64)    AS tax,
        VARCHAR(64)    AS shipping,
        VARCHAR(64)    AS total,
        VARCHAR(32)    AS promo_code,
        VARCHAR(32)    AS payment_method,
        VARCHAR(128)   AS payment_ref,
        LVARCHAR(1024) AS shipping_address,
        LVARCHAR(256)  AS receipt_sig,
        VARCHAR(128)   AS receipt_hash,
        VARCHAR(64)    AS created_at;

    DEFINE v_id               VARCHAR(64);
    DEFINE v_user_fp          VARCHAR(128);
    DEFINE v_username         VARCHAR(64);
    DEFINE v_status           VARCHAR(32);
    DEFINE v_subtotal         VARCHAR(64);
    DEFINE v_discount         VARCHAR(64);
    DEFINE v_tax              VARCHAR(64);
    DEFINE v_shipping         VARCHAR(64);
    DEFINE v_total            VARCHAR(64);
    DEFINE v_promo_code       VARCHAR(32);
    DEFINE v_payment_method   VARCHAR(32);
    DEFINE v_payment_ref      VARCHAR(128);
    DEFINE v_shipping_address LVARCHAR(1024);
    DEFINE v_receipt_sig      LVARCHAR(256);
    DEFINE v_receipt_hash     VARCHAR(128);
    DEFINE v_created_at       VARCHAR(64);

    FOREACH
        SELECT id, user_fp, username, status,
               TRIM(TO_CHAR(subtotal)), TRIM(TO_CHAR(discount)),
               TRIM(TO_CHAR(tax)), TRIM(TO_CHAR(shipping)), TRIM(TO_CHAR(total)),
               promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
             v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
             v_created_at
        FROM orders
        WHERE id = p_order_id

        RETURN v_id, v_user_fp, v_username, v_status, v_subtotal, v_discount, v_tax, v_shipping, v_total,
               v_promo_code, v_payment_method, v_payment_ref, v_shipping_address, v_receipt_sig, v_receipt_hash,
               v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_order_items(p_order_id VARCHAR(64))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(64)  AS order_id,
        VARCHAR(32)  AS sku,
        VARCHAR(128) AS name,
        INTEGER      AS qty,
        VARCHAR(64)  AS unit_price,
        VARCHAR(64)  AS line_total;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_name       VARCHAR(128);
    DEFINE v_qty        INTEGER;
    DEFINE v_unit_price VARCHAR(64);
    DEFINE v_line_total VARCHAR(64);

    FOREACH
        SELECT id, order_id, sku, name, qty, TRIM(TO_CHAR(unit_price)), TRIM(TO_CHAR(line_total))
        INTO v_id, v_order_id, v_sku, v_name, v_qty, v_unit_price, v_line_total
        FROM order_items
        WHERE order_id = p_order_id
        ORDER BY id ASC

        RETURN v_id, v_order_id, v_sku, v_name, v_qty, v_unit_price, v_line_total WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_order_by_ref(p_payment_ref VARCHAR(128))
    RETURNING VARCHAR(64) AS id;

    DEFINE v_id VARCHAR(64);

    FOREACH
        SELECT FIRST 1 id
        INTO v_id
        FROM orders
        WHERE payment_ref = p_payment_ref
        ORDER BY created_at DESC

        RETURN v_id WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_update_order_status(
    p_order_id VARCHAR(64),
    p_status   VARCHAR(32)
)
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS total,
        VARCHAR(128) AS payment_ref;

    DEFINE v_id          VARCHAR(64);
    DEFINE v_status      VARCHAR(32);
    DEFINE v_total       VARCHAR(64);
    DEFINE v_payment_ref VARCHAR(128);
    DEFINE v_rc          INTEGER;

    UPDATE orders
    SET status = p_status
    WHERE id = p_order_id;

    LET v_rc = DBINFO('sqlca.sqlerrd2');
    IF v_rc > 0 THEN
        FOREACH
            SELECT id, status, TRIM(TO_CHAR(total)), payment_ref
            INTO v_id, v_status, v_total, v_payment_ref
            FROM orders
            WHERE id = p_order_id

            RETURN v_id, v_status, v_total, v_payment_ref WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_update_order_receipt(
    p_order_id     VARCHAR(64),
    p_receipt_hash VARCHAR(128),
    p_receipt_sig  LVARCHAR(256)
)
    UPDATE orders
    SET receipt_hash = p_receipt_hash,
        receipt_sig  = p_receipt_sig
    WHERE id = p_order_id;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_gmv_summary()
    RETURNING
        INTEGER     AS order_count,
        VARCHAR(64) AS total_gmv;

    DEFINE v_cnt INTEGER;
    DEFINE v_gmv DECIMAL(32,4);

    SELECT COUNT(*), NVL(SUM(total), 0.0000)
    INTO v_cnt, v_gmv
    FROM orders
    WHERE LOWER(status) <> 'cancelled';

    RETURN v_cnt, TRIM(TO_CHAR(v_gmv));
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_product_history(
    p_sku   VARCHAR(32),
    p_limit INTEGER
)
    RETURNING
        VARCHAR(32)  AS sku,
        VARCHAR(128) AS name,
        VARCHAR(64)  AS price,
        INTEGER      AS stock,
        VARCHAR(64)  AS sys_start,
        VARCHAR(64)  AS sys_end;

    DEFINE v_sku       VARCHAR(32);
    DEFINE v_name      VARCHAR(128);
    DEFINE v_price     VARCHAR(64);
    DEFINE v_stock     INTEGER;
    DEFINE v_sys_start VARCHAR(64);
    DEFINE v_sys_end   VARCHAR(64);
    DEFINE v_limit     INTEGER;
    DEFINE v_cnt       INTEGER;

    LET v_limit = 20;
    IF p_limit IS NOT NULL AND p_limit > 0 THEN
        LET v_limit = p_limit;
    END IF;
    LET v_cnt = 0;

    FOREACH
        SELECT sku, name, TRIM(TO_CHAR(price)), stock,
               TO_CHAR(sys_start, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(sys_end,   '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_sku, v_name, v_price, v_stock, v_sys_start, v_sys_end
        FROM products_audit
        WHERE sku = p_sku
        ORDER BY audit_id DESC

        LET v_cnt = v_cnt + 1;
        IF v_cnt > v_limit THEN
            EXIT FOREACH;
        END IF;
        RETURN v_sku, v_name, v_price, v_stock, v_sys_start, v_sys_end WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_catalog_as_of(p_ts VARCHAR(64))
    RETURNING
        VARCHAR(32)  AS sku,
        VARCHAR(128) AS name,
        VARCHAR(64)  AS category,
        VARCHAR(64)  AS price,
        INTEGER      AS stock;

    DEFINE v_ts       DATETIME YEAR TO FRACTION(5);
    DEFINE v_sku      VARCHAR(32);
    DEFINE v_name     VARCHAR(128);
    DEFINE v_category VARCHAR(64);
    DEFINE v_price    VARCHAR(64);
    DEFINE v_stock    INTEGER;

    LET v_ts = TO_DATE(p_ts, '%Y-%m-%d %H:%M:%S.%F5');

    FOREACH
        SELECT sku, name, category, TRIM(TO_CHAR(price)), stock
        INTO v_sku, v_name, v_category, v_price, v_stock
        FROM products_audit
        WHERE sys_start <= v_ts
          AND sys_end > v_ts
        ORDER BY sku ASC

        RETURN v_sku, v_name, v_category, v_price, v_stock WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_order_history(p_order_id VARCHAR(64))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS total,
        VARCHAR(128) AS payment_ref,
        VARCHAR(64)  AS sys_start,
        VARCHAR(64)  AS sys_end;

    DEFINE v_id          VARCHAR(64);
    DEFINE v_status      VARCHAR(32);
    DEFINE v_total       VARCHAR(64);
    DEFINE v_payment_ref VARCHAR(128);
    DEFINE v_sys_start   VARCHAR(64);
    DEFINE v_sys_end     VARCHAR(64);

    FOREACH
        SELECT id, status, TRIM(TO_CHAR(total)), payment_ref,
               TO_CHAR(sys_start, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(sys_end,   '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_status, v_total, v_payment_ref, v_sys_start, v_sys_end
        FROM orders_audit
        WHERE id = p_order_id
        ORDER BY audit_id DESC

        RETURN v_id, v_status, v_total, v_payment_ref, v_sys_start, v_sys_end WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_category_olap()
    RETURNING
        VARCHAR(64) AS category,
        INTEGER     AS order_count,
        INTEGER     AS units_sold,
        VARCHAR(64) AS revenue,
        VARCHAR(32) AS share_pct,
        INTEGER     AS rank;

    DEFINE v_category     VARCHAR(64);
    DEFINE v_order_count  INTEGER;
    DEFINE v_units_sold   INTEGER;
    DEFINE v_revenue      DECIMAL(32,4);
    DEFINE v_grand_orders INTEGER;
    DEFINE v_grand_units  INTEGER;
    DEFINE v_grand_rev    DECIMAL(32,4);
    DEFINE v_share_pct    DECIMAL(10,2);
    DEFINE v_rank         INTEGER;
    DEFINE v_row_num      INTEGER;
    DEFINE v_prev_rev     DECIMAL(32,4);

    SELECT COUNT(DISTINCT o.id), NVL(SUM(oi.qty), 0), NVL(SUM(oi.line_total), 0.0000)
    INTO v_grand_orders, v_grand_units, v_grand_rev
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id AND LOWER(o.status) <> 'cancelled'
    JOIN products p ON p.sku = oi.sku;

    LET v_rank = 0;
    LET v_row_num = 0;
    LET v_prev_rev = NULL;

    FOREACH
        SELECT
            p.category,
            COUNT(DISTINCT o.id),
            NVL(SUM(oi.qty), 0),
            NVL(SUM(oi.line_total), 0.0000)
        INTO v_category, v_order_count, v_units_sold, v_revenue
        FROM order_items oi
        JOIN orders o   ON o.id = oi.order_id AND LOWER(o.status) <> 'cancelled'
        JOIN products p ON p.sku = oi.sku
        GROUP BY p.category
        ORDER BY 4 DESC, 1 ASC

        LET v_row_num = v_row_num + 1;
        IF v_prev_rev IS NULL OR v_revenue <> v_prev_rev THEN
            LET v_rank = v_row_num;
            LET v_prev_rev = v_revenue;
        END IF;
        IF v_grand_rev > 0 THEN
            LET v_share_pct = ROUND((v_revenue * 100.0) / v_grand_rev, 2);
        ELSE
            LET v_share_pct = 0.00;
        END IF;

        RETURN v_category, v_order_count, v_units_sold, TRIM(TO_CHAR(v_revenue)), TRIM(TO_CHAR(v_share_pct)), v_rank WITH RESUME;
    END FOREACH;

    IF v_grand_orders > 0 THEN
        IF v_grand_rev > 0 THEN
            LET v_share_pct = 100.00;
        ELSE
            LET v_share_pct = 0.00;
        END IF;
        RETURN 'ALL CATEGORIES', v_grand_orders, v_grand_units, TRIM(TO_CHAR(v_grand_rev)), TRIM(TO_CHAR(v_share_pct)), 0 WITH RESUME;
    END IF;
END PROCEDURE@

-- =========================================================================
-- 3. Shipments Audit Trail SPL Procedures + Triggers
-- =========================================================================

CREATE OR REPLACE PROCEDURE shop_trg_shipments_ins(
    p_id              VARCHAR(64),
    p_order_id        VARCHAR(64),
    p_warehouse_code  VARCHAR(16),
    p_carrier         VARCHAR(64),
    p_tracking_number VARCHAR(128),
    p_status          VARCHAR(32)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    INSERT INTO shipments_audit (id, order_id, warehouse_code, carrier, tracking_number, status, op, sys_start, sys_end)
    VALUES (p_id, p_order_id, p_warehouse_code, p_carrier, p_tracking_number, p_status, 'I', v_now, v_max);
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_trg_shipments_upd(
    p_id              VARCHAR(64),
    p_order_id        VARCHAR(64),
    p_warehouse_code  VARCHAR(16),
    p_carrier         VARCHAR(64),
    p_tracking_number VARCHAR(128),
    p_status          VARCHAR(32)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    UPDATE shipments_audit
    SET sys_end = v_now
    WHERE id = p_id
      AND sys_end = v_max;

    INSERT INTO shipments_audit (id, order_id, warehouse_code, carrier, tracking_number, status, op, sys_start, sys_end)
    VALUES (p_id, p_order_id, p_warehouse_code, p_carrier, p_tracking_number, p_status, 'U', v_now, v_max);
END PROCEDURE@

CREATE TRIGGER trg_shipments_ins
    INSERT ON shipments
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_shipments_ins(n.id, n.order_id, n.warehouse_code, n.carrier, n.tracking_number, n.status)
    )@

CREATE TRIGGER trg_shipments_upd
    UPDATE ON shipments
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_shipments_upd(n.id, n.order_id, n.warehouse_code, n.carrier, n.tracking_number, n.status)
    )@

-- =========================================================================
-- 4. Logistics, Warehouses, Purchase Orders, Shipments, and Tax Nexus (SP_ONLY)
-- =========================================================================

CREATE OR REPLACE PROCEDURE shop_sp_list_warehouses()
    RETURNING
        VARCHAR(16)  AS code,
        VARCHAR(128) AS name,
        VARCHAR(128) AS city,
        VARCHAR(16)  AS state,
        VARCHAR(32)  AS postal_code,
        SMALLINT     AS active;

    DEFINE v_code        VARCHAR(16);
    DEFINE v_name        VARCHAR(128);
    DEFINE v_city        VARCHAR(128);
    DEFINE v_state       VARCHAR(16);
    DEFINE v_postal_code VARCHAR(32);
    DEFINE v_active      SMALLINT;

    FOREACH
        SELECT code, name, city, state, postal_code, active
        INTO v_code, v_name, v_city, v_state, v_postal_code, v_active
        FROM warehouses
        WHERE active = 1
        ORDER BY code ASC

        RETURN v_code, v_name, v_city, v_state, v_postal_code, v_active WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_warehouse_stock(p_wh_code VARCHAR(16))
    RETURNING
        VARCHAR(16) AS warehouse_code,
        VARCHAR(32) AS sku,
        INTEGER     AS qty,
        VARCHAR(32) AS bin_location;

    DEFINE v_wh_code VARCHAR(16);
    DEFINE v_sku     VARCHAR(32);
    DEFINE v_qty     INTEGER;
    DEFINE v_bin     VARCHAR(32);

    IF p_wh_code IS NULL OR p_wh_code = '' THEN
        FOREACH
            SELECT warehouse_code, sku, qty, bin_location
            INTO v_wh_code, v_sku, v_qty, v_bin
            FROM warehouse_stock
            ORDER BY warehouse_code ASC, sku ASC

            RETURN v_wh_code, v_sku, v_qty, v_bin WITH RESUME;
        END FOREACH;
    ELSE
        FOREACH
            SELECT warehouse_code, sku, qty, bin_location
            INTO v_wh_code, v_sku, v_qty, v_bin
            FROM warehouse_stock
            WHERE warehouse_code = p_wh_code
            ORDER BY sku ASC

            RETURN v_wh_code, v_sku, v_qty, v_bin WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_create_po(
    p_id         VARCHAR(64),
    p_supplier   VARCHAR(128),
    p_wh_code    VARCHAR(16),
    p_total_cost VARCHAR(64)
)
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS supplier,
        VARCHAR(16)  AS warehouse_code,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS total_cost,
        VARCHAR(64)  AS created_at;

    DEFINE v_total_dec  DECIMAL(32,4);
    DEFINE v_id         VARCHAR(64);
    DEFINE v_supplier   VARCHAR(128);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_total_cost VARCHAR(64);
    DEFINE v_created_at VARCHAR(64);

    LET v_total_dec = p_total_cost;

    INSERT INTO purchase_orders (id, supplier, warehouse_code, status, total_cost)
    VALUES (p_id, p_supplier, p_wh_code, 'OPEN', v_total_dec);

    FOREACH
        SELECT id, supplier, warehouse_code, status, TRIM(TO_CHAR(total_cost)),
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_supplier, v_wh_code, v_status, v_total_cost, v_created_at
        FROM purchase_orders
        WHERE id = p_id

        RETURN v_id, v_supplier, v_wh_code, v_status, v_total_cost, v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_add_po_line(
    p_id        VARCHAR(64),
    p_po_id     VARCHAR(64),
    p_sku       VARCHAR(32),
    p_qty_ord   INTEGER,
    p_unit_cost VARCHAR(64)
)
    RETURNING
        VARCHAR(64) AS id,
        VARCHAR(64) AS po_id,
        VARCHAR(32) AS sku,
        INTEGER     AS qty_ordered,
        INTEGER     AS qty_received,
        VARCHAR(64) AS unit_cost;

    DEFINE v_cost_dec   DECIMAL(32,4);
    DEFINE v_id         VARCHAR(64);
    DEFINE v_po_id      VARCHAR(64);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_qty_ord    INTEGER;
    DEFINE v_qty_rcv    INTEGER;
    DEFINE v_unit_cost  VARCHAR(64);

    LET v_cost_dec = p_unit_cost;

    INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost)
    VALUES (p_id, p_po_id, p_sku, p_qty_ord, 0, v_cost_dec);

    FOREACH
        SELECT id, po_id, sku, qty_ordered, qty_received, TRIM(TO_CHAR(unit_cost))
        INTO v_id, v_po_id, v_sku, v_qty_ord, v_qty_rcv, v_unit_cost
        FROM po_lines
        WHERE id = p_id

        RETURN v_id, v_po_id, v_sku, v_qty_ord, v_qty_rcv, v_unit_cost WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_pos()
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS supplier,
        VARCHAR(16)  AS warehouse_code,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS total_cost,
        VARCHAR(64)  AS created_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_supplier   VARCHAR(128);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_total_cost VARCHAR(64);
    DEFINE v_created_at VARCHAR(64);

    FOREACH
        SELECT id, supplier, warehouse_code, status, TRIM(TO_CHAR(total_cost)),
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_supplier, v_wh_code, v_status, v_total_cost, v_created_at
        FROM purchase_orders
        ORDER BY created_at DESC, id DESC

        RETURN v_id, v_supplier, v_wh_code, v_status, v_total_cost, v_created_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_po_lines(p_po_id VARCHAR(64))
    RETURNING
        VARCHAR(64) AS id,
        VARCHAR(64) AS po_id,
        VARCHAR(32) AS sku,
        INTEGER     AS qty_ordered,
        INTEGER     AS qty_received,
        VARCHAR(64) AS unit_cost;

    DEFINE v_id        VARCHAR(64);
    DEFINE v_po_id     VARCHAR(64);
    DEFINE v_sku       VARCHAR(32);
    DEFINE v_qty_ord   INTEGER;
    DEFINE v_qty_rcv   INTEGER;
    DEFINE v_unit_cost VARCHAR(64);

    FOREACH
        SELECT id, po_id, sku, qty_ordered, qty_received, TRIM(TO_CHAR(unit_cost))
        INTO v_id, v_po_id, v_sku, v_qty_ord, v_qty_rcv, v_unit_cost
        FROM po_lines
        WHERE po_id = p_po_id
        ORDER BY id ASC

        RETURN v_id, v_po_id, v_sku, v_qty_ord, v_qty_rcv, v_unit_cost WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_receive_po_line(
    p_po_line_id VARCHAR(64),
    p_recv_qty   INTEGER
)
    RETURNING
        VARCHAR(64) AS po_id,
        VARCHAR(64) AS po_line_id,
        VARCHAR(16) AS warehouse_code,
        VARCHAR(32) AS sku,
        INTEGER     AS qty_received,
        INTEGER     AS new_stock,
        VARCHAR(32) AS po_status;

    DEFINE v_po_id     VARCHAR(64);
    DEFINE v_wh_code   VARCHAR(16);
    DEFINE v_sku       VARCHAR(32);
    DEFINE v_new_rcv   INTEGER;
    DEFINE v_new_stock INTEGER;
    DEFINE v_open_cnt  INTEGER;
    DEFINE v_po_status VARCHAR(32);
    DEFINE v_found     SMALLINT;

    IF p_recv_qty IS NULL OR p_recv_qty <= 0 THEN
        RETURN;
    END IF;

    LET v_found = 0;
    FOREACH
        SELECT l.po_id, p.warehouse_code, l.sku, l.qty_received
        INTO v_po_id, v_wh_code, v_sku, v_new_rcv
        FROM po_lines l
        JOIN purchase_orders p ON p.id = l.po_id
        WHERE l.id = p_po_line_id

        LET v_found = 1;
        EXIT FOREACH;
    END FOREACH;

    IF v_found = 0 THEN
        RETURN;
    END IF;

    UPDATE po_lines
    SET qty_received = qty_received + p_recv_qty
    WHERE id = p_po_line_id;

    LET v_new_rcv = v_new_rcv + p_recv_qty;

    UPDATE warehouse_stock
    SET qty = qty + p_recv_qty
    WHERE warehouse_code = v_wh_code
      AND sku = v_sku;

    IF DBINFO('sqlca.sqlerrd2') = 0 THEN
        INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location)
        VALUES (v_wh_code, v_sku, p_recv_qty, 'RCV-01');
    END IF;

    UPDATE products
    SET stock = stock + p_recv_qty,
        updated_at = CURRENT YEAR TO FRACTION(5)
    WHERE sku = v_sku;

    LET v_new_stock = 0;
    SELECT NVL(MAX(stock), 0)
    INTO v_new_stock
    FROM products
    WHERE sku = v_sku;

    SELECT COUNT(*)
    INTO v_open_cnt
    FROM po_lines
    WHERE po_id = v_po_id
      AND qty_received < qty_ordered;

    IF v_open_cnt = 0 THEN
        LET v_po_status = 'RECEIVED';
    ELSE
        LET v_po_status = 'PARTIAL';
    END IF;

    UPDATE purchase_orders
    SET status = v_po_status
    WHERE id = v_po_id;

    RETURN v_po_id, p_po_line_id, v_wh_code, v_sku, v_new_rcv, v_new_stock, v_po_status WITH RESUME;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_create_shipment(
    p_id          VARCHAR(64),
    p_order_id    VARCHAR(64),
    p_wh_code     VARCHAR(16),
    p_carrier     VARCHAR(64),
    p_service     VARCHAR(64),
    p_rate_amount VARCHAR(64),
    p_tracking    VARCHAR(128),
    p_label_url   LVARCHAR(512),
    p_status      VARCHAR(32)
)
    RETURNING
        VARCHAR(64)   AS id,
        VARCHAR(64)   AS order_id,
        VARCHAR(16)   AS warehouse_code,
        VARCHAR(64)   AS carrier,
        VARCHAR(64)   AS service,
        VARCHAR(64)   AS rate_amount,
        VARCHAR(128)  AS tracking_number,
        LVARCHAR(512) AS label_url,
        VARCHAR(32)   AS status,
        VARCHAR(64)   AS updated_at;

    DEFINE v_rate_dec   DECIMAL(32,4);
    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_carrier    VARCHAR(64);
    DEFINE v_service    VARCHAR(64);
    DEFINE v_rate_str   VARCHAR(64);
    DEFINE v_tracking   VARCHAR(128);
    DEFINE v_label_url  LVARCHAR(512);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_updated_at VARCHAR(64);

    IF p_rate_amount IS NULL OR p_rate_amount = '' THEN
        LET v_rate_dec = 0.0000;
    ELSE
        LET v_rate_dec = p_rate_amount;
    END IF;

    INSERT INTO shipments (
        id, order_id, warehouse_code, carrier, service, rate_amount,
        tracking_number, label_url, status
    ) VALUES (
        p_id, p_order_id, p_wh_code,
        NVL(p_carrier, ''),
        NVL(p_service, ''),
        v_rate_dec,
        NVL(p_tracking, ''),
        NVL(p_label_url, ''),
        NVL(p_status, 'PENDING')
    );

    FOREACH
        SELECT id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
               tracking_number, label_url, status,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
             v_tracking, v_label_url, v_status, v_updated_at
        FROM shipments
        WHERE id = p_id

        RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
               v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_update_shipment(
    p_id        VARCHAR(64),
    p_status    VARCHAR(32),
    p_tracking  VARCHAR(128),
    p_label_url LVARCHAR(512)
)
    RETURNING
        VARCHAR(64)   AS id,
        VARCHAR(64)   AS order_id,
        VARCHAR(16)   AS warehouse_code,
        VARCHAR(64)   AS carrier,
        VARCHAR(64)   AS service,
        VARCHAR(64)   AS rate_amount,
        VARCHAR(128)  AS tracking_number,
        LVARCHAR(512) AS label_url,
        VARCHAR(32)   AS status,
        VARCHAR(64)   AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_carrier    VARCHAR(64);
    DEFINE v_service    VARCHAR(64);
    DEFINE v_rate_str   VARCHAR(64);
    DEFINE v_tracking   VARCHAR(128);
    DEFINE v_label_url  LVARCHAR(512);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_updated_at VARCHAR(64);

    UPDATE shipments
    SET status          = NVL(p_status, status),
        tracking_number = NVL(p_tracking, tracking_number),
        label_url       = NVL(p_label_url, label_url),
        updated_at      = CURRENT YEAR TO FRACTION(5)
    WHERE id = p_id;

    FOREACH
        SELECT id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
               tracking_number, label_url, status,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
             v_tracking, v_label_url, v_status, v_updated_at
        FROM shipments
        WHERE id = p_id

        RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
               v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_shipment_by_order(p_order_id VARCHAR(64))
    RETURNING
        VARCHAR(64)   AS id,
        VARCHAR(64)   AS order_id,
        VARCHAR(16)   AS warehouse_code,
        VARCHAR(64)   AS carrier,
        VARCHAR(64)   AS service,
        VARCHAR(64)   AS rate_amount,
        VARCHAR(128)  AS tracking_number,
        LVARCHAR(512) AS label_url,
        VARCHAR(32)   AS status,
        VARCHAR(64)   AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_carrier    VARCHAR(64);
    DEFINE v_service    VARCHAR(64);
    DEFINE v_rate_str   VARCHAR(64);
    DEFINE v_tracking   VARCHAR(128);
    DEFINE v_label_url  LVARCHAR(512);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_updated_at VARCHAR(64);

    FOREACH
        SELECT FIRST 1
               id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
               tracking_number, label_url, status,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
             v_tracking, v_label_url, v_status, v_updated_at
        FROM shipments
        WHERE order_id = p_order_id
        ORDER BY updated_at DESC, id DESC

        RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
               v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_shipment_by_tracking(p_tracking VARCHAR(128))
    RETURNING
        VARCHAR(64)   AS id,
        VARCHAR(64)   AS order_id,
        VARCHAR(16)   AS warehouse_code,
        VARCHAR(64)   AS carrier,
        VARCHAR(64)   AS service,
        VARCHAR(64)   AS rate_amount,
        VARCHAR(128)  AS tracking_number,
        LVARCHAR(512) AS label_url,
        VARCHAR(32)   AS status,
        VARCHAR(64)   AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_carrier    VARCHAR(64);
    DEFINE v_service    VARCHAR(64);
    DEFINE v_rate_str   VARCHAR(64);
    DEFINE v_tracking   VARCHAR(128);
    DEFINE v_label_url  LVARCHAR(512);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_updated_at VARCHAR(64);

    FOREACH
        SELECT FIRST 1
               id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
               tracking_number, label_url, status,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
             v_tracking, v_label_url, v_status, v_updated_at
        FROM shipments
        WHERE tracking_number = p_tracking
        ORDER BY updated_at DESC, id DESC

        RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
               v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_shipments(p_status VARCHAR(32))
    RETURNING
        VARCHAR(64)   AS id,
        VARCHAR(64)   AS order_id,
        VARCHAR(16)   AS warehouse_code,
        VARCHAR(64)   AS carrier,
        VARCHAR(64)   AS service,
        VARCHAR(64)   AS rate_amount,
        VARCHAR(128)  AS tracking_number,
        LVARCHAR(512) AS label_url,
        VARCHAR(32)   AS status,
        VARCHAR(64)   AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_order_id   VARCHAR(64);
    DEFINE v_wh_code    VARCHAR(16);
    DEFINE v_carrier    VARCHAR(64);
    DEFINE v_service    VARCHAR(64);
    DEFINE v_rate_str   VARCHAR(64);
    DEFINE v_tracking   VARCHAR(128);
    DEFINE v_label_url  LVARCHAR(512);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_updated_at VARCHAR(64);

    IF p_status IS NULL OR p_status = '' THEN
        FOREACH
            SELECT id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
                   tracking_number, label_url, status,
                   TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
                 v_tracking, v_label_url, v_status, v_updated_at
            FROM shipments
            ORDER BY updated_at DESC, id DESC

            RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
                   v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
        END FOREACH;
    ELSE
        FOREACH
            SELECT id, order_id, warehouse_code, carrier, service, TRIM(TO_CHAR(rate_amount)),
                   tracking_number, label_url, status,
                   TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
                 v_tracking, v_label_url, v_status, v_updated_at
            FROM shipments
            WHERE UPPER(status) = UPPER(p_status)
            ORDER BY updated_at DESC, id DESC

            RETURN v_id, v_order_id, v_wh_code, v_carrier, v_service, v_rate_str,
                   v_tracking, v_label_url, v_status, v_updated_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_tax_nexus(p_state VARCHAR(8))
    RETURNING
        VARCHAR(8)  AS state,
        VARCHAR(64) AS rate,
        VARCHAR(64) AS threshold_sales,
        INTEGER     AS threshold_txns,
        SMALLINT    AS registered;

    DEFINE v_state        VARCHAR(8);
    DEFINE v_rate         VARCHAR(64);
    DEFINE v_thresh_sales VARCHAR(64);
    DEFINE v_thresh_txns  INTEGER;
    DEFINE v_registered   SMALLINT;

    FOREACH
        SELECT state, TRIM(TO_CHAR(rate)), TRIM(TO_CHAR(threshold_sales)), threshold_txns, registered
        INTO v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered
        FROM tax_nexus
        WHERE UPPER(state) = UPPER(p_state)

        RETURN v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_tax_nexus()
    RETURNING
        VARCHAR(8)  AS state,
        VARCHAR(64) AS rate,
        VARCHAR(64) AS threshold_sales,
        INTEGER     AS threshold_txns,
        SMALLINT    AS registered;

    DEFINE v_state        VARCHAR(8);
    DEFINE v_rate         VARCHAR(64);
    DEFINE v_thresh_sales VARCHAR(64);
    DEFINE v_thresh_txns  INTEGER;
    DEFINE v_registered   SMALLINT;

    FOREACH
        SELECT state, TRIM(TO_CHAR(rate)), TRIM(TO_CHAR(threshold_sales)), threshold_txns, registered
        INTO v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered
        FROM tax_nexus
        ORDER BY state ASC

        RETURN v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_tax_nexus_report()
    RETURNING
        VARCHAR(8)  AS state,
        VARCHAR(64) AS rate,
        VARCHAR(64) AS threshold_sales,
        INTEGER     AS threshold_txns,
        SMALLINT    AS registered,
        VARCHAR(64) AS ytd_sales,
        INTEGER     AS ytd_txns;

    DEFINE v_state        VARCHAR(8);
    DEFINE v_rate         VARCHAR(64);
    DEFINE v_thresh_sales VARCHAR(64);
    DEFINE v_thresh_txns  INTEGER;
    DEFINE v_registered   SMALLINT;
    DEFINE v_ytd_dec      DECIMAL(32,4);
    DEFINE v_ytd_txns     INTEGER;
    DEFINE v_p1           VARCHAR(32);
    DEFINE v_p2           VARCHAR(32);
    DEFINE v_p3           VARCHAR(32);
    DEFINE v_p4           VARCHAR(32);

    FOREACH
        SELECT state, TRIM(TO_CHAR(rate)), TRIM(TO_CHAR(threshold_sales)), threshold_txns, registered
        INTO v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered
        FROM tax_nexus
        ORDER BY state ASC

        LET v_p1 = '%, ' || UPPER(v_state) || ',%';
        LET v_p2 = '%, ' || UPPER(v_state) || ' %';
        LET v_p3 = '% '  || UPPER(v_state) || ' %';
        LET v_p4 = '%, ' || UPPER(v_state);

        SELECT NVL(SUM(total), 0.0000), COUNT(*)
        INTO v_ytd_dec, v_ytd_txns
        FROM orders
        WHERE LOWER(status) <> 'cancelled'
          AND (UPPER(shipping_address) LIKE v_p1
            OR UPPER(shipping_address) LIKE v_p2
            OR UPPER(shipping_address) LIKE v_p3
            OR UPPER(shipping_address) LIKE v_p4);

        RETURN v_state, v_rate, v_thresh_sales, v_thresh_txns, v_registered,
               TRIM(TO_CHAR(v_ytd_dec)), v_ytd_txns WITH RESUME;
    END FOREACH;
END PROCEDURE@

-- =========================================================================
-- Memberships and Recurring Subscriptions (+ SPL trigger audit, SP_ONLY)
-- =========================================================================

CREATE OR REPLACE PROCEDURE shop_trg_subscriptions_ins(
    p_id            VARCHAR(64),
    p_user_fp       VARCHAR(128),
    p_sku           VARCHAR(32),
    p_qty           INTEGER,
    p_interval_days INTEGER,
    p_unit_price    DECIMAL(32,4),
    p_status        VARCHAR(32),
    p_next_bill_at  VARCHAR(64),
    p_last_order_id VARCHAR(64)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    INSERT INTO subscriptions_audit (
        id, user_fp, sku, qty, interval_days, unit_price,
        status, next_bill_at, last_order_id, op, sys_start, sys_end
    ) VALUES (
        p_id, p_user_fp, p_sku, p_qty, p_interval_days, p_unit_price,
        p_status, p_next_bill_at, p_last_order_id, 'I', v_now, v_max
    );
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_trg_subscriptions_upd(
    p_id            VARCHAR(64),
    p_user_fp       VARCHAR(128),
    p_sku           VARCHAR(32),
    p_qty           INTEGER,
    p_interval_days INTEGER,
    p_unit_price    DECIMAL(32,4),
    p_status        VARCHAR(32),
    p_next_bill_at  VARCHAR(64),
    p_last_order_id VARCHAR(64)
)
    DEFINE v_now DATETIME YEAR TO FRACTION(5);
    DEFINE v_max DATETIME YEAR TO FRACTION(5);
    LET v_now = CURRENT YEAR TO FRACTION(5);
    LET v_max = DATETIME(9999-12-30 00:00:00.00000) YEAR TO FRACTION(5);

    UPDATE subscriptions_audit
    SET sys_end = v_now
    WHERE id = p_id
      AND sys_end = v_max;

    INSERT INTO subscriptions_audit (
        id, user_fp, sku, qty, interval_days, unit_price,
        status, next_bill_at, last_order_id, op, sys_start, sys_end
    ) VALUES (
        p_id, p_user_fp, p_sku, p_qty, p_interval_days, p_unit_price,
        p_status, p_next_bill_at, p_last_order_id, 'U', v_now, v_max
    );
END PROCEDURE@

CREATE TRIGGER trg_subscriptions_ins
    INSERT ON subscriptions
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_subscriptions_ins(
            n.id, n.user_fp, n.sku, n.qty, n.interval_days,
            n.unit_price, n.status, n.next_bill_at, n.last_order_id
        )
    )@

CREATE TRIGGER trg_subscriptions_upd
    UPDATE ON subscriptions
    REFERENCING NEW AS n
    FOR EACH ROW (
        EXECUTE PROCEDURE shop_trg_subscriptions_upd(
            n.id, n.user_fp, n.sku, n.qty, n.interval_days,
            n.unit_price, n.status, n.next_bill_at, n.last_order_id
        )
    )@

CREATE OR REPLACE PROCEDURE shop_sp_list_membership_tiers()
    RETURNING
        VARCHAR(32)  AS code,
        VARCHAR(128) AS name,
        VARCHAR(64)  AS monthly_price,
        VARCHAR(64)  AS discount_pct,
        SMALLINT     AS free_shipping,
        SMALLINT     AS priority_fulfillment,
        SMALLINT     AS active;

    DEFINE v_code   VARCHAR(32);
    DEFINE v_name   VARCHAR(128);
    DEFINE v_price  VARCHAR(64);
    DEFINE v_disc   VARCHAR(64);
    DEFINE v_free   SMALLINT;
    DEFINE v_prio   SMALLINT;
    DEFINE v_active SMALLINT;

    FOREACH
        SELECT code, name, TRIM(TO_CHAR(monthly_price)), TRIM(TO_CHAR(discount_pct)),
               free_shipping, priority_fulfillment, active
        INTO v_code, v_name, v_price, v_disc, v_free, v_prio, v_active
        FROM membership_tiers
        WHERE active = 1
        ORDER BY monthly_price ASC, code ASC

        RETURN v_code, v_name, v_price, v_disc, v_free, v_prio, v_active WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_membership(p_user_fp VARCHAR(128))
    RETURNING
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS tier_code,
        VARCHAR(32)  AS status,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS started_at,
        VARCHAR(64)  AS renews_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_tier_code  VARCHAR(32);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_started_at VARCHAR(64);
    DEFINE v_renews_at  VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    FOREACH
        SELECT user_fp, tier_code, status, stripe_sub_id,
               TO_CHAR(started_at, '%Y-%m-%d %H:%M:%S.%F5'),
               renews_at,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_user_fp, v_tier_code, v_status, v_stripe_sub,
             v_started_at, v_renews_at, v_updated_at
        FROM memberships
        WHERE user_fp = p_user_fp

        RETURN v_user_fp, v_tier_code, v_status, v_stripe_sub,
               v_started_at, v_renews_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_upsert_membership(
    p_user_fp       VARCHAR(128),
    p_tier_code     VARCHAR(32),
    p_status        VARCHAR(32),
    p_stripe_sub_id VARCHAR(128),
    p_renews_at     VARCHAR(64)
)
    RETURNING
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS tier_code,
        VARCHAR(32)  AS status,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS started_at,
        VARCHAR(64)  AS renews_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_tier_code  VARCHAR(32);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_started_at VARCHAR(64);
    DEFINE v_renews_at  VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    MERGE INTO memberships AS t
    USING (
        SELECT
            p_user_fp       AS user_fp,
            p_tier_code     AS tier_code,
            p_status        AS status,
            p_stripe_sub_id AS stripe_sub_id,
            p_renews_at     AS renews_at
        FROM sysmaster:sysdual
    ) AS s
    ON t.user_fp = s.user_fp
    WHEN MATCHED THEN
        UPDATE SET
            t.tier_code     = NVL(s.tier_code, t.tier_code),
            t.status        = NVL(s.status, t.status),
            t.stripe_sub_id = NVL(s.stripe_sub_id, t.stripe_sub_id),
            t.renews_at     = NVL(s.renews_at, t.renews_at),
            t.updated_at    = CURRENT YEAR TO FRACTION(5)
    WHEN NOT MATCHED THEN
        INSERT (user_fp, tier_code, status, stripe_sub_id, renews_at)
        VALUES (
            s.user_fp,
            NVL(s.tier_code, 'FREE'),
            NVL(s.status, 'ACTIVE'),
            NVL(s.stripe_sub_id, ''),
            NVL(s.renews_at, '')
        );

    FOREACH
        SELECT user_fp, tier_code, status, stripe_sub_id,
               TO_CHAR(started_at, '%Y-%m-%d %H:%M:%S.%F5'),
               renews_at,
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_user_fp, v_tier_code, v_status, v_stripe_sub,
             v_started_at, v_renews_at, v_updated_at
        FROM memberships
        WHERE user_fp = p_user_fp

        RETURN v_user_fp, v_tier_code, v_status, v_stripe_sub,
               v_started_at, v_renews_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_create_subscription(
    p_id            VARCHAR(64),
    p_user_fp       VARCHAR(128),
    p_sku           VARCHAR(32),
    p_qty           INTEGER,
    p_interval_days INTEGER,
    p_unit_price    VARCHAR(64),
    p_next_bill_at  VARCHAR(64),
    p_stripe_sub_id VARCHAR(128)
)
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS sku,
        INTEGER      AS qty,
        INTEGER      AS interval_days,
        VARCHAR(64)  AS unit_price,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS next_bill_at,
        VARCHAR(64)  AS last_order_id,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS created_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_price_dec   DECIMAL(32,4);
    DEFINE v_id          VARCHAR(64);
    DEFINE v_user_fp     VARCHAR(128);
    DEFINE v_sku         VARCHAR(32);
    DEFINE v_qty         INTEGER;
    DEFINE v_interval    INTEGER;
    DEFINE v_unit_price  VARCHAR(64);
    DEFINE v_status      VARCHAR(32);
    DEFINE v_next_bill   VARCHAR(64);
    DEFINE v_last_ord    VARCHAR(64);
    DEFINE v_stripe_sub  VARCHAR(128);
    DEFINE v_created_at  VARCHAR(64);
    DEFINE v_updated_at  VARCHAR(64);

    IF p_unit_price IS NULL OR p_unit_price = '' THEN
        LET v_price_dec = 0.0000;
    ELSE
        LET v_price_dec = p_unit_price;
    END IF;

    INSERT INTO subscriptions (
        id, user_fp, sku, qty, interval_days, unit_price,
        status, next_bill_at, last_order_id, stripe_sub_id
    ) VALUES (
        p_id, p_user_fp, p_sku, p_qty, p_interval_days, v_price_dec,
        'ACTIVE',
        NVL(p_next_bill_at, ''),
        '',
        NVL(p_stripe_sub_id, '')
    );

    FOREACH
        SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
               status, next_bill_at, last_order_id, stripe_sub_id,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
             v_status, v_next_bill, v_last_ord, v_stripe_sub,
             v_created_at, v_updated_at
        FROM subscriptions
        WHERE id = p_id

        RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
               v_status, v_next_bill, v_last_ord, v_stripe_sub,
               v_created_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_list_subscriptions(p_user_fp VARCHAR(128))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS sku,
        INTEGER      AS qty,
        INTEGER      AS interval_days,
        VARCHAR(64)  AS unit_price,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS next_bill_at,
        VARCHAR(64)  AS last_order_id,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS created_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_qty        INTEGER;
    DEFINE v_interval   INTEGER;
    DEFINE v_unit_price VARCHAR(64);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_next_bill  VARCHAR(64);
    DEFINE v_last_ord   VARCHAR(64);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_created_at VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    IF p_user_fp IS NULL OR p_user_fp = '' THEN
        FOREACH
            SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
                   status, next_bill_at, last_order_id, stripe_sub_id,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
                   TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
                 v_status, v_next_bill, v_last_ord, v_stripe_sub,
                 v_created_at, v_updated_at
            FROM subscriptions
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
                   v_status, v_next_bill, v_last_ord, v_stripe_sub,
                   v_created_at, v_updated_at WITH RESUME;
        END FOREACH;
    ELSE
        FOREACH
            SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
                   status, next_bill_at, last_order_id, stripe_sub_id,
                   TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
                   TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
            INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
                 v_status, v_next_bill, v_last_ord, v_stripe_sub,
                 v_created_at, v_updated_at
            FROM subscriptions
            WHERE user_fp = p_user_fp
            ORDER BY created_at DESC, id DESC

            RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
                   v_status, v_next_bill, v_last_ord, v_stripe_sub,
                   v_created_at, v_updated_at WITH RESUME;
        END FOREACH;
    END IF;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_get_subscription(p_id VARCHAR(64))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS sku,
        INTEGER      AS qty,
        INTEGER      AS interval_days,
        VARCHAR(64)  AS unit_price,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS next_bill_at,
        VARCHAR(64)  AS last_order_id,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS created_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_qty        INTEGER;
    DEFINE v_interval   INTEGER;
    DEFINE v_unit_price VARCHAR(64);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_next_bill  VARCHAR(64);
    DEFINE v_last_ord   VARCHAR(64);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_created_at VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    FOREACH
        SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
               status, next_bill_at, last_order_id, stripe_sub_id,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
             v_status, v_next_bill, v_last_ord, v_stripe_sub,
             v_created_at, v_updated_at
        FROM subscriptions
        WHERE id = p_id

        RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
               v_status, v_next_bill, v_last_ord, v_stripe_sub,
               v_created_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_update_subscription(
    p_id            VARCHAR(64),
    p_status        VARCHAR(32),
    p_next_bill_at  VARCHAR(64),
    p_last_order_id VARCHAR(64)
)
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS sku,
        INTEGER      AS qty,
        INTEGER      AS interval_days,
        VARCHAR(64)  AS unit_price,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS next_bill_at,
        VARCHAR(64)  AS last_order_id,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS created_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_id         VARCHAR(64);
    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_qty        INTEGER;
    DEFINE v_interval   INTEGER;
    DEFINE v_unit_price VARCHAR(64);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_next_bill  VARCHAR(64);
    DEFINE v_last_ord   VARCHAR(64);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_created_at VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    UPDATE subscriptions
    SET status        = NVL(p_status, status),
        next_bill_at  = NVL(p_next_bill_at, next_bill_at),
        last_order_id = NVL(p_last_order_id, last_order_id),
        updated_at    = CURRENT YEAR TO FRACTION(5)
    WHERE id = p_id;

    FOREACH
        SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
               status, next_bill_at, last_order_id, stripe_sub_id,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
             v_status, v_next_bill, v_last_ord, v_stripe_sub,
             v_created_at, v_updated_at
        FROM subscriptions
        WHERE id = p_id

        RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
               v_status, v_next_bill, v_last_ord, v_stripe_sub,
               v_created_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_due_subscriptions(p_as_of_ts VARCHAR(64))
    RETURNING
        VARCHAR(64)  AS id,
        VARCHAR(128) AS user_fp,
        VARCHAR(32)  AS sku,
        INTEGER      AS qty,
        INTEGER      AS interval_days,
        VARCHAR(64)  AS unit_price,
        VARCHAR(32)  AS status,
        VARCHAR(64)  AS next_bill_at,
        VARCHAR(64)  AS last_order_id,
        VARCHAR(128) AS stripe_sub_id,
        VARCHAR(64)  AS created_at,
        VARCHAR(64)  AS updated_at;

    DEFINE v_as_of      VARCHAR(64);
    DEFINE v_id         VARCHAR(64);
    DEFINE v_user_fp    VARCHAR(128);
    DEFINE v_sku        VARCHAR(32);
    DEFINE v_qty        INTEGER;
    DEFINE v_interval   INTEGER;
    DEFINE v_unit_price VARCHAR(64);
    DEFINE v_status     VARCHAR(32);
    DEFINE v_next_bill  VARCHAR(64);
    DEFINE v_last_ord   VARCHAR(64);
    DEFINE v_stripe_sub VARCHAR(128);
    DEFINE v_created_at VARCHAR(64);
    DEFINE v_updated_at VARCHAR(64);

    IF p_as_of_ts IS NULL OR p_as_of_ts = '' THEN
        LET v_as_of = TO_CHAR(CURRENT YEAR TO SECOND, '%Y-%m-%d %H:%M:%S');
    ELSE
        LET v_as_of = p_as_of_ts;
    END IF;

    FOREACH
        SELECT id, user_fp, sku, qty, interval_days, TRIM(TO_CHAR(unit_price)),
               status, next_bill_at, last_order_id, stripe_sub_id,
               TO_CHAR(created_at, '%Y-%m-%d %H:%M:%S.%F5'),
               TO_CHAR(updated_at, '%Y-%m-%d %H:%M:%S.%F5')
        INTO v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
             v_status, v_next_bill, v_last_ord, v_stripe_sub,
             v_created_at, v_updated_at
        FROM subscriptions
        WHERE UPPER(status) = 'ACTIVE'
          AND next_bill_at <> ''
          AND next_bill_at <= v_as_of
        ORDER BY next_bill_at ASC, id ASC

        RETURN v_id, v_user_fp, v_sku, v_qty, v_interval, v_unit_price,
               v_status, v_next_bill, v_last_ord, v_stripe_sub,
               v_created_at, v_updated_at WITH RESUME;
    END FOREACH;
END PROCEDURE@

CREATE OR REPLACE PROCEDURE shop_sp_subscription_metrics()
    RETURNING
        INTEGER     AS active_members,
        INTEGER     AS active_subscriptions,
        VARCHAR(64) AS membership_mrr,
        VARCHAR(64) AS subscription_mrr;

    DEFINE v_active_members INTEGER;
    DEFINE v_active_subs    INTEGER;
    DEFINE v_mem_mrr        DECIMAL(32,4);
    DEFINE v_sub_mrr        DECIMAL(32,4);

    SELECT COUNT(*), NVL(SUM(mt.monthly_price), 0.0000)
    INTO v_active_members, v_mem_mrr
    FROM memberships m
    JOIN membership_tiers mt ON UPPER(mt.code) = UPPER(m.tier_code)
    WHERE UPPER(m.status) = 'ACTIVE'
      AND UPPER(m.tier_code) <> 'FREE';

    SELECT COUNT(*), NVL(SUM((unit_price * qty * 30.0000) / interval_days), 0.0000)
    INTO v_active_subs, v_sub_mrr
    FROM subscriptions
    WHERE UPPER(status) = 'ACTIVE';

    RETURN v_active_members, v_active_subs,
           TRIM(TO_CHAR(v_mem_mrr)), TRIM(TO_CHAR(v_sub_mrr)) WITH RESUME;
END PROCEDURE@
