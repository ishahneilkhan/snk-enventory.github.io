-- Offline sync support. Run after schema.sql and logic.sql.
-- Design: see docs/sync-design.md

ALTER TABLE sales
  ADD COLUMN IF NOT EXISTS device_id    text,
  ADD COLUMN IF NOT EXISTS occurred_at  timestamptz NOT NULL DEFAULT now(),  -- real time of the bill (device clock)
  ADD COLUMN IF NOT EXISTS needs_review boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS review_note  text,
  ADD COLUMN IF NOT EXISTS local_no     text;                                -- e.g. D1-0005
ALTER TABLE payments ADD COLUMN IF NOT EXISTS client_uuid uuid UNIQUE;
CREATE INDEX IF NOT EXISTS sales_review_idx ON sales (shop_id) WHERE needs_review;

-- OFFLINE SALE ---------------------------------------------------------
-- The device already chose the batches and prices and gave the customer a receipt, so the
-- server keeps the sale as it is, and only FLAGS anything odd (needs_review) for the owner.
-- p_allocations example: [{"batch_id": 1, "qty": 30, "unit_price": 1.0}]  (qty in base units)
-- Bad data (unknown batch, bad numbers, discount by a salesman) still raises an error;
-- the whole sale is then not saved and the app shows it in its "problem" list.
CREATE FUNCTION sync_sale(p_shop bigint, p_user bigint, p_client_uuid uuid, p_device_id text,
                          p_occurred_at timestamptz, p_local_no text, p_customer bigint,
                          p_method text, p_discount numeric, p_paid numeric, p_allocations jsonb,
                          OUT o_sale_id bigint, OUT o_status text, OUT o_note text)
AS $$
DECLARE
  v_role text; v_notes text[] := '{}'; v_sub numeric := 0; v_total numeric; v_paid numeric;
  v_when timestamptz := COALESCE(p_occurred_at, now());
  v_stock numeric; a record; bt record;
BEGIN
  v_role := assert_user(p_shop, p_user);

  SELECT id, review_note INTO o_sale_id, o_note FROM sales WHERE client_uuid = p_client_uuid;
  IF FOUND THEN o_status := 'duplicate'; RETURN; END IF;

  IF COALESCE(p_discount, 0) < 0 THEN RAISE EXCEPTION 'discount cannot be negative'; END IF;
  IF COALESCE(p_discount, 0) > 0 AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'only the owner can give a discount';
  END IF;
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN RAISE EXCEPTION 'no items'; END IF;
  IF p_customer IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM customers WHERE id = p_customer AND shop_id = p_shop) THEN
    RAISE EXCEPTION 'customer not found';
  END IF;

  IF abs(extract(epoch FROM (v_when - now()))) > 86400 THEN
    v_notes := v_notes || 'device time differs by more than 1 day'::text;
  END IF;

  INSERT INTO sales (shop_id, client_uuid, customer_id, discount, total, paid, payment_method,
                     created_by, device_id, occurred_at, local_no)
  VALUES (p_shop, p_client_uuid, p_customer, COALESCE(p_discount, 0), 0, 0, p_method,
          p_user, p_device_id, v_when, p_local_no)
  RETURNING id INTO o_sale_id;

  FOR a IN
    SELECT x.batch_id, SUM(x.qty) AS qty, x.unit_price
    FROM jsonb_to_recordset(p_allocations) AS x(batch_id bigint, qty numeric, unit_price numeric)
    GROUP BY x.batch_id, x.unit_price ORDER BY x.batch_id
  LOOP
    IF a.qty IS NULL OR a.qty <= 0 OR a.unit_price IS NULL OR a.unit_price < 0 THEN
      RAISE EXCEPTION 'bad allocation for batch %', a.batch_id;
    END IF;
    SELECT bb.id, bb.product_id, bb.expiry_date, bb.cost_price, bb.sell_price INTO bt
      FROM batches bb JOIN products p ON p.id = bb.product_id
     WHERE bb.id = a.batch_id AND p.shop_id = p_shop FOR UPDATE OF bb;
    IF NOT FOUND THEN RAISE EXCEPTION 'batch not found: %', a.batch_id; END IF;

    SELECT COALESCE(SUM(qty), 0) INTO v_stock FROM stock_movements WHERE batch_id = a.batch_id;
    IF v_stock - a.qty < 0 THEN
      v_notes := v_notes || ('stock below zero (batch ' || a.batch_id || ')')::text;
    END IF;
    IF bt.expiry_date IS NOT NULL AND bt.expiry_date < v_when::date THEN
      v_notes := v_notes || ('expired batch sold (batch ' || a.batch_id || ')')::text;
    END IF;
    IF abs(a.unit_price - bt.sell_price) > 0.0001 THEN
      v_notes := v_notes || ('price differs from batch price (batch ' || a.batch_id || ')')::text;
    END IF;

    INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, ref_type, ref_id, user_id)
    VALUES (p_shop, bt.product_id, a.batch_id, -a.qty, 'sale', 'sale', o_sale_id, p_user);
    INSERT INTO sale_items (sale_id, product_id, qty, unit_price, unit_cost)
    VALUES (o_sale_id, bt.product_id, a.qty, a.unit_price, bt.cost_price);
    v_sub := v_sub + a.qty * a.unit_price;
  END LOOP;

  v_total := round(v_sub - COALESCE(p_discount, 0), 2);
  IF v_total < 0 THEN RAISE EXCEPTION 'discount is more than the bill'; END IF;
  v_paid := CASE WHEN p_method = 'due' THEN LEAST(COALESCE(p_paid, 0), v_total) ELSE v_total END;
  o_note := NULLIF(array_to_string(v_notes, '; '), '');
  UPDATE sales SET total = v_total, paid = v_paid,
         needs_review = (o_note IS NOT NULL), review_note = o_note
   WHERE id = o_sale_id;
  IF o_note IS NOT NULL THEN
    INSERT INTO audit_log (shop_id, user_id, action, table_name, row_id, new_data)
    VALUES (p_shop, p_user, 'sync_review', 'sales', o_sale_id, jsonb_build_object('note', o_note));
  END IF;
  o_status := CASE WHEN o_note IS NULL THEN 'ok' ELSE 'review' END;
END $$ LANGUAGE plpgsql;

-- OFFLINE PAYMENT (customer pays a due) -----------------------------------
CREATE FUNCTION sync_payment(p_shop bigint, p_user bigint, p_client_uuid uuid, p_party_type text,
                             p_party_id bigint, p_amount numeric, p_method text,
                             OUT o_id bigint, OUT o_status text)
AS $$
BEGIN
  SELECT id INTO o_id FROM payments WHERE client_uuid = p_client_uuid;
  IF FOUND THEN o_status := 'duplicate'; RETURN; END IF;
  o_id := record_payment(p_shop, p_user, p_party_type, p_party_id, p_amount, COALESCE(p_method, 'cash'));
  UPDATE payments SET client_uuid = p_client_uuid WHERE id = o_id;
  o_status := 'ok';
END $$ LANGUAGE plpgsql;
