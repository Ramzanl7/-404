-- Migration 003: transactional booking and DB events. Apply after 001_schema.sql.
-- PostgreSQL 16+. Requires trustworthy application permissions for payment confirmation.
BEGIN;
SET search_path = cinema, public;

CREATE TABLE IF NOT EXISTS cinema.inventory_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 screening_id uuid NOT NULL,
 seat_id uuid NOT NULL,
 old_status cinema.inventory_status,
 new_status cinema.inventory_status NOT NULL,
 order_id uuid,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 txid bigint NOT NULL DEFAULT txid_current()
);
CREATE INDEX IF NOT EXISTS inventory_events_screening_idx
 ON cinema.inventory_events (screening_id, occurred_at DESC);

-- Event 1: first publication materializes price snapshots for all active seats.
-- Subsequent edits to published screening's identity/time are forbidden.
CREATE OR REPLACE FUNCTION cinema.screening_publish_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
BEGIN
 IF TG_OP = 'UPDATE' THEN
   IF OLD.status = 'published' AND
      (NEW.hall_id, NEW.movie_id, NEW.starts_at, NEW.ends_at)
       IS DISTINCT FROM
      (OLD.hall_id, OLD.movie_id, OLD.starts_at, OLD.ends_at) THEN
     RAISE EXCEPTION 'Cannot change hall, movie, or times of a published screening';
   END IF;
 END IF;
 IF NEW.status = 'published' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'published') THEN
   IF NEW.starts_at <= statement_timestamp() THEN
     RAISE EXCEPTION 'Cannot publish an already started screening';
   END IF;
   INSERT INTO cinema.screening_seats (screening_id, hall_id, seat_id, price, currency)
   SELECT NEW.id, NEW.hall_id, st.id,
          CASE WHEN st.seat_type = 'sofa' THEN 900.00
               WHEN st.row_number BETWEEN 1 AND 3 THEN 350.00
               ELSE 550.00 END, 'RUB'
   FROM cinema.seats st
   WHERE st.hall_id = NEW.hall_id AND st.is_active
   ON CONFLICT (screening_id,seat_id) DO NOTHING;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_screening_publish
 AFTER INSERT OR UPDATE OF status, hall_id, movie_id, starts_at, ends_at
 ON cinema.screenings FOR EACH ROW EXECUTE FUNCTION cinema.screening_publish_event();

-- Inventory invariants and audit events.
CREATE OR REPLACE FUNCTION cinema.inventory_validate() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE order_state cinema.order_status;
BEGIN
 NEW.updated_at := clock_timestamp();
 IF TG_OP = 'UPDATE' AND (NEW.screening_id, NEW.seat_id, NEW.hall_id) IS DISTINCT FROM
     (OLD.screening_id, OLD.seat_id, OLD.hall_id) THEN
   RAISE EXCEPTION 'Inventory identity is immutable';
 END IF;
 IF NEW.status = 'held' THEN
   SELECT status INTO order_state FROM cinema.orders WHERE id = NEW.order_id;
   IF order_state IS DISTINCT FROM 'pending' OR NEW.held_until <= statement_timestamp() THEN
     RAISE EXCEPTION 'Held seat requires live pending order and future hold deadline';
   END IF;
 ELSIF NEW.status = 'sold' THEN
   SELECT status INTO order_state FROM cinema.orders WHERE id = NEW.order_id;
   IF order_state NOT IN ('pending','paid') OR order_state IS NULL THEN
     RAISE EXCEPTION 'Sold seat must belong to a pending/paid order';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_inventory_validate BEFORE INSERT OR UPDATE ON cinema.screening_seats
 FOR EACH ROW EXECUTE FUNCTION cinema.inventory_validate();

