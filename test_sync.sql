-- Run after schema.sql, logic.sql and sync.sql. Everything is rolled back at the end.
-- Success prints: NOTICE: ALL SYNC TESTS PASSED
BEGIN;
DO $$
DECLARE
  sh bigint; own bigint; sman bigint; sup bigint; cus bigint; p bigint;
  bA bigint; bB bigint; bC bigint; bX bigint; r record; v_t timestamptz; n_before int; u uuid;
BEGIN
  INSERT INTO shops (name, business_type) VALUES ('Test', 'pharmacy') RETURNING id INTO sh;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'O', 's_owner', 'x', 'owner') RETURNING id INTO own;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'S', 's_sman', 'x', 'salesman') RETURNING id INTO sman;
  INSERT INTO suppliers (shop_id, name) VALUES (sh, 'Sup') RETURNING id INTO sup;
  INSERT INTO customers (shop_id, name) VALUES (sh, 'Cus') RETURNING id INTO cus;
  INSERT INTO products (shop_id, name, base_unit, pack_unit, pack_size) VALUES (sh, 'Napa', 'piece', 'strip', 10) RETURNING id INTO p;

  PERFORM create_purchase(sh, own, sup, 'INV1', 0, jsonb_build_array(
    jsonb_build_object('product_id', p, 'batch_no', 'A', 'expiry_date', current_date + 30,  'qty', 100,  'unit_cost', 0.8, 'sell_price', 1.0),
    jsonb_build_object('product_id', p, 'batch_no', 'B', 'expiry_date', current_date + 365, 'qty', 100,  'unit_cost', 0.9, 'sell_price', 1.2),
    jsonb_build_object('product_id', p, 'batch_no', 'C', 'expiry_date', current_date + 100, 'qty', 1000, 'unit_cost', 1.0, 'sell_price', 1.5)));
  SELECT id INTO bA FROM batches WHERE product_id = p AND batch_no = 'A';
  SELECT id INTO bB FROM batches WHERE product_id = p AND batch_no = 'B';
  SELECT id INTO bC FROM batches WHERE product_id = p AND batch_no = 'C';
  INSERT INTO batches (product_id, batch_no, expiry_date, cost_price, sell_price) VALUES (p, 'X', current_date - 1, 0.5, 0.7) RETURNING id INTO bX;
  INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, user_id) VALUES (sh, p, bX, 500, 'purchase', own);

  -- 1. a clean offline sale is saved as it is
  u := gen_random_uuid();
  SELECT * INTO r FROM sync_sale(sh, sman, u, 'D1', now(), 'D1-0001', NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bA, 'qty', 100, 'unit_price', 1.0)));
  ASSERT r.o_status = 'ok', 'clean sale should be ok, got ' || r.o_status;
  ASSERT (SELECT total FROM sales WHERE id = r.o_sale_id) = 100, 'total should be 100';
  ASSERT (SELECT local_no FROM sales WHERE id = r.o_sale_id) = 'D1-0001', 'local number should be kept';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 0, 'batch A should be empty';

  -- 2. sending it again does not sell twice
  SELECT * INTO r FROM sync_sale(sh, sman, u, 'D1', now(), 'D1-0001', NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bA, 'qty', 100, 'unit_price', 1.0)));
  ASSERT r.o_status = 'duplicate', 'retry should be duplicate';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 0, 'retry must not change stock';
  ASSERT (SELECT count(*) FROM sales WHERE client_uuid = u) = 1, 'only one sale row';

  -- 3. overselling is saved but flagged (stock goes negative)
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D2', now(), 'D2-0001', NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bB, 'qty', 150, 'unit_price', 1.2)));
  ASSERT r.o_status = 'review' AND r.o_note LIKE '%stock below zero%', 'oversell should be flagged: ' || COALESCE(r.o_note, 'null');
  ASSERT (SELECT total FROM sales WHERE id = r.o_sale_id) = 180, 'oversold bill is still recorded';
  ASSERT (SELECT needs_review FROM sales WHERE id = r.o_sale_id), 'needs_review should be true';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bB) = -50, 'batch B should be at -50';

  -- 4. a price that differs from the batch price is flagged
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D1', now(), NULL, NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bC, 'qty', 1, 'unit_price', 2.0)));
  ASSERT r.o_status = 'review' AND r.o_note LIKE '%price differs%', 'price difference should be flagged';

  -- 5. an expired batch is flagged
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D1', now(), NULL, NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bX, 'qty', 1, 'unit_price', 0.7)));
  ASSERT r.o_status = 'review' AND r.o_note LIKE '%expired batch%', 'expired batch should be flagged';

  -- 6. a device clock far from the server clock is flagged
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D1', now() - interval '3 days', NULL, NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bC, 'qty', 1, 'unit_price', 1.5)));
  ASSERT r.o_status = 'review' AND r.o_note LIKE '%device time%', 'clock difference should be flagged';

  -- 7. the real (device) time is kept in occurred_at
  v_t := now() - interval '2 hours';
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D1', v_t, NULL, NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bC, 'qty', 2, 'unit_price', 1.5)));
  ASSERT r.o_status = 'ok', 'sale with an earlier time should be ok';
  ASSERT (SELECT occurred_at FROM sales WHERE id = r.o_sale_id) = v_t, 'occurred_at should be kept';

  -- 8. due sale: 10 paid now of 15, customer owes 5... then pays it offline, twice
  SELECT * INTO r FROM sync_sale(sh, sman, gen_random_uuid(), 'D1', now(), NULL, cus, 'due', 0, 10,
      jsonb_build_array(jsonb_build_object('batch_id', bC, 'qty', 10, 'unit_price', 1.5)));
  ASSERT r.o_status = 'ok', 'due sale should be ok';
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 5, 'customer due should be 5';
  u := gen_random_uuid();
  SELECT * INTO r FROM sync_payment(sh, sman, u, 'customer', cus, 5, 'cash');
  ASSERT r.o_status = 'ok', 'payment should be ok';
  SELECT * INTO r FROM sync_payment(sh, sman, u, 'customer', cus, 5, 'cash');
  ASSERT r.o_status = 'duplicate', 'payment retry should be duplicate';
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 0, 'customer due should be 0';

  -- 9. a salesman cannot give a discount
  BEGIN
    PERFORM sync_sale(sh, sman, gen_random_uuid(), 'D1', now(), NULL, NULL, 'cash', 5, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', bC, 'qty', 1, 'unit_price', 1.5)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'only the owner%', 'wrong error: ' || SQLERRM;
  END;

  -- 10. an unknown batch fails and saves nothing
  SELECT count(*) INTO n_before FROM sales;
  BEGIN
    PERFORM sync_sale(sh, sman, gen_random_uuid(), 'D1', now(), NULL, NULL, 'cash', 0, NULL,
      jsonb_build_array(jsonb_build_object('batch_id', 999999999, 'qty', 1, 'unit_price', 1.5)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'batch not found%', 'wrong error: ' || SQLERRM;
  END;
  ASSERT (SELECT count(*) FROM sales) = n_before, 'failed sale must not leave a row';

  RAISE NOTICE 'ALL SYNC TESTS PASSED';
END $$;
ROLLBACK;
