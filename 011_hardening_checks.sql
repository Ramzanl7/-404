-- Requires seeded data 005; destructive changes are rolled back.
-- Test commands run as DB owner (service role direct DML is intentionally denied).
BEGIN;
DO $$
DECLARE v_paid uuid; v_screening uuid; v_ref uuid; v_tickets int;
BEGIN
 SELECT o.id,ss.screening_id INTO v_paid,v_screening FROM cinema.orders o
 JOIN cinema.screening_seats ss ON ss.order_id=o.id
 WHERE o.client_idempotency_key='seed-paid-001' AND o.status='paid' LIMIT 1;
 IF v_paid IS NULL THEN RAISE EXCEPTION 'Seed paid order is missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cinema.seat_tariffs WHERE amount=900) THEN
  RAISE EXCEPTION 'Tariffs missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cinema.order_status_events WHERE order_id=v_paid) THEN
  RAISE EXCEPTION 'Order history missing'; END IF;
 -- Cancelling one screening must request, but not falsely confirm refunds.
 PERFORM cinema.cancel_screening(v_screening,'Integration test: screening cancelled');
 IF (SELECT status FROM cinema.orders WHERE id=v_paid)<>'paid' THEN
  RAISE EXCEPTION 'Order should remain paid until external refund confirms'; END IF;
 SELECT id INTO v_ref FROM cinema.refunds WHERE order_id=v_paid;
 IF v_ref IS NULL OR (SELECT status FROM cinema.refunds WHERE id=v_ref)<>'requested' THEN
  RAISE EXCEPTION 'Missing refund request'; END IF;
 PERFORM cinema.confirm_refund(v_ref,'integration-test-refund-001');
 IF (SELECT status FROM cinema.orders WHERE id=v_paid)<>'refunded' THEN
  RAISE EXCEPTION 'Order not refunded'; END IF;
 SELECT count(*) INTO v_tickets FROM cinema.tickets
 WHERE order_id=v_paid AND revoked_at IS NULL;
 IF v_tickets<>0 THEN RAISE EXCEPTION 'Tickets not revoked'; END IF;
 IF EXISTS(SELECT 1 FROM cinema.screening_seats
           WHERE screening_id=v_screening AND status='sold') THEN
  RAISE EXCEPTION 'Sold inventory left after refund'; END IF;
 IF EXISTS(SELECT 1 FROM cinema.screening_seats
           WHERE screening_id=v_screening AND status='available') THEN
  RAISE EXCEPTION 'Cancelled screening inventory must be blocked'; END IF;
END $$;
-- Explicitly evaluate deferred cross-table checks before rollback.
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
