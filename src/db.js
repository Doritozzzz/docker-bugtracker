import pg from 'pg';
import { config } from './config.js';
import { log } from './logger.js';

const { Pool } = pg;

const pool = new Pool({
  host: config.db.host,
  port: config.db.port,
  database: config.db.database,
  user: config.db.user,
  password: config.db.password,
  max: 10,
  application_name: 'bugtracker-web',
  // Fail fast: without limits a ping can hang while PostgreSQL is unreachable.
  connectionTimeoutMillis: 2000,
  query_timeout: 2000,
});

// null = unknown yet, true = reachable, false = unreachable.
let dbAvailable = null;

// Logs only when the state changes, so a database that stays down does not
// flood the logs with one line per ping.
function recordAvailability(available, reason) {
  if (dbAvailable === available) return;
  dbAvailable = available;

  if (available) {
    log.info('database_available');
  } else {
    log.error('database_unavailable', { reason });
  }
}

// An idle connection that dies (e.g. PostgreSQL restarts) emits "error" on
// the pool. Without this listener Node would treat it as unhandled and crash.
// Every idle connection fails at once, so it goes through recordAvailability
// to produce a single log line instead of one per connection.
pool.on('error', (error) => {
  recordAvailability(false, error.message || error.code);
});

async function ping() {
  try {
    await pool.query('SELECT 1');
    recordAvailability(true);
    return true;
  } catch (error) {
    recordAvailability(false, error.message || error.code);
    return false;
  }
}

async function close() {
  await pool.end();
}

export { pool, ping, close };
