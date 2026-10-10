import { Router } from 'express';
import { config } from './config.js';
import * as cache from './cache.js';
import * as db from './db.js';

const router = Router();

const INCIDENTS_KEY = 'incidents';
const LIST_LIMIT = 20;
const COLUMNS = 'id, title, system_name, priority, status, created_at, updated_at';

const elapsedMs = (start) => Number((performance.now() - start).toFixed(2));

// Liveness: only reports that the process is running. It never touches the
// database or the cache, so a dependency outage cannot make the web container
// look unhealthy.
router.get('/live', (req, res) => {
  res.type('text/plain').send('ok');
});

// Runs a health check and measures how long it takes.
async function probe(check) {
  const start = performance.now();
  const up = await check();
  return { up, latencyMs: elapsedMs(start) };
}

// Status: reports the state of the dependencies. Both checks run in parallel,
// so the response time is bounded by the slowest one (2 s timeout each).
async function statusHandler(req, res) {
  const [database, redis] = await Promise.all([
    probe(db.ping),
    cache.enabled ? probe(cache.ping) : null,
  ]);

  const services = {
    database: {
      type: 'PostgreSQL',
      status: database.up ? 'up' : 'down',
      latencyMs: database.latencyMs,
    },
    cache: redis
      ? { type: 'Redis', status: redis.up ? 'up' : 'down', latencyMs: redis.latencyMs }
      : { type: 'Redis', status: 'disabled' },
  };

  const degraded = !database.up || (redis !== null && !redis.up);

  res.set('Cache-Control', 'no-store');
  // Without the database the application cannot work (503). Without the cache
  // it still works, reading from the database, so it answers 200 as "degraded".
  res.status(database.up ? 200 : 503).json({
    status: degraded ? 'degraded' : 'ok',
    environment: config.env,
    uptimeSeconds: Math.round(process.uptime()),
    timestamp: new Date().toISOString(),
    services,
  });
}

router.get('/status', statusHandler);
router.get('/health', statusHandler);

// Cache-aside read: tries Redis first and falls back to PostgreSQL on a miss
// or when the cache is down, storing the result for the next request.
async function readThrough(key, load) {
  const start = performance.now();

  const cached = await cache.get(key);
  if (cached !== null) {
    return { data: cached, source: 'cache', cache: 'HIT', durationMs: elapsedMs(start) };
  }

  const data = await load();
  const durationMs = elapsedMs(start);
  await cache.set(key, data);
  return {
    data,
    source: 'database',
    cache: cache.enabled ? 'MISS' : 'DISABLED',
    durationMs,
  };
}

// Loads the latest incidents and the totals per status. The totals query scans
// the whole table, which is the cost the cache avoids on later requests. Both
// queries run in parallel.
async function loadIncidents() {
  const [list, counts] = await Promise.all([
    db.pool.query(
      `SELECT ${COLUMNS} FROM incidents ORDER BY created_at DESC LIMIT $1`,
      [LIST_LIMIT],
    ),
    db.pool.query('SELECT status, count(*)::int AS count FROM incidents GROUP BY status'),
  ]);

  const stats = { total: 0, byStatus: { OPEN: 0, IN_PROGRESS: 0, RESOLVED: 0 } };
  for (const row of counts.rows) {
    stats.byStatus[row.status] = row.count;
    stats.total += row.count;
  }
  return { incidents: list.rows, stats };
}

// Latest incidents plus totals. The headers make the cache behaviour visible
// from curl.
router.get('/api/incidents', async (req, res) => {
  const result = await readThrough(INCIDENTS_KEY, loadIncidents);
  res.set('X-Cache', result.cache);
  res.set('X-Response-Time', `${result.durationMs}ms`);
  res.json({
    data: result.data,
    meta: { source: result.source, cache: result.cache, durationMs: result.durationMs },
  });
});

const PRIORITIES = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];

// Validates the body of a new incident and returns the cleaned fields
// together with the list of validation errors.
function validateNewIncident(body) {
  const errors = [];

  const text = (field, max) => {
    const value = typeof body?.[field] === 'string' ? body[field].trim() : '';
    if (value.length === 0 || value.length > max) {
      errors.push(`${field} must be between 1 and ${max} characters`);
    }
    return value;
  };

  const title = text('title', 150);
  const systemName = text('system_name', 100);
  const priority = body?.priority;
  if (!PRIORITIES.includes(priority)) {
    errors.push(`priority must be one of ${PRIORITIES.join(', ')}`);
  }

  return { errors, title, systemName, priority };
}

// Creates an incident. The cache entry is dropped only after the insert has
// committed; if Redis is down the entry simply expires on its own.
router.post('/api/incidents', async (req, res) => {
  const { errors, title, systemName, priority } = validateNewIncident(req.body);
  if (errors.length > 0) {
    return res.status(400).json({ error: 'validation_failed', details: errors });
  }

  const { rows } = await db.pool.query(
    `INSERT INTO incidents (title, system_name, priority)
     VALUES ($1, $2, $3) RETURNING ${COLUMNS}`,
    [title, systemName, priority],
  );
  await cache.del(INCIDENTS_KEY);
  res.status(201).json({ data: rows[0] });
});

export default router;
