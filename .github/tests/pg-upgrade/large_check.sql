-- One line describing the large dataset: row counts, content hashes, a spatial query through
-- each GiST index and the GiST indexes present. Run on source and target; they must match.
\set ON_ERROR_STOP on
SET enable_seqscan = off;
SELECT concat_ws(' ',
  'places=' || (SELECT count(*) FROM gis.places),
  'parcels=' || (SELECT count(*) FROM gis.parcels),
  'roads=' || (SELECT count(*) FROM gis.roads),
  'observations=' || (SELECT count(*) FROM public.observations),
  'documents=' || (SELECT count(*) FROM public.documents),
  'largest_document=' || (SELECT max(octet_length(body)) FROM public.documents),
  'documents_md5=' || (SELECT md5(string_agg(md5(body), '' ORDER BY id)) FROM public.documents),
  'parcels_md5=' || (SELECT md5(string_agg(md5(ST_AsEWKB(geom)), '' ORDER BY id)) FROM gis.parcels),
  'observations_md5=' || (SELECT md5(string_agg(md5(o::text), '' ORDER BY id)) FROM public.observations o),
  'places_in_box=' || (SELECT count(*) FROM gis.places WHERE geom && ST_MakeEnvelope(1200000, 600000, 1400000, 900000, 3005)),
  'parcels_in_box=' || (SELECT count(*) FROM gis.parcels WHERE geom && ST_MakeEnvelope(1200000, 600000, 1400000, 900000, 3005)),
  'roads_crossing=' || (SELECT count(*) FROM gis.roads WHERE ST_Intersects(geom, ST_MakeEnvelope(1200000, 600000, 1210000, 610000, 3005))),
  'gist_indexes=' || (SELECT count(*) FROM pg_indexes WHERE schemaname = 'gis' AND indexdef LIKE '%USING gist%'));
