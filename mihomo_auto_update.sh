#!/usr/bin/env bash

set -uo pipefail

SERVICE_NAME="mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
INSTALL_DIR="/root"
LOCAL_BIN="${INSTALL_DIR}/mihomo"
TARGET_BIN=""
DEFAULT_TARGET_BIN="/usr/local/bin/mihomo"
CONFIG_DIR=""
DEFAULT_CONFIG_DIR="/etc/mihomo"
CONFIG_FILE=""
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

tmp_dir=""
backup_bin=""
service_stopped="0"
STEP_INDEX=0
STEP_TOTAL=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

start_steps() {
  STEP_INDEX=0
  STEP_TOTAL="$1"
}

step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  log "步骤 ${STEP_INDEX}/${STEP_TOTAL}: $*"
}

cleanup() {
  if [ -n "${tmp_dir}" ] && [ -d "${tmp_dir}" ]; then
    log "清理临时目录 ${tmp_dir}"
    rm -rf "${tmp_dir}"
  fi
}

rollback() {
  if [ -n "${backup_bin}" ] && [ -f "${backup_bin}" ]; then
    log "更新失败，回滚到旧版本"
    install -m 755 "${backup_bin}" "${TARGET_BIN}"
    if [ "${service_stopped}" = "1" ]; then
      systemctl start "${SERVICE_NAME}"
    fi
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    log "请用 root 执行"
    exit 1
  fi
}

get_release_json() {
  curl -fsSL "${API_URL}"
}

get_latest_tag() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

get_asset_urls() {
  printf '%s\n' "$1" | sed -n 's#^[[:space:]]*"browser_download_url":[[:space:]]*"\(https://[^"]*\.gz\)".*#\1#p'
}

