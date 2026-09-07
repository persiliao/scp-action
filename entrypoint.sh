#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# scp-action :: entrypoint
#
# 通过 SSH/SCP 把本地文件/目录打包上传到一台或多台远程服务器。
# 参数由 GitHub Actions 以 INPUT_<NAME> 环境变量注入（Docker action 约定）。
#
# 传输语义（与 appleboy/drone-scp 保持一致）：
#   1. 本地按 source 原样打包为 tar.gz —— source 中写的路径会完整保留；
#      例：source=tests/a.txt, target=/tmp/out  =>  /tmp/out/tests/a.txt
#   2. 远端解包时才应用 --strip-components；
#      例：strip_components=1                  =>  /tmp/out/a.txt
#   3. 以 ! 开头的 source 条目作为 --exclude 排除模式。
# ------------------------------------------------------------------------------
set -Eeuo pipefail

readonly ACTION_VERSION="v1"

# ==============================================================================
# 基础工具
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

# 布尔值判定：1 / true / yes / y / on（忽略大小写与首尾空白）
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

# 去除首尾空白
trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 单引号包裹，供远端 shell 安全解析
sq() {
  local s="${1-}"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# 时长字符串 -> 秒（30 / 30s / 2m / 1h / 500ms）
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

# 随机串，用于远端临时文件名（避免管道，防止 pipefail 干扰）
random_string() {
  printf '%s%s%s' "${RANDOM}" "${RANDOM}" "$(date +%s)"
}

# 逗号 / 换行分隔的字符串 -> 逐行输出
# 注意：必须先补一个换行，否则 while read 会丢弃末尾没有换行符的最后一项
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

# 解析 "host" 或 "host:port"，结果写入 RHOST / RPORT
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
# 输入
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

# 兼容老旧服务端的不安全算法清单
readonly INSECURE_CIPHERS="aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc,arcfour,arcfour128,arcfour256"
readonly INSECURE_KEX="diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1"
readonly INSECURE_MACS="hmac-sha1,hmac-md5,hmac-sha1-96,hmac-md5-96"
readonly INSECURE_HOSTKEY="ssh-rsa,ssh-dss"

# ==============================================================================
# 运行时状态
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
declare -a REMOTE_NAMES=()   # 每台主机一个独立的远端临时包文件名
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
# 校验
# ==============================================================================

validate_inputs() {
  mapfile -t HOSTS < <(split_list "${INPUT_HOST}")
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    die "缺少必填参数：host"
  fi

  mapfile -t TARGETS < <(split_list "${INPUT_TARGET}")
  if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    die "缺少必填参数：target"
  fi

  if [[ -z "${INPUT_USERNAME}" ]]; then
    die "缺少必填参数：username"
  fi

  if [[ -z "${INPUT_KEY}" && -z "${INPUT_KEY_PATH}" && -z "${INPUT_PASSWORD}" ]]; then
    die "必须提供 password 或 key / key_path 之一，否则无法完成认证"
  fi

  if [[ ! "${INPUT_STRIP_COMPONENTS}" =~ ^[0-9]+$ ]]; then
    die "strip_components 必须是非负整数，当前值：${INPUT_STRIP_COMPONENTS}"
  fi

  case "${INPUT_PROTOCOL}" in
    tcp | tcp4 | tcp6) ;;
    *) die "protocol 取值非法：${INPUT_PROTOCOL}（可选 tcp / tcp4 / tcp6）" ;;
  esac

  # tar_tmp_path 必须以 / 结尾，否则会拼出畸形路径
  if [[ -n "${INPUT_TAR_TMP_PATH}" && "${INPUT_TAR_TMP_PATH}" != */ ]]; then
    INPUT_TAR_TMP_PATH="${INPUT_TAR_TMP_PATH}/"
  fi

  ARCHIVE_NAME="$(random_string).tar.gz"
  ARCHIVE="${TMPDIR:-/tmp}/${ARCHIVE_NAME}"

  # 每台主机使用独立的远端临时文件名，避免同一物理机被重复列举时互相覆盖
  local i
  for i in "${!HOSTS[@]}"; do
    REMOTE_NAMES+=("$(random_string).${i}.tar.gz")
  done

  debug "hosts=${HOSTS[*]} targets=${TARGETS[*]}"
  debug "protocol=${INPUT_PROTOCOL} connect_timeout=${CONNECT_TIMEOUT}s command_timeout=${INPUT_COMMAND_TIMEOUT}"
}

# ==============================================================================
# 本地凭据
# ==============================================================================

write_key_file() {
  local content="$1" path="$2"
  printf '%s\n' "${content}" | tr -d '\r' >"${path}"
  chmod 0600 "${path}"
}

