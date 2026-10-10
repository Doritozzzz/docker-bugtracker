// Incident Tracker UI. Plain JavaScript with no dependencies: the CSP only
// allows files served by this same origin.

const STATUS_INTERVAL_MS = 3000;
const REQUEST_TIMEOUT_MS = 5000;
const MAX_POINTS = 30;
const MAX_READS = 10;
const MAX_EVENTS = 12;

const PRIORITIES = { LOW: 'Low', MEDIUM: 'Medium', HIGH: 'High', CRITICAL: 'Critical' };
const PRIORITY_RANK = { LOW: 0, MEDIUM: 1, HIGH: 2, CRITICAL: 3 };
const STATUSES = { OPEN: 'Open', IN_PROGRESS: 'In progress', RESOLVED: 'Resolved' };
const STATUS_RANK = { OPEN: 0, IN_PROGRESS: 1, RESOLVED: 2 };
const SOURCES = {
  HIT: { label: 'Redis cache', kind: 'ok' },
  MISS: { label: 'PostgreSQL', kind: 'info' },
  DISABLED: { label: 'PostgreSQL (cache off)', kind: 'neutral' },
};
const VIEWS = { overview: 'Overview', incidents: 'Incidents', system: 'System' };
const SERVICES = [
  { key: 'web', name: 'Web application', kind: 'Express' },
  { key: 'database', name: 'PostgreSQL', kind: 'Database' },
  { key: 'cache', name: 'Redis', kind: 'Cache' },
];
const SERVICE_STATE = { up: 'Operational', down: 'Unavailable', disabled: 'Disabled', unknown: 'Unknown' };

const state = {
  incidents: [],
  stats: null,
  loaded: false,
  error: false,
  highlight: null,
  query: '',
  status: '',
  priority: '',
  sort: { key: 'created_at', dir: 'desc' },
  reads: [],
  events: [],
  services: { web: null, database: null, cache: null },
  history: { web: [], database: [], cache: [] },
  uptime: null,
  lastCheck: null,
};

const $ = (selector) => document.querySelector(selector);
const fmt = new Intl.NumberFormat('en-GB');
const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });

// Fetch with a timeout, so a hung server cannot block the polling loop.
const request = (url, options = {}) =>
  fetch(url, { ...options, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });

// ----------------------------------------------------------------- helpers

// Builds a DOM element. Text is always inserted as text, never as HTML.
function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'text') el.textContent = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else el.setAttribute(key, value === true ? '' : value);
  }
  el.append(...children.flat().filter((child) => child !== null && child !== undefined && child !== false));
  return el;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'text') el.textContent = value;
    else el.setAttribute(key, value);
  }
  el.append(...children);
  return el;
}

const tag = (label, key) => h('span', { class: `tag c-${key}`, text: label });
const priorityTag = (p) => tag(PRIORITIES[p] ?? p, p.toLowerCase());
const statusTag = (s) => tag(STATUSES[s] ?? s, s.toLowerCase());

const absoluteDate = (iso) =>
  new Date(iso).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' });

function timeAgo(iso) {
  const seconds = (new Date(iso) - Date.now()) / 1000;
  const abs = Math.abs(seconds);
  if (abs < 45) return 'just now';
  for (const [unit, size] of [['day', 86400], ['hour', 3600], ['minute', 60]]) {
    if (abs >= size) return rtf.format(Math.round(seconds / size), unit);
  }
  return 'just now';
}

const timeEl = (iso) => h('time', { datetime: iso, title: absoluteDate(iso), text: timeAgo(iso) });
const formatMs = (value) => (value < 10 ? value.toFixed(1) : String(Math.round(value)));

