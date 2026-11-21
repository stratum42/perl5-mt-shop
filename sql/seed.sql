-- Seed data for perl5-mt-shop (compatible with IBM Db2 and SQLite)
-- 12 terminal/systems/retro-computing products + 2 promo codes

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('VT-220', 'DEC VT220 Amber Phosphor Terminal', 'Terminals',
 'Refurbished amber CRT serial terminal with crisp 80/132-col mode and LK201 tactile keyboard.',
 '  +------------------+
  | >_ LOGIN: root   |
  | AMBER CRT 80x24  |
  | [DEC VT220]      |
  +------------------+
   /================\ ',
 429.0000, 6, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('KB-M01', 'IBM Model M Buckling Spring 101', 'Keyboards',
 '1989 bolt-modded buckling spring mechanical keyboard with detachable SDL-to-USB-C cable.',
 ' +--------------------+
 | [ESC][F1][F2] [IBM]|
 | [Q][W][E][R][T][Y] |
 | [   SPACEBAR     ] |
 +--------------------+',
 189.5000, 14, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('KB-HHK', 'Topre 60% Electrostatic Split', 'Keyboards',
 'Compact 60% Unix-layout capacitive keyboard with Control on Caps Lock and PBT keycaps.',
 ' +------------------+
 | [~][1][2][3][BS] |
 | [CTRL][A][S][D]  |
 |   [   SPACE  ]   |
 +------------------+',
 249.9900, 9, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('SW-001', 'Perl5-MT Camel Concurrency Tee', 'Apparel',
 'Heavyweight 240gsm ring-spun cotton tee featuring the lock-free MT::Cell & Fiber diagram.',
 '   ___    ___
  /   \__/   \
 /  MT::Cell  \
 |  LOCK-FREE |
 |   PERL5-MT |
 \____________/',
 32.0000, 45, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('HW-YBK', 'Ed25519 Hardware SSH Token', 'Security',
 'FIDO2/PIV USB-C hardware security key for resident Ed25519-SK SSH authentication.',
 '   +----------+
   | [o] ED25 |
   |  519-SK  |===+
   |  FIDO2   |===+
   +----------+',
 64.9500, 25, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('BK-KRN', 'Systems Programming in C & POSIX', 'Books',
 'Hardcover reference covering syscalls, kqueue/epoll, lock-free atomics, and ELF/Mach-O.',
 '  +--------------+
  | /  SYSTEMS  /|
  |   C & POSIX  |
  |  2nd Edition |
  |______________|',
 54.0000, 18, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('BK-PLM', 'Mastering Perl5-MT Internals', 'Books',
 'Reference on arenas, MT::Image::freeze, Tier-1 thread-safe XS, and IEEE decimal128.',
 '  +--------------+
  | / PERL5-MT  /|
  |  INTERNALS   |
  |  DEC128 & XS |
  |______________|',
 48.5000, 22, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('HW-RISC', 'RISC-V 64-bit Pocket Dev Board', 'Hardware',
 'Quad-core RV64GC single-board computer with 8GB LPDDR4, GbE, and UART console header.',
 '  +--------------+
  | [RV64GC] 8GB |
  | :::: UART    |
  | [GbE] [USB-C]|
  +--------------+',
 89.0000, 12, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('HW-DBG', 'USB-C Logic Analyzer 16-Ch', 'Hardware',
 '100MS/s 16-channel protocol analyzer for SPI, I2C, UART, and CAN bus debugging.',
 '  +--------------+
  | _|-|_|--|_   |
  | 16CH 100MS/s |
  | [||||||||||] |
  +--------------+',
 74.5000, 15, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('AC-MUG', 'Enamel 0xDEADBEEF Camp Mug', 'Accessories',
 'Speckled black steel enamel mug printed with hexadecimal core-dump coordinates.',
 '   .--------.
  | 0xDEAD   |--.
  |  BEEF    |  |
  |  COFFEE  |--''
   `--------''',
 19.9500, 50, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('AC-STK', 'Retro Unix Sticker Pack (12x)', 'Accessories',
 'Die-cut matte vinyl stickers: Plan 9, AIX, SunOS, BSD Daemon, VT100, and Perl5-MT.',
 '  /------------\
 | [BSD] [AIX]  |
 | [P9] [VT100] |
  \------------/',
 12.5000, 80, 1);

INSERT INTO products (sku, name, category, description, ascii_art, price, stock, active) VALUES
('NW-SER', 'RS-232 to USB-C Null Modem Kit', 'Hardware',
 'FTDI FT232RL industrial serial console kit with DB9, DB25, and RJ45 Cisco rollovers.',
 '  [DB9]====+
           |==[FTDI]==[USB-C]
  [RJ45]===+',
 28.7500, 30, 1);

INSERT INTO promo_codes (code, kind, value, min_subtotal, active) VALUES
('PERLMT20', 'percent', 20.0000, 0.0000, 1);

INSERT INTO promo_codes (code, kind, value, min_subtotal, active) VALUES
('SSH10', 'fixed', 10.0000, 50.0000, 1);

-- 3 Fulfillment Warehouse Hubs
INSERT INTO warehouses (code, name, city, state, postal_code, active) VALUES
('DAL1', 'Dallas Central Hub', 'Dallas', 'TX', '75201', 1);

INSERT INTO warehouses (code, name, city, state, postal_code, active) VALUES
('NYC1', 'Newark East Hub', 'Newark', 'NJ', '07102', 1);

INSERT INTO warehouses (code, name, city, state, postal_code, active) VALUES
('SFO1', 'Oakland West Hub', 'Oakland', 'CA', '94607', 1);

-- Initial Warehouse Stock Split (sums match products.stock)
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'VT-220', 2, 'A1-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'VT-220', 2, 'B1-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'VT-220', 2, 'C1-01');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'KB-M01', 5, 'A1-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'KB-M01', 5, 'B1-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'KB-M01', 4, 'C1-02');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'KB-HHK', 3, 'A1-03');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'KB-HHK', 3, 'B1-03');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'KB-HHK', 3, 'C1-03');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'SW-001', 15, 'A2-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'SW-001', 15, 'B2-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'SW-001', 15, 'C2-01');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'HW-YBK', 9, 'A2-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'HW-YBK', 8, 'B2-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'HW-YBK', 8, 'C2-02');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'BK-KRN', 6, 'A3-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'BK-KRN', 6, 'B3-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'BK-KRN', 6, 'C3-01');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'BK-PLM', 8, 'A3-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'BK-PLM', 7, 'B3-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'BK-PLM', 7, 'C3-02');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'HW-RISC', 4, 'A4-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'HW-RISC', 4, 'B4-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'HW-RISC', 4, 'C4-01');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'HW-DBG', 5, 'A4-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'HW-DBG', 5, 'B4-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'HW-DBG', 5, 'C4-02');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'AC-MUG', 17, 'A5-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'AC-MUG', 17, 'B5-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'AC-MUG', 16, 'C5-01');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'AC-STK', 27, 'A5-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'AC-STK', 27, 'B5-02');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'AC-STK', 26, 'C5-02');

INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('DAL1', 'NW-SER', 10, 'A6-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('NYC1', 'NW-SER', 10, 'B6-01');
INSERT INTO warehouse_stock (warehouse_code, sku, qty, bin_location) VALUES ('SFO1', 'NW-SER', 10, 'C6-01');

-- 2 Open Sample Inbound Purchase Orders
INSERT INTO purchase_orders (id, supplier, warehouse_code, status, total_cost) VALUES
('PO-2026-001', 'DEC Vintage Supply Co.', 'DAL1', 'OPEN', 6550.0000);

INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-001-01', 'PO-2026-001', 'VT-220', 10, 0, 260.0000);
INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-001-02', 'PO-2026-001', 'KB-M01', 20, 0, 115.0000);
INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-001-03', 'PO-2026-001', 'HW-RISC', 30, 0, 55.0000);

INSERT INTO purchase_orders (id, supplier, warehouse_code, status, total_cost) VALUES
('PO-2026-002', 'Silicon Foundry Logistics', 'NYC1', 'PARTIAL', 2485.0000);

INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-002-01', 'PO-2026-002', 'HW-YBK', 30, 10, 39.5000);
INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-002-02', 'PO-2026-002', 'HW-DBG', 20, 0, 45.0000);
INSERT INTO po_lines (id, po_id, sku, qty_ordered, qty_received, unit_cost) VALUES
('PO-2026-002-03', 'PO-2026-002', 'SW-001', 25, 5, 16.0000);

-- 6 State Tax Nexus Rules (3 registered, 3 economic-nexus monitored)
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('TX', 0.0825,  500000.0000,   0, 1);
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('CA', 0.0825,  500000.0000,   0, 1);
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('NY', 0.08875, 500000.0000, 100, 1);
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('WA', 0.0650,  100000.0000,   0, 0);
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('FL', 0.0600,  100000.0000,   0, 0);
INSERT INTO tax_nexus (state, rate, threshold_sales, threshold_txns, registered) VALUES ('IL', 0.0625,  100000.0000, 200, 0);

-- 3 Membership Tiers
INSERT INTO membership_tiers (code, name, monthly_price, discount_pct, free_shipping, priority_fulfillment, active) VALUES
('FREE',    'Standard',   0.00,  0.00, 0, 0, 1);
INSERT INTO membership_tiers (code, name, monthly_price, discount_pct, free_shipping, priority_fulfillment, active) VALUES
('PRO',     'Pro Member', 9.99, 10.00, 1, 1, 1);
INSERT INTO membership_tiers (code, name, monthly_price, discount_pct, free_shipping, priority_fulfillment, active) VALUES
('FOUNDER', 'Founder',   24.99, 20.00, 1, 1, 1);
