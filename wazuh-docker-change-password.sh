#!/usr/bin/env bash
set -euo pipefail

# ============================================
#  Wazuh Docker – This script helps change the password of Indexer users (admin | kibanaserver)
#  - Generates HASH (on host) via wazuh/wazuh-indexer:<tag> image (hash.sh -p / -stdin, with JAVA_HOME)
#  - Updates internal_users.yml (host), docker-compose.yml and .env
#  - Recreates the stack
#  - Applies changes via securityadmin.sh with -cd /tmp/sec-* (full copy + new internal_users.yml)
#  - Optional verification (HTTP 200 with new credentials)
# ============================================

usage() {
  cat <<'EOF'
Usage:
  ./wazuh-docker-change-password.sh [options]

Options:
  -d <dir>                 Stack directory (where docker-compose.yml is located). Default: .
  -U <user>                Target user: admin | kibanaserver
  -P <password>            New password (if omitted, will be prompted)
  --old-password <pass>    Old password (optional, for final validation)
  --indexer-container <c>  Force Indexer container name
  --indexer-tag <tag>      Image tag used to generate the hash. Default: 4.12.0
  --wait-secs <n>          Dynamic wait timeout (default: 120)
  -H, --hash-only          Only generate/print password + hash (does not change anything) and exit
  -h, --help               Help

Examples:
  ./wazuh-docker-change-password.sh -d /wazuh/wazuh-docker/multi-node -U admin -P 'NewP@ssw0rd!' --old-password 'SecretPassword'
  ./wazuh-docker-change-password.sh -H -P 'NewP@ssw0rd!'
EOF
}

# --------- Defaults ----------
COMPOSE_DIR="$(pwd)"
USER_TO_CHANGE=""
NEW_PASSWORD=""
OLD_PASSWORD=""
INDEXER_CTN_FORCED=""
INDEXER_CTN=""
INDEXER_TAG="4.12.0"
WAIT_SECS=120
HASH_ONLY="false"

# --------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) COMPOSE_DIR="$2"; shift 2 ;;
    -U) USER_TO_CHANGE="$2"; shift 2 ;;
    -P) NEW_PASSWORD="$2"; shift 2 ;;
    --old-password) OLD_PASSWORD="$2"; shift 2 ;;
    --indexer-container) INDEXER_CTN_FORCED="$2"; shift 2 ;;
    --indexer-tag) INDEXER_TAG="$2"; shift 2 ;;
    --wait-secs) WAIT_SECS="$2"; shift 2 ;;
    -H|--hash-only) HASH_ONLY="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Invalid option: $1" >&2; usage; exit 1 ;;
  esac
done

# --------- Assisted Input ----------
if [[ "${HASH_ONLY}" == "false" && -z "${USER_TO_CHANGE}" ]]; then
  read -rp "User to change [admin|kibanaserver]: " USER_TO_CHANGE
fi
if [[ "${HASH_ONLY}" == "false" && "${USER_TO_CHANGE}" != "admin" && "${USER_TO_CHANGE}" != "kibanaserver" ]]; then
  echo "Error: User must be 'admin' or 'kibanaserver'." >&2; exit 1
fi
if [[ -z "${NEW_PASSWORD}" ]]; then
  read -rs -p "New password: " NEW_PASSWORD; echo
  read -rs -p "Confirm password: " NEW_PASSWORD2; echo
  [[ "${NEW_PASSWORD}" == "${NEW_PASSWORD2}" ]] || { echo "Passwords do not match."; exit 1; }
fi

generate_hash_via_image() {
  local pw="$1" tag="$2" out hash
  out="$(docker run --rm "wazuh/wazuh-indexer:${tag}" \
        bash -lc 'export JAVA_HOME=/usr/share/wazuh-indexer/jdk; export OPENSEARCH_JAVA_HOME=$JAVA_HOME; /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p '"\"${pw//\"/\\\"}\"" 2>&1 || true)"
  hash="$(echo "$out" | awk '/^\$/ {print; exit}')"
  if [[ -z "$hash" ]]; then
    out="$(printf "%s" "$pw" | docker run --rm -i "wazuh/wazuh-indexer:${tag}" \
          bash -lc 'export JAVA_HOME=/usr/share/wazuh-indexer/jdk; export OPENSEARCH_JAVA_HOME=$JAVA_HOME; /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -stdin' 2>&1 || true)"
    hash="$(echo "$out" | awk '/^\$/ {print; exit}')"
  fi
  if [[ -z "$hash" || "${hash:0:1}" != '$' ]]; then
    echo "Failed to generate hash via wazuh/wazuh-indexer:${tag} image" >&2
    echo "Output:" >&2; echo "$out" >&2
    echo "Tip: docker pull wazuh/wazuh-indexer:${tag}" >&2
    exit 1
  fi
  echo "$hash"
}

