--#SET TERMINATOR @
-- IBM Db2 Static SQL PL Stored Procedures for perl5-mt-shop (SP_ONLY lockdown)
-- 100% static compiled SQL inside every procedure (ZERO PREPARE / EXECUTE IMMEDIATE).

CREATE OR REPLACE PROCEDURE SHOP_SP_CURRENT_TIMESTAMP()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT VARCHAR(CURRENT TIMESTAMP(12)) AS ts
        FROM SYSIBM.SYSDUMMY1;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_PRODUCTS()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, category, description, ascii_art, price, stock, active
        FROM products
        WHERE active = 1
        ORDER BY sku;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_PRODUCT(
    IN p_sku VARCHAR(32)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, category, description, ascii_art, price, stock, active
        FROM products
        WHERE sku = p_sku;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPSERT_PRODUCT(
    IN p_sku         VARCHAR(32),
    IN p_name        VARCHAR(128),
    IN p_category    VARCHAR(64),
    IN p_description VARCHAR(1024),
    IN p_ascii_art   VARCHAR(2048),
    IN p_price       DECFLOAT(34),
    IN p_stock       INTEGER,
    IN p_active      SMALLINT
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 0
BEGIN
    MERGE INTO products AS t
    USING (
        VALUES (p_sku, p_name, p_category, p_description, p_ascii_art, p_price, p_stock, p_active)
    ) AS s (sku, name, category, description, ascii_art, price, stock, active)
    ON t.sku = s.sku
    WHEN MATCHED THEN
        UPDATE SET
            name        = COALESCE(s.name, t.name),
            category    = COALESCE(s.category, t.category),
            description = COALESCE(s.description, t.description),
            ascii_art   = COALESCE(s.ascii_art, t.ascii_art),
            price       = COALESCE(s.price, t.price),
            stock       = COALESCE(s.stock, t.stock),
            active      = COALESCE(s.active, t.active),
            updated_at  = CURRENT TIMESTAMP
    WHEN NOT MATCHED THEN
        INSERT (sku, name, category, description, ascii_art, price, stock, active)
        VALUES (
            s.sku,
            COALESCE(s.name, s.sku),
            COALESCE(s.category, 'General'),
            COALESCE(s.description, ''),
            COALESCE(s.ascii_art, ''),
            COALESCE(s.price, CAST(0 AS DECFLOAT(34))),
            COALESCE(s.stock, 0),
            COALESCE(s.active, 1)
        );
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_DECREMENT_STOCK(
    IN p_sku VARCHAR(32),
    IN p_qty INTEGER
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, price, stock, updated_at
        FROM FINAL TABLE (
            UPDATE products
            SET stock = stock - p_qty,
                updated_at = CURRENT TIMESTAMP
            WHERE sku = p_sku
              AND stock >= p_qty
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPDATE_PRODUCT_STOCK(
    IN p_sku   VARCHAR(32),
    IN p_stock INTEGER
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, price, stock, updated_at
        FROM FINAL TABLE (
            UPDATE products
            SET stock = p_stock,
                updated_at = CURRENT TIMESTAMP
            WHERE sku = p_sku
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_PROMO(
    IN p_code VARCHAR(32)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT code, kind, value, min_subtotal, active
        FROM promo_codes
        WHERE UPPER(code) = UPPER(p_code)
          AND active = 1;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_USER(
    IN p_fp VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4, created_at
        FROM users
        WHERE fingerprint = p_fp;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPSERT_USER(
    IN p_fp          VARCHAR(128),
    IN p_username    VARCHAR(64),
    IN p_email       VARCHAR(128),
    IN p_pubkey_type VARCHAR(64),
    IN p_is_admin    SMALLINT,
    IN p_stripe_cust VARCHAR(128),
    IN p_pm_id       VARCHAR(128),
    IN p_pm_last4    VARCHAR(8)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4, created_at
        FROM users
        WHERE fingerprint = p_fp;

    MERGE INTO users AS t
    USING (
        VALUES (p_fp, p_username, p_email, p_pubkey_type, p_is_admin, p_stripe_cust, p_pm_id, p_pm_last4)
    ) AS s (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4)
    ON t.fingerprint = s.fingerprint
    WHEN MATCHED THEN
        UPDATE SET
            username               = COALESCE(s.username, t.username),
            email                  = COALESCE(s.email, t.email),
            pubkey_type            = COALESCE(s.pubkey_type, t.pubkey_type),
            is_admin               = COALESCE(s.is_admin, t.is_admin),
            stripe_customer_id     = COALESCE(s.stripe_customer_id, t.stripe_customer_id),
            default_payment_method = COALESCE(s.default_payment_method, t.default_payment_method),
            default_payment_last4  = COALESCE(s.default_payment_last4, t.default_payment_last4)
    WHEN NOT MATCHED THEN
        INSERT (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4)
        VALUES (
            s.fingerprint,
            COALESCE(s.username, 'guest'),
            COALESCE(s.email, ''),
            COALESCE(s.pubkey_type, ''),
            COALESCE(s.is_admin, 0),
            COALESCE(s.stripe_customer_id, ''),
            COALESCE(s.default_payment_method, ''),
            COALESCE(s.default_payment_last4, '')
        );

    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_SAVE_PAYMENT_METHOD(
    IN p_fp          VARCHAR(128),
    IN p_pm_id       VARCHAR(128),
    IN p_pm_last4    VARCHAR(8),
    IN p_stripe_cust VARCHAR(128)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT fingerprint, username, email, pubkey_type, is_admin,
               stripe_customer_id, default_payment_method, default_payment_last4, created_at
        FROM users
        WHERE fingerprint = p_fp;

    MERGE INTO users AS t
    USING (
        VALUES (p_fp, p_pm_id, p_pm_last4, p_stripe_cust)
    ) AS s (fingerprint, default_payment_method, default_payment_last4, stripe_customer_id)
    ON t.fingerprint = s.fingerprint
    WHEN MATCHED THEN
        UPDATE SET
            default_payment_method = COALESCE(s.default_payment_method, ''),
            default_payment_last4  = COALESCE(s.default_payment_last4, ''),
            stripe_customer_id     = COALESCE(s.stripe_customer_id, t.stripe_customer_id)
    WHEN NOT MATCHED THEN
        INSERT (fingerprint, username, email, pubkey_type, is_admin, stripe_customer_id, default_payment_method, default_payment_last4)
        VALUES (
            s.fingerprint,
            'guest',
            '',
            '',
            0,
            COALESCE(s.stripe_customer_id, ''),
            COALESCE(s.default_payment_method, ''),
            COALESCE(s.default_payment_last4, '')
        );

    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_ADDRESSES(
    IN p_user_fp VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default
        FROM addresses
        WHERE user_fp = p_user_fp
        ORDER BY is_default DESC, id ASC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_SAVE_ADDRESS(
    IN p_id          VARCHAR(64),
    IN p_user_fp     VARCHAR(128),
    IN p_label       VARCHAR(64),
    IN p_recipient   VARCHAR(128),
    IN p_line1       VARCHAR(255),
    IN p_line2       VARCHAR(255),
    IN p_city        VARCHAR(128),
    IN p_state       VARCHAR(64),
    IN p_postal_code VARCHAR(32),
    IN p_country     VARCHAR(8),
    IN p_is_default  SMALLINT
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default
        FROM addresses
        WHERE id = p_id;

    MERGE INTO addresses AS t
    USING (
        VALUES (p_id, p_user_fp, p_label, p_recipient, p_line1, p_line2, p_city, p_state, p_postal_code, p_country, p_is_default)
    ) AS s (id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default)
    ON t.id = s.id AND t.user_fp = s.user_fp
    WHEN MATCHED THEN
        UPDATE SET
            label       = s.label,
            recipient   = s.recipient,
            line1       = s.line1,
            line2       = s.line2,
            city        = s.city,
            state       = s.state,
            postal_code = s.postal_code,
            country     = s.country,
            is_default  = s.is_default
    WHEN NOT MATCHED THEN
        INSERT (id, user_fp, label, recipient, line1, line2, city, state, postal_code, country, is_default)
        VALUES (s.id, s.user_fp, s.label, s.recipient, s.line1, s.line2, s.city, s.state, s.postal_code, s.country, s.is_default);

    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_DELETE_ADDRESS(
    IN p_id      VARCHAR(64),
    IN p_user_fp VARCHAR(128)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 0
BEGIN
    DELETE FROM addresses
    WHERE id = p_id
      AND user_fp = p_user_fp;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_CREATE_ORDER(
    IN p_id               VARCHAR(64),
    IN p_user_fp          VARCHAR(128),
    IN p_username         VARCHAR(64),
    IN p_status           VARCHAR(32),
    IN p_subtotal         DECFLOAT(34),
    IN p_discount         DECFLOAT(34),
    IN p_tax              DECFLOAT(34),
    IN p_shipping         DECFLOAT(34),
    IN p_total            DECFLOAT(34),
    IN p_promo_code       VARCHAR(32),
    IN p_payment_method   VARCHAR(32),
    IN p_payment_ref      VARCHAR(128),
    IN p_shipping_address VARCHAR(1024),
    IN p_receipt_sig      VARCHAR(256),
    IN p_receipt_hash     VARCHAR(128)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 0
BEGIN
    INSERT INTO orders (
        id, user_fp, username, status, subtotal, discount, tax, shipping, total,
        promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash
    ) VALUES (
        p_id, p_user_fp, p_username, p_status, p_subtotal, p_discount, p_tax, p_shipping, p_total,
        p_promo_code, p_payment_method, p_payment_ref, p_shipping_address, p_receipt_sig, p_receipt_hash
    );
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_ADD_ORDER_ITEM(
    IN p_id         VARCHAR(64),
    IN p_order_id   VARCHAR(64),
    IN p_sku        VARCHAR(32),
    IN p_name       VARCHAR(128),
    IN p_qty        INTEGER,
    IN p_unit_price DECFLOAT(34),
    IN p_line_total DECFLOAT(34)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 0
BEGIN
    INSERT INTO order_items (id, order_id, sku, name, qty, unit_price, line_total)
    VALUES (p_id, p_order_id, p_sku, p_name, p_qty, p_unit_price, p_line_total);
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_ORDERS(
    IN p_user_fp VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur_all CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total,
               promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash, created_at
        FROM orders
        ORDER BY created_at DESC, id DESC;

    DECLARE cur_user CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total,
               promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash, created_at
        FROM orders
        WHERE user_fp = p_user_fp
        ORDER BY created_at DESC, id DESC;

    IF p_user_fp IS NULL OR p_user_fp = '' THEN
        OPEN cur_all;
    ELSE
        OPEN cur_user;
    END IF;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_ORDERS_MASKED(
    IN p_user_fp VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur_all CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total,
               promo_code, payment_method, payment_ref, shipping_address, receipt_hash, created_at
        FROM v_orders_masked
        ORDER BY created_at DESC, id DESC;

    DECLARE cur_user CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total,
               promo_code, payment_method, payment_ref, shipping_address, receipt_hash, created_at
        FROM v_orders_masked
        WHERE user_fp = p_user_fp
        ORDER BY created_at DESC, id DESC;

    IF p_user_fp IS NULL OR p_user_fp = '' THEN
        OPEN cur_all;
    ELSE
        OPEN cur_user;
    END IF;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_ORDER(
    IN p_order_id VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, user_fp, username, status, subtotal, discount, tax, shipping, total,
               promo_code, payment_method, payment_ref, shipping_address, receipt_sig, receipt_hash, created_at
        FROM orders
        WHERE id = p_order_id;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_ORDER_ITEMS(
    IN p_order_id VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, sku, name, qty, unit_price, line_total
        FROM order_items
        WHERE order_id = p_order_id
        ORDER BY id ASC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_ORDER_BY_REF(
    IN p_payment_ref VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id
        FROM orders
        WHERE payment_ref = p_payment_ref
        ORDER BY created_at DESC
        FETCH FIRST 1 ROWS ONLY;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPDATE_ORDER_STATUS(
    IN p_order_id VARCHAR(64),
    IN p_status   VARCHAR(32)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, status, total, payment_ref
        FROM FINAL TABLE (
            UPDATE orders
            SET status = p_status
            WHERE id = p_order_id
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPDATE_ORDER_RECEIPT(
    IN p_order_id     VARCHAR(64),
    IN p_receipt_hash VARCHAR(128),
    IN p_receipt_sig  VARCHAR(256)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 0
BEGIN
    UPDATE orders
    SET receipt_hash = p_receipt_hash,
        receipt_sig  = p_receipt_sig
    WHERE id = p_order_id;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GMV_SUMMARY()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT COUNT(*) AS order_count,
               COALESCE(SUM(total), CAST(0 AS DECFLOAT(34))) AS total_gmv
        FROM orders
        WHERE LOWER(status) <> 'cancelled';
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_PRODUCT_HISTORY(
    IN p_sku   VARCHAR(32),
    IN p_limit INTEGER
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE v_limit INTEGER DEFAULT 20;
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, price, stock,
               VARCHAR(sys_start) AS sys_start,
               VARCHAR(sys_end)   AS sys_end
        FROM products FOR SYSTEM_TIME FROM '0001-01-01-00.00.00.000000000000' TO '9999-12-31-23.59.59.999999999999'
        WHERE sku = p_sku
        ORDER BY sys_start DESC
        FETCH FIRST v_limit ROWS ONLY;

    IF p_limit IS NOT NULL AND p_limit > 0 THEN
        SET v_limit = p_limit;
    END IF;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_CATALOG_AS_OF(
    IN p_ts VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE v_ts TIMESTAMP(12);
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT sku, name, category, price, stock
        FROM products FOR SYSTEM_TIME AS OF v_ts
        ORDER BY sku;

    SET v_ts = CAST(p_ts AS TIMESTAMP(12));
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_ORDER_HISTORY(
    IN p_order_id VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, status, total, payment_ref,
               VARCHAR(sys_start) AS sys_start,
               VARCHAR(sys_end)   AS sys_end
        FROM orders FOR SYSTEM_TIME FROM '0001-01-01-00.00.00.000000000000' TO '9999-12-31-23.59.59.999999999999'
        WHERE id = p_order_id
        ORDER BY sys_start DESC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_CATEGORY_OLAP()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT category, order_count, units_sold, revenue, share_pct, rank
        FROM v_category_olap
        ORDER BY is_total ASC, rank ASC, category ASC;
    OPEN cur;
END@

-- =========================================================================
-- Logistics, Warehouses, Purchase Orders, Shipments, and Tax Nexus (SP_ONLY)
-- =========================================================================

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_WAREHOUSES()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT code, name, city, state, postal_code, active
        FROM warehouses
        WHERE active = 1
        ORDER BY code ASC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_WAREHOUSE_STOCK(
    IN p_wh_code VARCHAR(16)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur_all CURSOR WITH RETURN TO CLIENT FOR
        SELECT warehouse_code, sku, qty, bin_location
        FROM warehouse_stock
        ORDER BY warehouse_code ASC, sku ASC;
    DECLARE cur_one CURSOR WITH RETURN TO CLIENT FOR
        SELECT warehouse_code, sku, qty, bin_location
        FROM warehouse_stock
        WHERE warehouse_code = p_wh_code
        ORDER BY sku ASC;

    IF p_wh_code IS NULL OR p_wh_code = '' THEN
        OPEN cur_all;
    ELSE
        OPEN cur_one;
    END IF;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_CREATE_PO(
    IN p_id         VARCHAR(64),
    IN p_supplier   VARCHAR(128),
    IN p_wh_code    VARCHAR(16),
    IN p_total_cost DECFLOAT(34)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, supplier, warehouse_code, status, total_cost,
               VARCHAR(created_at) AS created_at
        FROM FINAL TABLE (
            INSERT INTO purchase_orders (id, supplier, warehouse_code, status, total_cost)
            VALUES (p_id, p_supplier, p_wh_code, 'OPEN', p_total_cost)
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_ADD_PO_LINE(
    IN p_id        VARCHAR(64),
    IN p_po_id     VARCHAR(64),
    IN p_sku       VARCHAR(32),
    IN p_qty_ord   INTEGER,
    IN p_unit_cost DECFLOAT(34)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, po_id, sku, qty_ordered, qty_received, unit_cost
        FROM FINAL TABLE (
            INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost)
            VALUES (p_id, p_po_id, p_sku, p_qty_ord, 0, p_unit_cost)
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_POS()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, supplier, warehouse_code, status, total_cost,
               VARCHAR(created_at) AS created_at
        FROM purchase_orders
        ORDER BY created_at DESC, id DESC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_PO_LINES(
    IN p_po_id VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, po_id, sku, qty_ordered, qty_received, unit_cost
        FROM po_lines
        WHERE po_id = p_po_id
        ORDER BY id ASC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_RECEIVE_PO_LINE(
    IN p_po_line_id VARCHAR(64),
    IN p_recv_qty   INTEGER
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE v_po_id      VARCHAR(64) DEFAULT '';
    DECLARE v_wh_code    VARCHAR(16) DEFAULT '';
    DECLARE v_sku        VARCHAR(32) DEFAULT '';
    DECLARE v_new_rcv    INTEGER     DEFAULT 0;
    DECLARE v_new_stock  INTEGER     DEFAULT 0;
    DECLARE v_open_cnt   INTEGER     DEFAULT 0;
    DECLARE v_po_status  VARCHAR(32) DEFAULT 'PARTIAL';
    DECLARE v_not_found  SMALLINT    DEFAULT 0;

    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT v_po_id      AS po_id,
               p_po_line_id AS po_line_id,
               v_wh_code    AS warehouse_code,
               v_sku        AS sku,
               v_new_rcv    AS qty_received,
               v_new_stock  AS new_stock,
               v_po_status  AS po_status
        FROM SYSIBM.SYSDUMMY1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND
        SET v_not_found = 1;

    IF p_recv_qty IS NULL OR p_recv_qty <= 0 THEN
        RETURN;
    END IF;

    SELECT l.po_id, p.warehouse_code, l.sku, l.qty_received
    INTO v_po_id, v_wh_code, v_sku, v_new_rcv
    FROM po_lines l
    JOIN purchase_orders p ON p.id = l.po_id
    WHERE l.id = p_po_line_id;

    IF v_not_found = 1 THEN
        RETURN;
    END IF;

    UPDATE po_lines
    SET qty_received = qty_received + p_recv_qty
    WHERE id = p_po_line_id;

    SET v_new_rcv = v_new_rcv + p_recv_qty;

    MERGE INTO warehouse_stock AS t
    USING (VALUES (v_wh_code, v_sku, p_recv_qty)) AS s (warehouse_code, sku, qty)
    ON t.warehouse_code = s.warehouse_code AND t.sku = s.sku
    WHEN MATCHED THEN
        UPDATE SET qty = t.qty + s.qty
    WHEN NOT MATCHED THEN
        INSERT (warehouse_code, sku, qty, bin_location)
        VALUES (s.warehouse_code, s.sku, s.qty, 'RCV-01');

    UPDATE products
    SET stock = stock + p_recv_qty,
        updated_at = CURRENT TIMESTAMP
    WHERE sku = v_sku;

    SET v_not_found = 0;
    SELECT stock INTO v_new_stock FROM products WHERE sku = v_sku;

    SELECT COUNT(*)
    INTO v_open_cnt
    FROM po_lines
    WHERE po_id = v_po_id
      AND qty_received < qty_ordered;

    IF v_open_cnt = 0 THEN
        SET v_po_status = 'RECEIVED';
    ELSE
        SET v_po_status = 'PARTIAL';
    END IF;

    UPDATE purchase_orders
    SET status = v_po_status
    WHERE id = v_po_id;

    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_CREATE_SHIPMENT(
    IN p_id          VARCHAR(64),
    IN p_order_id    VARCHAR(64),
    IN p_wh_code     VARCHAR(16),
    IN p_carrier     VARCHAR(64),
    IN p_service     VARCHAR(64),
    IN p_rate_amount DECFLOAT(34),
    IN p_tracking    VARCHAR(128),
    IN p_label_url   VARCHAR(512),
    IN p_status      VARCHAR(32)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM FINAL TABLE (
            INSERT INTO shipments (
                id, order_id, warehouse_code, carrier, service, rate_amount,
                tracking_number, label_url, status
            ) VALUES (
                p_id, p_order_id, p_wh_code,
                COALESCE(p_carrier, ''),
                COALESCE(p_service, ''),
                COALESCE(p_rate_amount, CAST(0 AS DECFLOAT(34))),
                COALESCE(p_tracking, ''),
                COALESCE(p_label_url, ''),
                COALESCE(p_status, 'PENDING')
            )
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_UPDATE_SHIPMENT(
    IN p_id        VARCHAR(64),
    IN p_status    VARCHAR(32),
    IN p_tracking  VARCHAR(128),
    IN p_label_url VARCHAR(512)
)
    LANGUAGE SQL
    MODIFIES SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM FINAL TABLE (
            UPDATE shipments
            SET status          = COALESCE(p_status, status),
                tracking_number = COALESCE(p_tracking, tracking_number),
                label_url       = COALESCE(p_label_url, label_url),
                updated_at      = CURRENT TIMESTAMP
            WHERE id = p_id
        );
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_SHIPMENT_BY_ORDER(
    IN p_order_id VARCHAR(64)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM shipments
        WHERE order_id = p_order_id
        ORDER BY updated_at DESC, id DESC
        FETCH FIRST 1 ROW ONLY;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_SHIPMENT_BY_TRACKING(
    IN p_tracking VARCHAR(128)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM shipments
        WHERE tracking_number = p_tracking
        ORDER BY updated_at DESC, id DESC
        FETCH FIRST 1 ROW ONLY;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_SHIPMENTS(
    IN p_status VARCHAR(32)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur_all CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM shipments
        ORDER BY updated_at DESC, id DESC;
    DECLARE cur_filt CURSOR WITH RETURN TO CLIENT FOR
        SELECT id, order_id, warehouse_code, carrier, service, rate_amount,
               tracking_number, label_url, status,
               VARCHAR(updated_at) AS updated_at
        FROM shipments
        WHERE UPPER(status) = UPPER(p_status)
        ORDER BY updated_at DESC, id DESC;

    IF p_status IS NULL OR p_status = '' THEN
        OPEN cur_all;
    ELSE
        OPEN cur_filt;
    END IF;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_GET_TAX_NEXUS(
    IN p_state VARCHAR(8)
)
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT state, rate, threshold_sales, threshold_txns, registered
        FROM tax_nexus
        WHERE UPPER(state) = UPPER(p_state);
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_LIST_TAX_NEXUS()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT state, rate, threshold_sales, threshold_txns, registered
        FROM tax_nexus
        ORDER BY state ASC;
    OPEN cur;
END@

CREATE OR REPLACE PROCEDURE SHOP_SP_TAX_NEXUS_REPORT()
    LANGUAGE SQL
    READS SQL DATA
    DYNAMIC RESULT SETS 1
BEGIN
    DECLARE cur CURSOR WITH RETURN TO CLIENT FOR
        SELECT
            tn.state,
            tn.rate,
            tn.threshold_sales,
            tn.threshold_txns,
            tn.registered,
            CAST(COALESCE(SUM(CAST(o.total AS DECIMAL(31,4))), DECIMAL(0, 31, 4)) AS DECFLOAT(34)) AS ytd_sales,
            COUNT(o.id) AS ytd_txns
        FROM tax_nexus tn
        LEFT JOIN orders o
            ON LOWER(o.status) <> 'cancelled'
           AND (
               UPPER(o.shipping_address) LIKE '%, ' || UPPER(tn.state) || ',%'
            OR UPPER(o.shipping_address) LIKE '%, ' || UPPER(tn.state) || ' %'
            OR UPPER(o.shipping_address) LIKE '% '  || UPPER(tn.state) || ' %'
            OR UPPER(o.shipping_address) LIKE '%, ' || UPPER(tn.state)
           )
        GROUP BY tn.state, tn.rate, tn.threshold_sales, tn.threshold_txns, tn.registered
        ORDER BY tn.state ASC;
    OPEN cur;
END@
