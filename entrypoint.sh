#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# scp-action :: entrypoint
#
# Upload local files/directories to one or more remote servers over SSH/SCP.
# Inputs are injected by GitHub Actions as INPUT_<NAME> environment variables
# (the Docker action convention).
#
# Copy semantics (consistent with appleboy/drone-scp):
#   1. Sources are archived exactly as written in `source` -- paths are preserved.
#      e.g. source=tests/a.txt, target=/tmp/out  =>  /tmp/out/tests/a.txt
#   2. --strip-components is applied on the remote side during extraction.
#      e.g. strip_components=1                  =>  /tmp/out/a.txt
#   3. A `source` entry prefixed with ! is treated as a tar --exclude pattern.
# ------------------------------------------------------------------------------
set -Eeuo pipefail

readonly ACTION_VERSION="v1"

# ==============================================================================
# Basic utilities
# ==============================================================================

log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

debug() {
  if [[ "${DEBUG}" -eq 1 ]]; then
    printf '::debug::%s\n' "$*"
  fi
}

# Boolean check: 1 / true / yes / y / on (case-insensitive, trimmed)
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

# Trim leading/trailing whitespace
trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Single-quote wrap for safe parsing by the remote shell
sq() {
  local s="${1-}"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# Duration string -> seconds (30 / 30s / 2m / 1h / 500ms)
to_seconds() {
  local v
  v="$(trim "${1-}")"
  if [[ -z "${v}" ]]; then
    printf '0'
    return
  fi
  if [[ "${v}" =~ ^([0-9]+)(ms|s|m|h)?$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "${u}" in
      ms)
        if [[ "${n}" -gt 0 ]]; then printf '1'; else printf '0'; fi
        ;;
      m) printf '%s' "$((n * 60))" ;;
      h) printf '%s' "$((n * 3600))" ;;
      *) printf '%s' "${n}" ;;
    esac
  else
    printf '30'
  fi
}

# Random string for remote temp file names (no pipe, to avoid pipefail interference)
random_string() {
  printf '%s%s%s' "${RANDOM}" "${RANDOM}" "$(date +%s)"
}

# Comma / newline separated string -> one item per line
# Note: a trailing newline is prepended first, otherwise `while read`
# drops the last item when the input has no trailing newline.
split_list() {
  local raw="${1-}" item
  printf '%s\n' "${raw}" | tr ',' '\n' | while IFS= read -r item; do
    item="$(trim "${item}")"
    if [[ -n "${item}" ]]; then
      printf '%s\n' "${item}"
    fi
  done
  return 0
}

# Parse "host" or "host:port", writing results into RHOST / RPORT
RHOST=""
RPORT=""
resolve_host_port() {
  local entry="$1"
  RHOST="${entry}"
  RPORT="${INPUT_PORT}"
  if [[ "${INPUT_PROTOCOL}" != "tcp6" && "${entry}" == *:* && "${entry}" != *:*:* ]]; then
    RHOST="${entry%%:*}"
    RPORT="${entry##*:}"
  fi
}

# ==============================================================================
# Inputs
# ==============================================================================

INPUT_HOST="${INPUT_HOST:-}"
INPUT_PORT="${INPUT_PORT:-22}"
INPUT_PROTOCOL="${INPUT_PROTOCOL:-tcp}"
INPUT_USERNAME="${INPUT_USERNAME:-}"
INPUT_PASSWORD="${INPUT_PASSWORD:-}"
INPUT_KEY="${INPUT_KEY:-}"
INPUT_KEY_PATH="${INPUT_KEY_PATH:-}"
INPUT_PASSPHRASE="${INPUT_PASSPHRASE:-}"
INPUT_FINGERPRINT="${INPUT_FINGERPRINT:-}"
INPUT_TIMEOUT="${INPUT_TIMEOUT:-30s}"
INPUT_COMMAND_TIMEOUT="${INPUT_COMMAND_TIMEOUT:-10m}"
INPUT_USE_INSECURE_CIPHER="${INPUT_USE_INSECURE_CIPHER:-false}"
INPUT_CIPHER="${INPUT_CIPHER:-}"