get_current_version() {
  local version_bin=""

  if [ -n "${TARGET_BIN}" ] && [ -x "${TARGET_BIN}" ]; then
    version_bin="${TARGET_BIN}"
  elif [ -x "${LOCAL_BIN}" ]; then
    version_bin="${LOCAL_BIN}"
  else
    return 0
  fi

  "${version_bin}" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

get_service_property() {
  local property="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl show -p "${property}" --value "${SERVICE_NAME}" 2>/dev/null | head -n 1
}

resolve_bin_path() {
  local bin_path="$1"

  if [ -z "${bin_path}" ]; then
    return 1
  fi

  if command -v readlink >/dev/null 2>&1; then
    readlink -f "${bin_path}" 2>/dev/null || printf '%s\n' "${bin_path}"
  else
    printf '%s\n' "${bin_path}"
  fi
}

get_service_bin_from_systemd() {
  local execstart=""
  local service_bin=""

  execstart="$(get_service_property ExecStart)"
  if [ -z "${execstart}" ]; then
    return 1
  fi

  service_bin="$(printf '%s\n' "${execstart}" | sed -n 's/.*path=\([^ ;}][^ ;}]*\).*/\1/p' | head -n 1)"
  if [ -z "${service_bin}" ]; then
    service_bin="$(printf '%s\n' "${execstart}" | sed -n 's/.*argv\[\]=\([^ ;}][^ ;}]*\).*/\1/p' | head -n 1)"
  fi

  if [ -z "${service_bin}" ] || [ "${service_bin}" = "/usr/bin/env" ]; then
    return 1
  fi

  resolve_bin_path "${service_bin}"
}

get_service_config_dir_from_systemd() {
  local execstart=""
  local service_dir=""

  execstart="$(get_service_property ExecStart)"
  if [ -z "${execstart}" ]; then
    return 1
  fi

  service_dir="$(printf '%s\n' "${execstart}" | sed -n 's/.* -d \([^ ;}][^ ;}]*\).*/\1/p' | head -n 1)"
  if [ -z "${service_dir}" ]; then
    service_dir="$(printf '%s\n' "${execstart}" | sed -n 's/.*--dir=\([^ ;}][^ ;}]*\).*/\1/p' | head -n 1)"
  fi
  if [ -z "${service_dir}" ]; then
    service_dir="$(printf '%s\n' "${execstart}" | sed -n 's/.*--dir \([^ ;}][^ ;}]*\).*/\1/p' | head -n 1)"
  fi

  if [ -z "${service_dir}" ]; then
    return 1
  fi

  resolve_bin_path "${service_dir}"
}

detect_config_dir() {
  local detected_dir=""

  detected_dir="$(get_service_config_dir_from_systemd)" || true
  if [ -n "${detected_dir}" ]; then
    printf '%s\n' "${detected_dir}"
    return 0
  fi

  if [ -d "${DEFAULT_CONFIG_DIR}" ]; then
    printf '%s\n' "${DEFAULT_CONFIG_DIR}"
    return 0
  fi

  printf '%s\n' "${DEFAULT_CONFIG_DIR}"
}

detect_target_bin() {
  local detected_bin=""

  detected_bin="$(get_service_bin_from_systemd)" || true
  if [ -n "${detected_bin}" ]; then
    printf '%s\n' "${detected_bin}"
    return 0
  fi

  if command -v mihomo >/dev/null 2>&1; then
    resolve_bin_path "$(command -v mihomo)"
    return 0
  fi

  if [ -x "${LOCAL_BIN}" ]; then
    resolve_bin_path "${LOCAL_BIN}"
    return 0
  fi

  printf '%s\n' "${LOCAL_BIN}"
}

service_exists() {
  systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"
}

get_system_version_summary() {
  local pretty_name=""

  if [ -r /etc/os-release ]; then
    pretty_name="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | tr -d '"')"
  fi

  if [ -n "${pretty_name}" ]; then
    printf '%s (%s %s)\n' "${pretty_name}" "$(uname -s)" "$(uname -m)"
  else
    printf '%s %s %s\n' "$(uname -s)" "$(uname -r)" "$(uname -m)"
  fi
}

show_home_summary() {
  local system_version=""
  local detected_bin=""
  local detected_config=""
  local current_version=""
  local install_status="未安装"

  system_version="$(get_system_version_summary)"
  detected_bin="$(detect_target_bin)"
  detected_config="$(detect_config_dir)"

  if [ -n "${detected_bin}" ] && [ -x "${detected_bin}" ]; then
    TARGET_BIN="${detected_bin}"
    current_version="$(get_current_version)"
    install_status="已安装"
  fi

  printf '\n当前环境信息:\n'
  printf '系统版本: %s\n' "${system_version}"
  printf 'mihomo 状态: %s\n' "${install_status}"

  if [ "${install_status}" = "已安装" ]; then
    printf '当前版本: %s\n' "${current_version:-未知}"
    printf '二进制路径: %s\n' "${detected_bin}"
    printf '配置目录: %s\n' "${detected_config}"
  else
    printf '默认安装路径: %s\n' "${DEFAULT_TARGET_BIN}"
    printf '默认配置目录: %s\n' "${DEFAULT_CONFIG_DIR}"
  fi
}

normalize_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "darwin" ;;
    FreeBSD) echo "freebsd" ;;
    *)
      log "不支持的系统: $(uname -s)"
      exit 1
      ;;
  esac
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    armv5tel|armv5) echo "armv5" ;;
    i386|i486|i586|i686) echo "386" ;;
    loongarch64) echo "loong64" ;;
    mips64le) echo "mips64le" ;;
    mips64) echo "mips64" ;;
    mipsle) echo "mipsle" ;;
    mips) echo "mips" ;;
    ppc64le) echo "ppc64le" ;;
    riscv64) echo "riscv64" ;;
    s390x) echo "s390x" ;;
    *)
      log "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

get_cpu_flags() {
  local flags=""

  if command -v lscpu >/dev/null 2>&1; then
    flags="$(LC_ALL=C lscpu | sed -n 's/^Flags:[[:space:]]*//p')"
  fi

  if [ -z "${flags}" ] && [ -r /proc/cpuinfo ]; then
    flags="$(sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
  fi

  printf '%s\n' "${flags}"
}

has_cpu_flags() {
  local flags_string=" $1 "
  shift
  local flag=""

  for flag in "$@"; do
    case "${flags_string}" in
      *" ${flag} "*) ;;
      *) return 1 ;;
    esac
  done

  return 0
}

