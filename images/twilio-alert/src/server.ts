import express, { NextFunction, Request, Response } from 'express';
import { timingSafeEqual } from 'node:crypto';
import Twilio, { validateRequest } from 'twilio';
import MessagingResponse from 'twilio/lib/twiml/MessagingResponse';
import VoiceResponse from 'twilio/lib/twiml/VoiceResponse';

// Settings come from the environment (in Docker/Kubernetes) or, for local runs, `node --env-file=.env`.
const PORT = Number(process.env.PORT || 3000);
const TWILIO_ACCOUNT_SID = process.env.TWILIO_ACCOUNT_SID;
const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;
// Preferred: an API key (SK…) and its secret, revocable on its own; still needs TWILIO_ACCOUNT_SID (AC…).
// The auth token is then only needed to check incoming Twilio webhooks.
const TWILIO_API_KEY = process.env.TWILIO_API_KEY;
const TWILIO_API_SECRET = process.env.TWILIO_API_SECRET;
const TWILIO_PHONE_NUMBER = process.env.TWILIO_PHONE_NUMBER;
const FORWARD_TO_NUMBER = process.env.FORWARD_TO_NUMBER;
// /alert, /test-call, /pager, /watchdog: the password callers must pass. ALERT_NUMBER: the phone that gets called.
const SERVICE_PASSWORD = process.env.SERVICE_PASSWORD;
const ALERT_NUMBER = process.env.ALERT_NUMBER;

// ---- The pager: when to call while something is wrong
// Calls in a burst, then less and less often: one call at each of these minutes after the problem started, then
// every CALL_REPEAT_MINUTES until it's resolved.
const minutesList = (s: string) => s.split(',').map((x) => Number(x.trim())).filter((x) => Number.isFinite(x) && x >= 0);
const CALL_SCHEDULE_MS = minutesList(process.env.CALL_SCHEDULE_MINUTES || '0,2,4,6,10,15,20,30,45,60').map((m) => m * 60000);
const CALL_REPEAT_MS = Number(process.env.CALL_REPEAT_MINUTES || 60) * 60000;
const MIN_GAP_MS = Number(process.env.CALL_MIN_GAP_SECONDS || 60) * 1000;
// No calls in these hours (local time in QUIET_TIMEZONE), e.g. "03-09"; a call due then waits until they end.
const QUIET_HOURS = (process.env.QUIET_HOURS ?? '03-09').trim();
const QUIET_TIMEZONE = process.env.QUIET_TIMEZONE || 'Europe/London';
// Answering a call (a person, not voicemail) stops the calls for this long.
const ACK_SNOOZE_MS = Number(process.env.ACK_SNOOZE_MINUTES || 60) * 60000;
// An Alertmanager alert not re-sent for this long counts as over (in case its "resolved" never arrives).
const ALERT_STALE_MS = Number(process.env.ALERT_STALE_MINUTES || 20) * 60000;
const TICK_MS = Number(process.env.TICK_SECONDS || 30) * 1000;
// Autopilot (POST /autopilot): an automated fixer can hold the calls while it works, at most this long, once per incident.
const AUTOPILOT_MAX_MS = 20 * 60000;
const AUTOPILOT_SUMMARY_MAX = 300;
// A summary sent while no incident is open is kept for the next incident that opens within this long.
const AUTOPILOT_PENDING_SUMMARY_MS = 60 * 60000;
// When the autopilot gives up (any result but "fixed"), we call at once and keep a problem of our own open this long
// (the autopilot's own cooldown): its restart or rollback can make the alert look resolved for a while (alert rules
// ignore workloads changed in the last 10 minutes), and "gave up" must still reach a person.
const AUTOPILOT_GAVEUP_MS = Number(process.env.AUTOPILOT_GAVEUP_MINUTES || 60) * 60000;
const AUTOPILOT_GAVEUP_KEY = 'autopilot-gave-up';
// DRY_RUN=1: log the calls instead of placing them (for testing the schedule).
const DRY_RUN = process.env.DRY_RUN === '1';