INPUT_SOURCE="${INPUT_SOURCE:-}"
INPUT_TARGET="${INPUT_TARGET:-}"
INPUT_RM="${INPUT_RM:-false}"
INPUT_STRIP_COMPONENTS="${INPUT_STRIP_COMPONENTS:-0}"
INPUT_OVERWRITE="${INPUT_OVERWRITE:-false}"
INPUT_TAR_DEREFERENCE="${INPUT_TAR_DEREFERENCE:-false}"
INPUT_TAR_TMP_PATH="${INPUT_TAR_TMP_PATH:-/tmp/}"
INPUT_TAR_EXEC="${INPUT_TAR_EXEC:-tar}"
INPUT_DEBUG="${INPUT_DEBUG:-false}"
INPUT_DRY_RUN="${INPUT_DRY_RUN:-false}"
INPUT_CAPTURE_STDOUT="${INPUT_CAPTURE_STDOUT:-false}"

INPUT_PROXY_HOST="${INPUT_PROXY_HOST:-}"
INPUT_PROXY_PORT="${INPUT_PROXY_PORT:-22}"
INPUT_PROXY_USERNAME="${INPUT_PROXY_USERNAME:-}"
INPUT_PROXY_PASSWORD="${INPUT_PROXY_PASSWORD:-}"
INPUT_PROXY_KEY="${INPUT_PROXY_KEY:-}"
INPUT_PROXY_KEY_PATH="${INPUT_PROXY_KEY_PATH:-}"
INPUT_PROXY_PASSPHRASE="${INPUT_PROXY_PASSPHRASE:-}"
INPUT_PROXY_FINGERPRINT="${INPUT_PROXY_FINGERPRINT:-}"
INPUT_PROXY_TIMEOUT="${INPUT_PROXY_TIMEOUT:-30s}"
INPUT_PROXY_USE_INSECURE_CIPHER="${INPUT_PROXY_USE_INSECURE_CIPHER:-false}"
INPUT_PROXY_CIPHER="${INPUT_PROXY_CIPHER:-}"

if is_true "${INPUT_DEBUG}"; then DEBUG=1; else DEBUG=0; fi
if is_true "${INPUT_DRY_RUN}"; then DRY_RUN=1; else DRY_RUN=0; fi
if is_true "${INPUT_CAPTURE_STDOUT}"; then CAPTURE_STDOUT=1; else CAPTURE_STDOUT=0; fi

CONNECT_TIMEOUT="$(to_seconds "${INPUT_TIMEOUT}")"
PROXY_CONNECT_TIMEOUT="$(to_seconds "${INPUT_PROXY_TIMEOUT}")"
if [[ -z "${INPUT_COMMAND_TIMEOUT}" ]]; then
  INPUT_COMMAND_TIMEOUT="10m"
fi

# Insecure algorithm list for legacy servers
readonly INSECURE_CIPHERS="aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc,arcfour,arcfour128,arcfour256"
readonly INSECURE_KEX="diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1"
readonly INSECURE_MACS="hmac-sha1,hmac-md5,hmac-sha1-96,hmac-md5-96"
readonly INSECURE_HOSTKEY="ssh-rsa,ssh-dss"

# ==============================================================================
# Runtime state
# ==============================================================================

WORK_ROOT="$(mktemp -d)"
readonly WORK_ROOT
readonly STDOUT_LOG="${WORK_ROOT}/stdout.log"
readonly PROXY_SCRIPT="${WORK_ROOT}/proxy.sh"

KEY_FILE=""
PROXY_KEY_FILE=""
SSH_AGENT_PID=""
ARCHIVE=""
ARCHIVE_NAME=""
PROXY_KH_FILE="/dev/null"
PROXY_STRICT="no"

