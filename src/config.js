// Reads and validates every environment variable in one place, once, at startup.
// If something is missing or malformed the process fails immediately with a
// clear message, instead of crashing later in the middle of a request.

// Returns the variable's value, or undefined when it is unset or empty.
const raw = (name) => {
  const value = process.env[name];
  return value === undefined || value === '' ? undefined : value;
};

const text = (name) => {
  const value = raw(name);
  if (value === undefined) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

const integer = (name, fallback) => {
  const value = raw(name);
  if (value === undefined) return fallback;
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) {
    throw new Error(`${name} must be a positive integer, got "${value}"`);
  }
  return number;
};

const oneOf = (name, allowed, fallback) => {
  const value = raw(name) ?? fallback;
  if (!allowed.includes(value)) {
    throw new Error(`${name} must be one of ${allowed.join(', ')}, got "${value}"`);
  }
  return value;
};

const cacheEnabled = oneOf('CACHE_ENABLED', ['true', 'false'], 'false') === 'true';

export const config = {
  env: oneOf('NODE_ENV', ['development', 'production'], 'development'),
  port: integer('PORT', 3000),
  logLevel: oneOf('LOG_LEVEL', ['debug', 'info', 'warn', 'error'], 'info'),
  db: {
    host: text('DB_HOST'),
    port: integer('DB_PORT', 5432),
    database: text('POSTGRES_DB'),
    user: text('POSTGRES_USER'),
    password: text('POSTGRES_PASSWORD'),
  },
  // Redis settings are only read (and required) when the cache is enabled.
  cache: cacheEnabled
    ? {
        enabled: true,
        host: text('REDIS_HOST'),
        port: integer('REDIS_PORT', 6379),
        password: text('REDIS_PASSWORD'),
        ttlSeconds: integer('CACHE_TTL_SECONDS', 60),
      }
    : { enabled: false },
};

// Same shape as config but without any secret: this is the only version
// that is allowed to be printed in logs.
export const describeConfig = () => ({
  env: config.env,
  port: config.port,
  logLevel: config.logLevel,
  db: {
    host: config.db.host,
    port: config.db.port,
    database: config.db.database,
    user: config.db.user,
  },
  cache: config.cache.enabled
    ? {
        enabled: true,
        host: config.cache.host,
        port: config.cache.port,
        ttlSeconds: config.cache.ttlSeconds,
      }
    : { enabled: false },
});
