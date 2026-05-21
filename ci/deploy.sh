#!/usr/bin/env bash
#
# Deploy the ai-worker service to one of the secure-vault-* k3s clusters.
# Mirrors the notes / ai-core-service deploy structure: render locally,
# scp, run remote script.
#
# Required environment variables (set per environment in Bitbucket
# Deployment variables):
#   VPS_USER, VPS_HOST                SSH details for the LXD host
#   REMOTE_DIR                        Shared staging dir for this cluster
#   LXD_CONTAINER                     LXD container name
#   KUBE_NAMESPACE                    k8s namespace inside the container
#   APP_NAME                          e.g. ai-worker
#   IMAGE_REPO                        Docker image repo
#   IMAGE_TAG                         Image tag — exported by the build step
#   INGRESS_HOST                      Public hostname routed by host nginx
#   LXD_BRIDGE_IP                     IP of the LXD container on lxdbr0
#   GEMINI_API_KEY                    Gemini API key
# Optional:
#   REPLICAS                          Default 1
#   GEMINI_MODEL                      Default "gemini-2.5-flash"
#   SUMMARY_CHUNK_THRESHOLD_CHARS     Default 3500
#   SUMMARY_CHUNK_SIZE_CHARS          Default 3500
#   SUMMARY_MAX_CONCURRENT_CHUNKS     Default 5

set -euo pipefail

: "${VPS_USER:?}"
: "${VPS_HOST:?}"
: "${REMOTE_DIR:?}"
: "${LXD_CONTAINER:?}"
: "${KUBE_NAMESPACE:?}"
: "${APP_NAME:?}"
: "${IMAGE_REPO:?}"
: "${IMAGE_TAG:?}"
: "${INGRESS_HOST:?}"
: "${LXD_BRIDGE_IP:?}"
: "${GEMINI_API_KEY:?}"

REPLICAS="${REPLICAS:-1}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
SUMMARY_CHUNK_THRESHOLD_CHARS="${SUMMARY_CHUNK_THRESHOLD_CHARS:-3500}"
SUMMARY_CHUNK_SIZE_CHARS="${SUMMARY_CHUNK_SIZE_CHARS:-3500}"
SUMMARY_MAX_CONCURRENT_CHUNKS="${SUMMARY_MAX_CONCURRENT_CHUNKS:-5}"

REMOTE_DIR="${REMOTE_DIR}/${APP_NAME}"
REMOTE_TARGET="${VPS_USER}@${VPS_HOST}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
)

echo "==> Rendering manifests locally"
mkdir -p rendered
render_file() {
  local in="$1" out="$2"
  sed \
    -e "s|\${APP_NAME}|${APP_NAME}|g" \
    -e "s|\${KUBE_NAMESPACE}|${KUBE_NAMESPACE}|g" \
    -e "s|\${IMAGE_REPO}|${IMAGE_REPO}|g" \
    -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
    -e "s|\${INGRESS_HOST}|${INGRESS_HOST}|g" \
    -e "s|\${REPLICAS}|${REPLICAS}|g" \
    -e "s|\${GEMINI_API_KEY}|${GEMINI_API_KEY}|g" \
    -e "s|\${GEMINI_MODEL}|${GEMINI_MODEL}|g" \
    -e "s|\${SUMMARY_CHUNK_THRESHOLD_CHARS}|${SUMMARY_CHUNK_THRESHOLD_CHARS}|g" \
    -e "s|\${SUMMARY_CHUNK_SIZE_CHARS}|${SUMMARY_CHUNK_SIZE_CHARS}|g" \
    -e "s|\${SUMMARY_MAX_CONCURRENT_CHUNKS}|${SUMMARY_MAX_CONCURRENT_CHUNKS}|g" \
    "$in" > "$out"
}
render_file deployment.yml rendered/deployment.yml
render_file service.yml    rendered/service.yml
render_file ingress.yml    rendered/ingress.yml

echo "==> Rendering nginx location snippet"
sed -e "s|\${LXD_BRIDGE_IP}|${LXD_BRIDGE_IP}|g" \
    ci/nginx/ai-worker.location.conf > rendered/ai-worker.location.conf

echo "=== Rendered manifests (secrets redacted) ==="
for f in rendered/*.yml; do
  echo "--- $f ---"
  sed -e "s|${GEMINI_API_KEY}|***GEMINI_API_KEY***|g" "$f"
done

echo "==> Preparing remote staging dir ${REMOTE_DIR} on ${VPS_HOST}"
ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "mkdir -p '${REMOTE_DIR}'"

echo "==> Shipping manifests + deploy-remote.sh to ${VPS_HOST}"
scp "${SSH_OPTS[@]}" \
    rendered/deployment.yml \
    rendered/service.yml \
    rendered/ingress.yml \
    rendered/ai-worker.location.conf \
    ci/deploy-remote.sh \
    "${REMOTE_TARGET}:${REMOTE_DIR}/"

echo "==> Executing deploy-remote.sh on ${VPS_HOST}"
ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" \
    "env \
      APP_NAME='${APP_NAME}' \
      KUBE_NAMESPACE='${KUBE_NAMESPACE}' \
      IMAGE_REPO='${IMAGE_REPO}' \
      IMAGE_TAG='${IMAGE_TAG}' \
      INGRESS_HOST='${INGRESS_HOST}' \
      REPLICAS='${REPLICAS}' \
      REMOTE_DIR='${REMOTE_DIR}' \
      LXD_CONTAINER='${LXD_CONTAINER}' \
      LXD_BRIDGE_IP='${LXD_BRIDGE_IP}' \
      bash '${REMOTE_DIR}/deploy-remote.sh'"
