#!/usr/bin/env bash
# End-to-end test of the barman-cloud sidecar image against a real object store.
#
# Runs every barman-cloud-* command the CNPG plugin uses against RustFS, the S3
# store the gitops clusters run, configured like production:
#   * TLS from a private CA with an intermediate (like step-ca's internal
#     issuer): ECDSA P-256 leaf, clients trust only the root
#   * a non-default signing region (production uses coda-azl-kub-<cluster>)
#   * bucket versioning on (01-rustfs/new_bucket.sh enables it)
#   * WAL: gzip, maxParallel 8; base backups: zstd, jobs 4, immediate
#     checkpoint; retention 14d (02-cnpg ObjectStore coda-azl-kub-clp03)
# and with the sidecar locked down like an instance pod: read-only root
# filesystem, UID/GID 26, all capabilities dropped, no new privileges.
#
#   1. TLS: without the CA bundle barman must reject the certificate; stdlib
#      ssl (VERIFY_X509_STRICT) and boto3 must both accept the private CA.
#   2. barman-cloud-check-wal-archive passes on an empty archive and refuses
#      a non-empty one.
#   3. barman-cloud-wal-archive --gzip, PARALLEL uploads at a time.
#   4. barman-cloud-backup --zstd -J 4, -backup-list, -backup-show.
#   5. barman-cloud-restore plus barman-cloud-wal-restore (checksums must match
#      the originals), then Postgres replays the WAL and promotes, and rows
#      written after the backup must be present.
#   6. barman-cloud-backup-delete: RECOVERY WINDOW OF 14 DAYS keeps both
#      backups, REDUNDANCY 1 deletes the older one.
#
# Usage: scripts/e2e-test.sh [SIDECAR_IMAGE]
#
# Environment:
#   SIDECAR_IMAGE  image under test (default localhost/plugin-barman-cloud-sidecar:dev)
#   CONTAINER_CLI  podman or docker (default: podman if installed, else docker)
#   PG_IMAGE       Postgres server image (default docker.io/library/postgres:18)
#   RUSTFS_IMAGE   RustFS image (default: the version 01-rustfs deploys)
#   PLATFORM       platform for the sidecar image (default linux/amd64)
#   PARALLEL       concurrent WAL uploads (default 8, maxParallel in gitops)
#   KEEP=1         leave containers and volumes behind for debugging
#
# Needs bash, openssl and python3 on the host. Postgres and RustFS run at the
# host's native architecture; only the sidecar is pinned to PLATFORM.

set -euo pipefail

IMAGE="${1:-${SIDECAR_IMAGE:-localhost/plugin-barman-cloud-sidecar:dev}}"
if [[ -z "${CONTAINER_CLI:-}" ]]; then
  if command -v podman >/dev/null 2>&1; then CONTAINER_CLI=podman; else CONTAINER_CLI=docker; fi
fi
CLI="${CONTAINER_CLI}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:18}"
RUSTFS_IMAGE="${RUSTFS_IMAGE:-docker.io/rustfs/rustfs:1.0.4}"
PLATFORM="${PLATFORM:-linux/amd64}"
PARALLEL="${PARALLEL:-8}"
KEEP="${KEEP:-0}"

run_id="barman-e2e-$$"
net="${run_id}"
c_s3="${run_id}-rustfs"
c_pg="${run_id}-pg"
c_restore="${run_id}-pg-restore"
c_sidecar="${run_id}-sidecar"
v_certs="${run_id}-certs"
v_pgdata="${run_id}-pgdata"
v_archive="${run_id}-archive"
v_restore="${run_id}-restore"
v_walrestore="${run_id}-walrestore"

bucket="pg18"
server="pg18-e2e"
region="coda-e2e-test"
endpoint="https://rustfs:9000"
dest="s3://${bucket}"
barman_args=(--cloud-provider aws-s3 --endpoint-url "${endpoint}")

pg_password="e2e-$(openssl rand -hex 12)"
s3_user="e2e-access"
s3_secret="e2e-$(openssl rand -hex 16)"

work="$(mktemp -d "${TMPDIR:-/tmp}/barman-e2e.XXXXXX")"
: >"${work}/uploaded"