declare -a HOSTS=()
declare -a TARGETS=()
declare -a SOURCES=()
declare -a EXCLUDES=()
declare -a REMOTE_NAMES=()   # one independent remote temp archive name per host
declare -a SSH_OPTS=()
declare -A KH_FILE=()
declare -A KH_STRICT=()

cleanup() {
  if [[ -n "${SSH_AGENT_PID}" ]]; then
    kill "${SSH_AGENT_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${ARCHIVE}" && -f "${ARCHIVE}" ]]; then
    rm -f "${ARCHIVE}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK_ROOT}" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

# ==============================================================================
# Validation
# ==============================================================================

validate_inputs() {
  mapfile -t HOSTS < <(split_list "${INPUT_HOST}")
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    die "Missing required input: host"
  fi

  mapfile -t TARGETS < <(split_list "${INPUT_TARGET}")
  if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    die "Missing required input: target"
  fi

  if [[ -z "${INPUT_USERNAME}" ]]; then
    die "Missing required input: username"
  fi

  if [[ -z "${INPUT_KEY}" && -z "${INPUT_KEY_PATH}" && -z "${INPUT_PASSWORD}" ]]; then
    die "Either password, key or key_path must be provided for authentication"
  fi

  if [[ ! "${INPUT_STRIP_COMPONENTS}" =~ ^[0-9]+$ ]]; then
    die "strip_components must be a non-negative integer, got: ${INPUT_STRIP_COMPONENTS}"
  fi

  case "${INPUT_PROTOCOL}" in
    tcp | tcp4 | tcp6) ;;
    *) die "Invalid protocol: ${INPUT_PROTOCOL} (expected tcp / tcp4 / tcp6)" ;;
  esac

  # tar_tmp_path must end with /, otherwise a malformed path is assembled
  if [[ -n "${INPUT_TAR_TMP_PATH}" && "${INPUT_TAR_TMP_PATH}" != */ ]]; then
    INPUT_TAR_TMP_PATH="${INPUT_TAR_TMP_PATH}/"
  fi

  ARCHIVE_NAME="$(random_string).tar.gz"
  ARCHIVE="${TMPDIR:-/tmp}/${ARCHIVE_NAME}"

  # One independent remote temp archive name per host, so that listing the
  # same physical host multiple times does not cause concurrent uploads to
  # overwrite each other.
  local i
  for i in "${!HOSTS[@]}"; do
    REMOTE_NAMES+=("$(random_string).${i}.tar.gz")
  done

  debug "hosts=${HOSTS[*]} targets=${TARGETS[*]}"
  debug "protocol=${INPUT_PROTOCOL} connect_timeout=${CONNECT_TIMEOUT}s command_timeout=${INPUT_COMMAND_TIMEOUT}"
}

# ==============================================================================
# Local credentials
# ==============================================================================

write_key_file() {
  local content="$1" path="$2"
  printf '%s\n' "${content}" | tr -d '\r' >"${path}"
  chmod 0600 "${path}"
}

