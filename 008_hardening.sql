-- PostgreSQL 16+. Apply after 001,003,005,006,007.
-- Database owner must run this migration. All writes are transactionally atomic.
BEGIN;
SET search_path = cinema, pg_temp;

-- 1. Tariffs: editable, prioritized, time-bounded. Existing snapshots never reprice.
CREATE TABLE cinema.seat_tariffs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 hall_id uuid NOT NULL REFERENCES cinema.halls(id),
 seat_type cinema.seat_type,
 row_from integer NOT NULL DEFAULT 1 CHECK (row_from > 0),
 row_to integer NOT NULL DEFAULT 9999 CHECK (row_to >= row_from),
 amount numeric(12,2) NOT NULL CHECK (amount >= 0),
 currency char(3) NOT NULL DEFAULT 'RUB',
 priority integer NOT NULL DEFAULT 0,
 effective_from timestamptz NOT NULL DEFAULT '-infinity'::timestamptz,
 effective_until timestamptz NOT NULL DEFAULT 'infinity'::timestamptz,
 is_active boolean NOT NULL DEFAULT true,
 CHECK (effective_until > effective_from)
);
CREATE INDEX seat_tariffs_lookup_idx ON cinema.seat_tariffs(hall_id,priority DESC)
 WHERE is_active;
-- Deterministic tie-breaking by id, and no two equal-priority matching rules allowed.
-- Overlaps with different priorities are intentional (e.g. sofas override generic rows).
INSERT INTO cinema.seat_tariffs(hall_id,seat_type,row_from,row_to,amount,priority)
SELECT h.id,v.seat_type::cinema.seat_type,v.rf,v.rt,v.amount,v.priority
FROM cinema.halls h CROSS JOIN (VALUES
 ('sofa',1,9999,900.00::numeric,100),
 (NULL,1,3,350.00::numeric,20),
 (NULL,4,9999,550.00::numeric,10)
) v(seat_type,rf,rt,amount,priority);

CREATE OR REPLACE FUNCTION cinema.screening_publish_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = cinema, pg_temp AS $$
DECLARE v_missing integer;
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='published' AND
   (NEW.hall_id,NEW.movie_id,NEW.starts_at,NEW.ends_at)
   IS DISTINCT FROM (OLD.hall_id,OLD.movie_id,OLD.starts_at,OLD.ends_at) THEN
   RAISE EXCEPTION 'Cannot edit a published screening identity/time';
 END IF;
 IF NEW.status='published' AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM 'published') THEN
   IF NEW.starts_at <= statement_timestamp() THEN
     RAISE EXCEPTION 'Cannot publish a past screening';
   END IF;
   -- Prevent ambiguous top-priority price rules.
   SELECT count(*) INTO v_missing FROM cinema.seats st
   WHERE st.hall_id=NEW.hall_id AND st.is_active
     AND (SELECT count(*) FROM cinema.seat_tariffs t
          WHERE t.hall_id=NEW.hall_id AND t.is_active
            AND (t.seat_type IS NULL OR t.seat_type=st.seat_type)
            AND st.row_number BETWEEN t.row_from AND t.row_to
            AND NEW.starts_at >= t.effective_from AND NEW.starts_at < t.effective_until
            AND t.priority=(SELECT max(t2.priority) FROM cinema.seat_tariffs t2
             WHERE t2.hall_id=NEW.hall_id AND t2.is_active
               AND (t2.seat_type IS NULL OR t2.seat_type=st.seat_type)
               AND st.row_number BETWEEN t2.row_from AND t2.row_to
               AND NEW.starts_at >= t2.effective_from AND NEW.starts_at < t2.effective_until)) <> 1;
   IF v_missing > 0 THEN RAISE EXCEPTION '% seats have missing or ambiguous tariff',v_missing; END IF;
   INSERT INTO cinema.screening_seats(screening_id,hall_id,seat_id,price,currency)
   SELECT NEW.id,NEW.hall_id,st.id,t.amount,t.currency
   FROM cinema.seats st
   CROSS JOIN LATERAL (
     SELECT amount,currency FROM cinema.seat_tariffs t
     WHERE t.hall_id=NEW.hall_id AND t.is_active
       AND (t.seat_type IS NULL OR t.seat_type=st.seat_type)
       AND st.row_number BETWEEN t.row_from AND t.row_to
       AND NEW.starts_at >= t.effective_from AND NEW.starts_at < t.effective_until
     ORDER BY t.priority DESC,t.id LIMIT 1
   ) t
   WHERE st.hall_id=NEW.hall_id AND st.is_active
   ON CONFLICT (screening_id,seat_id) DO NOTHING;
 END IF;
 RETURN NEW;
