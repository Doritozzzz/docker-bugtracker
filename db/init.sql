-- Schema and seed data for the incident tracker.
-- The postgres image runs this file only on the FIRST start, when the data
-- volume is empty. Later restarts keep the existing data untouched.

CREATE TABLE incidents (
    id          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       VARCHAR(150) NOT NULL,
    system_name VARCHAR(100) NOT NULL,
    priority    VARCHAR(10)  NOT NULL
                CHECK (priority IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    status      VARCHAR(12)  NOT NULL DEFAULT 'OPEN'
                CHECK (status IN ('OPEN', 'IN_PROGRESS', 'RESOLVED')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Serves "latest incidents" without sorting the whole table.
CREATE INDEX incidents_created_at_idx ON incidents (created_at DESC);

-- Recent, human-readable incidents (shown first in the UI).
INSERT INTO incidents (title, system_name, priority, status, created_at, updated_at)
SELECT title, system_name, priority, status, now() - ago, now() - ago
FROM (VALUES
    ('Elevated latency on payment gateway',   'api-gateway-01', 'HIGH',     'OPEN',        interval '5 minutes'),
    ('TLS certificate expires in 7 days',     'auth-service',   'MEDIUM',   'IN_PROGRESS', interval '20 minutes'),
    ('Disk I/O saturation on primary DB',     'db-primary',     'CRITICAL', 'OPEN',        interval '45 minutes'),
    ('NTP clock drift on edge router',        'edge-router-b',  'LOW',      'RESOLVED',    interval '2 hours'),
    ('Cache hit ratio below threshold',       'cache-cluster',  'MEDIUM',   'OPEN',        interval '3 hours'),
    ('Worker queue backlog is growing',       'worker-queue',   'HIGH',     'IN_PROGRESS', interval '5 hours')
) AS recent (title, system_name, priority, status, ago);

-- 50,000 historical incidents, generated deterministically (no random()).
-- Repeated array values weight the distribution (mostly LOW and RESOLVED).
-- This volume makes the aggregate in /api/stats expensive enough for the
-- Redis cache to make a measurable difference.
INSERT INTO incidents (title, system_name, priority, status, created_at, updated_at)
SELECT title, system_name, priority, status, ts, ts
FROM (
    SELECT
        (ARRAY['Elevated latency', 'Disk I/O saturation', 'TLS certificate expiring',
               'Memory leak detected', 'Failed health check', 'Connection pool exhausted',
               'Replication lag', 'Unexpected restart'])[1 + g % 8]         AS title,
        (ARRAY['api-gateway', 'auth-service', 'payments-api', 'db-primary',
               'cache-cluster', 'worker-queue', 'edge-proxy', 'metrics-collector'])[1 + (g / 8) % 8] AS system_name,
        (ARRAY['LOW', 'LOW', 'LOW', 'LOW', 'MEDIUM', 'MEDIUM', 'MEDIUM',
               'HIGH', 'HIGH', 'CRITICAL'])[1 + g % 10]                     AS priority,
        (ARRAY['RESOLVED', 'RESOLVED', 'RESOLVED', 'RESOLVED', 'RESOLVED',
               'RESOLVED', 'RESOLVED', 'RESOLVED', 'IN_PROGRESS', 'OPEN'])[1 + (g / 10) % 10] AS status,
        now() - interval '1 day' - g * interval '10 minutes'                AS ts
    FROM generate_series(1, 50000) AS g
) AS seed;

-- Refresh planner statistics after the bulk load.
ANALYZE incidents;
