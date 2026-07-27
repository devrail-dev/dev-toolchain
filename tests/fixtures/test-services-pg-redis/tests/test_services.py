import os

import psycopg2
import redis


def test_postgres_is_reachable_and_queryable():
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
            assert cur.fetchone() == (1,)
    finally:
        conn.close()


def test_redis_is_reachable_and_usable():
    client = redis.from_url(os.environ["REDIS_URL"])
    client.set("story-15-4", "works")
    assert client.get("story-15-4") == b"works"