CREATE OR REPLACE FUNCTION cinema.inventory_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
BEGIN
 IF TG_OP = 'INSERT' OR (OLD.status, OLD.order_id) IS DISTINCT FROM (NEW.status, NEW.order_id) THEN
   INSERT INTO cinema.inventory_events(screening_id, seat_id, old_status, new_status, order_id)
   VALUES (NEW.screening_id, NEW.seat_id,
           CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
           NEW.status, NEW.order_id);
   -- Notification is delivered only on successful COMMIT, with a minimal payload.
   PERFORM pg_notify('cinema_inventory', NEW.screening_id::text);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_inventory_audit AFTER INSERT OR UPDATE ON cinema.screening_seats
 FOR EACH ROW EXECUTE FUNCTION cinema.inventory_audit();

-- Event 2: release all non-sold held seats when an order expires or is cancelled.
CREATE OR REPLACE FUNCTION cinema.order_release_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
BEGIN
 IF NEW.status IN ('expired','cancelled') AND OLD.status = 'pending' THEN
   UPDATE cinema.screening_seats
   SET status='available', order_id=NULL, held_until=NULL
   WHERE order_id=NEW.id AND status='held';
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_order_release AFTER UPDATE OF status ON cinema.orders
 FOR EACH ROW EXECUTE FUNCTION cinema.order_release_event();

-- Command 1: book all requested seats together. The calling SELECT runs in one transaction.
-- Lock hierarchy: screening -> inventory (sorted); order inserted only after locks.
CREATE OR REPLACE FUNCTION cinema.hold_seats(
 p_screening_id uuid, p_seat_ids uuid[], p_email text,
 p_user_id uuid DEFAULT NULL, p_idempotency_key text DEFAULT NULL,
 p_hold_minutes integer DEFAULT 10
) RETURNS uuid LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE
 v_screening cinema.screenings%ROWTYPE;
 v_seat_id uuid;
 v_ss cinema.screening_seats%ROWTYPE;
 v_order_id uuid;
 v_total numeric(12,2) := 0;
 v_currency char(3);
 v_count integer := 0;
 v_unique_count integer;
 v_expires timestamptz;
BEGIN
 IF p_email IS NULL OR btrim(p_email) = '' OR p_hold_minutes NOT BETWEEN 1 AND 30 THEN
   RAISE EXCEPTION 'Invalid booking parameters';
 END IF;
 IF p_seat_ids IS NULL OR array_length(p_seat_ids,1) IS NULL
    OR array_length(p_seat_ids,1) > 12 OR array_position(p_seat_ids, NULL) IS NOT NULL THEN
   RAISE EXCEPTION 'Select 1 to 12 valid seats';
 END IF;
 SELECT count(DISTINCT x) INTO v_unique_count FROM unnest(p_seat_ids) AS x;
 IF v_unique_count <> array_length(p_seat_ids,1) THEN
   RAISE EXCEPTION 'Duplicate seat in request';
 END IF;
 -- A repeated key is only valid for exactly the same request; verify seats and contact.
 IF p_idempotency_key IS NOT NULL THEN
   SELECT id INTO v_order_id FROM cinema.orders WHERE client_idempotency_key = p_idempotency_key;
   IF FOUND THEN
     IF NOT EXISTS (
       SELECT 1 FROM cinema.orders o
       WHERE o.id=v_order_id AND o.customer_email=p_email AND o.user_id IS NOT DISTINCT FROM p_user_id
         AND o.status='pending' AND o.expires_at > statement_timestamp()
         AND (SELECT count(*) FROM cinema.screening_seats s WHERE s.order_id=o.id AND s.status='held'
              AND s.screening_id=p_screening_id)=v_unique_count
         AND NOT EXISTS (
             SELECT 1 FROM unnest(p_seat_ids) requested(id)
             WHERE NOT EXISTS (SELECT 1 FROM cinema.screening_seats s
                               WHERE s.order_id=o.id AND s.screening_id=p_screening_id
                                 AND s.seat_id=requested.id AND s.status='held')
         )
     ) THEN RAISE EXCEPTION 'Idempotency key reused or booking no longer active'; END IF;
     RETURN v_order_id;
   END IF;
 END IF;
 SELECT * INTO v_screening FROM cinema.screenings
 WHERE id=p_screening_id FOR SHARE;
 IF NOT FOUND OR v_screening.status <> 'published' OR v_screening.starts_at <= statement_timestamp() THEN
   RAISE EXCEPTION 'Screening is not available for booking';
 END IF;
 -- Explicit deterministic row-lock ordering avoids most inventory lock cycles.
 FOR v_seat_id IN SELECT DISTINCT x FROM unnest(p_seat_ids) AS x ORDER BY x LOOP
   SELECT * INTO v_ss FROM cinema.screening_seats
    WHERE screening_id=p_screening_id AND seat_id=v_seat_id FOR UPDATE;
   IF NOT FOUND OR v_ss.status <> 'available' THEN
     RAISE EXCEPTION 'Seat % is unavailable', v_seat_id USING ERRCODE='P0001';
   END IF;
   IF v_currency IS NOT NULL AND v_currency <> v_ss.currency THEN
     RAISE EXCEPTION 'Mixed currencies are not supported';
   END IF;
   v_currency := v_ss.currency;
   v_total := v_total + v_ss.price;
   v_count := v_count+1;
 END LOOP;
 IF v_count <> v_unique_count THEN RAISE EXCEPTION 'Not all seats were found'; END IF;
 v_expires := statement_timestamp() + make_interval(mins => p_hold_minutes);
 INSERT INTO cinema.orders(user_id,customer_email,status,expires_at,total_amount,currency,client_idempotency_key)
 VALUES(p_user_id,p_email,'pending',v_expires,v_total,v_currency,p_idempotency_key)
 RETURNING id INTO v_order_id;
 UPDATE cinema.screening_seats
 SET status='held',order_id=v_order_id,held_until=v_expires
 WHERE screening_id=p_screening_id AND seat_id=ANY(p_seat_ids);
 RETURN v_order_id;