// Watchdog (optional; for a second machine watching the main server, e.g. a home machine watching the server).
// It only *pulls* WATCH_URL every minute; the server never has to reach it. WATCH_URL answers JSON:
//   {"ok": true|false, "reason": "...", "mutedUntil": "<ISO time>"|null}
// - unreachable (or not that JSON) for WATCH_FAIL_MINUTES -> a problem ("the server has not answered");
// - ok:false (e.g. the server's alerting has stopped) -> a problem with its reason;
// - mutedUntil in the future -> no problem raised until then, remembered even if the server becomes unreachable
//   (so muting in Alertmanager mutes this watchdog too).
// Problems are called about on the pager's schedule above.
const WATCH_URL = process.env.WATCH_URL || '';
const WATCH_FAIL_MS = Number(process.env.WATCH_FAIL_MINUTES || 10) * 60 * 1000;

const twilioClient =
  TWILIO_API_KEY && TWILIO_API_SECRET && TWILIO_ACCOUNT_SID
    ? Twilio(TWILIO_API_KEY, TWILIO_API_SECRET, { accountSid: TWILIO_ACCOUNT_SID })
    : TWILIO_ACCOUNT_SID && TWILIO_AUTH_TOKEN
      ? Twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
      : null;

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// Constant-time comparison, so the password can't be guessed from response times.
function passwordMatches(given: unknown): boolean {
  if (typeof given !== 'string' || !SERVICE_PASSWORD) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(SERVICE_PASSWORD);
  return a.length === b.length && timingSafeEqual(a, b);
}

// Words safe to read out loud: "SiteDown" -> "Site Down"; letters, digits and spaces only.
function speakable(text: string): string {
  return text.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[^A-Za-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
}

// ---------------------------------------------------------------- calls

type CallResult = { ok: true; callSid: string } | { ok: false; status: number; error: string; message?: string };

/** Phones ALERT_NUMBER and reads the reasons out. */
async function placeCall(reasons: string[], autopilotSummary: string | null = null): Promise<CallResult> {
  const what = reasons.length ? ` ${reasons.join('. ')}.` : '';
  // The autopilot's note, read out after the alert names. say() escapes it for XML.
  const note = autopilotSummary ? ` Autopilot says: ${autopilotSummary}` : '';
  const twiml = new VoiceResponse();
  twiml.say({ voice: 'alice', language: 'en-US' }, `This is an alert. This is an alert.${what}${note} Please check your system immediately.`);
  twiml.pause({ length: 1 });
  twiml.say({ voice: 'alice', language: 'en-US' }, `This is an alert.${what}${note} Please check your system immediately.`);
  if (DRY_RUN) {
    console.log(`DRY RUN: would call${reasons.length ? ` (${reasons.join(', ')})` : ''}: ${twiml.toString()}`);
    return { ok: true, callSid: 'dry-run' };
  }
  if (!twilioClient) {
    console.error('Twilio client not initialized - set TWILIO_ACCOUNT_SID and either TWILIO_API_KEY + TWILIO_API_SECRET or TWILIO_AUTH_TOKEN');
    return { ok: false, status: 500, error: 'Twilio not configured' };
  }
  if (!ALERT_NUMBER || !TWILIO_PHONE_NUMBER) {
    console.error('ALERT_NUMBER and TWILIO_PHONE_NUMBER must be set');
    return { ok: false, status: 500, error: 'Phone numbers not configured' };
  }
  try {
    console.log(`Calling${reasons.length ? ` (${reasons.join(', ')})` : ''}${autopilotSummary ? ' with the autopilot summary' : ''}`);
    const call = await twilioClient.calls.create({
      to: ALERT_NUMBER,
      from: TWILIO_PHONE_NUMBER,
      twiml: twiml.toString(),
      // Tells a person (answeredBy "human", or "unknown" when you pick up and say nothing) from voicemail
      // ("machine_…"): voicemail doesn't count as answered, so the calls go on.
      machineDetection: 'Enable',
    });
    console.log(`Call placed. Call SID: ${call.sid}`);
    return { ok: true, callSid: call.sid };
  } catch (error) {
    console.error('Error placing call:', error);
    return { ok: false, status: 500, error: 'Failed to initiate call', message: error instanceof Error ? error.message : 'Unknown error' };
  }
}

/** After a call: if you picked up (said anything or nothing; not voicemail), stop calling for ACK_SNOOZE_MINUTES. */
async function watchCallOutcome(callSid: string, snoozeIfAnswered = true): Promise<void> {
  if (!twilioClient || callSid === 'dry-run') return;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 15000));
    try {
      const c = await twilioClient.calls(callSid).fetch();
      if (!['completed', 'busy', 'no-answer', 'failed', 'canceled'].includes(c.status)) continue;
      console.log(`Call ${callSid}: ${c.status}, answered by ${c.answeredBy ?? 'nobody'}, ${c.duration ?? 0} s`);
      // Answered = you picked up: "human" (you spoke) or "unknown" (you listened in silence). Voicemail is
      // "machine_start" / "machine_end_…" (or "fax"): not answered, like no-answer, busy, failed or canceled.
      const machine = /^(machine|fax)/.test(c.answeredBy ?? '');
      if (c.status === 'completed' && !machine && snoozeIfAnswered) {
        pager.snoozedUntil = Date.now() + ACK_SNOOZE_MS;
        console.log(`Answered: no more calls until ${new Date(pager.snoozedUntil).toISOString()}`);
      } else if (machine) {
        console.log('Voicemail: not answered, calls go on');
      }
      return;
    } catch (error) {
      console.error(`Checking call ${callSid} failed:`, error instanceof Error ? error.message : error);
    }
  }
}

