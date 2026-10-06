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

export default router;
