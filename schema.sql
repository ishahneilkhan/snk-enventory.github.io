-- Inventory system schema (PostgreSQL 14+)
-- One core for pharmacy / grocery / restaurant. Quantities are stored in the
-- BASE unit (piece, gram, ml). Prices are per BASE unit; the UI shows per pack.

CREATE TABLE shops (
  id            bigserial PRIMARY KEY,
  name          text NOT NULL,
  business_type text NOT NULL CHECK (business_type IN ('pharmacy','grocery','restaurant')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id            bigserial PRIMARY KEY,
  shop_id       bigint NOT NULL REFERENCES shops(id),
  name          text NOT NULL,
  username      text NOT NULL UNIQUE,
  password_hash text NOT NULL,              -- argon2/bcrypt hash, never plain text
  role          text NOT NULL CHECK (role IN ('owner','salesman')),
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
  id           bigserial PRIMARY KEY,
  shop_id      bigint NOT NULL REFERENCES shops(id),
  name         text NOT NULL,
  generic_name text,                        -- pharmacy: generic; grocery: type
  company      text,
  category     text,
  barcode      text,
  base_unit    text NOT NULL CHECK (base_unit IN ('piece','gram','ml')),
  pack_unit    text NOT NULL DEFAULT 'piece',  -- strip, box, kg, litre, bottle ...
  pack_size    integer NOT NULL DEFAULT 1 CHECK (pack_size > 0), -- base units per pack
  min_stock    numeric(14,3) NOT NULL DEFAULT 0,                 -- in base units
  active       boolean NOT NULL DEFAULT true,
  UNIQUE (shop_id, barcode)
);
CREATE INDEX products_name_idx ON products (shop_id, lower(name));

CREATE TABLE batches (
  id          bigserial PRIMARY KEY,
  product_id  bigint NOT NULL REFERENCES products(id),
  batch_no    text NOT NULL,
  expiry_date date,                         -- NULL = no expiry
  cost_price  numeric(14,4) NOT NULL CHECK (cost_price >= 0),  -- per base unit
  sell_price  numeric(14,4) NOT NULL CHECK (sell_price >= 0),  -- per base unit
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, batch_no, expiry_date)
);

CREATE TABLE suppliers (
  id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id),
  name text NOT NULL, phone text
);
CREATE TABLE customers (
  id bigserial PRIMARY KEY, shop_id bigint NOT NULL REFERENCES shops(id),
  name text NOT NULL, phone text
);