END $$;

-- 2. Acoustic rendering data; renderer can use attenuation/occlusion.
ALTER TABLE cinema.halls
 ADD COLUMN audio_enabled boolean NOT NULL DEFAULT false,
 ADD COLUMN speaker_layout jsonb NOT NULL DEFAULT '[]'::jsonb,
 ADD COLUMN audio_reference_distance_m numeric(8,2) NOT NULL DEFAULT 1 CHECK (audio_reference_distance_m > 0),
 ADD COLUMN audio_rolloff_factor numeric(6,3) NOT NULL DEFAULT 1 CHECK (audio_rolloff_factor >= 0),
 ADD CONSTRAINT hall_speakers_array CHECK (jsonb_typeof(speaker_layout)='array');
ALTER TABLE cinema.seats
 ADD COLUMN audio_gain_db numeric(6,2) NOT NULL DEFAULT 0,
 ADD COLUMN audio_occlusion numeric(4,3) NOT NULL DEFAULT 0
   CHECK (audio_occlusion BETWEEN 0 AND 1),
 ADD COLUMN audio_delay_ms numeric(8,2) NOT NULL DEFAULT 0 CHECK (audio_delay_ms >= 0);

-- 3. Explicit immutable history with transaction IDs.
CREATE TABLE cinema.order_status_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 order_id uuid NOT NULL REFERENCES cinema.orders(id),
 old_status cinema.order_status,
 new_status cinema.order_status NOT NULL,
 changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 txid bigint NOT NULL DEFAULT txid_current()
);
CREATE TABLE cinema.payment_status_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 payment_id uuid NOT NULL REFERENCES cinema.payments(id),
 order_id uuid NOT NULL REFERENCES cinema.orders(id),
 old_status cinema.payment_status,
 new_status cinema.payment_status NOT NULL,
 changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 txid bigint NOT NULL DEFAULT txid_current()
);
CREATE OR REPLACE FUNCTION cinema.audit_order_status() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status THEN
   INSERT INTO cinema.order_status_events(order_id,old_status,new_status)
   VALUES(NEW.id,CASE WHEN TG_OP='INSERT' THEN NULL ELSE OLD.status END,NEW.status);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_order_status_audit AFTER INSERT OR UPDATE OF status ON cinema.orders
 FOR EACH ROW EXECUTE FUNCTION cinema.audit_order_status();
CREATE OR REPLACE FUNCTION cinema.audit_payment_status() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status THEN
   INSERT INTO cinema.payment_status_events(payment_id,order_id,old_status,new_status)
   VALUES(NEW.id,NEW.order_id,CASE WHEN TG_OP='INSERT' THEN NULL ELSE OLD.status END,NEW.status);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_payment_status_audit AFTER INSERT OR UPDATE OF status ON cinema.payments
 FOR EACH ROW EXECUTE FUNCTION cinema.audit_payment_status();
-- Preserve pre-migration histories' *current* states, not imagined past transitions.
INSERT INTO cinema.order_status_events(order_id,new_status) SELECT id,status FROM cinema.orders;
INSERT INTO cinema.payment_status_events(payment_id,order_id,new_status)
 SELECT id,order_id,status FROM cinema.payments;

