-- PostgreSQL 16+. Execute in an empty database.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS cinema;
SET search_path TO cinema, public;

CREATE TYPE user_role AS ENUM ('customer','admin');
CREATE TYPE screening_status AS ENUM ('draft','published','cancelled','finished');
CREATE TYPE seat_type AS ENUM ('standard','premium','sofa','accessible');
CREATE TYPE inventory_status AS ENUM ('available','held','sold','blocked');
CREATE TYPE order_status AS ENUM ('pending','paid','cancelled','expired','refunded');
CREATE TYPE payment_status AS ENUM ('created','succeeded','failed','refunded');

CREATE TABLE users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 email text NOT NULL UNIQUE,
 password_hash text,
 display_name text,
 role user_role NOT NULL DEFAULT 'customer',
 created_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT email_not_blank CHECK (length(trim(email)) > 3)
);

CREATE TABLE cinemas (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL,
 city text NOT NULL,
 address text NOT NULL,
 timezone text NOT NULL DEFAULT 'Europe/Moscow',
 is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE halls (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cinema_id uuid NOT NULL REFERENCES cinemas(id) ON DELETE RESTRICT,
 name text NOT NULL,
 screen_width_m numeric(7,2) NOT NULL CHECK (screen_width_m > 0),
 screen_height_m numeric(7,2) NOT NULL CHECK (screen_height_m > 0),
 -- URL/asset key points to an external 3D model, not raw geometry in the DB.
 scene_asset_url text,
 screen_x numeric(9,3) NOT NULL DEFAULT 0,
 screen_y numeric(9,3) NOT NULL DEFAULT 0,
 screen_z numeric(9,3) NOT NULL DEFAULT 0,
 is_active boolean NOT NULL DEFAULT true,
 UNIQUE (cinema_id,name),
 UNIQUE (id,cinema_id)
);

CREATE TABLE seats (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 hall_id uuid NOT NULL REFERENCES halls(id) ON DELETE RESTRICT,
 row_number int NOT NULL CHECK (row_number > 0),
 seat_number int NOT NULL CHECK (seat_number > 0),
 seat_type seat_type NOT NULL DEFAULT 'standard',
 -- World position in meters. Renderer computes eye pose from these parameters.
 pos_x numeric(9,3) NOT NULL,
 pos_y numeric(9,3) NOT NULL,
 pos_z numeric(9,3) NOT NULL,
 eye_height_m numeric(5,3) NOT NULL DEFAULT 1.150 CHECK (eye_height_m > 0),
 view_yaw_deg numeric(7,3) NOT NULL DEFAULT 0,
 view_pitch_deg numeric(7,3) NOT NULL DEFAULT 0,
 view_fov_deg numeric(6,2) NOT NULL DEFAULT 75 CHECK (view_fov_deg BETWEEN 20 AND 150),
 preview_asset_url text,
 is_active boolean NOT NULL DEFAULT true,
 UNIQUE (hall_id,row_number,seat_number),
 UNIQUE (hall_id,id)
);
CREATE INDEX seats_hall_row_idx ON seats(hall_id,row_number,seat_number);

CREATE TABLE movies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 title text NOT NULL,
 synopsis text,
 duration_minutes int NOT NULL CHECK (duration_minutes > 0),
 age_rating text,
 poster_url text,
 is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE screenings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 hall_id uuid NOT NULL REFERENCES halls(id) ON DELETE RESTRICT,
 movie_id uuid NOT NULL REFERENCES movies(id) ON DELETE RESTRICT,
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL,
 status screening_status NOT NULL DEFAULT 'draft',
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_at > starts_at),
 UNIQUE (id,hall_id),
 -- Prevent overlapping published sessions in the same hall.
 CONSTRAINT no_overlapping_published_screenings EXCLUDE USING gist (
   hall_id WITH =,
   tstzrange(starts_at,ends_at,'[)') WITH &&
 ) WHERE (status = 'published')
);
CREATE INDEX screenings_movie_date_idx ON screenings(movie_id,starts_at);
CREATE INDEX screenings_hall_date_idx ON screenings(hall_id,starts_at);

CREATE TABLE orders (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid REFERENCES users(id) ON DELETE SET NULL,
 customer_email text NOT NULL,
 status order_status NOT NULL DEFAULT 'pending',
 expires_at timestamptz,
 total_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
 currency char(3) NOT NULL DEFAULT 'RUB',
 created_at timestamptz NOT NULL DEFAULT now(),
 paid_at timestamptz,
 client_idempotency_key text UNIQUE,
 CONSTRAINT pending_order_has_expiry CHECK (status <> 'pending' OR expires_at IS NOT NULL)
);
CREATE INDEX orders_expiring_idx ON orders(expires_at) WHERE status='pending';

-- The inventory is materialized once when a screening is published.
-- A row can belong to only one seat and one screening, and its hall must match both.
CREATE TABLE screening_seats (
 screening_id uuid NOT NULL,
 hall_id uuid NOT NULL,
 seat_id uuid NOT NULL,
 price numeric(12,2) NOT NULL CHECK (price >= 0),
 currency char(3) NOT NULL DEFAULT 'RUB',
 status inventory_status NOT NULL DEFAULT 'available',
 order_id uuid REFERENCES orders(id) ON DELETE RESTRICT,
 held_until timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (screening_id,seat_id),
 FOREIGN KEY (screening_id,hall_id) REFERENCES screenings(id,hall_id) ON DELETE RESTRICT,
 FOREIGN KEY (hall_id,seat_id) REFERENCES seats(hall_id,id) ON DELETE RESTRICT,
 CHECK (
    (status IN ('available','blocked') AND order_id IS NULL AND held_until IS NULL)
 OR (status = 'held' AND order_id IS NOT NULL AND held_until IS NOT NULL)
 OR (status = 'sold' AND order_id IS NOT NULL AND held_until IS NULL)
 )
);
CREATE INDEX screening_seats_by_screening_status_idx ON screening_seats(screening_id,status);
CREATE INDEX screening_seats_order_idx ON screening_seats(order_id) WHERE order_id IS NOT NULL;
CREATE INDEX screening_seats_held_until_idx ON screening_seats(held_until) WHERE status='held';

CREATE TABLE payments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
 provider text NOT NULL,
 provider_payment_id text,
 status payment_status NOT NULL DEFAULT 'created',
 amount numeric(12,2) NOT NULL CHECK (amount >= 0),
 currency char(3) NOT NULL DEFAULT 'RUB',
 created_at timestamptz NOT NULL DEFAULT now(),
 completed_at timestamptz,
 UNIQUE (provider,provider_payment_id)
);
CREATE INDEX payments_order_idx ON payments(order_id);

CREATE TABLE tickets (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
 screening_id uuid NOT NULL,
 seat_id uuid NOT NULL,
 code uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
 issued_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 UNIQUE (screening_id,seat_id),
 FOREIGN KEY (screening_id,seat_id) REFERENCES screening_seats(screening_id,seat_id) ON DELETE RESTRICT
);
CREATE INDEX tickets_order_idx ON tickets(order_id);

COMMENT ON TABLE screening_seats IS 'Single source of truth for seat availability on each screening; changes must be transactional.';
COMMENT ON COLUMN seats.preview_asset_url IS 'Optional pre-rendered view; otherwise render scene_asset_url with camera pose.';
COMMIT;
