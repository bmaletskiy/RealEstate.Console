
CREATE SCHEMA IF NOT EXISTS benchmark;

CREATE TABLE IF NOT EXISTS benchmark.properties (
    id BIGINT PRIMARY KEY,
    type_name TEXT NOT NULL,
    address TEXT NOT NULL,
    area NUMERIC(10,2) NOT NULL,
    description TEXT
);

CREATE TABLE IF NOT EXISTS benchmark.property_photos (
    id BIGSERIAL PRIMARY KEY,
    property_id BIGINT NOT NULL REFERENCES benchmark.properties(id),
    url TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS benchmark.property_amenities (
    property_id BIGINT NOT NULL REFERENCES benchmark.properties(id),
    amenity_name TEXT NOT NULL,
    PRIMARY KEY (property_id, amenity_name)
);

CREATE INDEX IF NOT EXISTS idx_benchmark_photos_property
    ON benchmark.property_photos(property_id);
CREATE INDEX IF NOT EXISTS idx_bench_property_type_area
    ON benchmark.properties(type_name, area);

TRUNCATE benchmark.property_photos, benchmark.property_amenities,
         benchmark.properties RESTART IDENTITY;

INSERT INTO benchmark.properties (id, type_name, address, area, description)
SELECT i,
       CASE i % 3 WHEN 0 THEN 'Apartment' WHEN 1 THEN 'House' ELSE 'Commercial' END,
       'Address ' || i,
       30 + (i % 200),
       'Property description ' || i
FROM generate_series(1, 100000) AS i;

INSERT INTO benchmark.property_photos (property_id, url)
SELECT p.id, 'https://example.com/photos/' || p.id || '/' || n || '.jpg'
FROM benchmark.properties p CROSS JOIN generate_series(1, 5) AS n;

INSERT INTO benchmark.property_amenities (property_id, amenity_name)
SELECT p.id, 'Amenity ' || n
FROM benchmark.properties p CROSS JOIN generate_series(1, 6) AS n;

ANALYZE benchmark.properties;
ANALYZE benchmark.property_photos;
ANALYZE benchmark.property_amenities;


SELECT p.id, p.type_name, p.address, p.area, p.description,
       (SELECT json_agg(json_build_object('url', ph.url) ORDER BY ph.url)
          FROM benchmark.property_photos ph WHERE ph.property_id = p.id) AS photos,
       (SELECT json_agg(pa.amenity_name ORDER BY pa.amenity_name)
          FROM benchmark.property_amenities pa WHERE pa.property_id = p.id) AS amenities
FROM benchmark.properties p WHERE p.id = 50000;

SELECT (SELECT count(*) FROM benchmark.properties) AS properties,
       (SELECT count(*) FROM benchmark.property_photos) AS photos,
       (SELECT count(*) FROM benchmark.property_amenities) AS amenities;
