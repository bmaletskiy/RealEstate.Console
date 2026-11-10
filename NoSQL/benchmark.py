"""RealEstate: same client, same Docker network, logically equivalent operations.

Requirements: psycopg[binary] and pymongo. Expected running containers:
realestate-postgres, realestate-mongo, connected to Docker network
realestate-bench. The script writes /app/results/{summary.csv,benchmark_results.csv}.

For this lab, run using the original run_bench.ps1 + Dockerfile runner, or:
  docker run --rm --network realestate-bench -v "${PWD}:/app" -w /app \
    python:3.12-slim sh -c "pip install 'psycopg[binary]' pymongo && python benchmark.py"
(When using the Docker image above, initialize the network first and connect
both database containers.)
"""
import csv
import os
import statistics
import time
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

import psycopg
from pymongo import MongoClient

ROUNDS = int(os.getenv('BENCH_ROUNDS', '3'))
READ_OPS = int(os.getenv('BENCH_READ_OPS', '500'))
WRITE_OPS = int(os.getenv('BENCH_WRITE_OPS', '100'))
WARMUP_OPS = 100

PG_DSN = 'host=realestate-postgres port=5432 dbname=RealestateDb user=postgres password=postgres'
PG_DETAIL = """
SELECT p.id, p.type_name, p.address, p.area, p.description,
  (SELECT json_agg(json_build_object('url', ph.url) ORDER BY ph.url)
   FROM benchmark.property_photos ph WHERE ph.property_id = p.id) AS photos,
  (SELECT json_agg(pa.amenity_name ORDER BY pa.amenity_name)
   FROM benchmark.property_amenities pa WHERE pa.property_id = p.id) AS amenities
FROM benchmark.properties p
WHERE p.id = %s
"""
PG_RANGE = """
SELECT p.id, p.type_name, p.address, p.area, p.description,
  (SELECT json_agg(json_build_object('url', ph.url) ORDER BY ph.url)
   FROM benchmark.property_photos ph WHERE ph.property_id = p.id) AS photos,
  (SELECT json_agg(pa.amenity_name ORDER BY pa.amenity_name)
   FROM benchmark.property_amenities pa WHERE pa.property_id = p.id) AS amenities
FROM benchmark.properties p
WHERE p.id BETWEEN %s AND %s ORDER BY p.id
"""
PG_FILTER = """
SELECT p.id, p.type_name, p.address, p.area, p.description,
  (SELECT json_agg(json_build_object('url', ph.url) ORDER BY ph.url)
   FROM benchmark.property_photos ph WHERE ph.property_id = p.id) AS photos,
  (SELECT json_agg(pa.amenity_name ORDER BY pa.amenity_name)
   FROM benchmark.property_amenities pa WHERE pa.property_id = p.id) AS amenities
FROM benchmark.properties p
WHERE p.type_name = 'Apartment' AND p.area BETWEEN 50 AND 100
ORDER BY p.id LIMIT 50
"""
PG_INSERT = """
WITH property AS (
 INSERT INTO benchmark.properties (id, type_name, address, area, description)
 VALUES (%s, 'Apartment', %s, 65, %s) RETURNING id
), photos AS (
 INSERT INTO benchmark.property_photos(property_id, url)
 SELECT property.id, 'https://example.com/photos/' || property.id || '/' || n || '.jpg'
 FROM property CROSS JOIN generate_series(1,5) AS n RETURNING id
), amenities AS (
 INSERT INTO benchmark.property_amenities(property_id, amenity_name)
 SELECT property.id, 'Amenity ' || n
 FROM property CROSS JOIN generate_series(1,6) AS n RETURNING property_id
)
SELECT (SELECT count(*) FROM photos), (SELECT count(*) FROM amenities)
"""


def mongo_document(property_id, address, description):
    return {
        'property_id': property_id, 'type_name': 'Apartment',
        'address': address, 'area': 65, 'description': description,
        'photos': [{'url': f'https://example.com/photos/{property_id}/{n}.jpg'} for n in range(1, 6)],
        'amenities': [f'Amenity {n}' for n in range(1, 7)],
    }


def percentile(values, p):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, int((len(ordered) - 1) * p + .999999)))]