function formatUptime(total) {
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m ${total % 60}s`;
  return `${total}s`;
}

const pushPoint = (series, value) => {
  series.push(value);
  if (series.length > MAX_POINTS) series.shift();
};

// Shown while data has not arrived yet (skeleton) or could not be loaded.
const placeholder = () =>
  state.error ? h('p', { class: 'empty', text: 'No data available.' }) : h('div', { class: 'sk sk-block' });

function toast(text, kind = 'info') {
  const el = h('div', { class: `toast c-${kind}`, role: 'status', text });
  $('#toasts').append(el);
  setTimeout(() => el.remove(), 4500);
}

function sparkline(values) {
  const width = 120;
  const height = 32;
  const svg = svgEl('svg', {
    class: 'spark',
    viewBox: `0 0 ${width} ${height}`,
    preserveAspectRatio: 'none',
    'aria-hidden': 'true',
  });
  if (values.length < 2) return svg;

  const max = Math.max(...values) || 1;
  const points = values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * width;
      const y = height - 2 - (value / max) * (height - 4);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');
  svg.append(
    svgEl('polygon', { class: 'spark-area', points: `0,${height} ${points} ${width},${height}` }),
    svgEl('polyline', { class: 'spark-line', points }),
  );
  return svg;
}

// ----------------------------------------------------------------- routing

let firstRoute = true;

function route() {
  const requested = location.hash.replace(/^#\//, '');
  const name = Object.hasOwn(VIEWS, requested) ? requested : 'overview';

  for (const view of document.querySelectorAll('[data-view]')) view.hidden = view.dataset.view !== name;
  for (const tab of document.querySelectorAll('[data-tab]')) {
    if (tab.dataset.tab === name) tab.setAttribute('aria-current', 'page');
    else tab.removeAttribute('aria-current');
  }
  document.title = `${VIEWS[name]} · Incident Tracker`;
  if (!firstRoute) window.scrollTo(0, 0);
  firstRoute = false;
}

function navigate(name) {
  location.hash = `#/${name}`;
  route();
}

// ------------------------------------------------------------- overview UI

function renderMetrics() {
  const stats = state.stats;
  const values = {
    total: stats?.total,
    open: stats?.byStatus.OPEN,
    progress: stats?.byStatus.IN_PROGRESS,
    resolved: stats?.byStatus.RESOLVED,
  };
  for (const [key, value] of Object.entries(values)) {
    const root = $(`[data-metric="${key}"]`);
    root.querySelector('.metric-value').textContent = value === undefined ? '–' : fmt.format(value);
    root.querySelector('.metric-sub').textContent =
      value === undefined ? '–' : key === 'total' ? 'All incidents in the database' : `${Math.round((value / stats.total) * 100)}% of total`;
  }
}

const DONUT_RADIUS = 48;
const DONUT_LENGTH = 2 * Math.PI * DONUT_RADIUS;

function renderDonut() {
  const stats = state.stats;
  if (!stats) {
    $('#donut').replaceChildren(placeholder());
    $('#donut-legend').replaceChildren();
    return;
  }

  const parts = Object.keys(STATUSES).map((key) => ({ key, value: stats.byStatus[key] ?? 0 }));
  const visible = parts.filter((part) => part.value > 0);
  const gap = visible.length > 1 ? 2 : 0;

  let offset = 0;
  const segments = visible.map((part) => {
    const length = (part.value / stats.total) * DONUT_LENGTH;
    const segment = svgEl('circle', {
      class: `seg c-${part.key.toLowerCase()}`,
      cx: 60,
      cy: 60,
      r: DONUT_RADIUS,
      'stroke-dasharray': `${Math.max(length - gap, 0)} ${DONUT_LENGTH}`,
      'stroke-dashoffset': -offset,
    });
    offset += length;
    return segment;
  });

  const summary = parts.map((part) => `${STATUSES[part.key]} ${fmt.format(part.value)}`).join(', ');
  $('#donut').replaceChildren(
    svgEl(
      'svg',
      { class: 'donut', viewBox: '0 0 120 120', role: 'img', 'aria-label': `Incidents by status: ${summary}` },
      svgEl('circle', { class: 'ring', cx: 60, cy: 60, r: DONUT_RADIUS }),
      svgEl('g', { transform: 'rotate(-90 60 60)' }, ...segments),
      svgEl('text', { class: 'donut-total', x: 60, y: 59, 'text-anchor': 'middle', text: fmt.format(stats.total) }),
      svgEl('text', { class: 'donut-label', x: 60, y: 73, 'text-anchor': 'middle', text: 'incidents' }),
    ),
  );

  $('#donut-legend').replaceChildren(
    ...parts.map((part) =>
      h(
        'li',
        { class: `c-${part.key.toLowerCase()}` },
        h('span', { class: 'swatch' }),
        h('span', { text: STATUSES[part.key] }),
        h('span', { class: 'legend-value', text: fmt.format(part.value) }),
        h('span', { class: 'legend-pct', text: `${Math.round((part.value / stats.total) * 100)}%` }),
      ),
    ),
  );
}

