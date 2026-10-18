// Go Service Load Test (k6)
// Tests order create/list endpoints at increasing RPS

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const orderCreateLatency = new Trend('order_create_latency');
const orderListLatency = new Trend('order_list_latency');
const orderGetLatency = new Trend('order_get_latency');

// Configuration
const BASE_URL = __ENV.GO_SERVICE_URL || 'http://go-service.dev.svc.cluster.local:8080';
const RPS_STAGES = JSON.parse(__ENV.RPS_STAGES || '[{duration: "30s", target: 10}, {duration: "30s", target: 50}, {duration: "30s", target: 100}, {duration: "30s", target: 200}]');

export const options = {
  stages: RPS_STAGES,
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
    order_create_latency: ['p(95)<500'],
    order_list_latency: ['p(95)<300'],
    order_get_latency: ['p(95)<200'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// Test data
const testOrders = [
  { customer_email: 'test1@example.com', items: [{ product_id: 'prod-001', quantity: 2, price: 29.99 }] },
  { customer_email: 'test2@example.com', items: [{ product_id: 'prod-002', quantity: 1, price: 49.99 }] },
  { customer_email: 'test3@example.com', items: [{ product_id: 'prod-003', quantity: 3, price: 19.99 }] },
];

let orderIds = [];

export function setup() {
  // Warm up - create some initial orders
  const params = { headers: { 'Content-Type': 'application/json' }, timeout: '30s' };
  for (const order of testOrders) {
    const res = http.post(`${BASE_URL}/api/v1/orders`, JSON.stringify(order), params);
    if (res.status === 201) {
      const data = res.json();
      if (data.id) orderIds.push(data.id);
    }
  }
  return { orderIds };
}

export default function (data) {
  const params = {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
    tags: { name: 'GoService' },
  };

  // Test 1: Create Order (20% of requests)
  if (Math.random() < 0.2) {
    const order = testOrders[Math.floor(Math.random() * testOrders.length)];
    const start = new Date();
    const res = http.post(`${BASE_URL}/api/v1/orders`, JSON.stringify(order), params);
    orderCreateLatency.add(new Date() - start);

    const success = check(res, {
      'create order status 201': (r) => r.status === 201,
      'create order has id': (r) => {
        try {
          const d = r.json();
          return d.id !== undefined;
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!success);

    if (success) {
      try {
        const d = res.json();
        if (d.id) orderIds.push(d.id);
      } catch {}
    }
  }
  // Test 2: List Orders (40% of requests)
  else if (Math.random() < 0.6) {
    const start = new Date();
    const res = http.get(`${BASE_URL}/api/v1/orders?limit=20`, params);
    orderListLatency.add(new Date() - start);

    const success = check(res, {
      'list orders status 200': (r) => r.status === 200,
      'list orders returns array': (r) => {
        try {
          const d = r.json();
          return Array.isArray(d.orders) || Array.isArray(d);
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!success);
  }
  // Test 3: Get Order (40% of requests)
  else {
    if (orderIds.length > 0 || data.orderIds.length > 0) {
      const ids = orderIds.length > 0 ? orderIds : data.orderIds;
      const orderId = ids[Math.floor(Math.random() * ids.length)];
      const start = new Date();
      const res = http.get(`${BASE_URL}/api/v1/orders/${orderId}`, params);
      orderGetLatency.add(new Date() - start);

      const success = check(res, {
        'get order status 200': (r) => r.status === 200,
        'get order has correct id': (r) => {
          try {
            const d = r.json();
            return d.id === orderId;
          } catch {
            return false;
          }
        },
      });
      errorRate.add(!success);
    }
  }

  sleep(Math.random() * 0.5); // Small think time
}

export function teardown(data) {
  // Cleanup - delete test orders (optional)
  console.log(`Test completed. Created ${data.orderIds.length} orders during warmup.`);
}