NEW_HASH="$(generate_hash_via_image "${NEW_PASSWORD}" "${INDEXER_TAG}")"
echo "-----------------------------"
echo "User     : ${USER_TO_CHANGE}"
echo "Password : ${NEW_PASSWORD}"
echo "Hash     : ${NEW_HASH}"
echo "-----------------------------"
[[ "${HASH_ONLY}" == "true" ]] && exit 0

COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
SEC_DIR_HOST="${COMPOSE_DIR}/config/wazuh_indexer"
INTERNAL_USERS_HOST="${SEC_DIR_HOST}/internal_users.yml"

[[ -f "${COMPOSE_FILE}" ]] || { echo "File not found: ${COMPOSE_FILE}"; exit 1; }
[[ -f "${INTERNAL_USERS_HOST}" ]] || { echo "File not found: ${INTERNAL_USERS_HOST}"; exit 1; }

TS="$(date +%Y%m%d%H%M%S)"
cp -a "${COMPOSE_FILE}" "${COMPOSE_FILE}.bak-${TS}"
cp -a "${INTERNAL_USERS_HOST}" "${INTERNAL_USERS_HOST}.bak-${USER_TO_CHANGE}-${TS}"

TMP_INTERNAL="$(mktemp)"
awk -v user="${USER_TO_CHANGE}" -v newhash="${NEW_HASH}" '
  BEGIN{ inblk=0 }
  $0 ~ ("^"user":") { inblk=1; print; next }
  /^[a-zA-Z0-9_-]+:\s*$/ && inblk==1 { inblk=0 }
  {
    if(inblk==1 && $1=="hash:" ){
      print "  hash: \"" newhash "\""
      next
    }
    print
  }
' "${INTERNAL_USERS_HOST}" > "${TMP_INTERNAL}"
mv "${TMP_INTERNAL}" "${INTERNAL_USERS_HOST}"
echo "Updated: ${INTERNAL_USERS_HOST}"

ESCAPED_PW="${NEW_PASSWORD//$/\$\$}"
if [[ "${USER_TO_CHANGE}" == "admin" ]]; then
  sed -i.bak-"${TS}" -E "s/(INDEXER_PASSWORD=).*/\1${ESCAPED_PW}/g" "${COMPOSE_FILE}" || true
  echo "Updated INDEXER_PASSWORD in docker-compose.yml"
else
  sed -i.bak-"${TS}" -E "s/(DASHBOARD_PASSWORD=).*/\1${ESCAPED_PW}/g" "${COMPOSE_FILE}" || true
  echo "Updated DASHBOARD_PASSWORD in docker-compose.yml"
fi
ENV_FILE="${COMPOSE_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  if [[ "${USER_TO_CHANGE}" == "admin" ]]; then
    sed -i.bak-"${TS}" -E "s/^(INDEXER_PASSWORD=).*/\1${ESCAPED_PW}/" "${ENV_FILE}"
  else
    sed -i.bak-"${TS}" -E "s/^(DASHBOARD_PASSWORD=).*/\1${ESCAPED_PW}/" "${ENV_FILE}"
  fi
  echo "Updated also ${ENV_FILE}"
fi

echo "docker compose up -d ..."
if docker compose version >/dev/null 2>&1; then
  (cd "${COMPOSE_DIR}" && docker compose up -d)
else
  (cd "${COMPOSE_DIR}" && docker-compose up -d)
fi