END $$;

-- Command 2: process one verified successful payment atomically.
-- Provider signature and paid amount MUST be verified by backend before calling.
-- We first lock order, then write the payment; the payment trigger does fulfillment.
CREATE OR REPLACE FUNCTION cinema.confirm_payment(
 p_order_id uuid, p_provider text, p_provider_payment_id text,
 p_amount numeric, p_currency char(3)
) RETURNS uuid LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE v_order cinema.orders%ROWTYPE; v_payment_id uuid; v_old cinema.payments%ROWTYPE;
BEGIN
 IF nullif(btrim(p_provider),'') IS NULL OR nullif(btrim(p_provider_payment_id),'') IS NULL THEN
   RAISE EXCEPTION 'Payment provider and external ID are required';
 END IF;
 SELECT * INTO v_order FROM cinema.orders WHERE id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown order'; END IF;
 SELECT * INTO v_old FROM cinema.payments
 WHERE provider=p_provider AND provider_payment_id=p_provider_payment_id;
 IF FOUND THEN
   IF v_old.order_id <> p_order_id OR v_old.amount <> p_amount OR v_old.currency <> p_currency
      OR v_old.status <> 'succeeded' OR v_order.status <> 'paid' THEN
     RAISE EXCEPTION 'Conflicting/replayed payment details';
   END IF;
   RETURN v_old.id;
 END IF;
 IF v_order.status <> 'pending' OR v_order.expires_at <= statement_timestamp() THEN
   RAISE EXCEPTION 'Order expired or not payable; reconcile/refund with provider';
 END IF;
 IF v_order.total_amount <> p_amount OR v_order.currency <> p_currency OR p_amount <= 0 THEN
   RAISE EXCEPTION 'Payment amount or currency mismatch';
 END IF;
 INSERT INTO cinema.payments(order_id,provider,provider_payment_id,status,amount,currency,completed_at)
 VALUES(p_order_id,p_provider,p_provider_payment_id,'succeeded',p_amount,p_currency,clock_timestamp())
 RETURNING id INTO v_payment_id;
 RETURN v_payment_id;
END $$;

