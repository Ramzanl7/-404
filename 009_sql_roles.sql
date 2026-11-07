-- Run as database owner with CREATEROLE. NOLOGIN roles are groups only.
-- Grant group roles to *separate* application login accounts via DBA-controlled GRANT.
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cinema_reader') THEN
  CREATE ROLE cinema_reader NOLOGIN;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cinema_booking') THEN
  CREATE ROLE cinema_booking NOLOGIN;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cinema_webhook') THEN
  CREATE ROLE cinema_webhook NOLOGIN;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cinema_manager_db') THEN
  CREATE ROLE cinema_manager_db NOLOGIN;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cinema_worker') THEN
  CREATE ROLE cinema_worker NOLOGIN;
 END IF;
END $$;
REVOKE ALL ON SCHEMA cinema FROM PUBLIC;
GRANT USAGE ON SCHEMA cinema TO cinema_reader,cinema_booking,cinema_webhook,
 cinema_manager_db,cinema_worker;
GRANT SELECT ON cinema.cinemas,cinema.halls,cinema.seats,cinema.movies,
 cinema.screenings,cinema.seat_availability,cinema.seat_tariffs
 TO cinema_reader;
GRANT cinema_reader TO cinema_booking,cinema_manager_db;
GRANT EXECUTE ON FUNCTION cinema.hold_seats(uuid,uuid[],text,uuid,text,integer),
 cinema.cancel_pending_order(uuid),cinema.has_permission(uuid,text,uuid)
 TO cinema_booking;
GRANT EXECUTE ON FUNCTION cinema.confirm_payment(uuid,text,text,numeric,char),
 cinema.confirm_refund(uuid,text) TO cinema_webhook;
GRANT EXECUTE ON FUNCTION cinema.cancel_screening_as(uuid,text,uuid),
 cinema.has_permission(uuid,text,uuid)
 TO cinema_manager_db;
GRANT EXECUTE ON FUNCTION cinema.expire_pending_orders(integer) TO cinema_worker;
GRANT EXECUTE ON FUNCTION cinema.claim_outbox(integer),
 cinema.ack_outbox(bigint) TO cinema_worker;
-- Worker reads only its own claimed outbox payloads through claim_outbox().
-- No direct INSERT/UPDATE/DELETE for any app roles.
-- Avoid granting cinema_webhook to publicly exposed general API account.
COMMIT;
