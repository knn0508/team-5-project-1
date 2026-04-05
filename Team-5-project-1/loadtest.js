import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('error_rate');
const BASE = (__ENV.TARGET_URL || 'https://20.124.33.118').replace(/\/+$/, '');
const PRODUCT_ID = __ENV.PRODUCT_ID || '1';
const PRODUCT_CATEGORY = __ENV.PRODUCT_CATEGORY || 'Electronics';
const USE_SYNTHETIC_XFF = (__ENV.USE_SYNTHETIC_XFF || 'true').toLowerCase() === 'true';

export const options = {
  insecureSkipTLSVerify: true,
  stages: [
    { duration: '2m', target: 50 },
    { duration: '5m', target: 200 },
    { duration: '3m', target: 200 },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<3000'],
    http_req_failed: ['rate<0.05'],
    error_rate: ['rate<0.05'],
    checks: ['rate>0.95'],
  },
};

function buildHeaders() {
  if (!USE_SYNTHETIC_XFF) {
    return {};
  }

  const thirdOctet = ((__VU - 1) % 250) + 1;
  const fourthOctet = (__ITER % 250) + 1;

  return {
    'X-Forwarded-For': `10.42.${thirdOctet}.${fourthOctet}`,
  };
}

function recordChecks(response, checks) {
  errorRate.add(response.status >= 400);
  check(response, checks);
}

function get(path, checks) {
  const response = http.get(`${BASE}${path}`, {
    headers: buildHeaders(),
  });

  recordChecks(response, checks);
  return response;
}

export default function () {
  const routeSelector = Math.random();

  if (routeSelector < 0.35) {
    group('Frontend', () => {
      get('/', {
        'homepage 200': (r) => r.status === 200,
      });
    });
  } else if (routeSelector < 0.5) {
    group('Frontend Health', () => {
      get('/health', {
        'health 200': (r) => r.status === 200,
        'health body contains healthy': (r) => r.body && r.body.indexOf('healthy') !== -1,
      });
    });
  } else if (routeSelector < 0.85) {
    group('API Products List', () => {
      get(`/api/products?page=1&limit=12&category=${encodeURIComponent(PRODUCT_CATEGORY)}`, {
        'products list 200': (r) => r.status === 200,
        'products list contains products': (r) => r.body && r.body.indexOf('"products"') !== -1,
      });
    });
  } else {
    group('API Product Detail', () => {
      get(`/api/products/${PRODUCT_ID}`, {
        'product detail 200': (r) => r.status === 200,
        'product detail contains product': (r) => r.body && r.body.indexOf('"product"') !== -1,
      });
    });
  }

  sleep(1);
}