prepare_credentials() {
  # Private keys always land in WORK_ROOT and are passed explicitly via -i,
  # so we neither rely on nor modify ~/.ssh.
  if [[ -n "${INPUT_KEY}" ]]; then
    KEY_FILE="${WORK_ROOT}/id_scp_action"
    write_key_file "${INPUT_KEY}" "${KEY_FILE}"
  elif [[ -n "${INPUT_KEY_PATH}" ]]; then
    if [[ ! -r "${INPUT_KEY_PATH}" ]]; then
      die "Private key at key_path is not readable: ${INPUT_KEY_PATH}"
    fi
    KEY_FILE="${INPUT_KEY_PATH}"
    chmod 0600 "${KEY_FILE}" 2>/dev/null || true
  fi

  # A passphrase-protected key is handed to ssh-agent, avoiding interactive input
  if [[ -n "${KEY_FILE}" && -n "${INPUT_PASSPHRASE}" ]]; then
    local askpass="${WORK_ROOT}/askpass.sh"
    printf '#!/bin/sh\nprintf %%s %s\n' "$(sq "${INPUT_PASSPHRASE}")" >"${askpass}"
    chmod 0700 "${askpass}"

    eval "$(ssh-agent -s)" >/dev/null
    if ! SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force DISPLAY=":0" \
      ssh-add "${KEY_FILE}" >/dev/null 2>&1; then
      die "Failed to load private key; please verify the passphrase"
    fi
    info "Loaded passphrase-protected key into ssh-agent (pid=${SSH_AGENT_PID})"
  fi

  if [[ -n "${INPUT_PROXY_KEY}" ]]; then
    PROXY_KEY_FILE="${WORK_ROOT}/id_scp_action_proxy"
    write_key_file "${INPUT_PROXY_KEY}" "${PROXY_KEY_FILE}"
  elif [[ -n "${INPUT_PROXY_KEY_PATH}" ]]; then
    if [[ ! -r "${INPUT_PROXY_KEY_PATH}" ]]; then
      die "Proxy private key at proxy_key_path is not readable: ${INPUT_PROXY_KEY_PATH}"
    fi
    PROXY_KEY_FILE="${INPUT_PROXY_KEY_PATH}"
    chmod 0600 "${PROXY_KEY_FILE}" 2>/dev/null || true
  fi

  if [[ -n "${PROXY_KEY_FILE}" && -n "${INPUT_PROXY_PASSPHRASE}" ]]; then
    warn "Cannot auto-load a passphrase-protected proxy key; use a key without passphrase"
  fi
}

# ==============================================================================
# Host key fingerprint verification
# ==============================================================================

# setup_known_hosts <host> <port> <fingerprint> <known_hosts_file>
# Returns 0 when the fingerprint matches and is written; returns 1 when no
# fingerprint is provided (verification skipped).
setup_known_hosts() {
  local host="$1" port="$2" fingerprint="$3" khfile="$4"

  : >"${khfile}"

  if [[ -z "${fingerprint}" ]]; then
    warn "No fingerprint provided for ${host}; skipping host key verification (vulnerable to MITM)"
    return 1
  fi

  local scan want got line matched=0
  scan="${WORK_ROOT}/keyscan.${host//[^a-zA-Z0-9.-]/_}.${port}"

  ssh-keyscan -T 20 -p "${port}" "${host}" >"${scan}" 2>/dev/null || true
  if [[ ! -s "${scan}" ]]; then
    die "ssh-keyscan failed for ${host}:${port}; unable to obtain host public key"
  fi

  want="$(printf '%s' "${fingerprint}" | sed -e 's/^SHA256://I' -e 's/://g')"

  while IFS= read -r line; do
    if [[ -z "${line}" ]]; then
      continue
    fi
    got="$(printf '%s\n' "${line}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
    got="$(printf '%s' "${got}" | sed -e 's/^SHA256://I' -e 's/://g')"
    if [[ -n "${got}" && "${got}" == "${want}" ]]; then
      printf '%s\n' "${line}" >>"${khfile}"
      matched=1
    fi
  done <"${scan}"

  if [[ "${matched}" -ne 1 ]]; then
    die "Host key fingerprint mismatch for ${host}:${port} (expected ${fingerprint})"
  fi

  info "Host key fingerprint verified: ${host}:${port}"
  return 0
}

# All target hosts are verified in the main process up front, to avoid
# concurrent writes to a shared known_hosts file.
prepare_host_keys() {
  local entry host port kh safe

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  for entry in "${HOSTS[@]}"; do
    resolve_host_port "${entry}"
    host="${RHOST}"
    port="${RPORT}"
    safe="${host//[^a-zA-Z0-9.-]/_}"
    kh="${WORK_ROOT}/kh.${safe}.${port}"

    if setup_known_hosts "${host}" "${port}" "${INPUT_FINGERPRINT}" "${kh}"; then
      KH_FILE["${entry}"]="${kh}"
      KH_STRICT["${entry}"]="yes"
    else
      KH_FILE["${entry}"]="/dev/null"
      KH_STRICT["${entry}"]="no"
    fi
  done
}

