-- Executable smoke/demo scenario, run against a CLEAN database after 001 and 003.
BEGIN;
INSERT INTO cinema.cinemas(name,city,address) VALUES ('Киноцентр','Грозный','ул. Демонстрационная, 1');
INSERT INTO cinema.halls(cinema_id,name,screen_width_m,screen_height_m)
SELECT id,'Зал 1',16,8 FROM cinema.cinemas WHERE name='Киноцентр';
INSERT INTO cinema.seats(hall_id,row_number,seat_number,pos_x,pos_y,pos_z)
SELECT h.id,r,s,(s-3)*0.7,0,r*1.1
FROM cinema.halls h CROSS JOIN generate_series(1,6) r CROSS JOIN generate_series(1,5) s
WHERE h.name='Зал 1';
INSERT INTO cinema.movies(title,duration_minutes) VALUES ('Демо-фильм',110);
INSERT INTO cinema.screenings(hall_id,movie_id,starts_at,ends_at,status)
SELECT h.id,m.id,now()+interval '1 day',now()+interval '1 day 110 minutes','published'
FROM cinema.halls h CROSS JOIN cinema.movies m WHERE h.name='Зал 1' AND m.title='Демо-фильм';
COMMIT;
-- Query some seats and test hold/payment from an API transaction:
SELECT sc.id AS screening_id, count(ss.*) AS inventory_count
FROM cinema.screenings sc JOIN cinema.screening_seats ss ON ss.screening_id=sc.id
GROUP BY sc.id;
-- SELECT cinema.hold_seats(:screening_id, ARRAY[:seat_a, :seat_b]::uuid[], 'buyer@example.org');
-- SELECT cinema.confirm_payment(:order_id, 'verified-provider', 'provider-payment-id', 700, 'RUB');
-- SELECT cinema.expire_pending_orders();