def main():
    if ROUNDS < 1 or READ_OPS < 1 or WRITE_OPS < 1:
        raise ValueError('Rounds and operation counts must be positive')

    pg = psycopg.connect(PG_DSN, autocommit=True)
    mongo = MongoClient('mongodb://realestate-mongo:27017/', serverSelectionTimeoutMS=10000)
    mongo.admin.command('ping')
    collection = mongo['RealEstateNoSql']['properties']

    with pg.cursor() as cur:
        cur.execute('SELECT count(*) FROM benchmark.properties WHERE id BETWEEN 1 AND 100000')
        pg_count = cur.fetchone()[0]
        cur.execute('CREATE INDEX IF NOT EXISTS idx_bench_property_type_area ON benchmark.properties(type_name, area)')
        cur.execute('SELECT COALESCE(max(id), 0) FROM benchmark.properties')
        pg_max_id = cur.fetchone()[0]
    mongo_count = collection.count_documents({'property_id': {'$gte': 1, '$lte': 100000}})
    if pg_count != 100000 or mongo_count != 100000:
        raise RuntimeError(f'Expected 100000 baseline properties in both DBs; PG={pg_count}, Mongo={mongo_count}')
    collection.create_index([('property_id', 1)], unique=True)
    collection.create_index([('type_name', 1), ('area', 1)])

    # Verify equivalent core data, 5 photos and 6 amenities before benchmarking.
    with pg.cursor() as cur:
        cur.execute(PG_DETAIL, (50000,))
        pg_row = cur.fetchone()
    md = collection.find_one({'property_id': 50000})
    assert pg_row and md, 'Missing id=50000'
    assert (pg_row[1], pg_row[2], float(pg_row[3]), pg_row[4]) == (md['type_name'], md['address'], md['area'], md['description'])
    assert [v['url'] for v in pg_row[5]] == sorted(v['url'] for v in md['photos'])
    assert pg_row[6] == sorted(md['amenities'])

    top_doc = collection.find_one({}, {'property_id': 1}, sort=[('property_id', -1)])
    mongo_max_id = top_doc['property_id'] if top_doc else 0
    base = max(2_000_000, pg_max_id, mongo_max_id) + 1
    samples = []

    def test_one(db_kind, op, i, cur):
        if op == 'read_one':
            pid = 1 + ((i * 7919) % 100000)
            if db_kind == 'PostgreSQL':
                cur.execute(PG_DETAIL, (pid,))
                result = cur.fetchone()
                assert result is not None
            else:
                assert collection.find_one({'property_id': pid}) is not None
        elif op == 'read_50':
            start = 1 + ((i * 7919) % 99951)
            if db_kind == 'PostgreSQL':
                cur.execute(PG_RANGE, (start, start + 49))
                result = cur.fetchall()
            else:
                result = list(collection.find({'property_id': {'$gte': start, '$lte': start + 49}}).sort('property_id', 1))
            assert len(result) == 50
        elif op == 'filter_50':
            if db_kind == 'PostgreSQL':
                cur.execute(PG_FILTER)
                result = cur.fetchall()
            else:
                result = list(collection.find({'type_name': 'Apartment', 'area': {'$gte': 50, '$lte': 100}}).sort('property_id', 1).limit(50))
            assert len(result) == 50
        elif op == 'update':
            pid = 40000 + (i % 1000)
            value = f'Benchmark updated {i}'
            if db_kind == 'PostgreSQL':
                cur.execute('UPDATE benchmark.properties SET description = %s WHERE id = %s', (value, pid))
                assert cur.rowcount == 1
            else:
                assert collection.update_one({'property_id': pid}, {'$set': {'description': value}}).matched_count == 1
        elif op == 'insert':
            # Each DB receives the same ID and identical record contents.
            pid = base + i
            address, description = f'Benchmark address {pid}', f'Benchmark new {pid}'
            if db_kind == 'PostgreSQL':
                cur.execute(PG_INSERT, (pid, address, description))
                assert cur.fetchone() == (5, 6)
            else:
                collection.insert_one(mongo_document(pid, address, description))
        else:
            raise ValueError(op)

    ops = [('read_one', READ_OPS), ('read_50', READ_OPS), ('filter_50', READ_OPS),
           ('update', WRITE_OPS), ('insert', WRITE_OPS)]
    # Alternating DB order between rounds reduces systematic order bias.
    for op_index, (op, iterations) in enumerate(ops):
        print(f'\n{op}: {iterations} timed operations per DB per round')
        for round_no in range(ROUNDS):
            db_order = ['PostgreSQL', 'MongoDB'] if round_no % 2 == 0 else ['MongoDB', 'PostgreSQL']
            for db_kind in db_order:
                with pg.cursor() as cur:
                    if op != 'insert':
                        for j in range(WARMUP_OPS):
                            # Warmup updates are deterministic; insert is excluded to avoid ID conflicts.
                            test_one(db_kind, op, 100000 + j, cur)
                    latencies = []
                    for j in range(iterations):
                        idx = round_no * iterations + j
                        t0 = time.perf_counter_ns()
                        test_one(db_kind, op, idx, cur)
                        latencies.append((time.perf_counter_ns() - t0) / 1_000_000)
                    for j, ms in enumerate(latencies):
                        samples.append({'operation': op, 'round': round_no + 1,
                                        'database': db_kind, 'sample': j + 1, 'latency_ms': round(ms, 6)})
                print(f'  Round {round_no + 1}: {db_kind}: median={statistics.median(latencies):.3f} ms, p95={percentile(latencies, .95):.3f} ms')

    out = Path('/app/results')
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'benchmark_results.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, ['operation', 'round', 'database', 'sample', 'latency_ms'])
        writer.writeheader()
        writer.writerows(samples)

    groups = defaultdict(list)
    for row in samples:
        groups[(row['operation'], row['database'])].append(row['latency_ms'])
    with (out / 'summary.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['operation', 'database', 'samples', 'median_ms', 'p95_ms', 'mean_ms'])
        for (op, db_kind), vals in groups.items():
            writer.writerow([op, db_kind, len(vals), round(statistics.median(vals), 6),
                             round(percentile(vals, .95), 6), round(statistics.mean(vals), 6)])

    # Verify inserted data counts in both DBs.
    inserted_total = ROUNDS * WRITE_OPS
    with pg.cursor() as cur:
        cur.execute('SELECT count(*) FROM benchmark.properties WHERE id >= %s AND id < %s', (base, base + inserted_total))
        assert cur.fetchone()[0] == inserted_total
    assert collection.count_documents({'property_id': {'$gte': base, '$lt': base + inserted_total}}) == inserted_total
    print('\nSUCCESS. CSV files: results/benchmark_results.csv and results/summary.csv')
    mongo.close()
    pg.close()


if __name__ == '__main__':
    main()
