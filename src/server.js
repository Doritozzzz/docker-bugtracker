import express from 'express';
import path from 'node:path';
import { log } from './logger.js';

// config.js validates the environment as soon as it is imported, so it is
// loaded dynamically to report a configuration error as one clean log line.
let loaded;
try {
  loaded = await import('./config.js');
} catch (error) {
  log.error('configuration_error', { reason: error.message });
  process.exit(1);
}
const { config, describeConfig } = loaded;

// These modules read the configuration when they are imported, so they are
// loaded only after it has been validated.
const db = await import('./db.js');
const cache = await import('./cache.js');
const { default: router } = await import('./routes.js');

const DB_UNAVAILABLE_CODES = new Set([
  'ECONNREFUSED',
  'ENOTFOUND',
  'ETIMEDOUT',
  'ECONNRESET',
  'EAI_AGAIN',
  '57P01',
  '57P03',
]);

// True when the error means PostgreSQL cannot be reached (down, restarting or
// too slow), as opposed to a bug or a bad query.
function isDatabaseUnavailable(error) {
  return DB_UNAVAILABLE_CODES.has(error.code) || /timeout|terminated/i.test(error.message);
}

const app = express();
app.disable('x-powered-by');

// Basic security headers for every response.
app.use((req, res, next) => {
  res.set({
    'Content-Security-Policy': "default-src 'self'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  next();
});

// One line per request at debug level (shown in dev, hidden in prod). The
// status endpoints are skipped: they are polled every few seconds and would
// bury the rest of the log.
const QUIET_PATHS = new Set(['/live', '/status']);

app.use((req, res, next) => {
  if (QUIET_PATHS.has(req.path)) return next();
  const start = performance.now();
  res.on('finish', () => {
    log.debug('request', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: Number((performance.now() - start).toFixed(2)),
    });
  });
  next();
});

// API responses must never be reused by the browser, otherwise it would hide
// the real HIT and MISS behaviour of the server-side cache.
app.use('/api', (req, res, next) => {
  res.set('Cache-Control', 'no-store');
  next();
});

app.use(express.json({ limit: '10kb' }));
app.use(router);
app.use(express.static(path.join(import.meta.dirname, 'public')));

app.use((req, res) => {
  res.status(404).json({ error: 'not_found' });
});

// Last-resort error handler. Express 5 forwards errors from async handlers here.
app.use((error, req, res, next) => {
  if (res.headersSent) return next(error);

  // Malformed or oversized JSON bodies are the client's mistake.
  if (error.status >= 400 && error.status < 500) {
    return res.status(error.status).json({ error: error.type ?? 'bad_request' });
  }

  // db.js already logs the outage once, so it is not logged per request.
  if (isDatabaseUnavailable(error)) {
    return res.status(503).json({ error: 'database_unavailable' });
  }

  log.error('request_failed', { method: req.method, path: req.path, reason: error.message });
  res.status(500).json({ error: 'internal_error' });
});

const server = app.listen(config.port, (error) => {
  if (error) {
    log.error('listen_failed', { reason: error.message });
    process.exit(1);
  }
  log.info('server_started', { port: config.port, config: describeConfig() });
});

let shuttingDown = false;

// Stops accepting requests, closes the connections to PostgreSQL and Redis and
// exits. The timer forces the exit before Docker's 10 s grace period ends.
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info('shutdown_started', { signal });

  setTimeout(() => {
    log.error('shutdown_timeout');
    process.exit(1);
  }, 8000).unref();

  server.close(async () => {
    try {
      await cache.close();
      await db.close();
      log.info('shutdown_complete');
      process.exit(0);
    } catch (error) {
      log.error('shutdown_failed', { reason: error.message });
      process.exit(1);
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
