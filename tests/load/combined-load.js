// Combined Load Test (k6)
// Realistic user journey: create order -> check notification -> view dashboard

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import ws from 'k6/ws';
import { Rate, Trend, Counter } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const journeyLatency = new Trend('journey_latency');
const orderCreateLatency = new Trend('order_create_latency');
const notificationCheckLatency = new Trend('notification_check_latency');
const dashboardLoadLatency = new Trend('dashboard_load_latency');
const journeysCompleted = new Counter('journeys_completed');
const journeysFailed = new Counter('journeys_failed');

// Configuration
const FRONTEND_URL = __ENV.FRONTEND_URL || 'http://frontend.dev.svc.cluster.local:3000';
const GO_SERVICE_URL = __ENV.GO_SERVICE_URL || 'http://go-service.dev.svc.cluster.local:8080';
const NODE_SERVICE_URL = __ENV.NODE_SERVICE_URL || 'http://node-service.dev.svc.cluster.local:3000';
const NODE_SERVICE_WS_URL = __ENV.NODE_SERVICE_WS_URL || 'ws://node-service.dev.svc.cluster.local:3001';
const RPS_STAGES = JSON.parse(__ENV.RPS_STAGES || '[{duration: "1m", target: 5}, {duration: "2m", target: 20}, {duration: "1m", target: 50}, {duration: "1m", target: 20}, {duration: "30s", target: 0}]');

export const options = {
  stages: RPS_STAGES,
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.02'],
    journey_latency: ['p(95)<5000'],
    order_create_latency: ['p(95)<500'],
    notification_check_latency: ['p(95)<500'],
    dashboard_load_latency: ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

const params = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '30s',
  tags: { name: 'CombinedJourney' },
};

const testOrders = [
  { customer_email: 'user1@test.com', items: [{ product_id: 'prod-001', quantity: 1, price: 29.99 }] },
  { customer_email: 'user2@test.com', items: [{ product_id: 'prod-002', quantity: 2, price: 49.99 }] },
  { customer_email: 'user3@test.com', items: [{ product_id: 'prod-003', quantity: 1, price: 19.99 }] },
];

export default function () {
  const journeyStart = new Date();
  let journeySuccess = true;

  try {
    // Step 1: Create Order (via Go Service)
    group('Create Order', function () {
      const order = testOrders[Math.floor(Math.random() * testOrders.length)];
      const start = new Date();
      const res = http.post(`${GO_SERVICE_URL}/api/v1/orders`, JSON.stringify(order), params);
      orderCreateLatency.add(new Date() - start);

      const success = check(res, {
        'create order 201': (r) => r.status === 201,
        'create order has id': (r) => {
          try { return r.json().id !== undefined; } catch { return false; }
        },
      });
      errorRate.add(!success);
      if (!success) journeySuccess = false;

      if (success) {
        const orderData = res.json();
        const orderId = orderData.id;

        // Step 2: Wait for notification (simulate async processing)
        sleep(Math.random() * 2 + 1); // 1-3s delay

        // Step 3: Check Notification (via Node Service)
        group('Check Notification', function () {
          const notifStart = new Date();
          const notifRes = http.get(`${NODE_SERVICE_URL}/api/v1/notifications?type=order_created&order_id=${orderId}&limit=1`, params);
          notificationCheckLatency.add(new Date() - notifStart);

          const notifSuccess = check(notifRes, {
            'notification query 200': (r) => r.status === 200,
            'notification found': (r) => {
              try {
                const data = r.json();
                return (data.notifications && data.notifications.length > 0) || (Array.isArray(data) && data.length > 0);
              } catch { return false; }
            },
          });
          errorRate.add(!notifSuccess);
          if (!notifSuccess) journeySuccess = false;
        });

        // Step 4: View Dashboard (via Frontend)
        group('View Dashboard', function () {
          const dashStart = new Date();
          const dashRes = http.get(`${FRONTEND_URL}/dashboard`, params);
          dashboardLoadLatency.add(new Date() - dashStart);

          const dashSuccess = check(dashRes, {
            'dashboard 200': (r) => r.status === 200,
            'dashboard has content': (r) => r.body && r.body.length > 2000,
          });
          errorRate.add(!dashSuccess);
          if (!dashSuccess) journeySuccess = false;
        });

        // Step 5: View Orders Page
        group('View Orders', function () {
          const ordersRes = http.get(`${FRONTEND_URL}/orders`, params);
          check(ordersRes, {
            'orders page 200': (r) => r.status === 200,
          });
        });

        // Step 6: View Notifications Page
        group('View Notifications', function () {
          const notifPageRes = http.get(`${FRONTEND_URL}/notifications`, params);
          check(notifPageRes, {
            'notifications page 200': (r) => r.status === 200,
          });
        });
      }
    });
  } catch (e) {
    journeySuccess = false;
    errorRate.add(true);
    console.log(`Journey error: ${e}`);
  }

  journeyLatency.add(new Date() - journeyStart);
  if (journeySuccess) {
    journeysCompleted.add(1);
  } else {
    journeysFailed.add(1);
  }

  // Think time between journeys
  sleep(Math.random() * 3 + 2); // 2-5s
}

// Optional: WebSocket connection test for real-time updates
export function setup() {
  // Verify services are reachable
  const services = [
    { name: 'Frontend', url: `${FRONTEND_URL}/health` },
    { name: 'Go Service', url: `${GO_SERVICE_URL}/health` },
    { name: 'Node Service', url: `${NODE_SERVICE_URL}/health` },
  ];

  for (const svc of services) {
    const res = http.get(svc.url, { timeout: '10s' });
    if (res.status !== 200) {
      console.log(`WARNING: ${svc.name} health check failed: ${res.status}`);
    } else {
      console.log(`${svc.name} health check OK`);
    }
  }
}

export function teardown() {
  console.log('Combined load test completed');
}