// ---------------------------------------------------------------- the pager

type Problem = { label: string; since: number; lastSeen: number; source: 'alertmanager' | 'watchdog' | 'autopilot' };

type Incident = {
  startedAt: number;
  callsDone: number;
  lastCallAt: number | null;
  autopilotUsed: boolean; // this incident already had its one autopilot hold
  autopilotSummary: string | null; // read out in its calls
  heldDue: number | null; // the call slot last logged as held (logs once per slot)
};

const pager = {
  problems: new Map<string, Problem>(),
  incident: null as null | Incident,
  snoozedUntil: 0,
  // Autopilot hold: no calls until then. Set with no incident open, it is "pending" and becomes the next incident's hold.
  autopilotUntil: 0,
  autopilotPending: false,
  autopilotPendingSummary: null as null | { text: string; at: number },
  // The autopilot gave up: the next call goes out at once (still not in quiet hours or after you answered).
  callNow: false,
};

const isoTime = (t: number) => new Date(t).toISOString();

function inQuietHours(now: number): boolean {
  const m = /^(\d{1,2})\s*-\s*(\d{1,2})$/.exec(QUIET_HOURS);
  if (!m) return false;
  const [from, to] = [Number(m[1]), Number(m[2])];
  const hour = Number(new Intl.DateTimeFormat('en-GB', { hour: 'numeric', hourCycle: 'h23', timeZone: QUIET_TIMEZONE }).format(now));
  return from <= to ? hour >= from && hour < to : hour >= from || hour < to;
}

function raise(key: string, label: string, source: Problem['source'], now = Date.now()): void {
  const p = pager.problems.get(key);
  if (p) {
    p.lastSeen = now;
    p.label = label;
  } else {
    pager.problems.set(key, { label, since: now, lastSeen: now, source });
    console.log(`Problem: ${label}`);
  }
}

function clear(key: string): void {
  const p = pager.problems.get(key);
  if (p) {
    pager.problems.delete(key);
    console.log(`Resolved: ${p.label}`);
  }
}

/** When the next call is due: the burst schedule from the incident's start, then every CALL_REPEAT_MINUTES. */
function nextCallAt(inc: NonNullable<typeof pager.incident>): number {
  const scheduled =
    inc.callsDone < CALL_SCHEDULE_MS.length
      ? inc.startedAt + CALL_SCHEDULE_MS[inc.callsDone]
      : (inc.lastCallAt ?? inc.startedAt) + CALL_REPEAT_MS;
  return inc.lastCallAt === null ? scheduled : Math.max(scheduled, inc.lastCallAt + MIN_GAP_MS);
}

