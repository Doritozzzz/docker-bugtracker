import Redis from 'ioredis';
import { config } from './config.js';
import { log } from './logger.js';

const settings = config.cache;
const enabled = settings.enabled;

// In dev there is no Redis: the client is never created, so nothing tries
// to connect and every function below becomes a harmless no-op.
const client = enabled
  ? new Redis({
      host: settings.host,
      port: settings.port,
      password: settings.password,
      // Fail fast instead of queueing commands while Redis is unreachable.
      connectTimeout: 2000,
      commandTimeout: 2000,
      enableOfflineQueue: false,
    })
  : null;

// null = unknown yet, true = reachable, false = unreachable.
let cacheAvailable = null;

// Logs only when the state changes, same idea as in db.js.
function recordAvailability(available, reason) {
  if (cacheAvailable === available) return;
  cacheAvailable = available;

  if (available) {
    log.info('cache_available');
  } else {
    log.error('cache_unavailable', { reason });
  }
}

if (client) {
  // Fires every time the connection is (re)established and usable.
  client.on('ready', () => recordAvailability(true));
  // Fires on every failed attempt while Redis is unreachable. ioredis keeps
  // retrying by itself; without a listener it would print noisy unhandled errors.
  client.on('error', (error) => recordAvailability(false, error.message || error.code));
}

// Commands only make sense on a ready connection. During startup or while
// reconnecting they would be rejected at once, which is not a real failure:
// the "ready" and "error" events above already report the actual state.
const isReady = () => client !== null && client.status === 'ready';

// Returns true when Redis answers. When the cache is disabled it also
// returns false, so callers must check `enabled` first to tell
// "disabled" (grey) apart from "down" (red).
async function ping() {
  if (!isReady()) return false;
  try {
    await client.ping();
    recordAvailability(true);
    return true;
  } catch (error) {
    recordAvailability(false, error.message || error.code);
    return false;
  }
}

// A cache failure must never break the app: on any error behave as a miss.
async function get(key) {
  if (!isReady()) return null;

  let value;
  try {
    value = await client.get(key);
  } catch (error) {
    recordAvailability(false, error.message || error.code);
    return null;
  }

  if (value === null) return null;
  try {
    return JSON.parse(value);
  } catch {
    // Corrupt entry: Redis itself is fine, so this is a plain miss and
    // must not mark the cache as unavailable.
    return null;
  }
}

// Stores a JSON-serializable value that expires after CACHE_TTL_SECONDS.
async function set(key, value) {
  if (!isReady()) return;
  try {
    await client.set(key, JSON.stringify(value), 'EX', settings.ttlSeconds);
  } catch (error) {
    recordAvailability(false, error.message || error.code);
  }
}

// Invalidates one or more keys after a write to the database. If Redis is
// unreachable the entries expire on their own when their TTL runs out.
async function del(...keys) {
  if (!isReady() || keys.length === 0) return;
  try {
    await client.del(...keys);
  } catch (error) {
    recordAvailability(false, error.message || error.code);
  }
}

async function close() {
  if (!client) return;
  try {
    await client.quit();
  } catch {
    client.disconnect();
  }
}

export { enabled, ping, get, set, del, close };
