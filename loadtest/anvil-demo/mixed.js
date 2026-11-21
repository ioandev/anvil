// k6 load test for the demo's load-test copy (scripts/loadtest anvil-demo run mixed). Two kinds of visitor:
//   readers:  the guestbook page and the entries API (what a crowd that comes, reads and leaves does)
//   writers:  post an entry (the form's JSON twin), as a smaller share of visitors do
// Settings (environment): BASE, AUTH ("user:password" of the copy's basic auth), RATE (peak reader visits per second),
// WRITE_RATE (peak posts per second), DURATION (at the peak).
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import encoding from 'k6/encoding';

const BASE = __ENV.BASE;
const AUTH = 'Basic ' + encoding.b64encode(__ENV.AUTH || 'loadtest:loadtest');
const RATE = parseInt(__ENV.RATE || '50');
const WRITE_RATE = parseInt(__ENV.WRITE_RATE || '5');
const DURATION = __ENV.DURATION || '5m';

function ramp(peak) {
  return [
    { target: Math.ceil(peak / 4), duration: '1m' },
    { target: peak, duration: '2m' },
    { target: peak, duration: DURATION },
    { target: 0, duration: '1m' },
  ];
}

export const options = {
  scenarios: {
    readers: { executor: 'ramping-arrival-rate', exec: 'reader', startRate: 1, timeUnit: '1s',
               preAllocatedVUs: 50, maxVUs: 2000, stages: ramp(RATE) },
    writers: { executor: 'ramping-arrival-rate', exec: 'writer', startRate: 1, timeUnit: '1s',
               preAllocatedVUs: 20, maxVUs: 1000, stages: ramp(WRITE_RATE) },
  },
  thresholds: {
    'http_req_failed': ['rate<0.01'],
    'http_req_duration{kind:page}': ['p(95)<1500'],
    'http_req_duration{kind:api}': ['p(95)<500'],
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
  const body = JSON.stringify({ name: `k6 ${__VU}`, message: `Load test entry ${__ITER} from VU ${__VU}.` });
  const w = http.post(`${BASE}/api/entries`, body,
    { headers: { ...H.headers, 'Content-Type': 'application/json' }, timeout: '20s', tags: { kind: 'write', name: 'post' } });
  check(w, { 'post 201': (x) => x.status === 201 });
  sleep(Math.random() * 3);
}