detect_indexer_ctn() {
  if [[ -n "${INDEXER_CTN_FORCED}" ]]; then
    echo "${INDEXER_CTN_FORCED}"; return
  fi
  if docker ps --format '{{.Names}}' | grep -qx 'multi-node-wazuh1.indexer-1'; then
    echo "multi-node-wazuh1.indexer-1"; return
  fi
  if docker ps --format '{{.Names}}' | grep -qx 'single-node-wazuh.indexer-1'; then
    echo "single-node-wazuh.indexer-1"; return
  fi
  docker ps --format '{{.Names}}' | grep -E '\.indexer' | head -n1 || true
}
INDEXER_CTN="$(detect_indexer_ctn || true)"
[[ -n "${INDEXER_CTN}" ]] || { echo "Error: could not detect container ${INDEXER_CTN_FORCED}"; exit 1; }
echo "Container: ${INDEXER_CTN}"

echo "Waiting for ${INDEXER_CTN_FORCED} to become operational (timeout ${WAIT_SECS}s)..."
sleep "${WAIT_SECS}"

TMP_SEC_HOST="$(mktemp -d)"
cp -a "${SEC_DIR_HOST}/." "${TMP_SEC_HOST}/"
cp -a "${INTERNAL_USERS_HOST}" "${TMP_SEC_HOST}/internal_users.yml"
TMP_SEC_IN_CTN="/tmp/sec-$(date +%s)"

docker exec -u 0 -i "${INDEXER_CTN}" bash -lc '
set -e
INSTALLATION_DIR=/usr/share/wazuh-indexer
SEC_DIR=$INSTALLATION_DIR/opensearch-security
TMP_DIR="'"${TMP_SEC_IN_CTN}"'"
mkdir -p "$TMP_DIR"
cp -a "$SEC_DIR/"* "$TMP_DIR"/
echo "Full copy at $TMP_DIR"
'

# 2) overwrite ONLY the internal_users.yml we modified on the host
docker cp "${TMP_SEC_HOST}/internal_users.yml" "${INDEXER_CTN}:${TMP_SEC_IN_CTN}/internal_users.yml"

# --------- Apply securityadmin.sh (using full TMP) ----------
docker exec -u 0 -i "${INDEXER_CTN}" bash -lc '
set -e
export INSTALLATION_DIR=/usr/share/wazuh-indexer
CACERT=$INSTALLATION_DIR/certs/root-ca.pem
KEY=$INSTALLATION_DIR/certs/admin-key.pem
CERT=$INSTALLATION_DIR/certs/admin.pem
export JAVA_HOME=/usr/share/wazuh-indexer/jdk
HOST=$(awk -F": *" "/^node\.name:/ {print \$2; exit}" $INSTALLATION_DIR/opensearch.yml)

bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
  -cd "'"${TMP_SEC_IN_CTN}"'" -nhnv -cacert $CACERT -cert $CERT -key $KEY -p 9200 -icl -h $HOST
'

# --------- Final verification (optional) ----------
if [[ -n "${OLD_PASSWORD}" ]]; then
  echo "Verification (via node HOST) with new and old password..."
  docker exec -i "${INDEXER_CTN}" bash -lc "
    set -e
    HOST=\$(grep '^node.name' /usr/share/wazuh-indexer/opensearch.yml | awk '{print \$2}')
    echo -n 'New Password Test:   '; curl -ks -u ${USER_TO_CHANGE}:'${NEW_PASSWORD}' https://\$HOST:9200 -o /dev/null -w '%{http_code}\n' || true
    echo -n 'Old Password Test:   '; curl -ks -u ${USER_TO_CHANGE}:'${OLD_PASSWORD}' https://\$HOST:9200 -o /dev/null -w '%{http_code}\n' || true
  "
else
  echo "Verification (via node HOST) with new password..."
  docker exec -i "${INDEXER_CTN}" bash -lc "
    set -e
    HOST=\$(grep '^node.name' /usr/share/wazuh-indexer/opensearch.yml | awk '{print \$2}')
    echo -n 'New Password Test:   '; curl -ks -u ${USER_TO_CHANGE}:'${NEW_PASSWORD}' https://\$HOST:9200 -o /dev/null -w '%{http_code}\n' || true
  "
fi

echo "✅ Done. '${USER_TO_CHANGE}' updated and applied via securityadmin."
echo "ℹ️  On the Dashboard, log out, clear cookies if necessary, or use an incognito window to test the new password."
