-- Business logic on top of schema.sql. Run schema.sql first.
-- Every function runs as ONE transaction: if anything fails, nothing is saved.
-- All quantities are in BASE units (piece, gram, ml). The app converts packs to base units.

CREATE FUNCTION assert_user(p_shop bigint, p_user bigint, p_owner_only boolean DEFAULT false)
RETURNS text AS $$
DECLARE r text;
BEGIN
  SELECT role INTO r FROM users WHERE id = p_user AND shop_id = p_shop AND active;
  IF r IS NULL THEN RAISE EXCEPTION 'unknown or inactive user'; END IF;
  IF p_owner_only AND r <> 'owner' THEN RAISE EXCEPTION 'owner only'; END IF;
  RETURN r;
END $$ LANGUAGE plpgsql;

-- SALE ---------------------------------------------------------------
-- p_items example: [{"product_id": 1, "qty": 30}, {"product_id": 2, "qty": 10}]
-- Prices are NOT taken from the client: they come from the batches that FEFO picks.
-- Calling again with the same p_client_uuid returns the same sale (safe for offline retry).
CREATE FUNCTION create_sale(p_shop bigint, p_user bigint, p_client_uuid uuid, p_customer bigint,
                            p_method text, p_discount numeric, p_paid numeric, p_items jsonb)
RETURNS bigint AS $$
DECLARE
  v_role text; v_sale bigint; v_sub numeric := 0; v_total numeric; v_paid numeric;
  it record; f record;
BEGIN
  v_role := assert_user(p_shop, p_user);
  SELECT id INTO v_sale FROM sales WHERE client_uuid = p_client_uuid;
  IF FOUND THEN RETURN v_sale; END IF;

  IF COALESCE(p_discount, 0) < 0 THEN RAISE EXCEPTION 'discount cannot be negative'; END IF;
  IF COALESCE(p_discount, 0) > 0 AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'only the owner can give a discount';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'no items'; END IF;
  IF p_customer IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM customers WHERE id = p_customer AND shop_id = p_shop) THEN
    RAISE EXCEPTION 'customer not found';
  END IF;

  INSERT INTO sales (shop_id, client_uuid, customer_id, discount, total, paid, payment_method, created_by)
  VALUES (p_shop, p_client_uuid, p_customer, COALESCE(p_discount, 0), 0, 0, p_method, p_user)
  RETURNING id INTO v_sale;

  -- ordered by product so two simultaneous sales lock in the same order (no deadlock)
  FOR it IN
    SELECT x.product_id, SUM(x.qty) AS qty
    FROM jsonb_to_recordset(p_items) AS x(product_id bigint, qty numeric)
    GROUP BY x.product_id ORDER BY x.product_id
  LOOP
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = it.product_id AND shop_id = p_shop AND active) THEN
      RAISE EXCEPTION 'product % not found', it.product_id;
    END IF;
    SELECT * INTO f FROM sell_fefo(v_sale, it.product_id, it.qty, p_user);
    INSERT INTO sale_items (sale_id, product_id, qty, unit_price, unit_cost)
    VALUES (v_sale, it.product_id, it.qty, f.o_revenue / it.qty, f.o_cost / it.qty);
    v_sub := v_sub + f.o_revenue;
  END LOOP;

  v_total := round(v_sub - COALESCE(p_discount, 0), 2);
  IF v_total < 0 THEN RAISE EXCEPTION 'discount is more than the bill'; END IF;
  v_paid := CASE WHEN p_method = 'due' THEN LEAST(COALESCE(p_paid, 0), v_total) ELSE v_total END;
  UPDATE sales SET total = v_total, paid = v_paid WHERE id = v_sale;

  IF COALESCE(p_discount, 0) > 0 THEN
    INSERT INTO audit_log (shop_id, user_id, action, table_name, row_id, new_data)
    VALUES (p_shop, p_user, 'discount', 'sales', v_sale, jsonb_build_object('discount', p_discount));
  END IF;
  RETURN v_sale;
END $$ LANGUAGE plpgsql;

-- PURCHASE -----------------------------------------------------------
-- p_items example: [{"product_id":1,"batch_no":"N-2601","expiry_date":"2028-03-31",
--                    "qty":1000,"unit_cost":0.8,"sell_price":1.0}]
-- If the same batch number + expiry already exists, its stock grows and its prices stay as they were.
CREATE FUNCTION create_purchase(p_shop bigint, p_user bigint, p_supplier bigint,
                                p_invoice text, p_paid numeric, p_items jsonb)
RETURNS bigint AS $$
DECLARE
  v_purchase bigint; v_total numeric := 0; v_batch bigint; it record;