has_any_cpu_flag() {
  local flags_string=" $1 "
  shift
  local flag=""

  for flag in "$@"; do
    case "${flags_string}" in
      *" ${flag} "*) return 0 ;;
    esac
  done

  return 1
}

get_amd64_level() {
  local flags=""
  flags="$(get_cpu_flags)"

  if [ -z "${flags}" ]; then
    echo "compatible"
    return
  fi

  if has_cpu_flags "${flags}" avx avx2 bmi1 bmi2 f16c fma movbe; then
    if has_any_cpu_flag "${flags}" lzcnt abm; then
      if has_any_cpu_flag "${flags}" osxsave xsave; then
        echo "v3"
        return
      fi
    fi
  fi

  if has_any_cpu_flag "${flags}" sse3 pni; then
    if has_cpu_flags "${flags}" ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm; then
      echo "v2"
      return
    fi
  fi

  if has_cpu_flags "${flags}" cmov cx8 fpu fxsr mmx sse sse2; then
    echo "v1"
  else
    echo "compatible"
  fi
}

version_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && [ "$1" != "$2" ]
}

get_linux_go_preferences() {
  local kernel_version=""
  kernel_version="$(uname -r | grep -oE '^[0-9]+(\.[0-9]+)+' | head -n 1)"

  if [ -n "${kernel_version}" ] && version_lt "${kernel_version}" "3.2"; then
    printf '%s\n' "go123 default go120"
  else
    printf '%s\n' "default go123 go120"
  fi
}

find_asset_url_by_name() {
  local asset_urls="$1"
  local asset_name="$2"

  printf '%s\n' "${asset_urls}" | sed -n "s#^\(https://.*/${asset_name}\)\$#\1#p" | head -n 1
}

choose_download_url() {
  local release_json="$1"
  local latest_tag="$2"
  local os arch asset_urls amd64_level go_preferences go_tag variant asset_name download_url
  local variants=""

  os="$(normalize_os)"
  arch="$(normalize_arch)"
  asset_urls="$(get_asset_urls "${release_json}")"

  if [ "${os}" = "linux" ] && [ "${arch}" = "amd64" ]; then
    amd64_level="$(get_amd64_level)"
    case "${amd64_level}" in
      v3) variants="v3 v2 v1 compatible" ;;
      v2) variants="v2 v1 compatible" ;;
      v1) variants="v1 compatible" ;;
      *) variants="compatible" ;;
    esac
  else
    variants="plain"
  fi

  if [ "${os}" = "linux" ]; then
    go_preferences="$(get_linux_go_preferences)"
  else
    go_preferences="default go124 go123 go122 go120"
  fi

  for variant in ${variants}; do
    for go_tag in ${go_preferences}; do
      if [ "${variant}" = "plain" ]; then
        if [ "${go_tag}" = "default" ]; then
          asset_name="mihomo-${os}-${arch}-${latest_tag}.gz"
        else
          asset_name="mihomo-${os}-${arch}-${go_tag}-${latest_tag}.gz"
        fi
      else
        if [ "${go_tag}" = "default" ]; then
          asset_name="mihomo-${os}-${arch}-${variant}-${latest_tag}.gz"
        else
          asset_name="mihomo-${os}-${arch}-${variant}-${go_tag}-${latest_tag}.gz"
        fi
      fi

      download_url="$(find_asset_url_by_name "${asset_urls}" "${asset_name}")"
      if [ -n "${download_url}" ]; then
        log "自动选择安装包: ${asset_name}"
        printf '%s\n' "${download_url}"
        return 0
      fi
    done
  done

  if [ "${os}" = "linux" ] && [ "${arch}" = "amd64" ]; then
    asset_name="mihomo-${os}-${arch}-${latest_tag}.gz"
    download_url="$(find_asset_url_by_name "${asset_urls}" "${asset_name}")"
    if [ -n "${download_url}" ]; then
      log "回退选择安装包: ${asset_name}"
      printf '%s\n' "${download_url}"
      return 0
    fi
  fi

  return 1
}