prepare_credentials() {
  # 私钥统一落在 WORK_ROOT 并通过 -i 显式指定，
  # 因此不依赖也不改动 ~/.ssh。
  if [[ -n "${INPUT_KEY}" ]]; then
    KEY_FILE="${WORK_ROOT}/id_scp_action"
    write_key_file "${INPUT_KEY}" "${KEY_FILE}"
  elif [[ -n "${INPUT_KEY_PATH}" ]]; then
    if [[ ! -r "${INPUT_KEY_PATH}" ]]; then
      die "key_path 指向的私钥不可读：${INPUT_KEY_PATH}"
    fi
    KEY_FILE="${INPUT_KEY_PATH}"
    chmod 0600 "${KEY_FILE}" 2>/dev/null || true
  fi

  # 带 passphrase 的私钥交给 ssh-agent 托管，避免交互式输入
  if [[ -n "${KEY_FILE}" && -n "${INPUT_PASSPHRASE}" ]]; then
    local askpass="${WORK_ROOT}/askpass.sh"
    printf '#!/bin/sh\nprintf %%s %s\n' "$(sq "${INPUT_PASSPHRASE}")" >"${askpass}"
    chmod 0700 "${askpass}"

    eval "$(ssh-agent -s)" >/dev/null
    if ! SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force DISPLAY=":0" \
      ssh-add "${KEY_FILE}" >/dev/null 2>&1; then
      die "加载私钥失败，请检查 passphrase 是否正确"
    fi
    info "已将带 passphrase 的私钥载入 ssh-agent（pid=${SSH_AGENT_PID}）"
  fi

  if [[ -n "${INPUT_PROXY_KEY}" ]]; then
    PROXY_KEY_FILE="${WORK_ROOT}/id_scp_action_proxy"
    write_key_file "${INPUT_PROXY_KEY}" "${PROXY_KEY_FILE}"
  elif [[ -n "${INPUT_PROXY_KEY_PATH}" ]]; then
    if [[ ! -r "${INPUT_PROXY_KEY_PATH}" ]]; then
      die "proxy_key_path 指向的私钥不可读：${INPUT_PROXY_KEY_PATH}"
    fi
    PROXY_KEY_FILE="${INPUT_PROXY_KEY_PATH}"
    chmod 0600 "${PROXY_KEY_FILE}" 2>/dev/null || true
  fi

  if [[ -n "${PROXY_KEY_FILE}" && -n "${INPUT_PROXY_PASSPHRASE}" ]]; then
    warn "跳板机私钥带 passphrase 时无法自动加载，请改用无口令私钥"
  fi
}

# ==============================================================================
# 主机指纹校验
# ==============================================================================

# setup_known_hosts <host> <port> <fingerprint> <known_hosts_file>
# 成功（返回 0）表示指纹匹配且已写入；返回 1 表示未提供指纹、跳过校验
setup_known_hosts() {
  local host="$1" port="$2" fingerprint="$3" khfile="$4"

  : >"${khfile}"

  if [[ -z "${fingerprint}" ]]; then
    warn "未提供 ${host} 的 fingerprint，已跳过主机指纹校验（存在中间人攻击风险）"
    return 1
  fi

  local scan want got line matched=0
  scan="${WORK_ROOT}/keyscan.${host//[^a-zA-Z0-9.-]/_}.${port}"

  ssh-keyscan -T 20 -p "${port}" "${host}" >"${scan}" 2>/dev/null || true
  if [[ ! -s "${scan}" ]]; then
    die "ssh-keyscan ${host}:${port} 失败，无法获取主机公钥"
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
    die "主机指纹不匹配：${host}:${port}（期望 ${fingerprint}）"
  fi

  info "主机指纹校验通过：${host}:${port}"
  return 0
}

# 全部目标主机的指纹在主进程中一次性校验，避免并发写同一文件
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
# 跳板机
# ==============================================================================

prepare_proxy() {
  if [[ -z "${INPUT_PROXY_HOST}" ]]; then
    return 0
  fi

  if [[ -z "${INPUT_PROXY_USERNAME}" ]]; then
    die "设置了 proxy_host，但缺少 proxy_username"
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
# scp-action 自动生成：经由跳板机转发 TCP 连接
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

  info "已启用跳板机：${INPUT_PROXY_USERNAME}@${INPUT_PROXY_HOST}:${INPUT_PROXY_PORT}"
}

# ==============================================================================
# SSH 选项
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
    warn "已开启 use_insecure_cipher，将允许不安全的加密算法"
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
# 远端命令执行
# ==============================================================================

