// k6 ceiling test for the demo's load-test copy (scripts/loadtest anvil-demo run ceiling): a staircase that keeps
// adding visitors until the site gives way, then stops itself. Same visits as mixed.js: readers (the page and the
// entries API) and a share of writers (posting an entry).
// Settings (environment): START (visits/s on the first step), STEP (added per step), STEPS, STEP_TIME (each step),
// WRITE_SHARE (0.1), plus BASE and AUTH as in mixed.js.
// Stops (abortOnFail) when over 5% of requests fail, or the 95th percentile passes 3 s, each held for 30 s: the step
// where latency climbs is the clean capacity (CAPACITY.md).
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import encoding from 'k6/encoding';

const BASE = __ENV.BASE;
const AUTH = 'Basic ' + encoding.b64encode(__ENV.AUTH || 'loadtest:loadtest');
const START = parseInt(__ENV.START || '50');
const STEP = parseInt(__ENV.STEP || '50');
const STEPS = parseInt(__ENV.STEPS || '19');
const STEP_TIME = __ENV.STEP_TIME || '60s';
const SHARE = parseFloat(__ENV.WRITE_SHARE || '0.1');

function staircase(share) {
  const st = [];
  for (let i = 0; i < STEPS; i++) {
    const rate = Math.max(1, Math.round((START + STEP * i) * share));
    st.push({ target: rate, duration: '10s' });       // climb to the step
    st.push({ target: rate, duration: STEP_TIME });   // hold it
  }
  return st;
}

export const options = {
  scenarios: {
    readers: { executor: 'ramping-arrival-rate', exec: 'reader', startRate: Math.round(START * (1 - SHARE)), timeUnit: '1s',
               preAllocatedVUs: 200, maxVUs: 6000, stages: staircase(1 - SHARE) },
    writers: { executor: 'ramping-arrival-rate', exec: 'writer', startRate: Math.max(1, Math.round(START * SHARE)), timeUnit: '1s',
               preAllocatedVUs: 50, maxVUs: 2000, stages: staircase(SHARE) },
  },
  thresholds: {
    'http_req_failed': [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' }],
    'http_req_duration': [{ threshold: 'p(95)<3000', abortOnFail: true, delayAbortEval: '30s' }],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const H = { headers: { Authorization: AUTH, 'User-Agent': 'k6-loadtest (anvil owner)' }, timeout: '20s' };
const tag = (kind, name) => ({ ...H, tags: { kind, name } });

export function reader() {
  group('read', () => {
    check(http.get(`${BASE}/`, tag('page', 'guestbook')), { 'page 200': (x) => x.status === 200 });
    check(http.get(`${BASE}/api/entries?limit=20`, tag('api', 'entries')), { 'entries 200': (x) => x.status === 200 });
  });
  sleep(Math.random() * 2);
}

export function writer() {
  const body = JSON.stringify({ name: `k6 ${__VU}`, message: `Ceiling entry ${__ITER} from VU ${__VU}.` });
  const w = http.post(`${BASE}/api/entries`, body,
    { headers: { ...H.headers, 'Content-Type': 'application/json' }, timeout: '20s', tags: { kind: 'write', name: 'post' } });
  check(w, { 'post 201': (x) => x.status === 201 });
  sleep(Math.random() * 3);
}