# ==============================================================================
# Jump host (proxy)
# ==============================================================================

prepare_proxy() {
  if [[ -z "${INPUT_PROXY_HOST}" ]]; then
    return 0
  fi

  if [[ -z "${INPUT_PROXY_USERNAME}" ]]; then
    die "proxy_host set but proxy_username is missing"
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    local pkh="${WORK_ROOT}/kh.proxy"
    if setup_known_hosts "${INPUT_PROXY_HOST}" "${INPUT_PROXY_PORT}" \
      "${INPUT_PROXY_FINGERPRINT}" "${pkh}"; then
      PROXY_STRICT="yes"
      PROXY_KH_FILE="${pkh}"
    fi
  fi

  local identity_arg=""
  if [[ -n "${PROXY_KEY_FILE}" ]]; then
    identity_arg="-i $(sq "${PROXY_KEY_FILE}")"
  fi

  local prefix=""
  if [[ -n "${INPUT_PROXY_PASSWORD}" ]]; then
    prefix="sshpass -p $(sq "${INPUT_PROXY_PASSWORD}")"
  fi

  local insecure=""
  if is_true "${INPUT_PROXY_USE_INSECURE_CIPHER}"; then
    insecure="-o Ciphers=+${INSECURE_CIPHERS} -o KexAlgorithms=+${INSECURE_KEX}"
  fi
  if [[ -n "${INPUT_PROXY_CIPHER}" ]]; then
    insecure="${insecure} -c $(sq "${INPUT_PROXY_CIPHER}")"
  fi

  cat >"${PROXY_SCRIPT}" <<EOF
#!/bin/sh
# scp-action generated: forward TCP through the jump host
exec ${prefix} ssh -W "[\$1]:\$2" \\
  -p $(sq "${INPUT_PROXY_PORT}") \\
  -l $(sq "${INPUT_PROXY_USERNAME}") \\
  ${identity_arg} \\
  -o "UserKnownHostsFile=$(sq "${PROXY_KH_FILE}")" \\
  -o "StrictHostKeyChecking=${PROXY_STRICT}" \\
  -o "ConnectTimeout=${PROXY_CONNECT_TIMEOUT}" \\
  -o "NumberOfPasswordPrompts=1" \\
  ${insecure} \\
  $(sq "${INPUT_PROXY_HOST}")
EOF
  chmod 0700 "${PROXY_SCRIPT}"

  info "Jump host enabled: ${INPUT_PROXY_USERNAME}@${INPUT_PROXY_HOST}:${INPUT_PROXY_PORT}"
}

# ==============================================================================
# SSH options
# ==============================================================================

build_ssh_opts() {
  local entry="$1"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    SSH_OPTS=(-o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null")
    return 0
  fi

  SSH_OPTS=(
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "UserKnownHostsFile=${KH_FILE["${entry}"]:-/dev/null}"
    -o "StrictHostKeyChecking=${KH_STRICT["${entry}"]:-no}"
    -o "NumberOfPasswordPrompts=1"
    -o "ServerAliveInterval=15"
    -o "ServerAliveCountMax=3"
  )

  case "${INPUT_PROTOCOL}" in
    tcp4) SSH_OPTS+=(-4) ;;
    tcp6) SSH_OPTS+=(-6) ;;
  esac

  if [[ -n "${KEY_FILE}" ]]; then
    SSH_OPTS+=(-i "${KEY_FILE}")
  fi

  if [[ "${DEBUG}" -eq 1 ]]; then
    SSH_OPTS+=(-vvv -o "LogLevel=DEBUG")
  else
    SSH_OPTS+=(-o "LogLevel=ERROR")
  fi

  if is_true "${INPUT_USE_INSECURE_CIPHER}"; then
    warn "use_insecure_cipher enabled; insecure ciphers will be allowed"
    SSH_OPTS+=(
      -o "Ciphers=+${INSECURE_CIPHERS}"
      -o "KexAlgorithms=+${INSECURE_KEX}"
      -o "MACs=+${INSECURE_MACS}"
      -o "HostKeyAlgorithms=+${INSECURE_HOSTKEY}"
      -o "PubkeyAcceptedAlgorithms=+ssh-rsa"
    )
  fi

  if [[ -n "${INPUT_CIPHER}" ]]; then
    SSH_OPTS+=(-c "${INPUT_CIPHER}")
  fi

  if [[ -n "${INPUT_PROXY_HOST}" ]]; then
    SSH_OPTS+=(-o "ProxyCommand=${PROXY_SCRIPT} %h %p")
  fi
}

