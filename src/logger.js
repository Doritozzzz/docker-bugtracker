// Minimal structured logger: one JSON object per line, written to the
// standard streams so `docker logs` captures it with no extra tooling.
//
// It reads LOG_LEVEL directly instead of importing config.js on purpose:
// that way a configuration error can still be reported through the logger.

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

// An unknown or missing LOG_LEVEL falls back to "info" (config.js rejects
// invalid values at startup, so this only matters before config is loaded).
const threshold = LEVELS[process.env.LOG_LEVEL] ?? LEVELS.info;

const write = (level, message, fields = {}) => {
  if (LEVELS[level] < threshold) return;
  const line = JSON.stringify({
    time: new Date().toISOString(),
    level,
    msg: message,
    ...fields,
  });
  // warn and error go to stderr, everything else to stdout.
  const stream = LEVELS[level] >= LEVELS.warn ? process.stderr : process.stdout;
  stream.write(`${line}\n`);
};

export const log = {
  debug: (message, fields) => write('debug', message, fields),
  info: (message, fields) => write('info', message, fields),
  warn: (message, fields) => write('warn', message, fields),
  error: (message, fields) => write('error', message, fields),
};