log() { printf '\n==> %s\n' "$*"; }
fail() {
  printf '\nFAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  report_tracebacks
  if [[ ${status} -ne 0 ]]; then
    for c in "${c_sidecar}" "${c_pg}" "${c_restore}" "${c_s3}"; do
      if "${CLI}" container inspect "${c}" >/dev/null 2>&1; then
        printf '\n----- logs: %s -----\n' "${c}" >&2
        "${CLI}" logs --tail 60 "${c}" >&2 2>&1 || true
      fi
    done
  fi
  if [[ "${KEEP}" == "1" ]]; then
    printf '\nKEEP=1: left %s-* containers, volumes and network; work dir %s\n' "${run_id}" "${work}" >&2
  else
    "${CLI}" rm -f "${c_sidecar}" "${c_pg}" "${c_restore}" "${c_s3}" >/dev/null 2>&1 || true
    "${CLI}" volume rm -f "${v_certs}" "${v_pgdata}" "${v_archive}" "${v_restore}" "${v_walrestore}" >/dev/null 2>&1 || true
    "${CLI}" network rm "${net}" >/dev/null 2>&1 || true
    rm -rf "${work}"
  fi
  if [[ ${status} -eq 0 ]]; then
    printf '\nPASS: %s\n' "${IMAGE}"
  fi
  exit "${status}"
}