# ==============================================================================
# Remote command execution
# ==============================================================================

declare -a PW_PREFIX=()
RUN_OUT=""

# run_remote <host> <port> <command> -- returns the remote exit code; output in RUN_OUT
run_remote() {
  local host="$1" port="$2" command="$3"
  local rc=0

  debug "\$ ssh ${INPUT_USERNAME}@${host}:${port} -- ${command}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "[dry-run] ${INPUT_USERNAME}@${host}:${port} :: ${command}"
    RUN_OUT=""
    return 0
  fi

  if [[ -n "${INPUT_PASSWORD}" ]]; then
    PW_PREFIX=(sshpass -p "${INPUT_PASSWORD}")
  fi

  set +e
  RUN_OUT="$(
    timeout "${INPUT_COMMAND_TIMEOUT}" \
      ${PW_PREFIX[@]+"${PW_PREFIX[@]}"} \
      ssh "${SSH_OPTS[@]}" -p "${port}" "${INPUT_USERNAME}@${host}" "${command}" 2>&1
  )"
  rc=$?
  set -e

  if [[ "${CAPTURE_STDOUT}" -eq 1 && -n "${RUN_OUT}" ]]; then
    printf '%s\n' "${RUN_OUT}" >>"${STDOUT_LOG}"
  fi

  if [[ "${DEBUG}" -eq 1 && -n "${RUN_OUT}" ]]; then
    printf '%s\n' "${RUN_OUT}"
  fi

  return "${rc}"
}

# Silent execution (for OS-type probing, cleanup, etc. where output is irrelevant)
run_remote_quiet() {
  local host="$1" port="$2" command="$3"
  local bak="${DEBUG}" rc=0
  DEBUG=0
  run_remote "${host}" "${port}" "${command}" || rc=$?
  DEBUG="${bak}"
  return "${rc}"
}

rm_cmd() {
  local os="$1" target="$2"
  if [[ "${os}" == "windows" ]]; then
    printf 'rd /s /q %s' "$(sq "${target}")"
  else
    printf 'rm -rf %s' "$(sq "${target}")"
  fi
}

mkdir_cmd() {
  printf 'mkdir -p %s' "$(sq "${1}")"
}

untar_cmd() {
  local target="$1" remote_tar="$2"
  local cmd="${INPUT_TAR_EXEC} -zxf $(sq "${remote_tar}")"

  if [[ "${INPUT_STRIP_COMPONENTS}" -gt 0 ]]; then
    cmd+=" --strip-components ${INPUT_STRIP_COMPONENTS}"
  fi
  if is_true "${INPUT_OVERWRITE}"; then
    cmd+=" --overwrite"
  fi
  cmd+=" -C $(sq "${target}")"
  printf '%s' "${cmd}"
}

# ==============================================================================
# Local archive creation
# ==============================================================================

