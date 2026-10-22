-- Run after schema.sql and logic.sql. Everything is rolled back at the end.
-- Success prints: NOTICE: ALL TESTS PASSED
BEGIN;
DO $$
DECLARE
  s bigint; own bigint; sman bigint; sup bigint; cus bigint; p bigint;
  bA bigint; bB bigint; bX bigint; sale bigint; sale2 bigint; q numeric; v_total numeric;
BEGIN
  INSERT INTO shops (name, business_type) VALUES ('Test', 'pharmacy') RETURNING id INTO s;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (s, 'O', 't_owner', 'x', 'owner') RETURNING id INTO own;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (s, 'S', 't_sman', 'x', 'salesman') RETURNING id INTO sman;
  INSERT INTO suppliers (shop_id, name) VALUES (s, 'Sup') RETURNING id INTO sup;
  INSERT INTO customers (shop_id, name) VALUES (s, 'Cus') RETURNING id INTO cus;
  INSERT INTO products (shop_id, name, base_unit, pack_unit, pack_size) VALUES (s, 'Napa', 'piece', 'strip', 10) RETURNING id INTO p;

  -- two good batches (prices per piece); the cheaper-to-expire one is batch A
  PERFORM create_purchase(s, own, sup, 'INV1', 0, jsonb_build_array(
    jsonb_build_object('product_id', p, 'batch_no', 'A', 'expiry_date', current_date + 30,  'qty', 100, 'unit_cost', 0.8, 'sell_price', 1.0),
    jsonb_build_object('product_id', p, 'batch_no', 'B', 'expiry_date', current_date + 365, 'qty', 100, 'unit_cost', 0.9, 'sell_price', 1.2)));
  SELECT id INTO bA FROM batches WHERE product_id = p AND batch_no = 'A';
  SELECT id INTO bB FROM batches WHERE product_id = p AND batch_no = 'B';

  -- an expired batch inserted directly (create_purchase refuses expired stock)
  INSERT INTO batches (product_id, batch_no, expiry_date, cost_price, sell_price) VALUES (p, 'X', current_date - 1, 0.5, 0.7) RETURNING id INTO bX;
  INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, user_id) VALUES (s, p, bX, 500, 'purchase', own);

  -- supplier due = 100*0.8 + 100*0.9 = 170
  ASSERT (SELECT due FROM supplier_balance WHERE supplier_id = sup) = 170, 'supplier due should be 170';

  -- FEFO: sell 150 -> 100 from A (1.0) + 50 from B (1.2) = 160, expired batch untouched
  sale := create_sale(s, own, gen_random_uuid(), NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 150)));
  SELECT total INTO v_total FROM sales WHERE id = sale;
  ASSERT v_total = 160, 'bill total should be 160, got ' || v_total;
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 0,   'batch A should be empty';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bB) = 50,  'batch B should have 50';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bX) = 500, 'expired batch must not be sold';
  ASSERT (SELECT sellable_qty FROM product_stock WHERE product_id = p) = 50, 'sellable stock should be 50';
  ASSERT (SELECT expired_qty  FROM product_stock WHERE product_id = p) = 500, 'expired stock should be 500';

  -- retry with the same client_uuid must not sell twice
  sale2 := create_sale(s, own, (SELECT client_uuid FROM sales WHERE id = sale), NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 150)));
  ASSERT sale2 = sale, 'retry should return the same sale';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bB) = 50, 'retry must not change stock';

  -- not enough sellable stock -> error, and nothing is saved
  BEGIN
    PERFORM create_sale(s, own, gen_random_uuid(), NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 51)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'insufficient sellable stock%', 'wrong error: ' || SQLERRM;
  END;
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bB) = 50, 'failed sale must not change stock';

  -- salesman cannot give a discount
  BEGIN
    PERFORM create_sale(s, sman, gen_random_uuid(), NULL, 'cash', 5, NULL, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 1)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'only the owner%', 'wrong error: ' || SQLERRM;
  END;

  -- due sale with 10 paid now: customer owes 24 - 10 = 14 (20 pieces of B at 1.2)
  PERFORM create_sale(s, sman, gen_random_uuid(), cus, 'due', 0, 10, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 20)));
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 14, 'customer due should be 14';
  PERFORM record_payment(s, sman, 'customer', cus, 14);
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 0, 'customer due should be 0';

  -- stock ledger cannot be edited
  BEGIN
    UPDATE stock_movements SET qty = 1 WHERE id = (SELECT min(id) FROM stock_movements);
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'stock_movements is append-only%', 'wrong error: ' || SQLERRM;
  END;

  -- waste: owner only, needs a reason, cannot go below zero
  PERFORM adjust_stock(s, own, bB, -5, 'waste', 'water damage');
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bB) = 25, 'batch B should have 25 after sale and waste';
  BEGIN
    PERFORM adjust_stock(s, own, bB, -26, 'waste', 'too much');
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'stock cannot go below zero%', 'wrong error: ' || SQLERRM;
  END;

  RAISE NOTICE 'ALL TESTS PASSED';
END $$;
ROLLBACK;
