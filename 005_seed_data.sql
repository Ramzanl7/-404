-- Demo dataset for PostgreSQL 16+. Requires 001_schema.sql and 003_booking_triggers.sql.
-- Idempotent seed for catalog/seats/screenings; demo orders created only once.
-- Run in a DEVELOPMENT database only.
BEGIN;
SET search_path TO cinema, public;

INSERT INTO cinema.cinemas(id,name,city,address,timezone) VALUES
 ('11111111-1111-4111-8111-111111111101','КиноГород','Грозный','проспект В. В. Путина, 15','Europe/Moscow'),
 ('11111111-1111-4111-8111-111111111102','Синема Парк','Грозный','улица Мира, 8','Europe/Moscow'),
 ('11111111-1111-4111-8111-111111111103','Горизонт','Аргун','улица А. А. Кадырова, 24','Europe/Moscow')
ON CONFLICT (id) DO NOTHING;

INSERT INTO cinema.halls(id,cinema_id,name,screen_width_m,screen_height_m,scene_asset_url,screen_x,screen_y,screen_z) VALUES
 ('22222222-2222-4222-8222-222222222201','11111111-1111-4111-8111-111111111101','Большой зал',18,9,'/assets/halls/big-hall.glb',0,3.5,0),
 ('22222222-2222-4222-8222-222222222202','11111111-1111-4111-8111-111111111101','Камерный зал',12,6,'/assets/halls/small-hall.glb',0,2.8,0),
 ('22222222-2222-4222-8222-222222222203','11111111-1111-4111-8111-111111111102','Премьер',16,8,'/assets/halls/premiere.glb',0,3.2,0),
 ('22222222-2222-4222-8222-222222222204','11111111-1111-4111-8111-111111111103','Зал 1',14,7,'/assets/halls/horizon.glb',0,3,0)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cinema.movies(id,title,synopsis,duration_minutes,age_rating,poster_url) VALUES
 ('33333333-3333-4333-8333-333333333301','Путь к звёздам','Научно-фантастическая история об экспедиции к далёкой планете.',124,'12+','/assets/posters/stars.jpg'),
 ('33333333-3333-4333-8333-333333333302','Город будущего','Семейное приключение в мире новых технологий.',98,'6+','/assets/posters/future-city.jpg'),
 ('33333333-3333-4333-8333-333333333303','Тайна старого маяка','Детективная история на побережье.',112,'16+','/assets/posters/lighthouse.jpg'),
 ('33333333-3333-4333-8333-333333333304','Вершина','Спортивная драма о команде альпинистов.',105,'12+','/assets/posters/summit.jpg')
ON CONFLICT (id) DO NOTHING;

-- Seats have deterministic UUIDs computed from hall/row/number via md5.
-- Coordinate convention: screen lies at z=0, audience rows extend toward +z.
-- x = horizontal meters, y = floor elevation; camera eye adds eye_height_m.
INSERT INTO cinema.seats(id,hall_id,row_number,seat_number,seat_type,pos_x,pos_y,pos_z,eye_height_m,view_yaw_deg,view_pitch_deg,view_fov_deg)
SELECT
 (substr(md5(h.id::text || ':' || r.row_number || ':' || s.seat_number),1,8) || '-' ||
  substr(md5(h.id::text || ':' || r.row_number || ':' || s.seat_number),9,4) || '-' ||
  '4' || substr(md5(h.id::text || ':' || r.row_number || ':' || s.seat_number),14,3) || '-' ||
  '8' || substr(md5(h.id::text || ':' || r.row_number || ':' || s.seat_number),18,3) || '-' ||
  substr(md5(h.id::text || ':' || r.row_number || ':' || s.seat_number),21,12))::uuid,
 h.id,r.row_number,s.seat_number,
 CASE WHEN r.row_number = h.n_rows AND s.seat_number BETWEEN 1 AND 4 THEN 'sofa'::cinema.seat_type
      WHEN r.row_number=1 AND s.seat_number IN (1,2) THEN 'accessible'::cinema.seat_type
      WHEN r.row_number BETWEEN 4 AND 7 THEN 'premium'::cinema.seat_type
      ELSE 'standard'::cinema.seat_type END,
 round(((s.seat_number - (h.n_seats+1)/2.0)*0.78)::numeric,3),
 round(((r.row_number-1)*0.17)::numeric,3),
 round((2.4+(r.row_number-1)*1.12)::numeric,3),
 1.15,
 round((degrees(atan2(-((s.seat_number-(h.n_seats+1)/2.0)*0.78),-(2.4+(r.row_number-1)*1.12)))::numeric),3),
 0,75
FROM (VALUES
 ('22222222-2222-4222-8222-222222222201'::uuid,10,12),
 ('22222222-2222-4222-8222-222222222202'::uuid,7,8),
 ('22222222-2222-4222-8222-222222222203'::uuid,9,10),
 ('22222222-2222-4222-8222-222222222204'::uuid,8,10)
) h(id,n_rows,n_seats)
CROSS JOIN LATERAL generate_series(1,h.n_rows) AS r(row_number)
CROSS JOIN LATERAL generate_series(1,h.n_seats) AS s(seat_number)
ON CONFLICT (hall_id,row_number,seat_number) DO NOTHING;