download_latest_binary() {
  local release_json latest_tag download_url asset_name new_bin

  step "查询 GitHub 最新版本"
  release_json="$(get_release_json)"
  latest_tag="$(get_latest_tag "${release_json}")"
  download_url="$(choose_download_url "${release_json}" "${latest_tag}")"

  if [ -z "${latest_tag}" ] || [ -z "${download_url}" ]; then
    log "获取最新版信息失败"
    return 1
  fi

  asset_name="${download_url##*/}"
  new_bin="${tmp_dir}/mihomo"

  log "最新版本标签: ${latest_tag}"
  step "下载安装包 ${asset_name}"
  curl -fL "${download_url}" -o "${tmp_dir}/${asset_name}"

  step "解压安装包"
  gzip -dc "${tmp_dir}/${asset_name}" > "${new_bin}"
  chmod 755 "${new_bin}"

  printf '%s\n%s\n' "${latest_tag}" "${new_bin}"
}

write_service_file() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=${DEFAULT_TARGET_BIN} -d ${CONFIG_DIR}
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
}

show_service_status() {
  systemctl status "${SERVICE_NAME}" --no-pager || true
}

start_and_enable_service() {
  step "重新加载 systemd 配置"
  systemctl daemon-reload

  step "启动服务 ${SERVICE_NAME}"
  if ! systemctl start "${SERVICE_NAME}"; then
    log "启动失败，当前状态如下"
    show_service_status
    return 1
  fi

  sleep 2
  step "检查服务状态"
  show_service_status

  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "服务未成功进入 active 状态，不设置开机自启"
    return 1
  fi

  step "设置开机自启"
  systemctl enable "${SERVICE_NAME}"
  return 0
}

wait_for_config_file() {
  local answer=""

  step "准备配置目录 ${CONFIG_DIR}"
  install -d -m 755 "${CONFIG_DIR}"
  CONFIG_FILE="${CONFIG_DIR}/config.yaml"

  printf '\n请先把 config.yaml 放到: %s\n' "${CONFIG_FILE}"
  printf '官方 systemd 文档路径也是: %s\n\n' "${CONFIG_DIR}"

  step "等待用户放置 config.yaml"
  while [ ! -f "${CONFIG_FILE}" ]; do
    printf '放好后按回车继续，输入 q 退出: '
    read -r answer
    if [ "${answer}" = "q" ] || [ "${answer}" = "Q" ]; then
      return 1
    fi
  done

  return 0
}

install_mihomo() {
  local download_output=""
  local latest_tag=""
  local new_bin=""

  start_steps 13
  step "初始化安装参数"
  CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
  CONFIG_FILE="${CONFIG_DIR}/config.yaml"
  TARGET_BIN="${DEFAULT_TARGET_BIN}"
  log "目标二进制路径: ${TARGET_BIN}"
  log "目标配置目录: ${CONFIG_DIR}"
  log "目标服务文件: ${SERVICE_FILE}"

  if service_exists || [ -e "${TARGET_BIN}" ]; then
    log "检测到可能已安装 mihomo，安装流程将按官方路径覆盖 ${TARGET_BIN}"
  fi

  if ! wait_for_config_file; then
    log "安装已取消"
    return 1
  fi

  if ! download_output="$(download_latest_binary)"; then
    return 1
  fi
  latest_tag="$(printf '%s\n' "${download_output}" | sed -n '1p')"
  new_bin="$(printf '%s\n' "${download_output}" | sed -n '2p')"

  step "安装二进制到 ${TARGET_BIN}"
  install -m 755 "${new_bin}" "${TARGET_BIN}"

  step "写入服务文件 ${SERVICE_FILE}"
  write_service_file

  if ! start_and_enable_service; then
    return 1
  fi

  step "输出安装结果"
  log "安装完成，当前版本 ${latest_tag}"
  "${TARGET_BIN}" -v 2>/dev/null | head -n 1 || true
}