let ticking = false;
async function pagerTick(): Promise<void> {
  if (ticking) return;
  ticking = true;
  try {
    const now = Date.now();
    for (const [key, p] of pager.problems) {
      if (p.source === 'alertmanager' && now - p.lastSeen > ALERT_STALE_MS) clear(key);
      if (p.source === 'autopilot' && now - p.since > AUTOPILOT_GAVEUP_MS) clear(key);
    }
    if (pager.problems.size === 0) {
      if (pager.incident) {
        console.log(`All clear after ${pager.incident.callsDone} call(s)`);
        // The autopilot hold never outlives its incident; the next incident gets a fresh one.
        if (pager.autopilotUntil > now) console.log('Autopilot hold ended: all clear');
        pager.autopilotUntil = 0;
        pager.autopilotPending = false;
        pager.autopilotPendingSummary = null;
      }
      pager.incident = null;
      pager.callNow = false;
      return;
    }
    if (!pager.incident) {
      const inc: Incident = { startedAt: now, callsDone: 0, lastCallAt: null, autopilotUsed: false, autopilotSummary: null, heldDue: null };
      // A hold or summary sent just before the incident opened belongs to it (and is its one hold).
      if (pager.autopilotPending && pager.autopilotUntil > now) {
        inc.autopilotUsed = true;
        console.log(`Autopilot hold applies to the new incident: calls held until ${isoTime(pager.autopilotUntil)}`);
      } else {
        pager.autopilotUntil = 0;
      }
      pager.autopilotPending = false;
      const ps = pager.autopilotPendingSummary;
      if (ps && now - ps.at <= AUTOPILOT_PENDING_SUMMARY_MS) inc.autopilotSummary = ps.text;
      pager.autopilotPendingSummary = null;
      pager.incident = inc;
    }
    const inc = pager.incident;
    if (inQuietHours(now) || now < pager.snoozedUntil) return;

    const due = pager.callNow ? now : nextCallAt(inc);
    if (now < due) return;
    if (now < pager.autopilotUntil) {
      if (inc.heldDue !== due) console.log(`Call held: autopilot working until ${isoTime(pager.autopilotUntil)}`);
      inc.heldDue = due;
      return;
    }
    // Quiet hours or a snooze made us late: carry on with the schedule from here, not with a rush of missed calls.
    if (now - due > 2 * TICK_MS) inc.startedAt += now - due;

    const labels = [...new Set([...pager.problems.values()].map((p) => p.label))].slice(0, 5);
    const r = await placeCall(labels, inc.autopilotSummary);
    pager.callNow = false;
    inc.callsDone += 1;
    inc.lastCallAt = now;
    if (r.ok) void watchCallOutcome(r.callSid);
  } finally {
    ticking = false;
  }
}
setInterval(() => void pagerTick(), TICK_MS);

// ---------------------------------------------------------------- endpoints

// Twilio webhook validation (skipped in development).
const twilioWebhookMiddleware = (req: Request, res: Response, next: NextFunction) => {
  if (process.env.NODE_ENV === 'development') {
    return next();
  }
  const twilioSignature = req.headers['x-twilio-signature'];
  const url = `https://${req.get('host')}${req.originalUrl}`;
  if (validateRequest(TWILIO_AUTH_TOKEN || '', twilioSignature as string, url, req.body)) {
    next();
  } else {
    console.error('Invalid Twilio request signature');
    res.status(403).send('Forbidden');
  }
};

app.get('/', (req, res) => {
  res.send('Twilio Webhook Server is running!');
});

// For Kubernetes/Docker probes: the process is up and serving.
app.get('/healthz', (req, res) => {
  res.json({ ok: true, twilioConfigured: Boolean(twilioClient && ALERT_NUMBER && TWILIO_PHONE_NUMBER) });
});

