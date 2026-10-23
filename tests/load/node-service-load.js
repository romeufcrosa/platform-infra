// Node Service Load Test (k6)
// Tests notification queries and WebSocket connections

import http from 'k6/http';
import { check, sleep } from 'k6';
import ws from 'k6/ws';
import { Rate, Trend, Counter } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const notificationQueryLatency = new Trend('notification_query_latency');
const wsConnectionLatency = new Trend('ws_connection_latency');
const wsMessageLatency = new Trend('ws_message_latency');
const wsConnections = new Counter('ws_connections');
const wsMessages = new Counter('ws_messages');

// Configuration
const BASE_URL = __ENV.NODE_SERVICE_URL || 'http://node-service.dev.svc.cluster.local:3000';
const WS_URL = __ENV.NODE_SERVICE_WS_URL || 'ws://node-service.dev.svc.cluster.local:3001';
const RPS_STAGES = JSON.parse(__ENV.RPS_STAGES || '[{"duration": "30s", "target": 10}, {"duration": "30s", "target": 50}, {"duration": "30s", "target": 100}, {"duration": "30s", "target": 150}]');

export const options = {
  stages: RPS_STAGES,
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
    notification_query_latency: ['p(95)<500'],
    ws_connection_latency: ['p(95)<300'],
    ws_message_latency: ['p(95)<100'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  ext: {
    loadimpact: {
      projectID: __ENV.K6_PROJECT_ID,
      name: 'Node Service Load Test',
    },
  },
};

const params = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '30s',
  tags: { name: 'NodeService' },
};

export default function () {
  // Scenario 1: HTTP Notification Queries (70% of VUs)
  if (__ITER % 10 < 7) {
    httpQueries();
  }
  // Scenario 2: WebSocket Connections (30% of VUs)
  else {
    websocketTest();
  }

  sleep(Math.random() * 0.5);
}

function httpQueries() {
  // Test 1: List notifications (50% of HTTP queries)
  if (Math.random() < 0.5) {
    const start = new Date();
    const res = http.get(`${BASE_URL}/api/v1/notifications?limit=50`, params);
    notificationQueryLatency.add(new Date() - start);

    const success = check(res, {
      'list notifications status 200': (r) => r.status === 200,
      'list notifications returns data': (r) => {
        try {
          const d = r.json();
          return d.notifications !== undefined || Array.isArray(d);
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!success);
  }
  // Test 2: Get notification by ID (25%)
  else if (Math.random() < 0.5) {
    const notificationId = `notif-${Math.floor(Math.random() * 1000)}`;
    const start = new Date();
    const res = http.get(`${BASE_URL}/api/v1/notifications/${notificationId}`, params);
    notificationQueryLatency.add(new Date() - start);

    const success = check(res, {
      'get notification status 200 or 404': (r) => r.status === 200 || r.status === 404,
    });
    errorRate.add(!success);
  }
  // Test 3: Search notifications (25%)
  else {
    const start = new Date();
    const res = http.get(`${BASE_URL}/api/v1/notifications?type=order_created&limit=20`, params);
    notificationQueryLatency.add(new Date() - start);

    const success = check(res, {
      'search notifications status 200': (r) => r.status === 200,
    });
    errorRate.add(!success);
  }

  // Test health endpoint (every iteration)
  const healthRes = http.get(`${BASE_URL}/health`, params);
  check(healthRes, { 'health status 200': (r) => r.status === 200 });
}

function websocketTest() {
  const wsParams = { tags: { name: 'NodeServiceWS' } };

  ws.connect(WS_URL, wsParams, function (socket) {
    const connStart = new Date();
    wsConnections.add(1);

    socket.on('open', function () {
      wsConnectionLatency.add(new Date() - connStart);

      // Send ping message
      const msgStart = new Date();
      socket.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
      wsMessageLatency.add(new Date() - msgStart);
      wsMessages.add(1);
    });

    socket.on('message', function (message) {
      const msgStart = new Date();
      try {
        const data = JSON.parse(message);
        if (data.type === 'pong') {
          wsMessageLatency.add(new Date() - msgStart);
          wsMessages.add(1);
        }
      } catch {}

      // Send another ping
      socket.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
    });

    socket.on('close', function () {
      // Connection closed
    });

    socket.on('error', function (e) {
      errorRate.add(true);
      console.log(`WebSocket error: ${e.error()}`);
    });

    // Keep connection alive for the test duration
    socket.setTimeout(function () {
      socket.close();
    }, 30000);
  });
}