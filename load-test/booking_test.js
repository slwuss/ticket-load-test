import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ── Custom metrics ──────────────────────────────────────────────────────────
const reserveSuccess  = new Counter('reserve_success');
const reserveConflict = new Counter('reserve_conflict');   // seat taken (expected)
const reserveFail     = new Counter('reserve_fail');       // unexpected errors
const confirmSuccess  = new Counter('confirm_success');
const confirmFail     = new Counter('confirm_fail');
const reserveDuration = new Trend('reserve_duration_ms', true);
const confirmDuration = new Trend('confirm_duration_ms', true);
const errorRate       = new Rate('error_rate');

// ── Load profile ────────────────────────────────────────────────────────────
// Ramp to 20,000 concurrent VUs simulating a concert ticket flash sale.
// Stages:
//   0→2k  VUs in 30s  — warm up
//   2k→20k VUs in 60s — flash sale spike
//   20k    VUs for 2m — sustained peak (this is where we measure)
//   20k→0  VUs in 30s — cool down
export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
  stages: [
    { duration: '30s',  target: 500  },
    { duration: '60s',  target: 1000 },
    { duration: '120s', target: 1000 },
    { duration: '30s',  target: 0     },
  ],
  thresholds: {
    // SLOs we must hit
    http_req_duration:        ['p(50)<200', 'p(95)<500', 'p(99)<1000'],
    http_req_failed:          ['rate<0.01'],                 // <1% HTTP errors
    error_rate:               ['rate<0.02'],                 // <2% application errors
    reserve_duration_ms:      ['p(50)<150', 'p(95)<300'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

const EVENTS = [
  { id: 'evt-001', seats: 5000  },
  { id: 'evt-002', seats: 10000 },
];

function randomEvent() {
  return EVENTS[Math.floor(Math.random() * EVENTS.length)];
}

function randomSeat(totalSeats) {
  const row  = String.fromCharCode(65 + Math.floor(Math.random() * 26));  // A–Z
  const seat = Math.floor(Math.random() * (totalSeats / 26)) + 1;
  return `${row}${seat}`;
}

function randomUser() {
  return `user-${Math.floor(Math.random() * 1_000_000)}`;
}

// ── Main scenario ────────────────────────────────────────────────────────────
export default function () {
  const userId  = randomUser();
  const event   = randomEvent();
  const seatId  = randomSeat(event.seats);

  const headers = { 'Content-Type': 'application/json' };

  // Step 1: Reserve a seat
  const reserveStart = Date.now();
  const reserveRes = http.post(
    `${BASE_URL}/api/v1/events/${event.id}/reserve`,
    JSON.stringify({ seat_id: seatId, user_id: userId }),
    { headers, timeout: '5s' }
  );
  reserveDuration.add(Date.now() - reserveStart);

  const reserveOK = check(reserveRes, {
    'reserve: status is 202 or 409': (r) => r.status === 202 || r.status === 409,
    'reserve: response time < 500ms': (r) => r.timings.duration < 500,
  });

  errorRate.add(!reserveOK);

  if (reserveRes.status === 409) {
    reserveConflict.add(1);
    return;  // seat taken — this is expected behaviour, not an error
  }

  if (reserveRes.status !== 202) {
    reserveFail.add(1);
    return;
  }

  reserveSuccess.add(1);

  const body = JSON.parse(reserveRes.body);
  const bookingId = body.booking_id;

  // Brief pause to simulate user reviewing booking (realistic think time)
  sleep(Math.random() * 2 + 0.5);  // 0.5–2.5s

  // Step 2: Confirm the booking
  const confirmStart = Date.now();
  const confirmRes = http.post(
    `${BASE_URL}/api/v1/bookings/${bookingId}/confirm`,
    JSON.stringify({ user_id: userId, event_id: event.id, seat_id: seatId }),
    { headers, timeout: '10s' }
  );
  confirmDuration.add(Date.now() - confirmStart);

  const confirmOK = check(confirmRes, {
    'confirm: status is 202': (r) => r.status === 202,
    'confirm: response time < 500ms': (r) => r.timings.duration < 500,
  });

  if (confirmOK) {
    confirmSuccess.add(1);
  } else {
    confirmFail.add(1);
    errorRate.add(1);
  }
}

// ── Summary ──────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const summary = {
    total_vus:         data.metrics.vus_max.values.max,
    reserve_success:   data.metrics.reserve_success?.values.count  || 0,
    reserve_conflict:  data.metrics.reserve_conflict?.values.count || 0,
    reserve_fail:      data.metrics.reserve_fail?.values.count     || 0,
    confirm_success:   data.metrics.confirm_success?.values.count  || 0,
    confirm_fail:      data.metrics.confirm_fail?.values.count     || 0,
    p50_reserve_ms:    data.metrics.reserve_duration_ms?.values['p(50)'] || 0,
    p95_reserve_ms:    data.metrics.reserve_duration_ms?.values['p(95)'] || 0,
    p50_confirm_ms:    data.metrics.confirm_duration_ms?.values['p(50)'] || 0,
    p95_confirm_ms:    data.metrics.confirm_duration_ms?.values['p(95)'] || 0,
    p50_http_ms:       data.metrics.http_req_duration?.values['p(50)']   || 0,
    p95_http_ms:       data.metrics.http_req_duration?.values['p(95)']   || 0,
    error_rate_pct:    ((data.metrics.error_rate?.values.rate || 0) * 100).toFixed(2) + '%',
  };

  console.log('\n=== LOAD TEST SUMMARY ===');
  Object.entries(summary).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

  return {
    'stdout': JSON.stringify(summary, null, 2),
    'load-test-result.json': JSON.stringify(data, null, 2),
  };
}