declare -a PW_PREFIX=()
RUN_OUT=""

# run_remote <host> <port> <command> —— 返回远端退出码，输出存入 RUN_OUT
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

# 静默执行（用于系统类型探测、清理等不关心输出的场景）
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
# 本地打包
# ==============================================================================

expand_sources() {
  local item
  local -a items=()
  local -a matches=()

  mapfile -t items < <(split_list "${INPUT_SOURCE}")
  if [[ "${#items[@]}" -eq 0 ]]; then
    die "缺少必填参数：source"
  fi

  for item in "${items[@]}"; do
    if [[ "${item:0:1}" == "!" ]]; then
      EXCLUDES+=("${item:1}")
      debug "exclude pattern: ${item:1}"
      continue
    fi

    # 仅在确实包含通配元字符时才做 glob 展开，
    # 避免对含空格的普通路径造成词分裂。
    if [[ "${item}" == *[\*\?\[]* ]]; then
      matches=()
      shopt -s nullglob
      # shellcheck disable=SC2206
      matches=(${item})
      shopt -u nullglob
      if [[ "${#matches[@]}" -eq 0 ]]; then
        die "source 通配符未匹配到任何文件：${item}"
      fi
      SOURCES+=("${matches[@]}")
    else
      if [[ ! -e "${item}" ]]; then
        die "source 路径不存在：${item}"
      fi
      SOURCES+=("${item}")
    fi
  done

  if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    die "source 解析后为空，没有可上传的文件"
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

  info "打包 ${#SOURCES[@]} 个条目 -> ${ARCHIVE}"
  debug "\$ tar ${tar_args[*]}"

  if ! tar "${tar_args[@]}"; then
    die "本地打包失败，请检查 source 路径"
  fi

  info "打包完成，大小 $(du -h "${ARCHIVE}" | awk '{print $1}')"
}

# ==============================================================================
# 传输
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
    warn "scp 传输失败，改用 ssh stdin 通道重试"
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

# deploy_one 在子 shell 中并发执行
deploy_one() {
  local idx="$1" entry="$2"
  local host port os_type remote_tar target

  resolve_host_port "${entry}"
  host="${RHOST}"
  port="${RPORT}"

  build_ssh_opts "${entry}"

  remote_tar="${INPUT_TAR_TMP_PATH}${REMOTE_NAMES[${idx}]}"

  # 通过执行 Windows 专有命令 ver 判断远端系统类型
  os_type="unix"
  if [[ "${DRY_RUN}" -eq 0 ]] && run_remote_quiet "${host}" "${port}" "ver"; then
    os_type="windows"
  fi
  info "远端系统类型：${os_type}"

  if ! upload_archive "${host}" "${port}" "${remote_tar}"; then
    return 1
  fi
  info "已上传临时包 ${remote_tar}"

  for target in "${TARGETS[@]}"; do
    if is_true "${INPUT_RM}"; then
      info "清理目标目录 ${target}"
      if ! run_remote "${host}" "${port}" "$(rm_cmd "${os_type}" "${target}")"; then
        printf '%s\n' "${RUN_OUT}" >&2
        return 1
      fi
    fi

    if ! run_remote "${host}" "${port}" "$(mkdir_cmd "${target}")"; then
      printf '%s\n' "${RUN_OUT}" >&2
      return 1
    fi

    info "解包到 ${target}"
    if ! run_remote "${host}" "${port}" "$(untar_cmd "${target}" "${remote_tar}")"; then
      printf '%s\n' "${RUN_OUT}" >&2
      return 1
    fi
  done

  run_remote_quiet "${host}" "${port}" "$(rm_cmd "${os_type}" "${remote_tar}")" || true
  info "完成 ${host}:${port}"
  return 0
}

# 失败回滚：清理所有主机上的临时包
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
      printf '::error::上传失败：%s\n' "${HOSTS[$i]}"
    fi
  done

  if [[ "${failed}" -ne 0 ]]; then
    warn "正在回滚远端临时文件"
    cleanup_remote
    die "部分主机上传失败，详见上方日志"
  fi

  log "==================================================="
  log "成功传输到全部 ${#HOSTS[@]} 台主机"
  log "==================================================="
}

# ==============================================================================
# 输出
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
    warn "dry_run 已开启，仅展示执行计划，不会实际连接远程服务器"
  fi

  prepare_credentials
  prepare_host_keys
  prepare_proxy
  build_archive
  deploy_all

  end="$(date +%s)"
  duration="$((end - start))"
  write_outputs "${duration}"
  info "耗时 ${duration}s"
}

main "$@"