-- Event 3: successful payment turns all held seats into sold seats and issues tickets.
CREATE OR REPLACE FUNCTION cinema.payment_succeeded_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE v_order cinema.orders%ROWTYPE; v_count int; v_total numeric(12,2);
BEGIN
 IF NEW.status <> 'succeeded' OR (TG_OP = 'UPDATE' AND OLD.status = 'succeeded') THEN
   RETURN NULL;
 END IF;
 SELECT * INTO v_order FROM cinema.orders WHERE id=NEW.order_id FOR UPDATE;
 IF NOT FOUND OR v_order.status <> 'pending' OR v_order.expires_at <= statement_timestamp() THEN
   RAISE EXCEPTION 'Cannot fulfill expired or inactive order';
 END IF;
 SELECT count(*),coalesce(sum(price),0) INTO v_count,v_total
 FROM cinema.screening_seats WHERE order_id=NEW.order_id AND status='held'
   AND held_until > statement_timestamp();
 IF v_count=0 OR v_total <> v_order.total_amount
    OR NEW.amount <> v_order.total_amount OR NEW.currency <> v_order.currency
    OR EXISTS (SELECT 1 FROM cinema.screening_seats
               WHERE order_id=NEW.order_id AND status <> 'held') THEN
   RAISE EXCEPTION 'Inconsistent held inventory or payment total';
 END IF;
 UPDATE cinema.screening_seats SET status='sold', held_until=NULL
 WHERE order_id=NEW.order_id AND status='held' AND held_until > statement_timestamp();
 GET DIAGNOSTICS v_count = ROW_COUNT;
 IF v_count=0 THEN RAISE EXCEPTION 'No valid inventory to sell'; END IF;
 UPDATE cinema.orders SET status='paid',paid_at=clock_timestamp() WHERE id=NEW.order_id;
 INSERT INTO cinema.tickets(order_id,screening_id,seat_id)
 SELECT NEW.order_id,screening_id,seat_id FROM cinema.screening_seats
 WHERE order_id=NEW.order_id AND status='sold'
 ON CONFLICT (screening_id,seat_id) DO NOTHING;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_payment_succeeded AFTER INSERT OR UPDATE OF status ON cinema.payments
 FOR EACH ROW EXECUTE FUNCTION cinema.payment_succeeded_event();

-- Command 3: cancellation releases seats through tr_order_release.
CREATE OR REPLACE FUNCTION cinema.cancel_pending_order(p_order_id uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE v_updated integer;
BEGIN
 UPDATE cinema.orders SET status='cancelled' WHERE id=p_order_id AND status='pending';
 GET DIAGNOSTICS v_updated = ROW_COUNT;
 RETURN v_updated=1;
END $$;

-- Command 4: invoke periodically, e.g. every minute from an external scheduler.
-- Using SKIP LOCKED means concurrent payment/booking requests are not blocked.
CREATE OR REPLACE FUNCTION cinema.expire_pending_orders(p_batch integer DEFAULT 200)
RETURNS integer LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE v_count integer;
BEGIN
 IF p_batch NOT BETWEEN 1 AND 5000 THEN RAISE EXCEPTION 'Invalid batch size'; END IF;
 WITH due AS (
  SELECT id FROM cinema.orders
  WHERE status='pending' AND expires_at <= statement_timestamp()
  ORDER BY expires_at,id FOR UPDATE SKIP LOCKED LIMIT p_batch
 ), changed AS (
  UPDATE cinema.orders o SET status='expired'
  FROM due WHERE o.id=due.id RETURNING o.id
 ) SELECT count(*) INTO v_count FROM changed;
 RETURN v_count;
END $$;

COMMENT ON FUNCTION cinema.confirm_payment(uuid,text,text,numeric,char) IS
 'ONLY call after server-side payment-provider signature and amount verification; restrict EXECUTE privilege.';
COMMENT ON FUNCTION cinema.expire_pending_orders(integer) IS
 'Call periodically; triggers do not run when wall-clock time passes without database activity.';
COMMIT;