expand_sources() {
  local item
  local -a items=()
  local -a matches=()

  mapfile -t items < <(split_list "${INPUT_SOURCE}")
  if [[ "${#items[@]}" -eq 0 ]]; then
    die "Missing required input: source"
  fi

  for item in "${items[@]}"; do
    if [[ "${item:0:1}" == "!" ]]; then
      EXCLUDES+=("${item:1}")
      debug "exclude pattern: ${item:1}"
      continue
    fi

    # Only perform glob expansion when a wildcard metacharacter is present,
    # to avoid word-splitting ordinary paths that contain spaces.
    if [[ "${item}" == *[\*\?\[]* ]]; then
      matches=()
      shopt -s nullglob
      # shellcheck disable=SC2206
      matches=(${item})
      shopt -u nullglob
      if [[ "${#matches[@]}" -eq 0 ]]; then
        die "source glob matched no files: ${item}"
      fi
      SOURCES+=("${matches[@]}")
    else
      if [[ ! -e "${item}" ]]; then
        die "source path does not exist: ${item}"
      fi
      SOURCES+=("${item}")
    fi
  done

  if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    die "source resolved to nothing; no files to upload"
  fi
}

build_archive() {
  local -a tar_args=()
  local ex

  for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    tar_args+=(--exclude "${ex}")
  done

  if is_true "${INPUT_TAR_DEREFERENCE}"; then
    tar_args+=(--dereference)
  fi

  tar_args+=(-zcf "${ARCHIVE}" -- "${SOURCES[@]}")

  info "Archiving ${#SOURCES[@]} item(s) -> ${ARCHIVE}"
  debug "\$ tar ${tar_args[*]}"

  if ! tar "${tar_args[@]}"; then
    die "Local archive creation failed; please check the source paths"
  fi

  info "Archive created, size $(du -h "${ARCHIVE}" | awk '{print $1}')"
}

# ==============================================================================
# Transfer
# ==============================================================================

upload_archive() {
  local host="$1" port="$2" remote_path="$3"
  local rc=0

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "[dry-run] upload ${ARCHIVE} -> ${INPUT_USERNAME}@${host}:${port}:${remote_path}"
    return 0
  fi

  if [[ -n "${INPUT_PASSWORD}" ]]; then
    PW_PREFIX=(sshpass -p "${INPUT_PASSWORD}")
  fi

  set +e
  RUN_OUT="$(
    timeout "${INPUT_COMMAND_TIMEOUT}" \
      ${PW_PREFIX[@]+"${PW_PREFIX[@]}"} \
      scp -P "${port}" "${SSH_OPTS[@]}" \
      "${ARCHIVE}" "${INPUT_USERNAME}@${host}:${remote_path}" 2>&1
  )"
  rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    warn "scp transfer failed; retrying over ssh stdin channel"
    set +e
    RUN_OUT="$(
      timeout "${INPUT_COMMAND_TIMEOUT}" \
        ${PW_PREFIX[@]+"${PW_PREFIX[@]}"} \
        ssh "${SSH_OPTS[@]}" -p "${port}" \
        "${INPUT_USERNAME}@${host}" "cat > $(sq "${remote_path}")" <"${ARCHIVE}" 2>&1
    )"
    rc=$?
    set -e
  fi

  if [[ "${rc}" -ne 0 && -n "${RUN_OUT}" ]]; then
    printf '%s\n' "${RUN_OUT}" >&2
  fi

  return "${rc}"
}