# Called before cleanup removes the work dir: barman commands that exited 0
# but printed a traceback.
report_tracebacks() {
  local f
  for f in "${work}"/stderr-*.log; do
    [[ -e "${f}" ]] || continue
    grep -q '^Traceback' "${f}" || continue
    local cmd="${f##*/stderr-}"
    cmd="${cmd%.log}"
    local last
    last="$(grep -E '^[A-Za-z_.]+(Error|Exception)' "${f}" | tail -n 1)"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      printf '::warning title=barman %s printed a traceback::%s\n' "${cmd}" "${last}"
    else
      printf '\nWARNING: barman %s exited 0 but printed a traceback: %s\n' "${cmd}" "${last}" >&2
    fi
  done
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------

# Run a command in the sidecar with the CA bundle, as the plugin does when an
# ObjectStore sets endpointCA.
sidecar() { "${CLI}" exec -e AWS_CA_BUNDLE=/certs/ca.crt "${c_sidecar}" "$@"; }

psql_in() {
  local container=$1
  shift
  "${CLI}" exec -e PGPASSWORD="${pg_password}" "${container}" \
    psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq -c "$@"
}

wait_for_pg() {
  local container=$1 i
  for i in $(seq 1 90); do
    if "${CLI}" exec "${container}" pg_isready -h 127.0.0.1 -U postgres -q >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  fail "${container} did not accept connections within 90s"
}

# Hand a fresh volume to UID 26 with the given mode.
own_volume() {
  "${CLI}" run --rm --user 0 -v "$1:/v" "${PG_IMAGE}" \
    sh -c "chown 26:26 /v && chmod $2 /v"
}

wait_for_archiver() {
  local i ready
  for i in $(seq 1 60); do
    ready="$(psql_in "${c_pg}" "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'")"
    [[ "${ready}" == "0" ]] && return 0
    sleep 1
  done
  fail "archive_command did not drain .ready files within 60s"
}

switch_wal() {
  local phase=$1 rounds=$2 i
  for i in $(seq 1 "${rounds}"); do
    psql_in "${c_pg}" "insert into e2e (phase, payload) select '${phase}', md5(g::text) from generate_series(1, 2000) g" >/dev/null
    psql_in "${c_pg}" "select pg_switch_wal()" >/dev/null
  done
  wait_for_archiver
}

# Upload every file in /archive not uploaded yet, PARALLEL at a time, the way
# the plugin fans out WAL archiving with maxParallel.
archive_pending() {
  local pending="${work}/pending" name pids=() names=() i failed=0
  "${CLI}" exec "${c_pg}" ls -1 /archive | sort >"${work}/listing"
  comm -23 "${work}/listing" <(sort "${work}/uploaded") >"${pending}"
  [[ -s "${pending}" ]] || return 0
  printf '    uploading %s file(s), %s at a time\n' "$(wc -l <"${pending}" | tr -d ' ')" "${PARALLEL}"

  flush() {
    for i in "${!pids[@]}"; do
      if ! wait "${pids[$i]}"; then
        printf '    wal-archive failed for %s:\n' "${names[$i]}" >&2
        sed 's/^/      /' "${work}/wal-${names[$i]}.log" >&2
        failed=1
      fi
    done
    pids=()
    names=()
  }

  while IFS= read -r name; do
    sidecar barman-cloud-wal-archive --gzip "${barman_args[@]}" \
      "${dest}" "${server}" "/archive/${name}" >"${work}/wal-${name}.log" 2>&1 &
    pids+=("$!")
    names+=("${name}")
    if [[ ${#pids[@]} -ge ${PARALLEL} ]]; then flush; fi
  done <"${pending}"
  if [[ ${#pids[@]} -gt 0 ]]; then flush; fi
  [[ ${failed} -eq 0 ]] || fail "barman-cloud-wal-archive failed"
  cat "${pending}" >>"${work}/uploaded"
}

# Run a barman command, keeping its stderr so tracebacks that do not change the
# exit code (e.g. multiprocessing cleanup at interpreter exit) are reported.
barman_logged() {
  local tag=$1
  shift
  sidecar "$@" 2> >(tee "${work}/stderr-${tag}.log" >&2)
}

base_backup() {
  barman_logged "backup-$1" barman-cloud-backup "${barman_args[@]}" --zstd -J 4 --immediate-checkpoint \
    -h pg -p 5432 -U postgres -d postgres "${dest}" "${server}"
  wait_for_archiver
  archive_pending
}

backup_ids() {
  sidecar barman-cloud-backup-list --format json "${barman_args[@]}" "${dest}" "${server}" \
    | python3 -c 'import json, sys; [print(b["backup_id"]) for b in sorted(json.load(sys.stdin)["backups_list"], key=lambda b: b["backup_id"])]'
}

# --- setup -------------------------------------------------------------------

log "Image under test: ${IMAGE} (${CLI}, ${PLATFORM})"
"${CLI}" image inspect "${IMAGE}" >/dev/null 2>&1 \
  || "${CLI}" pull --platform "${PLATFORM}" "${IMAGE}" >/dev/null

log "Generating a root CA, an intermediate and an ECDSA P-256 RustFS certificate"
(
  cd "${work}"
  ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }
  ec root.key
  openssl req -x509 -new -key root.key -sha256 -days 2 -subj "/CN=barman-e2e root CA" -out root.crt \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  ec intermediate.key
  openssl req -new -key intermediate.key -subj "/CN=barman-e2e intermediate CA" -out intermediate.csr
  cat >intermediate.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
  openssl x509 -req -in intermediate.csr -CA root.crt -CAkey root.key -CAcreateserial \
    -days 2 -sha256 -extfile intermediate.ext -out intermediate.crt 2>/dev/null
  ec server.key
  openssl req -new -key server.key -subj "/CN=rustfs" -out server.csr
  cat >server.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:rustfs
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
  openssl x509 -req -in server.csr -CA intermediate.crt -CAkey intermediate.key -CAcreateserial \
    -days 2 -sha256 -extfile server.ext -out server.crt 2>/dev/null
  mkdir certs
  # RustFS serves the leaf plus intermediate; clients trust only the root.
  cat server.crt intermediate.crt >certs/rustfs_cert.pem
  cp server.key certs/rustfs_key.pem
  cp root.crt certs/ca.crt
  chmod 0644 certs/*
)

log "Creating network and volumes"
"${CLI}" network create "${net}" >/dev/null
for v in "${v_certs}" "${v_pgdata}" "${v_archive}" "${v_restore}" "${v_walrestore}"; do
  "${CLI}" volume create "${v}" >/dev/null
done
filler="$("${CLI}" create -v "${v_certs}:/dst" "${PG_IMAGE}" true)"
"${CLI}" cp "${work}/certs/." "${filler}:/dst/"
"${CLI}" rm "${filler}" >/dev/null
for v in "${v_pgdata}" "${v_archive}" "${v_restore}" "${v_walrestore}"; do
  own_volume "${v}" 0700
done

log "Starting RustFS with TLS and region ${region}"
"${CLI}" run -d --name "${c_s3}" --network "${net}" --network-alias rustfs \
  -e RUSTFS_ACCESS_KEY="${s3_user}" -e RUSTFS_SECRET_KEY="${s3_secret}" \
  -e RUSTFS_ADDRESS=:9000 -e RUSTFS_REGION="${region}" \
  -e RUSTFS_SERVER_DOMAINS=rustfs -e RUSTFS_TLS_PATH=/certs \
  -e RUSTFS_CONSOLE_ENABLE=false \
  -v "${v_certs}:/certs:ro" \
  "${RUSTFS_IMAGE}" >/dev/null

log "Starting Postgres (archive_command copies WAL to a volume the sidecar uploads from)"
"${CLI}" run -d --name "${c_pg}" --network "${net}" --network-alias pg \
  --user 26:26 -e POSTGRES_PASSWORD="${pg_password}" -e PGDATA=/pgdata \
  -v "${v_pgdata}:/pgdata" -v "${v_archive}:/archive" \
  "${PG_IMAGE}" postgres \
  -c wal_level=replica -c archive_mode=on \
  -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f" >/dev/null

log "Starting the sidecar locked down like an instance pod"
# The real sidecar runs /manager; idle on python instead and exec each
# barman-cloud-* command into the running, read-only container.
"${CLI}" run -d --name "${c_sidecar}" --network "${net}" --platform "${PLATFORM}" \
  --user 26:26 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,size=256m \
  -e AWS_ACCESS_KEY_ID="${s3_user}" -e AWS_SECRET_ACCESS_KEY="${s3_secret}" \
  -e AWS_DEFAULT_REGION="${region}" -e PGPASSWORD="${pg_password}" \
  -v "${v_certs}:/certs:ro" -v "${v_pgdata}:/pgdata:ro" -v "${v_archive}:/archive:ro" \
  -v "${v_restore}:/restore" -v "${v_walrestore}:/walrestore" \
  --entrypoint /venv/bin/python "${IMAGE}" \
  -c 'import signal, sys, time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(86400)' >/dev/null

wait_for_pg "${c_pg}"

# --- 1. TLS and signing ------------------------------------------------------

log "TLS: stdlib ssl (strict X.509 checks) trusts the root through the intermediate"
tls_check='
import ssl, urllib.error, urllib.request
ctx = ssl.create_default_context(cafile="/certs/ca.crt")
try:
    urllib.request.urlopen("https://rustfs:9000/", context=ctx, timeout=3)
except urllib.error.HTTPError:
    pass  # any HTTP status means the TLS handshake succeeded
'
ok=0
for _ in $(seq 1 60); do
  if sidecar python -c "${tls_check}" 2>"${work}/tls.err"; then
    ok=1
    break
  fi
  sleep 1
done
[[ ${ok} -eq 1 ]] || fail "stdlib TLS to RustFS failed: $(tail -n 1 "${work}/tls.err")"

log "TLS: without AWS_CA_BUNDLE barman must reject the certificate"
if out="$("${CLI}" exec "${c_sidecar}" barman-cloud-check-wal-archive "${barman_args[@]}" "${dest}" "${server}" 2>&1)"; then
  fail "check-wal-archive succeeded without the CA bundle; TLS is not being verified"
fi
grep -qi 'certificate' <<<"${out}" || fail "expected a certificate error without the CA bundle, got: ${out}"

log "boto3 creates the bucket with versioning, signing for region ${region}"
sidecar python -c "
import boto3
s3 = boto3.client('s3', endpoint_url='${endpoint}')
s3.create_bucket(Bucket='${bucket}', CreateBucketConfiguration={'LocationConstraint': '${region}'})
s3.put_bucket_versioning(Bucket='${bucket}', VersioningConfiguration={'Status': 'Enabled'})
assert s3.get_bucket_versioning(Bucket='${bucket}').get('Status') == 'Enabled'
"

region_check="
import boto3, botocore.exceptions
s3 = boto3.client('s3', endpoint_url='${endpoint}', region_name='us-east-1')
try:
    s3.list_objects_v2(Bucket='${bucket}', MaxKeys=1)
except botocore.exceptions.ClientError as e:
    print('rejected:', e.response['Error'].get('Code'))
else:
    print('accepted')
"
if [[ "$(sidecar python -c "${region_check}")" == accepted ]]; then
  printf '    note: RustFS accepted a us-east-1 signature, so this run does not prove region signing\n'
else
  printf '    RustFS rejects other regions; the sidecar must sign with %s\n' "${region}"
fi

# --- 2. check-wal-archive ----------------------------------------------------

log "barman-cloud-check-wal-archive: empty archive is safe to use"
sidecar barman-cloud-check-wal-archive "${barman_args[@]}" "${dest}" "${server}"

# --- 3. WAL archiving --------------------------------------------------------

log "Writing data and archiving WAL (--gzip, ${PARALLEL} in parallel)"
psql_in "${c_pg}" "create table e2e (id bigint generated always as identity primary key, phase text not null, payload text not null)"
switch_wal pre-backup 12
archive_pending

log "barman-cloud-check-wal-archive: refuses an archive that already has WAL"
if sidecar barman-cloud-check-wal-archive "${barman_args[@]}" "${dest}" "${server}" >/dev/null 2>&1; then
  fail "check-wal-archive accepted a non-empty archive"
fi

# --- 4. base backup ----------------------------------------------------------

log "barman-cloud-backup --zstd -J 4 (first)"
base_backup 1
ids="$(backup_ids)"
[[ "$(wc -l <<<"${ids}" | tr -d ' ')" == "1" ]] || fail "expected 1 backup, got: ${ids}"
first_backup="${ids}"
log "barman-cloud-backup-show ${first_backup}"
sidecar barman-cloud-backup-show "${barman_args[@]}" "${dest}" "${server}" "${first_backup}" >/dev/null

log "Writing rows after the backup that only WAL replay can bring back"
switch_wal post-backup 4
archive_pending
expected_rows="$(psql_in "${c_pg}" "select count(*) from e2e")"
expected_post="$(psql_in "${c_pg}" "select count(*) from e2e where phase = 'post-backup'")"

# --- 5. restore --------------------------------------------------------------

log "barman-cloud-restore ${first_backup} into an empty PGDATA"
barman_logged restore barman-cloud-restore "${barman_args[@]}" "${dest}" "${server}" "${first_backup}" /restore

log "barman-cloud-wal-restore every archived segment and timeline history, checking it against the original"
# Postgres never asks restore_command for *.backup label files, and
# barman-cloud-wal-restore does not serve them.
grep -v '\.backup$' "${work}/uploaded" >"${work}/restorable"
while IFS= read -r name; do
  sidecar barman-cloud-wal-restore "${barman_args[@]}" "${dest}" "${server}" "${name}" "/walrestore/${name}" \
    || fail "wal-restore failed for ${name}"
done <"${work}/restorable"
"${CLI}" exec "${c_pg}" sh -c 'cd /archive && sha256sum *' | grep -v '\.backup$' | sort >"${work}/sums.archive"
sidecar python -c 'import hashlib, os; [print(hashlib.sha256(open(os.path.join("/walrestore", n), "rb").read()).hexdigest() + "  " + n) for n in sorted(os.listdir("/walrestore"))]' \
  | sort >"${work}/sums.restored"
if ! diff -u "${work}/sums.archive" "${work}/sums.restored" >"${work}/sums.diff"; then
  fail "restored WAL differs from what Postgres archived:
$(head -20 "${work}/sums.diff")"
fi

log "Replaying WAL on the restored data directory"
sidecar python -c 'open("/restore/recovery.signal", "w").close()'
"${CLI}" run -d --name "${c_restore}" --network "${net}" --user 26:26 -e PGDATA=/restore \
  -v "${v_restore}:/restore" -v "${v_walrestore}:/walrestore:ro" \
  "${PG_IMAGE}" postgres \
  -c "restore_command=cp /walrestore/%f %p" -c recovery_target_action=promote >/dev/null
wait_for_pg "${c_restore}"
promoted=0
for _ in $(seq 1 60); do
  if [[ "$(psql_in "${c_restore}" "select pg_is_in_recovery()")" == "f" ]]; then
    promoted=1
    break
  fi
  sleep 1
done
[[ ${promoted} -eq 1 ]] || fail "restored server did not finish recovery and promote"
got_rows="$(psql_in "${c_restore}" "select count(*) from e2e")"
got_post="$(psql_in "${c_restore}" "select count(*) from e2e where phase = 'post-backup'")"
[[ "${got_rows}" == "${expected_rows}" && "${got_post}" == "${expected_post}" ]] \
  || fail "restored rows ${got_rows} (post-backup ${got_post}), expected ${expected_rows} (${expected_post})"
printf '    restored %s rows, %s written after the backup\n' "${got_rows}" "${got_post}"

# --- 6. retention ------------------------------------------------------------

log "barman-cloud-backup --zstd -J 4 (second)"
sleep 2 # backup IDs have one-second resolution
base_backup 2
ids="$(backup_ids)"
[[ "$(wc -l <<<"${ids}" | tr -d ' ')" == "2" ]] || fail "expected 2 backups, got: ${ids}"
second_backup="$(tail -n 1 <<<"${ids}")"

log "barman-cloud-backup-delete RECOVERY WINDOW OF 14 DAYS keeps both backups"
sidecar barman-cloud-backup-delete "${barman_args[@]}" -r "RECOVERY WINDOW OF 14 DAYS" "${dest}" "${server}"
[[ "$(backup_ids | wc -l | tr -d ' ')" == "2" ]] || fail "14-day window deleted a backup"

log "barman-cloud-backup-delete REDUNDANCY 1 deletes the older backup"
sidecar barman-cloud-backup-delete "${barman_args[@]}" -r "REDUNDANCY 1" "${dest}" "${server}"
ids="$(backup_ids)"
[[ "${ids}" == "${second_backup}" ]] || fail "expected only ${second_backup} after REDUNDANCY 1, got: ${ids}"