-- Reject fulfillment when a screening has already been cancelled or started.
-- A cancellation racing with an in-flight payment still queues its refund.
CREATE OR REPLACE FUNCTION cinema.payment_succeeded_event() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
DECLARE v_order cinema.orders%ROWTYPE; v_count int; v_total numeric(12,2);
BEGIN
 IF NEW.status<>'succeeded' OR (TG_OP='UPDATE' AND OLD.status='succeeded') THEN
   RETURN NULL;
 END IF;
 SELECT * INTO v_order FROM cinema.orders WHERE id=NEW.order_id FOR UPDATE;
 IF NOT FOUND OR v_order.status<>'pending' OR v_order.expires_at<=statement_timestamp() THEN
   RAISE EXCEPTION 'Cannot fulfill inactive or expired order'; END IF;
 IF EXISTS (
  SELECT 1 FROM cinema.screening_seats ss
  JOIN cinema.screenings sc ON sc.id=ss.screening_id
  WHERE ss.order_id=NEW.order_id AND
    (sc.status<>'published' OR sc.starts_at<=statement_timestamp())
 ) THEN RAISE EXCEPTION 'Screening is cancelled or already started'; END IF;
 SELECT count(*),coalesce(sum(price),0) INTO v_count,v_total
 FROM cinema.screening_seats WHERE order_id=NEW.order_id AND status='held'
 AND held_until>statement_timestamp();
 IF v_count=0 OR v_total<>v_order.total_amount OR
    NEW.amount<>v_order.total_amount OR NEW.currency<>v_order.currency OR
    EXISTS(SELECT 1 FROM cinema.screening_seats WHERE order_id=NEW.order_id AND status<>'held') THEN
   RAISE EXCEPTION 'Inconsistent inventory or payment amount'; END IF;
 UPDATE cinema.screening_seats SET status='sold',held_until=NULL
 WHERE order_id=NEW.order_id AND status='held' AND held_until>statement_timestamp();
 GET DIAGNOSTICS v_count=ROW_COUNT;
 IF v_count=0 THEN RAISE EXCEPTION 'No seats to sell'; END IF;
 UPDATE cinema.orders SET status='paid',paid_at=clock_timestamp() WHERE id=NEW.order_id;
 INSERT INTO cinema.tickets(order_id,screening_id,seat_id)
 SELECT NEW.order_id,screening_id,seat_id FROM cinema.screening_seats
 WHERE order_id=NEW.order_id AND status='sold'
 ON CONFLICT DO NOTHING;
 RETURN NULL;
END $$;

-- 4. Refund lifecycle: request is NOT equivalent to refund completion.
CREATE TABLE cinema.refunds (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL REFERENCES cinema.orders(id),
 payment_id uuid NOT NULL REFERENCES cinema.payments(id),
 provider_refund_id text,
 status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','succeeded','failed')),
 amount numeric(12,2) NOT NULL CHECK (amount > 0),
 currency char(3) NOT NULL,
 reason text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 completed_at timestamptz,
 UNIQUE(payment_id),
 UNIQUE(provider_refund_id),
 CHECK ((status='requested' AND completed_at IS NULL) OR
        (status IN ('succeeded','failed') AND completed_at IS NOT NULL))
);
CREATE INDEX refunds_by_order_idx ON cinema.refunds(order_id);

-- Revoke direct DML is primary protection; guards additionally reject invalid transitions.
CREATE OR REPLACE FUNCTION cinema.order_transition_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF TG_OP='UPDATE' THEN
   IF (NEW.user_id,NEW.customer_email,NEW.total_amount,NEW.currency,
       NEW.client_idempotency_key,NEW.created_at)
      IS DISTINCT FROM
      (OLD.user_id,OLD.customer_email,OLD.total_amount,OLD.currency,
       OLD.client_idempotency_key,OLD.created_at) THEN
     RAISE EXCEPTION 'Order financial and ownership fields are immutable';
   END IF;
   IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
      (OLD.status='pending' AND NEW.status IN ('paid','expired','cancelled')) OR
      (OLD.status='paid' AND NEW.status='refunded')
   ) THEN RAISE EXCEPTION 'Invalid order transition % -> %',OLD.status,NEW.status; END IF;
   IF NEW.status='paid' AND (NEW.paid_at IS NULL OR OLD.paid_at IS NOT NULL AND NEW.paid_at<>OLD.paid_at) THEN
     RAISE EXCEPTION 'Invalid paid_at';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_order_transition_guard BEFORE UPDATE ON cinema.orders
 FOR EACH ROW EXECUTE FUNCTION cinema.order_transition_guard();