function renderPriority() {
  const root = $('#priority-bars');
  if (!state.incidents.length) {
    root.replaceChildren(placeholder());
    return;
  }

  const counts = { LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0 };
  for (const incident of state.incidents) counts[incident.priority] += 1;

  root.replaceChildren(
    ...['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'].map((key) => {
      const fill = h('span');
      fill.style.width = `${(counts[key] / state.incidents.length) * 100}%`;
      return h(
        'div',
        { class: `bar-row c-${key.toLowerCase()}` },
        h('span', { class: 'bar-label', text: PRIORITIES[key] }),
        h('div', { class: 'bar' }, fill),
        h('span', { class: 'bar-value', text: counts[key] }),
      );
    }),
  );
}

function renderFeed() {
  const list = $('#recent-list');
  if (!state.incidents.length) {
    list.replaceChildren(h('li', { class: 'feed-empty' }, placeholder()));
    return;
  }
  list.replaceChildren(
    ...state.incidents.slice(0, 6).map((incident) =>
      h(
        'li',
        { class: 'feed-item' },
        h(
          'div',
          { class: 'feed-main' },
          h('button', { class: 'row-link', type: 'button', text: incident.title, onclick: () => openDetail(incident.id) }),
          h('p', { class: 'sub' }, `${incident.system_name} · `, timeEl(incident.created_at)),
        ),
        priorityTag(incident.priority),
      ),
    ),
  );
}

function renderSource() {
  const last = state.reads[0];
  $('#source-name').textContent = last ? (SOURCES[last.cache]?.label ?? last.cache) : '–';
  $('#source-ms').textContent = last ? `${formatMs(last.ms)} ms` : '–';
  $('#source-spark').replaceChildren(sparkline(state.reads.map((read) => read.ms).reverse()));
}

// ------------------------------------------------------------ incidents UI

function visibleIncidents() {
  const query = state.query.trim().toLowerCase();
  const { key, dir } = state.sort;
  const direction = dir === 'asc' ? 1 : -1;
  const value = (incident) => {
    if (key === 'priority') return PRIORITY_RANK[incident.priority];
    if (key === 'status') return STATUS_RANK[incident.status];
    if (key === 'created_at') return Date.parse(incident.created_at);
    return incident.id;
  };

  return state.incidents
    .filter(
      (incident) =>
        (!state.status || incident.status === state.status) &&
        (!state.priority || incident.priority === state.priority) &&
        (!query || `${incident.title} ${incident.system_name} #${incident.id}`.toLowerCase().includes(query)),
    )
    .sort((a, b) => (value(a) - value(b)) * direction);
}

const messageRow = (...content) => h('tr', {}, h('td', { colspan: 5 }, h('div', { class: 'empty' }, ...content)));

function renderTable() {
  const body = $('#rows');
  const filtersActive = Boolean(state.query || state.status || state.priority);
  $('#clear-filters').hidden = !filtersActive;

  for (const th of document.querySelectorAll('th[data-col]')) {
    const active = th.dataset.col === state.sort.key;
    th.setAttribute('aria-sort', active ? (state.sort.dir === 'asc' ? 'ascending' : 'descending') : 'none');
    th.querySelector('.sort-ind').textContent = active ? (state.sort.dir === 'asc' ? ' ↑' : ' ↓') : '';
  }

  if (!state.loaded) {
    if (state.error) {
      body.replaceChildren(messageRow('Incidents are not available right now.'));
    } else {
      body.replaceChildren(
        ...Array.from({ length: 6 }, () =>
          h('tr', {}, ...Array.from({ length: 5 }, () => h('td', {}, h('span', { class: 'sk sk-line' })))),
        ),
      );
    }
    $('#table-foot').textContent = '';
    return;
  }

  const rows = visibleIncidents();
  if (rows.length === 0) {
    body.replaceChildren(messageRow(filtersActive ? 'No incidents match your filters.' : 'No incidents yet.'));
  } else {
    body.replaceChildren(
      ...rows.map((incident) =>
        h(
          'tr',
          {
            'data-id': incident.id,
            class: incident.id === state.highlight ? 'row-new' : null,
            onclick: () => openDetail(incident.id),
          },
          h('td', { class: 'id-cell', text: `#${incident.id}` }),
          h(
            'td',
            {},
            h('button', {
              class: 'row-link',
              type: 'button',
              text: incident.title,
              onclick: (event) => {
                event.stopPropagation();
                openDetail(incident.id);
              },
            }),
            h('div', { class: 'cell-sub', text: incident.system_name }),
          ),
          h('td', {}, priorityTag(incident.priority)),
          h('td', {}, statusTag(incident.status)),
          h('td', { class: 'muted-cell' }, timeEl(incident.created_at)),
        ),
      ),
    );
  }
  state.highlight = null;

  $('#table-foot').textContent =
    `${rows.length} of the ${state.incidents.length} latest incidents shown · ${fmt.format(state.stats.total)} in the database`;
}

