// Frontend Load Test (k6)
// Tests page loads, API calls, and WebSocket connections

import http from 'k6/http';
import { check, sleep } from 'k6';
import ws from 'k6/ws';
import { Rate, Trend, Counter } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const pageLoadLatency = new Trend('page_load_latency');
const apiCallLatency = new Trend('api_call_latency');
const wsConnectionLatency = new Trend('ws_connection_latency');
const staticAssetLatency = new Trend('static_asset_latency');
const wsConnections = new Counter('ws_connections');

// Configuration
const BASE_URL = __ENV.FRONTEND_URL || 'http://frontend.dev.svc.cluster.local:3000';
const WS_URL = __ENV.FRONTEND_WS_URL || 'ws://frontend.dev.svc.cluster.local:3001';
const API_GO_URL = __ENV.API_GO_URL || 'http://go-service.dev.svc.cluster.local:8080';
const API_NODE_URL = __ENV.API_NODE_URL || 'http://node-service.dev.svc.cluster.local:3000';
const RPS_STAGES = JSON.parse(__ENV.RPS_STAGES || '[{"duration": "30s", "target": 10}, {"duration": "30s", "target": 50}, {"duration": "30s", "target": 100}, {"duration": "30s", "target": 150}]');

export const options = {
  stages: RPS_STAGES,
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
    page_load_latency: ['p(95)<1000'],
    api_call_latency: ['p(95)<500'],
    static_asset_latency: ['p(95)<300'],
    ws_connection_latency: ['p(95)<500'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

const params = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '30s',
  tags: { name: 'Frontend' },
};

const pages = ['/', '/dashboard', '/orders', '/notifications', '/settings'];

export default function () {
  // Scenario weights
  const rand = Math.random();

  if (rand < 0.4) {
    // 40% - Page navigation
    navigatePages();
  } else if (rand < 0.7) {
    // 30% - API calls through frontend
    apiCalls();
  } else if (rand < 0.85) {
    // 15% - Static assets
    staticAssets();
  } else {
    // 15% - WebSocket
    websocketTest();
  }

  sleep(Math.random() * 1 + 0.5); // Think time 0.5-1.5s
}

function navigatePages() {
  for (let i = 0; i < 3; i++) {
    const page = pages[Math.floor(Math.random() * pages.length)];
    const start = new Date();
    const res = http.get(`${BASE_URL}${page}`, params);
    pageLoadLatency.add(new Date() - start);

    const success = check(res, {
      [`${page} status 200`]: (r) => r.status === 200,
      [`${page} has content`]: (r) => r.body && r.body.length > 1000,
    });
    errorRate.add(!success);

    sleep(Math.random() * 0.5 + 0.2);
  }
}

function apiCalls() {
  // Test Go Service API through frontend proxy
  if (Math.random() < 0.5) {
    const start = new Date();
    const res = http.get(`${API_GO_URL}/api/v1/orders?limit=10`, params);
    apiCallLatency.add(new Date() - start);

    const success = check(res, {
      'orders API status 200': (r) => r.status === 200,
    });
    errorRate.add(!success);
  }

  // Test Node Service API through frontend proxy
  if (Math.random() < 0.5) {
    const start = new Date();
    const res = http.get(`${API_NODE_URL}/api/v1/notifications?limit=10`, params);
    apiCallLatency.add(new Date() - start);

    const success = check(res, {
      'notifications API status 200': (r) => r.status === 200,
    });
    errorRate.add(!success);
  }

  // Test health endpoints
  http.get(`${API_GO_URL}/health`, params);
  http.get(`${API_NODE_URL}/health`, params);
}

function staticAssets() {
  const assets = [
    '/_next/static/css/app.css',
    '/_next/static/js/main.js',
    '/favicon.ico',
    '/images/logo.png',
  ];

  for (const asset of assets) {
    const start = new Date();
    const res = http.get(`${BASE_URL}${asset}`, {
      ...params,
      tags: { ...params.tags, name: 'StaticAsset' },
    });
    staticAssetLatency.add(new Date() - start);

    check(res, {
      [`${asset} status 200 or 304`]: (r) => r.status === 200 || r.status === 304,
    });
  }
}

function websocketTest() {
  const wsParams = { tags: { name: 'FrontendWS' } };

  ws.connect(WS_URL, wsParams, function (socket) {
    const connStart = new Date();
    wsConnections.add(1);

    socket.on('open', function () {
      wsConnectionLatency.add(new Date() - connStart);

      // Subscribe to channels
      socket.send(JSON.stringify({
        type: 'subscribe',
        channels: ['orders', 'notifications'],
      }));
    });

    socket.on('message', function (message) {
      // Handle incoming messages
    });

    socket.on('close', function () {
      // Connection closed
    });

    socket.on('error', function (e) {
      errorRate.add(true);
    });

    // Keep alive for test duration
    socket.setTimeout(function () {
      socket.close();
    }, 30000);
  });
}