CREATE OR REPLACE FUNCTION cinema.payment_transition_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF TG_OP='UPDATE' THEN
   IF (NEW.order_id,NEW.provider,NEW.provider_payment_id,NEW.amount,NEW.currency,NEW.created_at)
      IS DISTINCT FROM
      (OLD.order_id,OLD.provider,OLD.provider_payment_id,OLD.amount,OLD.currency,OLD.created_at) THEN
     RAISE EXCEPTION 'Payment identity and amount are immutable';
   END IF;
   IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
      (OLD.status='created' AND NEW.status IN ('succeeded','failed')) OR
      (OLD.status='succeeded' AND NEW.status='refunded')
   ) THEN RAISE EXCEPTION 'Invalid payment transition'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_payment_transition_guard BEFORE UPDATE ON cinema.payments
 FOR EACH ROW EXECUTE FUNCTION cinema.payment_transition_guard();

-- 5. Full cancellation: leave seats sold until provider confirms refund;
-- then block them (screening is cancelled). No false claim of refund.
CREATE OR REPLACE FUNCTION cinema.request_order_refund(p_order_id uuid,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_order cinema.orders%ROWTYPE; v_payment cinema.payments%ROWTYPE; v_refund_id uuid;
BEGIN
 IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Refund reason required'; END IF;
 SELECT * INTO v_order FROM cinema.orders WHERE id=p_order_id FOR UPDATE;
 IF NOT FOUND OR v_order.status<>'paid' THEN RAISE EXCEPTION 'Only paid orders may be refunded'; END IF;
 SELECT * INTO v_payment FROM cinema.payments WHERE order_id=p_order_id AND status='succeeded' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Successful payment missing'; END IF;
 INSERT INTO cinema.refunds(order_id,payment_id,amount,currency,reason)
 VALUES(p_order_id,v_payment.id,v_payment.amount,v_payment.currency,p_reason)
 ON CONFLICT (payment_id) DO UPDATE SET reason=cinema.refunds.reason
 RETURNING id INTO v_refund_id;
 RETURN v_refund_id;
END $$;

CREATE OR REPLACE FUNCTION cinema.confirm_refund(p_refund_id uuid,p_provider_refund_id text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_refund cinema.refunds%ROWTYPE; v_order cinema.orders%ROWTYPE; v_order_id uuid;
BEGIN
 IF nullif(btrim(p_provider_refund_id),'') IS NULL THEN RAISE EXCEPTION 'External refund ID required'; END IF;
 SELECT order_id INTO v_order_id FROM cinema.refunds WHERE id=p_refund_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found'; END IF;
 SELECT * INTO v_order FROM cinema.orders WHERE id=v_order_id FOR UPDATE;
 SELECT * INTO v_refund FROM cinema.refunds WHERE id=p_refund_id FOR UPDATE;
 IF v_refund.status='succeeded' THEN
   IF v_refund.provider_refund_id<>p_provider_refund_id THEN RAISE EXCEPTION 'Conflicting refund callback'; END IF;
   RETURN true;
 END IF;
 IF v_refund.status<>'requested' OR v_order.status<>'paid' THEN RAISE EXCEPTION 'Refund state conflict'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cinema.payments WHERE id=v_refund.payment_id AND status='succeeded'
    AND amount=v_refund.amount AND currency=v_refund.currency) THEN
   RAISE EXCEPTION 'Payment/refund mismatch';
 END IF;
 UPDATE cinema.refunds SET status='succeeded',provider_refund_id=p_provider_refund_id,
  completed_at=clock_timestamp() WHERE id=p_refund_id;
 UPDATE cinema.payments SET status='refunded' WHERE id=v_refund.payment_id;
 UPDATE cinema.orders SET status='refunded' WHERE id=v_refund.order_id;
 UPDATE cinema.tickets SET revoked_at=clock_timestamp()
 WHERE order_id=v_refund.order_id AND revoked_at IS NULL;
 -- A refunded seat in cancelled screening is blocked, not offered for resale.
 UPDATE cinema.screening_seats ss SET status=CASE WHEN sc.status='cancelled'
    THEN 'blocked'::cinema.inventory_status ELSE 'available'::cinema.inventory_status END,
    order_id=NULL,held_until=NULL
 FROM cinema.screenings sc
 WHERE ss.order_id=v_refund.order_id AND ss.status='sold' AND sc.id=ss.screening_id;
 RETURN true;
END $$;

CREATE OR REPLACE FUNCTION cinema.cancel_screening(p_screening_id uuid,p_reason text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_sc cinema.screenings%ROWTYPE; v_order_id uuid; v_count integer:=0;
BEGIN
 IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Cancellation reason required'; END IF;
 SELECT * INTO v_sc FROM cinema.screenings WHERE id=p_screening_id FOR UPDATE;
 IF NOT FOUND OR v_sc.status NOT IN ('draft','published') THEN
   RAISE EXCEPTION 'Screening not cancellable'; END IF;
 IF v_sc.starts_at<=statement_timestamp() THEN RAISE EXCEPTION 'Screening already started'; END IF;
 UPDATE cinema.screenings SET status='cancelled' WHERE id=p_screening_id;
 -- Pending orders get cancelled/released. Paid orders request provider refund.
 FOR v_order_id IN
  SELECT DISTINCT o.id FROM cinema.orders o
  JOIN cinema.screening_seats ss ON ss.order_id=o.id
  WHERE ss.screening_id=p_screening_id AND o.status='pending'
  ORDER BY o.id
 LOOP
   UPDATE cinema.orders SET status='cancelled' WHERE id=v_order_id AND status='pending';
   v_count:=v_count+1;
 END LOOP;
 FOR v_order_id IN
  SELECT DISTINCT o.id FROM cinema.orders o
  JOIN cinema.screening_seats ss ON ss.order_id=o.id
  WHERE ss.screening_id=p_screening_id AND o.status='paid'
  ORDER BY o.id
 LOOP
   PERFORM cinema.request_order_refund(v_order_id,p_reason);
   v_count:=v_count+1;
 END LOOP;
 UPDATE cinema.screening_seats SET status='blocked'
 WHERE screening_id=p_screening_id AND status='available';
 RETURN v_count;
END $$;

-- Transactional outbox: refund requests are persisted in the same commit.
CREATE TABLE cinema.outbox_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 event_type text NOT NULL,
 aggregate_id uuid NOT NULL,
 payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 delivered_at timestamptz,
 leased_until timestamptz,
 attempts integer NOT NULL DEFAULT 0,
 last_error text
);
CREATE INDEX outbox_due_idx ON cinema.outbox_events(id)
 WHERE delivered_at IS NULL;
CREATE OR REPLACE FUNCTION cinema.refund_outbox_event() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF NEW.status='requested' THEN
  INSERT INTO cinema.outbox_events(event_type,aggregate_id,payload)
  VALUES('refund.requested',NEW.id,jsonb_build_object(
   'refund_id',NEW.id,'order_id',NEW.order_id,'payment_id',NEW.payment_id,
   'amount',NEW.amount,'currency',NEW.currency,'reason',NEW.reason));
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_refund_outbox AFTER INSERT ON cinema.refunds
 FOR EACH ROW EXECUTE FUNCTION cinema.refund_outbox_event();
-- Worker uses the refund UUID as the provider's idempotency key.
CREATE FUNCTION cinema.claim_outbox(p_batch integer DEFAULT 100)
RETURNS SETOF cinema.outbox_events LANGUAGE plpgsql SECURITY DEFINER
SET search_path=cinema,pg_temp AS $$
BEGIN
 IF p_batch NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Invalid batch'; END IF;
 RETURN QUERY WITH due AS (
  SELECT id FROM cinema.outbox_events
  WHERE delivered_at IS NULL AND (leased_until IS NULL OR leased_until<clock_timestamp())
  ORDER BY id LIMIT p_batch FOR UPDATE SKIP LOCKED
 ) UPDATE cinema.outbox_events e
 SET leased_until=clock_timestamp()+interval '2 minutes',attempts=e.attempts+1
 FROM due WHERE e.id=due.id RETURNING e.*;
END $$;
CREATE FUNCTION cinema.ack_outbox(p_event_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_rows int;
BEGIN
 UPDATE cinema.outbox_events SET delivered_at=clock_timestamp(),leased_until=NULL
 WHERE id=p_event_id AND delivered_at IS NULL;
 GET DIAGNOSTICS v_rows=ROW_COUNT;
 RETURN v_rows=1;
END $$;

-- Revoked tickets must not prohibit later legitimate resale after refund.
ALTER TABLE cinema.tickets DROP CONSTRAINT IF EXISTS tickets_screening_id_seat_id_key;
CREATE UNIQUE INDEX tickets_active_seat_uq ON cinema.tickets(screening_id,seat_id)
 WHERE revoked_at IS NULL;

-- Validate cross-table consistency at transaction COMMIT, not in the middle of fulfillment.
CREATE OR REPLACE FUNCTION cinema.assert_order_consistency(p_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_order cinema.orders%ROWTYPE; v_held int; v_sold int; v_active_tickets int;
 v_held_amount numeric; v_sold_amount numeric; v_paid_count int;
BEGIN
 SELECT * INTO v_order FROM cinema.orders WHERE id=p_order_id;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT count(*) FILTER (WHERE status='held'),
        count(*) FILTER (WHERE status='sold'),
        coalesce(sum(price) FILTER (WHERE status='held'),0),
        coalesce(sum(price) FILTER (WHERE status='sold'),0)
 INTO v_held,v_sold,v_held_amount,v_sold_amount
 FROM cinema.screening_seats WHERE order_id=p_order_id;
 SELECT count(*) INTO v_active_tickets FROM cinema.tickets
 WHERE order_id=p_order_id AND revoked_at IS NULL;
 SELECT count(*) INTO v_paid_count FROM cinema.payments
 WHERE order_id=p_order_id AND status='succeeded';
 IF v_order.status='pending' AND
   (v_sold<>0 OR v_active_tickets<>0 OR v_paid_count<>0 OR v_held_amount<>v_order.total_amount OR v_held=0) THEN
   RAISE EXCEPTION 'Pending order % inconsistent',p_order_id;
 ELSIF v_order.status='paid' AND
   (v_held<>0 OR v_sold=0 OR v_sold<>v_active_tickets OR
    v_sold_amount<>v_order.total_amount OR v_paid_count<>1 OR
    EXISTS (SELECT 1 FROM cinema.tickets t
      WHERE t.order_id=p_order_id AND t.revoked_at IS NULL AND
       NOT EXISTS (SELECT 1 FROM cinema.screening_seats ss
           WHERE ss.order_id=t.order_id AND ss.screening_id=t.screening_id
           AND ss.seat_id=t.seat_id AND ss.status='sold'))) THEN
   RAISE EXCEPTION 'Paid order % inconsistent',p_order_id;
 ELSIF v_order.status IN ('cancelled','expired','refunded') AND
   (v_held<>0 OR v_sold<>0 OR v_active_tickets<>0 OR v_paid_count<>0) THEN
   RAISE EXCEPTION 'Closed order % has active seats/tickets/payment',p_order_id;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION cinema.consistency_event() RETURNS trigger
LANGUAGE plpgsql SET search_path=cinema,pg_temp AS $$
BEGIN
 IF TG_TABLE_NAME='orders' THEN
   PERFORM cinema.assert_order_consistency(NEW.id);
 ELSIF TG_TABLE_NAME='payments' OR TG_TABLE_NAME='tickets' THEN
   PERFORM cinema.assert_order_consistency(NEW.order_id);
 ELSIF TG_TABLE_NAME='screening_seats' THEN
   IF TG_OP='UPDATE' AND OLD.order_id IS NOT NULL AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
     PERFORM cinema.assert_order_consistency(OLD.order_id);
   END IF;
   IF NEW.order_id IS NOT NULL THEN PERFORM cinema.assert_order_consistency(NEW.order_id); END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER tr_order_consistency AFTER INSERT OR UPDATE ON cinema.orders
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cinema.consistency_event();
CREATE CONSTRAINT TRIGGER tr_payment_consistency AFTER INSERT OR UPDATE ON cinema.payments
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cinema.consistency_event();
CREATE CONSTRAINT TRIGGER tr_ticket_consistency AFTER INSERT OR UPDATE ON cinema.tickets
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cinema.consistency_event();
CREATE CONSTRAINT TRIGGER tr_seat_consistency AFTER INSERT OR UPDATE ON cinema.screening_seats
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cinema.consistency_event();

-- Privileged administrative command must be called via RBAC checked wrapper.
CREATE OR REPLACE FUNCTION cinema.cancel_screening_as(
 p_screening_id uuid,p_reason text,p_actor_id uuid
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_cinema_id uuid;
BEGIN
 SELECT h.cinema_id INTO v_cinema_id FROM cinema.screenings sc
 JOIN cinema.halls h ON h.id=sc.hall_id WHERE sc.id=p_screening_id;
 IF v_cinema_id IS NULL OR NOT cinema.has_permission(p_actor_id,'screenings.manage_cinema',v_cinema_id) THEN
  RAISE EXCEPTION 'Permission denied for this cinema' USING ERRCODE='42501';
 END IF;
 RETURN cinema.cancel_screening(p_screening_id,p_reason);
END $$;

-- 6. Expiry cleaning is a scheduled job; API can also call opportunistic cleanup.
-- This view returns *effective* availability even if cleaner is delayed.
CREATE VIEW cinema.seat_availability AS
SELECT ss.screening_id,ss.hall_id,ss.seat_id,ss.price,ss.currency,
 CASE WHEN ss.status='held' AND (ss.held_until<=statement_timestamp() OR
      o.status IS DISTINCT FROM 'pending') THEN 'available'::cinema.inventory_status
      ELSE ss.status END AS effective_status, ss.held_until
FROM cinema.screening_seats ss
LEFT JOIN cinema.orders o ON o.id=ss.order_id;

-- 7. Hardening: SECURITY DEFINER functions use fixed search_path.
-- Keep existing booking implementation as locked, permission-restricted core.
ALTER FUNCTION cinema.hold_seats(uuid,uuid[],text,uuid,text,integer) RENAME TO hold_seats_core;
ALTER FUNCTION cinema.hold_seats_core(uuid,uuid[],text,uuid,text,integer) SECURITY DEFINER;
-- Reap *only relevant* expired orders, lock orders before seats (avoids inversion).
CREATE FUNCTION cinema.hold_seats(
 p_screening_id uuid, p_seat_ids uuid[], p_email text,
 p_user_id uuid DEFAULT NULL,p_idempotency_key text DEFAULT NULL,
 p_hold_minutes integer DEFAULT 10
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=cinema,pg_temp AS $$
DECLARE v_order uuid;
BEGIN
 FOR v_order IN
  SELECT DISTINCT o.id FROM cinema.orders o
   JOIN cinema.screening_seats ss ON ss.order_id=o.id
   WHERE ss.screening_id=p_screening_id AND ss.seat_id=ANY(p_seat_ids)
    AND ss.status='held' AND o.status='pending'
    AND o.expires_at<=statement_timestamp()
   ORDER BY o.id
 LOOP
   UPDATE cinema.orders SET status='expired'
   WHERE id=v_order AND status='pending' AND expires_at<=statement_timestamp();
 END LOOP;
 RETURN cinema.hold_seats_core(p_screening_id,p_seat_ids,p_email,p_user_id,
                               p_idempotency_key,p_hold_minutes);
END $$;
ALTER FUNCTION cinema.confirm_payment(uuid,text,text,numeric,char) SECURITY DEFINER;
ALTER FUNCTION cinema.cancel_pending_order(uuid) SECURITY DEFINER;
ALTER FUNCTION cinema.expire_pending_orders(integer) SECURITY DEFINER;
ALTER FUNCTION cinema.has_permission(uuid,text,uuid) SECURITY DEFINER;

-- Avoid permission bypass by direct access; actual GRANTs in 009_sql_roles.sql.
REVOKE ALL ON ALL TABLES IN SCHEMA cinema FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA cinema FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA cinema FROM PUBLIC;
REVOKE USAGE,CREATE ON SCHEMA cinema FROM PUBLIC;
-- Do not let future functions silently acquire PUBLIC EXECUTE.
ALTER DEFAULT PRIVILEGES IN SCHEMA cinema REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMIT;