BEGIN
  PERFORM assert_user(p_shop, p_user, true);
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier AND shop_id = p_shop) THEN
    RAISE EXCEPTION 'supplier not found';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'no items'; END IF;

  INSERT INTO purchases (shop_id, supplier_id, invoice_no, total, paid, created_by)
  VALUES (p_shop, p_supplier, p_invoice, 0, 0, p_user) RETURNING id INTO v_purchase;

  FOR it IN
    SELECT * FROM jsonb_to_recordset(p_items)
      AS x(product_id bigint, batch_no text, expiry_date date, qty numeric, unit_cost numeric, sell_price numeric)
  LOOP
    IF it.qty IS NULL OR it.qty <= 0 THEN RAISE EXCEPTION 'quantity must be positive'; END IF;
    IF it.batch_no IS NULL OR it.batch_no = '' THEN RAISE EXCEPTION 'batch number is required'; END IF;
    IF it.expiry_date IS NOT NULL AND it.expiry_date < current_date THEN
      RAISE EXCEPTION 'batch % is already expired', it.batch_no;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = it.product_id AND shop_id = p_shop AND active) THEN
      RAISE EXCEPTION 'product % not found', it.product_id;
    END IF;

    SELECT id INTO v_batch FROM batches
     WHERE product_id = it.product_id AND batch_no = it.batch_no
       AND expiry_date IS NOT DISTINCT FROM it.expiry_date;
    IF v_batch IS NULL THEN
      INSERT INTO batches (product_id, batch_no, expiry_date, cost_price, sell_price)
      VALUES (it.product_id, it.batch_no, it.expiry_date, it.unit_cost, it.sell_price)
      RETURNING id INTO v_batch;
    END IF;

    INSERT INTO purchase_items (purchase_id, batch_id, qty, unit_cost)
    VALUES (v_purchase, v_batch, it.qty, it.unit_cost);
    INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, ref_type, ref_id, user_id)
    VALUES (p_shop, it.product_id, v_batch, it.qty, 'purchase', 'purchase', v_purchase, p_user);
    v_total := v_total + it.qty * it.unit_cost;
  END LOOP;

  v_total := round(v_total, 2);
  IF COALESCE(p_paid, 0) < 0 OR COALESCE(p_paid, 0) > v_total THEN
    RAISE EXCEPTION 'paid amount must be between 0 and the total';
  END IF;
  UPDATE purchases SET total = v_total, paid = COALESCE(p_paid, 0) WHERE id = v_purchase;
  RETURN v_purchase;
END $$ LANGUAGE plpgsql;

-- STOCK CORRECTION (waste, count error, supplier return, customer return) ----
-- p_delta is signed: negative removes stock, positive adds. A reason is required.
CREATE FUNCTION adjust_stock(p_shop bigint, p_user bigint, p_batch bigint,
                             p_delta numeric, p_kind text, p_reason text)
RETURNS bigint AS $$
DECLARE v_product bigint; v_now numeric; v_id bigint;
BEGIN
  PERFORM assert_user(p_shop, p_user, true);
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required'; END IF;
  SELECT b.product_id INTO v_product FROM batches b JOIN products p ON p.id = b.product_id
   WHERE b.id = p_batch AND p.shop_id = p_shop FOR UPDATE OF b;
  IF v_product IS NULL THEN RAISE EXCEPTION 'batch not found'; END IF;
  SELECT COALESCE(SUM(qty), 0) INTO v_now FROM stock_movements WHERE batch_id = p_batch;
  IF v_now + p_delta < 0 THEN RAISE EXCEPTION 'stock cannot go below zero (now %)', v_now; END IF;
  INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, reason, user_id)
  VALUES (p_shop, v_product, p_batch, p_delta, p_kind, p_reason, p_user) RETURNING id INTO v_id;
  INSERT INTO audit_log (shop_id, user_id, action, table_name, row_id, new_data)
  VALUES (p_shop, p_user, 'stock_' || p_kind, 'stock_movements', v_id,
          jsonb_build_object('batch', p_batch, 'delta', p_delta, 'reason', p_reason));
  RETURN v_id;
END $$ LANGUAGE plpgsql;

-- LATER PAYMENT (customer pays a due / we pay a supplier) ---------------
CREATE FUNCTION record_payment(p_shop bigint, p_user bigint, p_party_type text,
                               p_party_id bigint, p_amount numeric, p_method text DEFAULT 'cash')
RETURNS bigint AS $$
DECLARE v_due numeric; v_id bigint;
BEGIN
  PERFORM assert_user(p_shop, p_user, p_party_type = 'supplier');  -- paying suppliers: owner only
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;
  IF p_party_type = 'customer' THEN
    SELECT due INTO v_due FROM customer_balance WHERE customer_id = p_party_id AND shop_id = p_shop;
  ELSIF p_party_type = 'supplier' THEN
    SELECT due INTO v_due FROM supplier_balance WHERE supplier_id = p_party_id AND shop_id = p_shop;
  ELSE RAISE EXCEPTION 'party type must be customer or supplier';
  END IF;
  IF v_due IS NULL THEN RAISE EXCEPTION 'party not found'; END IF;
  IF p_amount > v_due THEN RAISE EXCEPTION 'amount is more than the due (%)', v_due; END IF;
  INSERT INTO payments (shop_id, party_type, party_id, amount, method, created_by)
  VALUES (p_shop, p_party_type, p_party_id, p_amount, p_method, p_user) RETURNING id INTO v_id;
  RETURN v_id;
END $$ LANGUAGE plpgsql;