function fact(label, value) {
  return [h('dt', { text: label }), h('dd', {}, value)];
}

function openDetail(id) {
  const incident = state.incidents.find((item) => item.id === id);
  if (!incident) return;

  $('#detail-body').replaceChildren(
    h('p', { class: 'eyebrow mono', text: `Incident #${incident.id}` }),
    h('h2', { id: 'detail-title', text: incident.title }),
    h('div', { class: 'tags' }, priorityTag(incident.priority), statusTag(incident.status)),
    h(
      'dl',
      { class: 'facts' },
      ...fact('System', h('span', { class: 'mono', text: incident.system_name })),
      ...fact('Created', `${absoluteDate(incident.created_at)} (${timeAgo(incident.created_at)})`),
      ...fact('Last updated', `${absoluteDate(incident.updated_at)} (${timeAgo(incident.updated_at)})`),
    ),
  );
  $('#detail-dialog').showModal();
}

// ---------------------------------------------------------------- system UI

function buildServiceCards() {
  $('#services').replaceChildren(
    ...SERVICES.map(({ key, name, kind }) =>
      h(
        'article',
        { class: 'card svc', 'data-service': key },
        h(
          'div',
          { class: 'svc-top' },
          h('div', {}, h('h3', { text: name }), h('p', { class: 'sub', text: kind })),
          h('span', { class: 'dot dot-unknown' }),
        ),
        h('p', { class: 'svc-state', text: 'Checking…' }),
        h('p', { class: 'svc-latency mono', text: '–' }),
        h('div', { class: 'svc-spark' }),
      ),
    ),
  );
}

function renderServices() {
  for (const { key } of SERVICES) {
    const info = state.services[key];
    if (!info) continue;
    const card = $(`[data-service="${key}"]`);
    card.dataset.state = info.state;
    card.querySelector('.dot').className = `dot dot-${info.state}`;
    card.querySelector('.svc-state').textContent = SERVICE_STATE[info.state] ?? info.state;
    card.querySelector('.svc-latency').textContent = info.latency === null ? '–' : `${formatMs(info.latency)} ms`;
    card.querySelector('.svc-spark').replaceChildren(sparkline(state.history[key]));
  }
}

function renderHealth() {
  const { web, database, cache } = state.services;
  if (!web) return;

  let dot = 'up';
  let text = 'All systems operational';
  if (web.state === 'down') [dot, text] = ['unknown', 'Server unreachable'];
  else if (database.state === 'down') [dot, text] = ['down', 'Database unavailable'];
  else if (cache.state === 'down') [dot, text] = ['warn', 'Cache unavailable (degraded)'];

  $('#health-dot').className = `dot dot-${dot}`;
  $('#health-text').textContent = text;
}

function renderDeployment() {
  $('#d-uptime').textContent = state.uptime === null ? '–' : formatUptime(state.uptime);
  $('#d-check').textContent = state.lastCheck ? state.lastCheck.toLocaleTimeString('en-GB') : '–';
}