-- Fixed IDs enable reproducible API tests. Times are 2/3/4 days in the future.
-- Publishing fires tr_screening_publish and populates screening_seats automatically.
INSERT INTO cinema.screenings(id,hall_id,movie_id,starts_at,ends_at,status)
SELECT v.id, v.hall_id,v.movie_id,v.starts_at,v.starts_at + make_interval(mins=>v.duration),'published'::cinema.screening_status
FROM (VALUES
 ('44444444-4444-4444-8444-444444444401'::uuid,'22222222-2222-4222-8222-222222222201'::uuid,'33333333-3333-4333-8333-333333333301'::uuid,2,13,0,124),
 ('44444444-4444-4444-8444-444444444402'::uuid,'22222222-2222-4222-8222-222222222201'::uuid,'33333333-3333-4333-8333-333333333302'::uuid,2,18,0,98),
 ('44444444-4444-4444-8444-444444444403'::uuid,'22222222-2222-4222-8222-222222222202'::uuid,'33333333-3333-4333-8333-333333333303'::uuid,2,15,30,112),
 ('44444444-4444-4444-8444-444444444404'::uuid,'22222222-2222-4222-8222-222222222203'::uuid,'33333333-3333-4333-8333-333333333304'::uuid,2,16,0,105),
 ('44444444-4444-4444-8444-444444444405'::uuid,'22222222-2222-4222-8222-222222222204'::uuid,'33333333-3333-4333-8333-333333333302'::uuid,2,19,0,98),
 ('44444444-4444-4444-8444-444444444406'::uuid,'22222222-2222-4222-8222-222222222201'::uuid,'33333333-3333-4333-8333-333333333303'::uuid,3,14,0,112),
 ('44444444-4444-4444-8444-444444444407'::uuid,'22222222-2222-4222-8222-222222222203'::uuid,'33333333-3333-4333-8333-333333333301'::uuid,3,20,0,124),
 ('44444444-4444-4444-8444-444444444408'::uuid,'22222222-2222-4222-8222-222222222204'::uuid,'33333333-3333-4333-8333-333333333304'::uuid,4,17,0,105)
) x(id,hall_id,movie_id,day_offset,local_hour,local_minute,duration)
CROSS JOIN LATERAL (
 SELECT x.id,x.hall_id,x.movie_id,x.duration,
   (((now() AT TIME ZONE 'Europe/Moscow')::date + x.day_offset)::timestamp +
     make_interval(hours=>x.local_hour,mins=>x.local_minute)) AT TIME ZONE 'Europe/Moscow' AS starts_at
) v
ON CONFLICT (id) DO NOTHING;

INSERT INTO cinema.users(id,email,display_name,role) VALUES
 ('55555555-5555-4555-8555-555555555501','alice.demo@example.test','Алина Тестовая','customer'),
 ('55555555-5555-4555-8555-555555555502','bob.demo@example.test','Руслан Тестовый','customer'),
 ('55555555-5555-4555-8555-555555555503','admin.demo@example.test','Администратор демо','admin')
ON CONFLICT (id) DO NOTHING;

-- Demonstrate order transitions exclusively through DB business functions.
-- No fabricated password hashes; demo accounts are not login-ready.
DO $demo$
DECLARE
 v_seats uuid[];
 v_order uuid;
 v_amount numeric;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM cinema.orders WHERE client_idempotency_key='seed-paid-001') THEN
   SELECT array_agg(id ORDER BY seat_number) INTO v_seats
   FROM cinema.seats
   WHERE hall_id='22222222-2222-4222-8222-222222222201' AND row_number=6 AND seat_number IN (5,6);
   v_order := cinema.hold_seats('44444444-4444-4444-8444-444444444401',v_seats,
       'alice.demo@example.test','55555555-5555-4555-8555-555555555501','seed-paid-001');
   SELECT total_amount INTO v_amount FROM cinema.orders WHERE id=v_order;
   PERFORM cinema.confirm_payment(v_order,'seed-mock','seed-payment-001',v_amount,'RUB');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM cinema.orders WHERE client_idempotency_key='seed-held-001') THEN
   SELECT array_agg(id ORDER BY seat_number) INTO v_seats FROM cinema.seats
   WHERE hall_id='22222222-2222-4222-8222-222222222201' AND row_number=4 AND seat_number IN (2,3);
   PERFORM cinema.hold_seats('44444444-4444-4444-8444-444444444401',v_seats,
       'bob.demo@example.test','55555555-5555-4555-8555-555555555502','seed-held-001',30);
 END IF;
 IF NOT EXISTS (SELECT 1 FROM cinema.orders WHERE client_idempotency_key='seed-cancelled-001') THEN
   SELECT array_agg(id ORDER BY seat_number) INTO v_seats FROM cinema.seats
   WHERE hall_id='22222222-2222-4222-8222-222222222201' AND row_number=2 AND seat_number IN (8);
   v_order := cinema.hold_seats('44444444-4444-4444-8444-444444444401',v_seats,
       'bob.demo@example.test','55555555-5555-4555-8555-555555555502','seed-cancelled-001');
   PERFORM cinema.cancel_pending_order(v_order);
 END IF;
END $demo$;
COMMIT;

-- Quick data verification (after COMMIT).
SELECT 'cinemas' AS entity, count(*) AS rows FROM cinema.cinemas
UNION ALL SELECT 'halls',count(*) FROM cinema.halls
UNION ALL SELECT 'seats',count(*) FROM cinema.seats
UNION ALL SELECT 'movies',count(*) FROM cinema.movies
UNION ALL SELECT 'screenings',count(*) FROM cinema.screenings
UNION ALL SELECT 'screening_seats',count(*) FROM cinema.screening_seats
UNION ALL SELECT 'orders',count(*) FROM cinema.orders
UNION ALL SELECT 'payments',count(*) FROM cinema.payments
UNION ALL SELECT 'tickets',count(*) FROM cinema.tickets;
