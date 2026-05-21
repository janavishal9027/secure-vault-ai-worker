#!/usr/bin/env bash
#
# Runs ON THE LXD HOST (the VPS), invoked by ci/deploy.sh via SSH.
# Same shape as the notes / ai-core-service deploy-remote scripts.

set -euxo pipefail

: "${APP_NAME:?}"
: "${KUBE_NAMESPACE:?}"
: "${IMAGE_REPO:?}"
: "${IMAGE_TAG:?}"
: "${INGRESS_HOST:?}"
: "${REMOTE_DIR:?}"
: "${LXD_CONTAINER:?}"
: "${LXD_BRIDGE_IP:?}"
REPLICAS="${REPLICAS:-1}"

export PATH="/snap/bin:$PATH"

mkdir -p "$REMOTE_DIR"
exec > >(tee -a "$REMOTE_DIR/deploy.log") 2>&1

echo "=== deploy-remote.sh starting at $(date -Iseconds) ==="
echo "    APP_NAME=$APP_NAME  LXD_CONTAINER=$LXD_CONTAINER  KUBE_NAMESPACE=$KUBE_NAMESPACE"
echo "    IMAGE=$IMAGE_REPO:$IMAGE_TAG  INGRESS_HOST=$INGRESS_HOST  REPLICAS=$REPLICAS"

cd "$REMOTE_DIR"

lxc_retry() {
  local attempt=1
  local max_attempts=4
  local rc=0
  while [ "$attempt" -le "$max_attempts" ]; do
    if "$@"; then return 0; fi
    rc=$?
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "  lxc operation failed after ${max_attempts} attempts (rc=${rc}): $*" >&2
      return $rc
    fi
    echo "  lxc operation failed (attempt ${attempt}/${max_attempts}, rc=${rc}); retrying in 2s..." >&2
    sleep 2
    attempt=$((attempt + 1))
  done
}

echo "=== Waiting for k3s to be ready in $LXD_CONTAINER (max 5 min) ==="
ATTEMPT=0
MAX_ATTEMPTS=60
until lxc exec "$LXD_CONTAINER" -- /usr/local/bin/k3s kubectl get nodes >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: k3s never came up in $LXD_CONTAINER after 5 minutes." >&2
    lxc_retry lxc exec "$LXD_CONTAINER" -- tail -n 80 /var/log/cloud-init-output.log >&2 || true
    exit 1
  fi
  echo "  attempt ${ATTEMPT}/${MAX_ATTEMPTS}: k3s API not yet responding, retrying in 5s..."
  sleep 5
done

kubectl_in_container() {
  lxc_retry lxc exec "$LXD_CONTAINER" -- /usr/local/bin/k3s kubectl "$@"
}

echo "=== Namespace ==="
kubectl_in_container get namespace "$KUBE_NAMESPACE" >/dev/null 2>&1 \
  || kubectl_in_container create namespace "$KUBE_NAMESPACE"

echo "=== Pushing manifests into $LXD_CONTAINER ==="
lxc_retry lxc exec "$LXD_CONTAINER" -- mkdir -p "/tmp/manifests/${APP_NAME}"
for f in deployment.yml service.yml ingress.yml; do
  lxc_retry lxc file push "$f" "${LXD_CONTAINER}/tmp/manifests/${APP_NAME}/${f}"
  if ! lxc_retry lxc exec "$LXD_CONTAINER" -- test -s "/tmp/manifests/${APP_NAME}/${f}"; then
    echo "ERROR: /tmp/manifests/${APP_NAME}/${f} missing or empty inside container after push" >&2
    exit 1
  fi
done

echo "=== Applying manifests to namespace '$KUBE_NAMESPACE' ==="
for f in deployment.yml service.yml ingress.yml; do
  echo "--- applying $f ---"
  kubectl_in_container -n "$KUBE_NAMESPACE" apply -f "/tmp/manifests/${APP_NAME}/$f" -o name
done

verify_resource() {
  local kind="$1" name="$2"
  if ! kubectl_in_container -n "$KUBE_NAMESPACE" get "$kind" "$name" >/dev/null 2>&1; then
    echo "ERROR: $kind/$name not found in namespace $KUBE_NAMESPACE after apply" >&2
    kubectl_in_container -n "$KUBE_NAMESPACE" get all,ingress -o wide >&2 || true
    exit 1
  fi
  kubectl_in_container -n "$KUBE_NAMESPACE" get "$kind" "$name"
}
verify_resource deployment "${APP_NAME}-deployment"
verify_resource service    "${APP_NAME}-service"
verify_resource ingress    "${APP_NAME}-ingress"

echo "=== Waiting for deployment to be Available (max 4 min) ==="
kubectl_in_container -n "$KUBE_NAMESPACE" \
  wait "deployment/${APP_NAME}-deployment" \
  --for=condition=Available --timeout=240s

echo "=== Service endpoints ==="
endpoints=$(kubectl_in_container -n "$KUBE_NAMESPACE" \
  get "endpoints/${APP_NAME}-service" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
if [[ -z "$endpoints" ]]; then
  echo "ERROR: service ${APP_NAME}-service has no endpoints — pod not Ready or selector mismatch" >&2
  exit 1
fi
echo "endpoints: $endpoints"

# Routing test: GET /ai-worker/health — Traefik strips /ai-worker via
# the Middleware and forwards /health to the pod, which returns 200.
echo "=== Routing test (Traefik forwards /ai-worker/* to the service?) ==="
body=$(lxc_retry lxc exec "$LXD_CONTAINER" -- curl -s --max-time 10 \
  -H "Host: $INGRESS_HOST" \
  http://127.0.0.1/ai-worker/health || true)
status=$(lxc_retry lxc exec "$LXD_CONTAINER" -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Host: $INGRESS_HOST" \
  http://127.0.0.1/ai-worker/health || true)
echo "GET /ai-worker/health -> HTTP $status"
echo "body: ${body:-<empty>}"
if [[ "$status" != "200" ]]; then
  echo "ERROR: /ai-worker/health did not return 200 — ingress/Middleware not wired up for $INGRESS_HOST/ai-worker" >&2
  kubectl_in_container -n "$KUBE_NAMESPACE" describe "ingress/${APP_NAME}-ingress" >&2 || true
  kubectl_in_container -n "$KUBE_NAMESPACE" get middleware.traefik.io >&2 || true
  exit 1
fi
echo "OK: /ai-worker/health returned 200 — Traefik StripPrefix is wired up"

echo "=== Installing nginx location snippet for $APP_NAME ==="
SNIPPET_DIR="/etc/nginx/snippets/${KUBE_NAMESPACE}"
SNIPPET_DST="${SNIPPET_DIR}/${APP_NAME}.location.conf"
mkdir -p "$SNIPPET_DIR"
cp "$REMOTE_DIR/${APP_NAME}.location.conf" "$SNIPPET_DST"
echo "Installed snippet at $SNIPPET_DST"

echo "=== nginx -t (config validation) ==="
nginx -t

echo "=== Reloading nginx ==="
systemctl reload nginx
echo "nginx reloaded"

echo "=== Final namespace state ==="
kubectl_in_container -n "$KUBE_NAMESPACE" get all,ingress -o wide
echo "=== Deploy complete: $APP_NAME -> $LXD_CONTAINER/$KUBE_NAMESPACE @ $IMAGE_REPO:$IMAGE_TAG ==="
echo "=== deploy-remote.sh finished at $(date -Iseconds) ==="