function renderReads() {
  const list = $('#read-log');
  if (!state.reads.length) {
    list.replaceChildren(h('li', { class: 'empty', text: 'No reads yet.' }));
    return;
  }
  list.replaceChildren(
    ...state.reads.map((read) => {
      const source = SOURCES[read.cache] ?? { label: read.cache, kind: 'neutral' };
      return h(
        'li',
        {},
        h('span', { class: 'mono', text: read.at.toLocaleTimeString('en-GB') }),
        tag(source.label, source.kind),
        h('span', { class: 'mono ms', text: `${formatMs(read.ms)} ms` }),
      );
    }),
  );
}

function renderEvents() {
  const list = $('#event-log');
  if (!state.events.length) {
    list.replaceChildren(h('li', { class: 'empty', text: 'No changes since you opened this page.' }));
    return;
  }
  list.replaceChildren(
    ...state.events.map((event) =>
      h(
        'li',
        {},
        h('span', { class: 'mono', text: event.at.toLocaleTimeString('en-GB') }),
        tag(event.kind === 'ok' ? 'Recovered' : 'Down', event.kind),
        h('span', { class: 'event-text', text: event.text }),
      ),
    ),
  );
}

// ------------------------------------------------------------------ status

function announce(name, current) {
  const up = current === 'up';
  const kind = up ? 'ok' : 'err';
  const text = up ? `${name} is back online` : `${name} became unavailable`;
  state.events.unshift({ at: new Date(), kind, text });
  state.events.length = Math.min(state.events.length, MAX_EVENTS);
  toast(text, kind);
}

function commit(next) {
  const real = (value) => value === 'up' || value === 'down';

  for (const { key, name } of SERVICES) {
    const before = state.services[key]?.state;
    const after = next[key].state;

    if (real(before) && real(after) && before !== after) announce(name, after);
    if (after === 'up' && next[key].latency !== null) pushPoint(state.history[key], next[key].latency);

    // The database came back (or the first load failed): read the data again.
    if (key === 'database' && after === 'up' && (before === 'down' || state.error)) loadIncidents();
  }

  state.services = next;
  state.lastCheck = new Date();
  renderHealth();
  renderServices();
  renderDeployment();
  renderEvents();
}

function applyStatus(status, roundTrip) {
  const { database, cache } = status.services;
  state.uptime = status.uptimeSeconds;

  const badge = $('#env-badge');
  badge.textContent = status.environment === 'production' ? 'Production' : 'Development';
  badge.className = `tag hide-sm c-${status.environment === 'production' ? 'violet' : 'info'}`;
  $('#d-env').textContent = badge.textContent;

  commit({
    web: { state: 'up', latency: roundTrip },
    database: { state: database.status, latency: database.latencyMs ?? null },
    cache: { state: cache.status, latency: cache.latencyMs ?? null },
  });
}

function applyOffline() {
  commit({
    web: { state: 'down', latency: null },
    database: { state: 'unknown', latency: null },
    cache: { state: 'unknown', latency: null },
  });
}

async function checkStatus() {
  const start = performance.now();
  try {
    // A 503 still carries the JSON body, so the status code is not checked.
    const response = await request('/status');
    const status = await response.json();
    applyStatus(status, performance.now() - start);
  } catch {
    applyOffline();
  }
  // The next check is scheduled when this one ends, so requests never overlap.
  setTimeout(checkStatus, STATUS_INTERVAL_MS);
}

// --------------------------------------------------------------- data load

let inFlight = false;

function renderAll() {
  document.body.toggleAttribute('data-loading', !state.loaded && !state.error);
  $('#banner').hidden = !state.error;
  $('#banner-text').textContent = state.loaded
    ? 'Could not refresh the incidents. Showing the last data received.'
    : 'Incidents are not available right now.';

  renderMetrics();
  renderDonut();
  renderPriority();
  renderFeed();
  renderSource();
  renderTable();
  renderReads();
}

async function loadIncidents() {
  if (inFlight) return;
  inFlight = true;
  $('#refresh').disabled = true;
  $('#read-now').disabled = true;

  try {
    const response = await request('/api/incidents');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const { data, meta } = await response.json();

    state.incidents = data.incidents;
    state.stats = data.stats;
    state.loaded = true;
    state.error = false;
    state.reads.unshift({ at: new Date(), cache: meta.cache, ms: meta.durationMs });
    state.reads.length = Math.min(state.reads.length, MAX_READS);
  } catch {
    state.error = true;
  } finally {
    inFlight = false;
    $('#refresh').disabled = false;
    $('#read-now').disabled = false;
  }
  renderAll();
}

