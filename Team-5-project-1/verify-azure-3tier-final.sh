#!/usr/bin/env bash
set -uo pipefail

# =========================
# Azure 3-Tier Final Verification
# =========================

RG="rg-webapp-prod-team-5"
GW_IP="20.124.33.118"
BASE="https://$GW_IP"
SQL_SERVER="sql-webapp-prod-team-5-1"
FRONTEND_APP="ca-frontend"
BACKEND_APP="ca-backend"

PASS=0
FAIL=0

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 2
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $message"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $message — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    echo "  ✓ $message"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $message — did not find '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

section() {
  echo
  echo "══ $1 ══"
}

require_cmd curl
require_cmd az
require_cmd grep
require_cmd sed
require_cmd wc

FE_FQDN=$(az containerapp show \
  --resource-group "$RG" \
  --name "$FRONTEND_APP" \
  --query properties.configuration.ingress.fqdn -o tsv 2>/dev/null || true)

BE_FQDN=$(az containerapp show \
  --resource-group "$RG" \
  --name "$BACKEND_APP" \
  --query properties.configuration.ingress.fqdn -o tsv 2>/dev/null || true)

FE_EXTERNAL=$(az containerapp show \
  --resource-group "$RG" \
  --name "$FRONTEND_APP" \
  --query properties.configuration.ingress.external -o tsv 2>/dev/null || true)

BE_EXTERNAL=$(az containerapp show \
  --resource-group "$RG" \
  --name "$BACKEND_APP" \
  --query properties.configuration.ingress.external -o tsv 2>/dev/null || true)

echo "Azure 3-Tier Final Verification"
echo "Resource Group: $RG"
echo "Gateway: $BASE"

# ---------------------------------
# 1. Functional Test
# ---------------------------------
section "Functional Test"

HOME_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE/" || true)
assert_eq "$HOME_STATUS" "200" "Homepage loads through App Gateway"

FRONT_HEALTH_BODY=$(curl -sk "$BASE/health" || true)
assert_contains "$FRONT_HEALTH_BODY" "healthy" "Frontend health endpoint reports healthy"

API_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE/api/products" || true)
assert_eq "$API_STATUS" "200" "GET /api/products returns HTTP 200"

PRODUCTS_BODY=$(curl -sk "$BASE/api/products" || true)
assert_contains "$PRODUCTS_BODY" "\"products\"" "Products API returns a products array"
assert_contains "$PRODUCTS_BODY" "Wireless Headphones" "Products API returns seeded DB data"

# ---------------------------------
# 2. Routing Verification
# ---------------------------------
section "Routing Verification"

HTTP_ROOT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$GW_IP/" || true)
assert_eq "$HTTP_ROOT_STATUS" "301" "HTTP listener redirects to HTTPS"

HTTPS_ROOT_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE/" || true)
assert_eq "$HTTPS_ROOT_STATUS" "200" "Route '/' is served successfully"

API_ROUTE_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE/api/products" || true)
assert_eq "$API_ROUTE_STATUS" "200" "Route '/api/*' is served successfully"

# ---------------------------------
# 3. Public Access Verification
# ---------------------------------
section "Public Access Verification"

GW_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE/" || true)
if [ "$GW_STATUS" = "200" ] || [ "$GW_STATUS" = "301" ] || [ "$GW_STATUS" = "302" ]; then
  echo "  ✓ App Gateway is publicly reachable"
  PASS=$((PASS + 1))
else
  echo "  ✗ App Gateway should be publicly reachable — got HTTP $GW_STATUS"
  FAIL=$((FAIL + 1))
fi

if [ "$FE_EXTERNAL" = "false" ]; then
  echo "  ✓ Frontend Container App ingress is internal-only"
  PASS=$((PASS + 1))
else
  echo "  ✗ Frontend Container App is publicly exposed"
  FAIL=$((FAIL + 1))
fi

if [ "$BE_EXTERNAL" = "false" ]; then
  echo "  ✓ Backend Container App ingress is internal-only"
  PASS=$((PASS + 1))
else
  echo "  ✗ Backend Container App is publicly exposed"
  FAIL=$((FAIL + 1))
fi

SQL_PNA=$(az sql server show \
  --resource-group "$RG" \
  --name "$SQL_SERVER" \
  --query publicNetworkAccess -o tsv 2>/dev/null || true)

if [ "$SQL_PNA" = "Disabled" ]; then
  echo "  ✓ SQL Server public network access is disabled"
  PASS=$((PASS + 1))
else
  echo "  ✗ SQL Server public network access should be disabled — got '$SQL_PNA'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------
# 4. Monitoring and Alerts Verification
# ---------------------------------
section "Monitoring and Alerts Verification"

METRIC_ALERTS=$(az resource list \
  --resource-group "$RG" \
  --resource-type Microsoft.Insights/metricAlerts \
  --query "[].name" -o tsv 2>/dev/null || true)

METRIC_ALERT_COUNT=$(printf '%s\n' "$METRIC_ALERTS" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$METRIC_ALERT_COUNT" -ge 3 ]; then
  echo "  ✓ At least 3 metric alerts are configured ($METRIC_ALERT_COUNT found)"
  PASS=$((PASS + 1))
else
  echo "  ✗ At least 3 metric alerts are required — found $METRIC_ALERT_COUNT"
  FAIL=$((FAIL + 1))
fi

for alert in alert-cpu-frontend alert-cpu-backend alert-5xx-gateway alert-sql-dtu; do
  if printf '%s\n' "$METRIC_ALERTS" | grep -qx "$alert"; then
    echo "  ✓ Metric alert exists: $alert"
    PASS=$((PASS + 1))
  else
    echo "  ✗ Metric alert missing: $alert"
    FAIL=$((FAIL + 1))
  fi
done

SCHEDULED_ALERTS=$(az resource list \
  --resource-group "$RG" \
  --resource-type Microsoft.Insights/scheduledQueryRules \
  --query "[].name" -o tsv 2>/dev/null || true)

if [ -n "$SCHEDULED_ALERTS" ]; then
  echo "  ✓ Scheduled query alerts found"
  PASS=$((PASS + 1))
  printf '%s\n' "$SCHEDULED_ALERTS" | sed 's/^/    - /'
else
  echo "  ! No scheduled query alerts found"
fi

# ---------------------------------
# 5. Evidence Output
# ---------------------------------
section "Evidence Output"

echo "Gateway:"
echo "  - $BASE"

echo "Frontend Container App:"
echo "  - External ingress: ${FE_EXTERNAL:-unknown}"
echo "  - FQDN: ${FE_FQDN:-unknown}"

echo "Backend Container App:"
echo "  - External ingress: ${BE_EXTERNAL:-unknown}"
echo "  - FQDN: ${BE_FQDN:-unknown}"

echo "Metric Alerts:"
if [ -n "$METRIC_ALERTS" ]; then
  printf '%s\n' "$METRIC_ALERTS" | sed 's/^/  - /'
else
  echo "  (none)"
fi

echo
echo "Scheduled Query Alerts:"
if [ -n "$SCHEDULED_ALERTS" ]; then
  printf '%s\n' "$SCHEDULED_ALERTS" | sed 's/^/  - /'
else
  echo "  (none)"
fi

echo
echo "SQL publicNetworkAccess: ${SQL_PNA:-unknown}"

# ---------------------------------
# Final Summary
# ---------------------------------
section "Summary"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "Final verification passed."
  exit 0
else
  echo
  echo "Final verification failed."
  exit 1
fi
