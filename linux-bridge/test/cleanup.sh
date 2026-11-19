#! /bin/bash

SCRIPT_PATH=$(dirname "$(realpath "$0")")
source $SCRIPT_PATH/env.sh

# Container-runtime. The podman networks are lab infrastructure and are left
# in place.
for c in "${CONTAINERS[@]}"; do
  echo "INFO: rm container [$c]"
  podman stop "$c" >/dev/null 2>&1 || true
  podman rm "$c" >/dev/null 2>&1 || true
done

echo "INFO: rm openperouter configs"
oc -n "$NAMESPACE" delete -f "$UNDERLAY_MANIFEST" --ignore-not-found || true
oc -n "$NAMESPACE" delete -f "$VNIS_MANIFEST" --ignore-not-found || true
oc delete -f "$NNCP_VNI_BR_MANIFEST" --ignore-not-found || true

echo "INFO: rm test namespace [$TEST_NS]"
oc delete ns "$TEST_NS" --ignore-not-found || true
while oc get ns "$TEST_NS" >/dev/null 2>&1; do
  echo "waiting for ns $TEST_NS to dispose.."
  sleep 3
done
