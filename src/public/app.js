const STATUS_INTERVAL_MS = 3000;
const REQUEST_TIMEOUT_MS = 5000;

const PRIORITIES = {
  LOW: { label: 'Low', css: 'priority-low' },
  MEDIUM: { label: 'Medium', css: 'priority-medium' },
  HIGH: { label: 'High', css: 'priority-high' },
  CRITICAL: { label: 'Critical', css: 'priority-critical' },
};
const STATUS_LABELS = { OPEN: 'Open', IN_PROGRESS: 'In progress', RESOLVED: 'Resolved' };
const SOURCE_LABELS = {
  HIT: 'Redis cache',
  MISS: 'PostgreSQL',
  DISABLED: 'PostgreSQL (cache disabled)',
};

const $ = (id) => document.getElementById(id);

// Fetch with a timeout, so a hung server cannot block the polling loop.
function request(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
}

// ------------------------------------------------------------------ status

function setService(name, state, text) {
  $(`${name}-dot`).className = `dot dot-${state}`;
  $(`${name}-text`).textContent = text;
}

function describeService(service) {
  if (service.status === 'up') return ['up', `Connected (${service.latencyMs} ms)`];
  if (service.status === 'down') return ['down', 'Disconnected'];
  return ['disabled', 'Disabled in this environment'];
}

// null = unknown yet. A reload is triggered only when the database was known
// to be down and comes back, so the first load is not repeated.
let databaseWasUp = null;

async function checkStatus() {
  try {
    // A 503 still carries the JSON body, so the status code is not checked.
    const response = await request('/status');
    const status = await response.json();

    $('env-badge').textContent = `Environment: ${status.environment}`;
    $('env-badge').className = `badge badge-${status.environment}`;
    for (const name of ['database', 'cache']) {
      setService(name, ...describeService(status.services[name]));
    }

    const databaseUp = status.services.database.status === 'up';
    if (databaseUp && databaseWasUp === false) loadIncidents();
    databaseWasUp = databaseUp;
  } catch {
    setService('database', 'unknown', 'No answer from the web server');
    setService('cache', 'unknown', 'No answer from the web server');
    databaseWasUp = false;
  }

  $('status-updated').textContent = `Last check: ${new Date().toLocaleTimeString('en-GB')}`;
  // The next check is scheduled when this one ends, so requests never overlap.
  setTimeout(checkStatus, STATUS_INTERVAL_MS);
}

// --------------------------------------------------------------- incidents

function cell(text, className) {
  const td = document.createElement('td');
  td.textContent = text;
  if (className) td.className = className;
  return td;
}

function renderCounters(stats) {
  const format = (value) => value.toLocaleString('en-GB');
  $('count-total').textContent = format(stats.total);
  $('count-open').textContent = format(stats.byStatus.OPEN);
  $('count-progress').textContent = format(stats.byStatus.IN_PROGRESS);
  $('count-resolved').textContent = format(stats.byStatus.RESOLVED);
}

// Incident fields are inserted as text, never as HTML.
function renderRows(incidents) {
  const rows = incidents.map((incident) => {
    const priority = PRIORITIES[incident.priority];
    const row = document.createElement('tr');
    row.append(
      cell(incident.id),
      cell(incident.title),
      cell(incident.system_name),
      cell(priority?.label ?? incident.priority, priority?.css),
      cell(STATUS_LABELS[incident.status] ?? incident.status),
      cell(new Date(incident.created_at).toLocaleString('en-GB')),
    );
    return row;
  });
  $('incident-rows').replaceChildren(...rows);
}

function renderMessageRow(message) {
  const td = cell(message);
  td.colSpan = 6;
  const row = document.createElement('tr');
  row.append(td);
  $('incident-rows').replaceChildren(row);
}

async function loadIncidents() {
  try {
    const response = await request('/api/incidents');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const { data, meta } = await response.json();

    renderCounters(data.stats);
    renderRows(data.incidents);
    $('read-source').textContent = SOURCE_LABELS[meta.cache] ?? meta.source;
    $('read-time').textContent = `${meta.durationMs} ms`;
  } catch {
    $('read-source').textContent = 'unavailable';
    $('read-time').textContent = '-';
    renderMessageRow('Incidents are not available right now.');
  }
}

// -------------------------------------------------------------------- form

const form = $('incident-form');

function showMessage(text, kind) {
  const message = $('form-message');
  message.textContent = text;
  message.className = `message-${kind}`;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;

  try {
    const response = await request('/api/incidents', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.fromEntries(new FormData(form))),
    });
    const body = await response.json().catch(() => ({}));

    if (response.status === 201) {
      form.reset();
      showMessage(`Incident #${body.data.id} created.`, 'ok');
      await loadIncidents();
    } else if (response.status === 400) {
      showMessage(body.details?.join('. ') ?? 'Invalid data.', 'error');
    } else if (response.status === 503) {
      showMessage('The database is unavailable. Try again in a moment.', 'error');
    } else {
      showMessage('The incident could not be created.', 'error');
    }
  } catch {
    showMessage('Could not reach the server.', 'error');
  } finally {
    button.disabled = false;
  }
});

$('refresh-button').addEventListener('click', loadIncidents);

loadIncidents();
checkStatus();