upgrade_mihomo() {
  local download_output=""
  local latest_tag=""
  local new_bin=""
  local current_version=""

  start_steps 11
  step "探测现有安装信息"
  TARGET_BIN="$(detect_target_bin)"
  CONFIG_DIR="$(detect_config_dir)"

  if [ -z "${TARGET_BIN}" ]; then
    log "无法确定 mihomo 安装路径"
    return 1
  fi

  log "检测到安装路径: ${TARGET_BIN}"
  log "检测到配置目录: ${CONFIG_DIR}"

  if ! download_output="$(download_latest_binary)"; then
    return 1
  fi
  latest_tag="$(printf '%s\n' "${download_output}" | sed -n '1p')"
  new_bin="$(printf '%s\n' "${download_output}" | sed -n '2p')"

  current_version="$(get_current_version)"
  step "比对当前版本"
  if [ -n "${current_version}" ] && [ "${current_version}" = "${latest_tag}" ]; then
    log "当前已是最新版本 ${current_version}"
    return 0
  fi

  step "备份当前二进制"
  if [ -e "${TARGET_BIN}" ]; then
    backup_bin="${tmp_dir}/mihomo.backup"
    cp -a "${TARGET_BIN}" "${backup_bin}"
  else
    log "未找到现有二进制，跳过备份"
  fi

  step "停止服务 ${SERVICE_NAME}"
  if ! systemctl stop "${SERVICE_NAME}"; then
    log "停止服务失败"
    return 1
  fi
  service_stopped="1"

  step "安装新版本到 ${TARGET_BIN}"
  if ! install -m 755 "${new_bin}" "${TARGET_BIN}"; then
    rollback
    return 1
  fi

  step "启动服务 ${SERVICE_NAME}"
  if ! systemctl start "${SERVICE_NAME}"; then
    rollback
    return 1
  fi
  service_stopped="0"

  step "检查服务状态"
  show_service_status

  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "服务未成功进入 active 状态"
    rollback
    return 1
  fi

  step "输出升级结果"
  log "升级完成，当前版本 ${latest_tag}"
  "${TARGET_BIN}" -v 2>/dev/null | head -n 1 || true
}

uninstall_mihomo() {
  local remove_config=""
  local detected_service_file=""

  start_steps 6
  step "探测现有安装信息"
  TARGET_BIN="$(detect_target_bin)"
  CONFIG_DIR="$(detect_config_dir)"
  detected_service_file="$(get_service_property FragmentPath)" || true
  if [ -n "${detected_service_file}" ]; then
    SERVICE_FILE="${detected_service_file}"
  fi

  step "停止并禁用服务 ${SERVICE_NAME}"
  if service_exists; then
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  else
    log "未检测到 ${SERVICE_NAME}.service，跳过停用"
  fi

  step "删除服务文件 ${SERVICE_FILE}"
  if [ -f "${SERVICE_FILE}" ]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
  else
    log "未找到服务文件，跳过删除"
  fi

  step "删除二进制 ${TARGET_BIN}"
  if [ -n "${TARGET_BIN}" ] && [ -e "${TARGET_BIN}" ]; then
    rm -f "${TARGET_BIN}"
  else
    log "未找到二进制，跳过删除"
  fi

  step "确认是否删除配置目录"
  printf '是否同时删除配置目录 %s ? [y/N]: ' "${CONFIG_DIR}"
  read -r remove_config
  if [ "${remove_config}" = "y" ] || [ "${remove_config}" = "Y" ]; then
    log "删除配置目录 ${CONFIG_DIR}"
    rm -rf "${CONFIG_DIR}"
  else
    log "保留配置目录 ${CONFIG_DIR}"
  fi

  step "输出卸载结果"
  log "卸载完成"
}

show_menu() {
  printf '\n请选择操作:\n'
  printf '1. 安装 mihomo\n'
  printf '2. 升级 mihomo\n'
  printf '3. 卸载 mihomo\n'
  printf '请输入 1/2/3: '
}

main() {
  local action="${1:-}"

  require_root
  tmp_dir="$(mktemp -d)"
  trap cleanup EXIT
  log "临时目录: ${tmp_dir}"

  if [ -z "${action}" ]; then
    show_home_summary
    show_menu
    read -r action
  fi

  case "${action}" in
    1|install)
      install_mihomo
      ;;
    2|upgrade|update)
      upgrade_mihomo
      ;;
    3|uninstall|remove)
      uninstall_mihomo
      ;;
    *)
      printf '用法: %s [1|2|3|install|upgrade|uninstall]\n' "$0" >&2
      exit 1
      ;;
  esac
}

main "$@"