// Alertmanager's webhook: firing alerts become problems (called about on the schedule), resolved ones end them.
// Set send_resolved: true and a short repeat_interval (it keeps firing alerts fresh; stale ones are dropped).
app.post('/alert', (req, res) => {
  if (!passwordMatches(req.query.password)) {
    console.log('Unauthorized alert attempt - invalid password');
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const alerts = (req.body?.alerts ?? []) as { status?: string; labels?: Record<string, string> }[];
  if (!Array.isArray(alerts) || alerts.length === 0) {
    // A bare POST (no Alertmanager payload): one problem until it goes stale.
    raise('alert:manual', 'Alert', 'alertmanager');
  }
  for (const a of Array.isArray(alerts) ? alerts : []) {
    const name = String(a?.labels?.alertname || 'Alert');
    const key = `am:${name}:${a?.labels?.instance ?? ''}`;
    if (a?.status === 'resolved') clear(key);
    else raise(key, speakable(name) || 'Alert', 'alertmanager');
  }
  void pagerTick();
  res.json({ success: true, problems: pager.problems.size });
});

// One call now, outside the schedule, quiet hours and snooze: to check the phone line works.
app.post('/test-call', async (req, res) => {
  if (!passwordMatches(req.query.password)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const r = await placeCall(['Test call']);
  if (r.ok) {
    void watchCallOutcome(r.callSid, false); // a test call never pauses real alerts
    return res.json({ success: true, callSid: r.callSid });
  }
  const { status, ...body } = r;
  res.status(status).json(body);
});

// The autopilot (an automated fixer) says it's working on the problem, or that it has finished.
//   {"working": true, "minutes": 20}: hold the calls until now + min(minutes, 20), once per incident. With no
//     incident open, the hold is kept for the next incident that opens before it runs out (and is that one's hold).
//   {"working": false, "summary": "..."}: end the hold now; the summary is read out in the incident's calls.
// The calls then carry on: the next one when the hold ends (if still due), then on schedule.
app.post('/autopilot', (req, res) => {
  if (!passwordMatches(req.query.password)) {
    console.log('Unauthorized autopilot attempt - invalid password');
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const body = (req.body ?? {}) as { working?: unknown; minutes?: unknown; summary?: unknown; result?: unknown };
  if (typeof body.working !== 'boolean') {
    return res.status(400).json({ error: 'working must be true or false' });
  }
  const now = Date.now();
  const inc = pager.incident;
  const where = inc ? 'the current incident' : 'the next incident';

  if (body.working) {
    if (inc ? inc.autopilotUsed : pager.autopilotPending && pager.autopilotUntil > now) {
      console.log(`Autopilot hold ignored: ${where} already had one`);
      return res.json({ success: true, held: false, reason: `${where} already had its autopilot hold`, autopilotUntil: pager.autopilotUntil > now ? isoTime(pager.autopilotUntil) : null });
    }
    const m = Number(body.minutes ?? 20);
    const ms = Number.isFinite(m) && m > 0 ? Math.min(m * 60000, AUTOPILOT_MAX_MS) : AUTOPILOT_MAX_MS;
    pager.autopilotUntil = now + ms;
    clear(AUTOPILOT_GAVEUP_KEY);
    if (inc) inc.autopilotUsed = true;
    else pager.autopilotPending = true;
    console.log(`Autopilot working: calls held until ${isoTime(pager.autopilotUntil)} (${where})`);
    return res.json({ success: true, held: true, autopilotUntil: isoTime(pager.autopilotUntil), incidentOpen: Boolean(inc) });
  }

  const wasHeld = pager.autopilotUntil > now;
  pager.autopilotUntil = 0;
  pager.autopilotPending = false;
  const summary = typeof body.summary === 'string' ? body.summary.replace(/\s+/g, ' ').trim().slice(0, AUTOPILOT_SUMMARY_MAX) : '';
  if (summary) {
    if (inc) inc.autopilotSummary = summary;
    else pager.autopilotPendingSummary = { text: summary, at: now };
  }
  console.log(`Autopilot done: ${wasHeld ? 'hold cleared' : 'no hold was active'}${summary ? `; summary kept for ${where}: ${summary}` : ''}`);
  // The run's result: the `result` field, else the summary's "<result>: ..." prefix. Anything but "fixed" (gave_up,
  // timeout, error) is a give-up: call now, even if the alert has since looked resolved.
  const result = typeof body.result === 'string' ? body.result : (/^(\w+):/.exec(summary)?.[1] ?? '');
  if (result === 'fixed') {
    clear(AUTOPILOT_GAVEUP_KEY);
  } else if (result) {
    const why = result === 'timeout' ? 'ran out of time' : result === 'error' ? 'failed to run' : "couldn't fix it";
    raise(AUTOPILOT_GAVEUP_KEY, `The autopilot ${why}`, 'autopilot', now);
    if (summary && !pager.incident) pager.autopilotPendingSummary = { text: summary, at: now };
    pager.callNow = true;
    console.log(`Autopilot gave up (${result}): calling now`);
  }
  void pagerTick();
  res.json({ success: true, held: false, summaryKept: Boolean(summary), incidentOpen: Boolean(inc) });
});

// What the pager sees: problems, the incident's progress, the next call, snooze and quiet hours.
app.get('/pager', (req, res) => {
  if (!passwordMatches(req.query.password)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const now = Date.now();
  const iso = (t: number | null | undefined) => (t ? new Date(t).toISOString() : null);
  res.json({
    problems: [...pager.problems.values()].map((p) => ({ label: p.label, since: iso(p.since), source: p.source })),
    incident: pager.incident && {
      startedAt: iso(pager.incident.startedAt),
      callsDone: pager.incident.callsDone,
      autopilotHoldUsed: pager.incident.autopilotUsed,
      nextCallAt: iso(nextCallAt(pager.incident)),
    },
    snoozedUntil: pager.snoozedUntil > now ? iso(pager.snoozedUntil) : null,
    autopilotUntil: pager.autopilotUntil > now ? iso(pager.autopilotUntil) : null,
    autopilotPending: pager.autopilotPending && pager.autopilotUntil > now, // a hold waiting for the next incident
    autopilotSummary: pager.incident ? pager.incident.autopilotSummary : (pager.autopilotPendingSummary?.text ?? null),
    quietHoursNow: inQuietHours(now),
    settings: {
      scheduleMinutes: CALL_SCHEDULE_MS.map((m) => m / 60000),
      repeatMinutes: CALL_REPEAT_MS / 60000,
      quietHours: QUIET_HOURS,
      quietTimezone: QUIET_TIMEZONE,
      ackSnoozeMinutes: ACK_SNOOZE_MS / 60000,
    },
  });
});

// ---------------------------------------------------------------- watchdog

const watch = {
  lastOk: null as number | null, // last time WATCH_URL answered with a status
  failingSince: null as number | null, // unreachable since (null while it answers)
  mutedUntil: 0, // from the server's last answer; kept while unreachable
};

// What the watchdog sees: for checking it by hand.
app.get('/watchdog', (req, res) => {
  if (!passwordMatches(req.query.password)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  res.json({
    watching: Boolean(WATCH_URL),
    lastOk: watch.lastOk ? new Date(watch.lastOk).toISOString() : null,
    failingSince: watch.failingSince ? new Date(watch.failingSince).toISOString() : null,
    mutedUntil: watch.mutedUntil > Date.now() ? new Date(watch.mutedUntil).toISOString() : null,
    problems: [...pager.problems.values()].filter((p) => p.source === 'watchdog').map((p) => p.label),
  });
});

type WatchStatus = { ok: boolean; reason?: string; mutedUntil?: string | null };

async function fetchStatus(): Promise<WatchStatus | null> {
  try {
    const res = await fetch(WATCH_URL, { signal: AbortSignal.timeout(20000), redirect: 'follow' });
    const body = (await res.json()) as WatchStatus;
    return typeof body?.ok === 'boolean' ? body : null;
  } catch {
    return null; // unreachable, timed out, or not our JSON (e.g. Cloudflare's error page)
  }
}

async function watchdogTick(): Promise<void> {
  const now = Date.now();
  const status = await fetchStatus();

  if (status === null) {
    if (watch.failingSince === null) {
      watch.failingSince = now;
      console.log('Server not answering');
    }
    if (now - watch.failingSince >= WATCH_FAIL_MS && now >= watch.mutedUntil) {
      raise('watch:unreachable', 'The server is not answering', 'watchdog', now);
    } else {
      clear('watch:unreachable');
    }
    return;
  }

  if (watch.failingSince !== null) console.log('Server answering again');
  watch.failingSince = null;
  watch.lastOk = now;
  clear('watch:unreachable');
  const muted = status.mutedUntil ? Date.parse(status.mutedUntil) : NaN;
  watch.mutedUntil = Number.isFinite(muted) ? muted : 0;

  if (status.ok || now < watch.mutedUntil) {
    clear('watch:reason');
  } else {
    raise('watch:reason', speakable(status.reason || 'The server reports a problem'), 'watchdog', now);
  }
}

if (WATCH_URL) {
  console.log(`Watchdog on: every minute; unreachable for ${WATCH_FAIL_MS / 60000} min -> a problem`);
  setInterval(() => void watchdogTick(), 60 * 1000);
  void watchdogTick();
}

// ---------------------------------------------------------------- Twilio webhooks

// SMS webhook endpoint
app.post('/webhook/sms', twilioWebhookMiddleware, (req, res) => {
  const twiml = new MessagingResponse();
  const incomingMsg = String(req.body.Body || '');
  console.log(`Received SMS from ${req.body.From}: ${incomingMsg}`);

  let responseMessage;
  const text = incomingMsg.toLowerCase();
  if (text.includes('hello')) {
    responseMessage = 'Hello! How can I help you today?';
  } else if (text.includes('help')) {
    responseMessage = 'Available commands: \n- Hello: Get a greeting\n- Help: Show this message\n- Info: Get information';
  } else if (text.includes('info')) {
    responseMessage = 'This is a Twilio webhook demo server. You can customize it to handle your specific use case!';
  } else {
    responseMessage = `You said: "${incomingMsg}". Reply with "help" for available commands.`;
  }

  twiml.message(responseMessage);
  res.type('text/xml');
  res.send(twiml.toString());
});

// Voice webhook endpoint (for call forwarding)
app.post('/webhook/voice', twilioWebhookMiddleware, (req, res) => {
  const twiml = new VoiceResponse();
  console.log(`Received call from ${req.body.From} to ${req.body.To}`);

  if (!FORWARD_TO_NUMBER) {
    console.error('FORWARD_TO_NUMBER environment variable is not set');
    twiml.say('Sorry, call forwarding is not configured properly.');
    twiml.hangup();
  } else {
    console.log(`Forwarding call to ${FORWARD_TO_NUMBER}`);
    twiml.say('Please hold while we connect your call.');
    twiml.dial(FORWARD_TO_NUMBER);
  }

  res.type('text/xml');
  res.send(twiml.toString());
});

// Status callback endpoint (for tracking message delivery)
app.post('/webhook/status', twilioWebhookMiddleware, (req, res) => {
  console.log(`Message ${req.body.MessageSid} status: ${req.body.MessageStatus}`);
  res.status(200).send('OK');
});

// Error handling middleware
app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal Server Error' });
});

const server = app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(
    `Pager: calls at ${CALL_SCHEDULE_MS.map((m) => m / 60000).join(', ')} min, then every ${CALL_REPEAT_MS / 60000} min; ` +
      `quiet ${QUIET_HOURS || 'never'} (${QUIET_TIMEZONE}); answering stops calls for ${ACK_SNOOZE_MS / 60000} min; ` +
      `autopilot can hold calls up to ${AUTOPILOT_MAX_MS / 60000} min once per incident (POST /autopilot)${DRY_RUN ? '; DRY RUN' : ''}`,
  );
});

// Shut down cleanly on SIGTERM/SIGINT (Kubernetes, docker stop): stop accepting, finish requests, exit.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    console.log(`${signal}: shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
