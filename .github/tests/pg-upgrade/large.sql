-- Large, PostGIS-heavy dataset for the pg-upgrade cluster test. psql -v scale=<n>; scale 1 is
-- about 400 MB: points, polygons and lines with GiST indexes, a wide fact table with a foreign
-- key, and ~512 KB values that don't compress (TOAST).
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA gis;

CREATE TABLE gis.places (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  kind text NOT NULL,
  geom geometry(Point, 3005) NOT NULL
);
INSERT INTO gis.places (name, kind, geom)
SELECT 'place ' || g, (ARRAY['lake', 'peak', 'town', 'camp'])[1 + g % 4],
  ST_SetSRID(ST_MakePoint(1000000 + (g * 7919) % 900000, 400000 + (g * 104729) % 1200000), 3005)
FROM generate_series(1::bigint, 400000 * :scale) g;
CREATE INDEX places_geom ON gis.places USING gist (geom);

CREATE TABLE gis.parcels (
  id bigserial PRIMARY KEY,
  pid text UNIQUE NOT NULL,
  area_m2 double precision,
  geom geometry(Polygon, 3005) NOT NULL
);
INSERT INTO gis.parcels (pid, geom)
SELECT lpad(g::text, 9, '0'),
  ST_Buffer(ST_SetSRID(ST_MakePoint(1000000 + (g * 15485863) % 900000, 400000 + (g * 32452843) % 1200000), 3005), 20 + g % 80, 4)
FROM generate_series(1::bigint, 100000 * :scale) g;
UPDATE gis.parcels SET area_m2 = ST_Area(geom);
CREATE INDEX parcels_geom ON gis.parcels USING gist (geom);

CREATE TABLE gis.roads (
  id bigserial PRIMARY KEY,
  class smallint NOT NULL,
  geom geometry(LineString, 3005) NOT NULL
);
INSERT INTO gis.roads (class, geom)
SELECT 1 + g % 5, ST_MakeLine(ARRAY(
  SELECT ST_SetSRID(ST_MakePoint(1000000 + (g * 7919 + v * 97) % 900000, 400000 + (g * 104729 + v * 89) % 1200000), 3005)
  FROM generate_series(0, 9) v))
FROM generate_series(1::bigint, 100000 * :scale) g;
CREATE INDEX roads_geom ON gis.roads USING gist (geom);

CREATE TABLE public.observations (
  id bigserial PRIMARY KEY,
  place_id bigint NOT NULL REFERENCES gis.places (id),
  observed_at timestamptz NOT NULL,
  value numeric(12, 3),
  tags jsonb
);
INSERT INTO public.observations (place_id, observed_at, value, tags)
SELECT 1 + g % (400000 * :scale), timestamptz '2020-01-01' + g * interval '1 minute', (g % 100000) / 7.0,
  jsonb_build_object('src', 'sensor-' || g % 50, 'ok', g % 9 <> 0)
FROM generate_series(1::bigint, 1000000 * :scale) g;
CREATE INDEX observations_place ON public.observations (place_id);

CREATE TABLE public.documents (
  id serial PRIMARY KEY,
  place_id bigint REFERENCES gis.places (id),
  body text NOT NULL
);
INSERT INTO public.documents (place_id, body)
SELECT g, (SELECT string_agg(md5(g::text || ':' || i || ':' || random()), '') FROM generate_series(1, 16384) i)
FROM generate_series(1::bigint, 200 * :scale) g;

-- Same shape as the small test, which the workflow uses to check writes
CREATE TABLE public.flyway_schema_history (installed_rank int PRIMARY KEY, version int);
INSERT INTO public.flyway_schema_history VALUES (1, 1), (2, 2);

ANALYZE;
SELECT pg_size_pretty(pg_database_size(current_database())) AS seeded_size;