# deploy_one runs concurrently in a subshell
deploy_one() {
  local idx="$1" entry="$2"
  local host port os_type remote_tar target

  resolve_host_port "${entry}"
  host="${RHOST}"
  port="${RPORT}"

  build_ssh_opts "${entry}"

  remote_tar="${INPUT_TAR_TMP_PATH}${REMOTE_NAMES[${idx}]}"

  # Detect remote OS by running the Windows-only command `ver`
  os_type="unix"
  if [[ "${DRY_RUN}" -eq 0 ]] && run_remote_quiet "${host}" "${port}" "ver"; then
    os_type="windows"
  fi
  info "Remote OS type: ${os_type}"

  if ! upload_archive "${host}" "${port}" "${remote_tar}"; then
    return 1
  fi
  info "Uploaded archive ${remote_tar}"

  for target in "${TARGETS[@]}"; do
    if is_true "${INPUT_RM}"; then
      info "Cleaning target directory ${target}"
      if ! run_remote "${host}" "${port}" "$(rm_cmd "${os_type}" "${target}")"; then
        printf '%s\n' "${RUN_OUT}" >&2
        return 1
      fi
    fi

    if ! run_remote "${host}" "${port}" "$(mkdir_cmd "${target}")"; then
      printf '%s\n' "${RUN_OUT}" >&2
      return 1
    fi

    info "Extracting to ${target}"
    if ! run_remote "${host}" "${port}" "$(untar_cmd "${target}" "${remote_tar}")"; then
      printf '%s\n' "${RUN_OUT}" >&2
      return 1
    fi
  done

  run_remote_quiet "${host}" "${port}" "$(rm_cmd "${os_type}" "${remote_tar}")" || true
  info "Done ${host}:${port}"
  return 0
}

# Failure rollback: clean up the temp archive on every host
cleanup_remote() {
  local i entry host port remote_tar

  for i in "${!HOSTS[@]}"; do
    entry="${HOSTS[$i]}"
    resolve_host_port "${entry}"
    host="${RHOST}"
    port="${RPORT}"
    build_ssh_opts "${entry}"
    remote_tar="${INPUT_TAR_TMP_PATH}${REMOTE_NAMES[$i]}"
    run_remote_quiet "${host}" "${port}" "rm -f $(sq "${remote_tar}")" || true
  done
}

deploy_all() {
  local -a pids=() status_files=() log_files=()
  local i entry sf lf st failed=0

  for i in "${!HOSTS[@]}"; do
    entry="${HOSTS[$i]}"
    sf="$(mktemp)"
    lf="$(mktemp)"
    status_files+=("${sf}")
    log_files+=("${lf}")

    (
      set +e
      deploy_one "${i}" "${entry}"
      printf '%s' "$?" >"${sf}"
    ) >"${lf}" 2>&1 &
    pids+=("$!")
  done

  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || true
    st="$(cat "${status_files[$i]}")"
    cat "${log_files[$i]}"
    if [[ "${st}" != "0" ]]; then
      failed=1
      printf '::error::Upload failed: %s\n' "${HOSTS[$i]}"
    fi
  done

  if [[ "${failed}" -ne 0 ]]; then
    warn "Rolling back remote temp files"
    cleanup_remote
    die "Upload failed on some hosts; see logs above"
  fi

  log "==================================================="
  log "Successfully transferred to all ${#HOSTS[@]} host(s)"
  log "==================================================="
}

# ==============================================================================
# Outputs
# ==============================================================================

write_outputs() {
  local duration="$1"

  if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
    return 0
  fi

  printf 'duration=%s\n' "${duration}" >>"${GITHUB_OUTPUT}"

  if [[ "${CAPTURE_STDOUT}" -eq 1 ]]; then
    local delim="SCP_ACTION_EOF_$(random_string)"
    {
      printf 'stdout<<%s\n' "${delim}"
      if [[ -f "${STDOUT_LOG}" ]]; then
        cat "${STDOUT_LOG}"
      fi
      printf '\n%s\n' "${delim}"
    } >>"${GITHUB_OUTPUT}"
  fi
}

# ==============================================================================
# main
# ==============================================================================

main() {
  local start end duration
  start="$(date +%s)"

  info "scp-action ${ACTION_VERSION}"

  validate_inputs
  expand_sources

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    warn "dry_run enabled; showing the execution plan only, no connection will be made"
  fi

  prepare_credentials
  prepare_host_keys
  prepare_proxy
  build_archive
  deploy_all

  end="$(date +%s)"
  duration="$((end - start))"
  write_outputs "${duration}"
  info "Elapsed time: ${duration}s"
}

main "$@"