// ------------------------------------------------------------- new incident

const newDialog = $('#new-dialog');
const newForm = $('#new-form');

function openNewIncident() {
  $('#new-message').textContent = '';
  newDialog.showModal();
}

newForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = newForm.querySelector('button[type="submit"]');
  const message = $('#new-message');
  button.disabled = true;
  message.textContent = '';

  try {
    const response = await request('/api/incidents', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.fromEntries(new FormData(newForm))),
    });
    const body = await response.json().catch(() => ({}));

    if (response.status === 201) {
      newForm.reset();
      newDialog.close();
      state.highlight = body.data.id;
      toast(`Incident #${body.data.id} created`, 'ok');
      await loadIncidents();
    } else if (response.status === 400) {
      message.textContent = body.details?.join('. ') ?? 'Invalid data.';
    } else if (response.status === 503) {
      message.textContent = 'The database is unavailable. Try again in a moment.';
    } else {
      message.textContent = 'The incident could not be created.';
    }
  } catch {
    message.textContent = 'Could not reach the server.';
  } finally {
    button.disabled = false;
  }
});

// ----------------------------------------------------------- event wiring

function setTheme(next) {
  document.documentElement.dataset.theme = next;
  try {
    localStorage.setItem('theme', next);
  } catch {
    // Storage can be blocked; the theme still changes for this visit.
  }
}
const toggleTheme = () => setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');

$('#theme-toggle').addEventListener('click', toggleTheme);
$('#new-button').addEventListener('click', openNewIncident);
$('#refresh').addEventListener('click', loadIncidents);
$('#read-now').addEventListener('click', loadIncidents);
$('#banner-retry').addEventListener('click', loadIncidents);

$('#search').addEventListener('input', (event) => {
  state.query = event.target.value;
  renderTable();
});
$('#search').addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  event.target.value = '';
  state.query = '';
  event.target.blur();
  renderTable();
});
$('#filter-status').addEventListener('change', (event) => {
  state.status = event.target.value;
  renderTable();
});
$('#filter-priority').addEventListener('change', (event) => {
  state.priority = event.target.value;
  renderTable();
});
$('#clear-filters').addEventListener('click', () => {
  Object.assign(state, { query: '', status: '', priority: '' });
  $('#search').value = '';
  $('#filter-status').value = '';
  $('#filter-priority').value = '';
  renderTable();
});

for (const button of document.querySelectorAll('[data-sort]')) {
  button.addEventListener('click', () => {
    const key = button.dataset.sort;
    state.sort =
      state.sort.key === key
        ? { key, dir: state.sort.dir === 'asc' ? 'desc' : 'asc' }
        : { key, dir: key === 'id' || key === 'status' ? 'asc' : 'desc' };
    renderTable();
  });
}

// Closes a dialog from its buttons or by clicking the backdrop.
document.addEventListener('click', (event) => {
  const closer = event.target.closest('[data-close]');
  if (closer) closer.closest('dialog').close();
  else if (event.target instanceof HTMLDialogElement) event.target.close();
});

document.addEventListener('keydown', (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.target.closest('input, textarea, select')) return;
  if (document.querySelector('dialog[open]')) return;

  const views = Object.keys(VIEWS);
  if (event.key === 'n') {
    event.preventDefault();
    openNewIncident();
  } else if (event.key === '/') {
    event.preventDefault();
    navigate('incidents');
    $('#search').focus();
  } else if (event.key === 't') {
    toggleTheme();
  } else if (['1', '2', '3'].includes(event.key)) {
    navigate(views[Number(event.key) - 1]);
  }
});

window.addEventListener('hashchange', route);

// Relative times ("5 minutes ago") are refreshed in place, without redrawing.
setInterval(() => {
  for (const time of document.querySelectorAll('time[datetime]')) time.textContent = timeAgo(time.dateTime);
}, 30000);

// -------------------------------------------------------------------- start

buildServiceCards();
route();
renderAll();
renderEvents();
loadIncidents();
checkStatus();
