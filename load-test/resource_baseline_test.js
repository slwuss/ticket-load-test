import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import exec from 'k6/execution';

// ── Custom metrics ───────────────────────────────────────────────────────────
const reserveOK   = new Counter('reserve_ok');
const reserveFail = new Counter('reserve_fail');
const confirmOK   = new Counter('confirm_ok');
const confirmFail = new Counter('confirm_fail');
const reserveDuration = new Trend('reserve_duration_ms', true);
const confirmDuration = new Trend('confirm_duration_ms', true);
const errorRate       = new Rate('error_rate');

// ── Load profile ─────────────────────────────────────────────────────────────
// constant-arrival-rate holds exactly 1000 iterations/min regardless of VU count.
// k6 spins up more VUs automatically if needed to maintain the rate.
// Duration 10m = 10,000 total transactions — well within the 15,000 seat pool.
export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    steady_booking: {
      executor:        'constant-arrival-rate',
      rate:            1000,
      timeUnit:        '1m',   // 1000 iterations per minute ≈ 16.67/sec
      duration:        '10m',
      preAllocatedVUs: 50,     // warm VU pool — enough for ~1s iterations at 16.67/s
      maxVUs:          150,    // ceiling in case latency spikes and more VUs are needed
    },
  },
  thresholds: {
    http_req_duration:    ['p(95)<500',  'p(99)<1000'],
    http_req_failed:      ['rate<0.01'],
    error_rate:           ['rate<0.01'],
    reserve_duration_ms:  ['p(95)<300'],
    confirm_duration_ms:  ['p(95)<500'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// Seat pool: evt-001 owns slots 0–4999, evt-002 owns slots 5000–14999.
// Each iteration picks a globally unique slot via iterationInTest so no two
// VUs ever touch the same seat — zero 409s, zero lock contention.
const SEAT_POOL = [
  { eventId: 'evt-001', size: 5000  },
  { eventId: 'evt-002', size: 10000 },
];
const TOTAL_SEATS = SEAT_POOL.reduce((s, e) => s + e.size, 0); // 15000

function assignSeat(globalIndex) {
  const i = globalIndex % TOTAL_SEATS;
  let offset = 0;
  for (const pool of SEAT_POOL) {
    if (i < offset + pool.size) {
      return { eventId: pool.eventId, seatId: `S${i - offset + 1}` };
    }
    offset += pool.size;
  }
}

function randomUser() {
  return `user-${Math.floor(Math.random() * 10_000_000)}`;
}

// ── Scenario ─────────────────────────────────────────────────────────────────
export default function () {
  const { eventId, seatId } = assignSeat(exec.scenario.iterationInTest);
  const userId  = randomUser();
  const headers = { 'Content-Type': 'application/json' };

  // Step 1: Reserve
  const t0 = Date.now();
  const reserveRes = http.post(
    `${BASE_URL}/api/v1/events/${eventId}/reserve`,
    JSON.stringify({ seat_id: seatId, user_id: userId }),
    { headers, timeout: '10s' }
  );
  reserveDuration.add(Date.now() - t0);

  const reserveOk = check(reserveRes, {
    'reserve 202':     (r) => r.status === 202,
    'reserve <500ms':  (r) => r.timings.duration < 500,
  });

  errorRate.add(!reserveOk);

  if (!reserveOk) {
    reserveFail.add(1);
    return;
  }

  reserveOK.add(1);

  const bookingId = JSON.parse(reserveRes.body).booking_id;

  // Simulate user reviewing before confirming (keeps the flow realistic)
  sleep(0.5);

  // Step 2: Confirm
  const t1 = Date.now();
  const confirmRes = http.post(
    `${BASE_URL}/api/v1/bookings/${bookingId}/confirm`,
    JSON.stringify({ user_id: userId, event_id: eventId, seat_id: seatId }),
    { headers, timeout: '10s' }
  );
  confirmDuration.add(Date.now() - t1);

  const confirmOk = check(confirmRes, {
    'confirm 202':    (r) => r.status === 202,
    'confirm <500ms': (r) => r.timings.duration < 500,
  });

  if (confirmOk) {
    confirmOK.add(1);
  } else {
    confirmFail.add(1);
    errorRate.add(1);
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const m          = data.metrics;
  const durationMin = (data.state?.testRunDurationMs || 600000) / 60000;
  const totalIter   = m.iterations?.values.count || 0;

  const summary = {
    target_tpm:       1000,
    actual_tpm:       (totalIter / durationMin).toFixed(1),
    total_iterations: totalIter,

    reserve_ok:       m.reserve_ok?.values.count   || 0,
    reserve_fail:     m.reserve_fail?.values.count || 0,
    confirm_ok:       m.confirm_ok?.values.count   || 0,
    confirm_fail:     m.confirm_fail?.values.count || 0,

    p50_reserve_ms:   m.reserve_duration_ms?.values['p(50)'] || 0,
    p95_reserve_ms:   m.reserve_duration_ms?.values['p(95)'] || 0,
    p99_reserve_ms:   m.reserve_duration_ms?.values['p(99)'] || 0,

    p50_confirm_ms:   m.confirm_duration_ms?.values['p(50)'] || 0,
    p95_confirm_ms:   m.confirm_duration_ms?.values['p(95)'] || 0,
    p99_confirm_ms:   m.confirm_duration_ms?.values['p(99)'] || 0,

    p95_http_ms:      m.http_req_duration?.values['p(95)'] || 0,
    error_rate_pct:   (((m.error_rate?.values.rate || 0) * 100).toFixed(2)) + '%',
  };

  console.log('\n=== RESOURCE BASELINE — 1000 TPM STEADY STATE ===');
  Object.entries(summary).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

  return {
    stdout:                         JSON.stringify(summary, null, 2),
    'resource-baseline-result.json': JSON.stringify(data, null, 2),
  };
}
