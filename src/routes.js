import { Router } from 'express';
import { config } from './config.js';
import * as cache from './cache.js';
import * as db from './db.js';

const router = Router();

const elapsedMs = (start) => Number((performance.now() - start).toFixed(2));

// Liveness: only reports that the process is running. It never touches the
// database or the cache, so a dependency outage cannot make Docker mark the
// web container as unhealthy or restart it.
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

router.get(['/status', '/health'], statusHandler);

const LIST_KEY = 'incidents:list';
const LIST_LIMIT = 20;
const COLUMNS = 'id, title, system_name, priority, status, created_at, updated_at';

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

async function loadIncidents() {
  const { rows } = await db.pool.query(
    `SELECT ${COLUMNS} FROM incidents ORDER BY created_at DESC LIMIT $1`,
    [LIST_LIMIT],
  );
  return rows;
}

// Latest incidents. The headers make the cache behaviour visible from curl.
router.get('/api/incidents', async (req, res) => {
  const result = await readThrough(LIST_KEY, loadIncidents);
  res.set('X-Cache', result.cache);
  res.set('X-Response-Time', `${result.durationMs}ms`);
  res.json({
    data: result.data,
    meta: { source: result.source, cache: result.cache, durationMs: result.durationMs },
  });
});

export default router;