CREATE TABLE purchases (
  id          bigserial PRIMARY KEY,
  shop_id     bigint NOT NULL REFERENCES shops(id),
  supplier_id bigint NOT NULL REFERENCES suppliers(id),
  invoice_no  text,
  total       numeric(14,2) NOT NULL CHECK (total >= 0),
  paid        numeric(14,2) NOT NULL DEFAULT 0 CHECK (paid >= 0),
  created_by  bigint NOT NULL REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE purchase_items (
  id          bigserial PRIMARY KEY,
  purchase_id bigint NOT NULL REFERENCES purchases(id),
  batch_id    bigint NOT NULL REFERENCES batches(id),
  qty         numeric(14,3) NOT NULL CHECK (qty > 0),   -- base units
  unit_cost   numeric(14,4) NOT NULL CHECK (unit_cost >= 0)
);

CREATE TABLE sales (
  id             bigserial PRIMARY KEY,
  shop_id        bigint NOT NULL REFERENCES shops(id),
  client_uuid    uuid NOT NULL UNIQUE,      -- made on the device; makes offline sync safe to retry
  customer_id    bigint REFERENCES customers(id),
  discount       numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  total          numeric(14,2) NOT NULL CHECK (total >= 0),   -- after discount
  paid           numeric(14,2) NOT NULL DEFAULT 0 CHECK (paid >= 0),
  payment_method text NOT NULL CHECK (payment_method IN ('cash','bkash','nagad','card','due')),
  created_by     bigint NOT NULL REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (payment_method <> 'due' OR customer_id IS NOT NULL)
);
CREATE TABLE sale_items (
  id         bigserial PRIMARY KEY,
  sale_id    bigint NOT NULL REFERENCES sales(id),
  product_id bigint NOT NULL REFERENCES products(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),     -- base units
  unit_price numeric(14,4) NOT NULL CHECK (unit_price >= 0),
  unit_cost  numeric(14,4) NOT NULL DEFAULT 0            -- filled from FEFO batches (for profit)
);

-- Later payments only (money collected / paid after the bill was made)
CREATE TABLE payments (
  id         bigserial PRIMARY KEY,
  shop_id    bigint NOT NULL REFERENCES shops(id),
  party_type text NOT NULL CHECK (party_type IN ('customer','supplier')),
  party_id   bigint NOT NULL,
  amount     numeric(14,2) NOT NULL CHECK (amount > 0),
  method     text NOT NULL DEFAULT 'cash',
  created_by bigint NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- STOCK LEDGER: the only source of truth for stock. Never edited, never deleted.
CREATE TABLE stock_movements (
  id         bigserial PRIMARY KEY,
  shop_id    bigint NOT NULL REFERENCES shops(id),
  product_id bigint NOT NULL REFERENCES products(id),
  batch_id   bigint NOT NULL REFERENCES batches(id),
  qty        numeric(14,3) NOT NULL,        -- signed, base units
  kind       text NOT NULL CHECK (kind IN
             ('purchase','sale','sale_return','adjustment','waste','supplier_return')),
  ref_type   text,                          -- 'sale', 'purchase', ...
  ref_id     bigint,
  reason     text,
  user_id    bigint NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (kind IN ('purchase','sale_return') AND qty > 0) OR
    (kind IN ('sale','waste','supplier_return') AND qty < 0) OR
    (kind = 'adjustment' AND qty <> 0)
  )
);
CREATE INDEX sm_batch_idx   ON stock_movements (batch_id);
CREATE INDEX sm_product_idx ON stock_movements (product_id, created_at);

CREATE FUNCTION forbid_change() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only: add a correcting row instead';
END $$ LANGUAGE plpgsql;
CREATE TRIGGER sm_no_update BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

CREATE TABLE audit_log (
  id         bigserial PRIMARY KEY,
  shop_id    bigint REFERENCES shops(id),
  user_id    bigint REFERENCES users(id),
  action     text NOT NULL,
  table_name text,
  row_id     bigint,
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- VIEWS ---------------------------------------------------------------
CREATE VIEW batch_stock AS
  SELECT batch_id, product_id, SUM(qty) AS qty
  FROM stock_movements GROUP BY batch_id, product_id;

CREATE VIEW product_stock AS
  SELECT p.id AS product_id, p.shop_id, p.name, p.min_stock,
         COALESCE(SUM(s.qty) FILTER (WHERE b.expiry_date IS NULL OR b.expiry_date >= current_date), 0) AS sellable_qty,
         COALESCE(SUM(s.qty) FILTER (WHERE b.expiry_date < current_date), 0) AS expired_qty
  FROM products p
  LEFT JOIN batches b ON b.product_id = p.id
  LEFT JOIN batch_stock s ON s.batch_id = b.id
  GROUP BY p.id;

CREATE VIEW customer_balance AS
  SELECT c.id AS customer_id, c.shop_id, c.name,
         COALESCE((SELECT SUM(total - paid) FROM sales WHERE customer_id = c.id), 0)
       - COALESCE((SELECT SUM(amount) FROM payments
                   WHERE party_type = 'customer' AND party_id = c.id), 0) AS due
  FROM customers c;

CREATE VIEW supplier_balance AS
  SELECT s.id AS supplier_id, s.shop_id, s.name,
         COALESCE((SELECT SUM(total - paid) FROM purchases WHERE supplier_id = s.id), 0)
       - COALESCE((SELECT SUM(amount) FROM payments
                   WHERE party_type = 'supplier' AND party_id = s.id), 0) AS due
  FROM suppliers s;

-- FEFO SALE: takes stock from the batch that expires first, skips expired
-- batches, returns the total cost of what was taken (for profit reports).
-- Call it once per sale item, inside the same transaction that inserts the sale.
CREATE FUNCTION sell_fefo(p_sale_id bigint, p_product_id bigint, p_qty numeric, p_user bigint)
RETURNS numeric AS $$
DECLARE
  need numeric := p_qty;
  take numeric;
  cost_total numeric := 0;
  v_shop bigint;
  r record;
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'quantity must be positive'; END IF;
  SELECT shop_id INTO v_shop FROM products WHERE id = p_product_id;
  -- lock this product's batches so two sellers cannot take the same stock
  PERFORM 1 FROM batches WHERE product_id = p_product_id FOR UPDATE;
  FOR r IN
    SELECT b.id, b.cost_price, COALESCE(s.qty, 0) AS qty
    FROM batches b LEFT JOIN batch_stock s ON s.batch_id = b.id
    WHERE b.product_id = p_product_id
      AND (b.expiry_date IS NULL OR b.expiry_date >= current_date)
      AND COALESCE(s.qty, 0) > 0
    ORDER BY b.expiry_date NULLS LAST, b.id
  LOOP
    EXIT WHEN need <= 0;
    take := LEAST(r.qty, need);
    INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, ref_type, ref_id, user_id)
    VALUES (v_shop, p_product_id, r.id, -take, 'sale', 'sale', p_sale_id, p_user);
    cost_total := cost_total + take * r.cost_price;
    need := need - take;
  END LOOP;
  IF need > 0 THEN
    RAISE EXCEPTION 'insufficient sellable stock for product %', p_product_id;
  END IF;
  RETURN cost_total;
END $$ LANGUAGE plpgsql;

-- Example (run after inserting a shop, user, product, batch and a purchase movement):
--   BEGIN;
--   INSERT INTO sales (shop_id, client_uuid, total, paid, payment_method, created_by)
--     VALUES (1, gen_random_uuid(), 30, 30, 'cash', 1) RETURNING id;   -- say id = 1
--   SELECT sell_fefo(1, 1, 3, 1);          -- sell 3 base units of product 1
--   COMMIT;
--   SELECT * FROM product_stock;
