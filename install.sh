#!/usr/bin/env bash
#
# install.sh — установка sing-box-extended (SFA) в Linux c systemd
# Репозиторий: https://github.com/shtorm-7/sing-box-extended
#
# Использование:
#   sudo ./install.sh [install|update|uninstall|status]
#     install    — скачать последнюю версию и установить (по умолчанию)
#     update     — обновить до последней версии и перезапустить сервис
#     uninstall  — удалить бинарник и systemd-юнит (конфиг в /etc/sing-box остаётся)
#     status     — показать статус сервиса и версию
#
# После установки команда `sing-box` доступна как в оригинале:
#   sing-box run -c /path/to/config.json
#   sing-box version
#   systemctl start|stop|restart|status sing-box
#
set -euo pipefail

REPO="shtorm-7/sing-box-extended"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
FALLBACK_TAG="v1.14.3-extended-2.7.3"   # запасной тег, если GitHub API недоступен
RAW_URL="https://raw.githubusercontent.com/ZloZloe39/SIng-box-Extended-install/main/install.sh"

BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
UNIT_PATH="/etc/systemd/system/sing-box.service"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[+][${NC}] $*"; }
note()  { echo -e "${YLW}[!][${NC}] $*"; }
fail()  { echo -e "${RED}[-][${NC}] $*" >&2; exit 1; }

# ---------------------------------------------------------------- проверки
need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "${RED}[-][${NC}] Нужны права root. Запустите, например:" >&2
        echo -e "      sudo bash <(curl -Ls ${RAW_URL}) $*" >&2
        exit 1
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

check_systemd() {
    if ! have systemctl || [[ ! -d /run/systemd/system ]]; then
        fail "systemd не обнаружен (скрипт рассчитан на systemd-системы: Debian/Ubuntu, RHEL, Arch и т.п.)"
    fi
}

# ---------------------------------------------------------------- архитектура
detect_arch() {
    local m
    m="$(uname -m)"
    case "${m}" in
        x86_64|amd64)      echo "amd64" ;;
        aarch64|arm64)     echo "arm64" ;;
        armv7l|armv7hl)    echo "armv7" ;;
        armv6l)            echo "armv6" ;;
        i386|i686|x86)     echo "386" ;;
        riscv64)           echo "riscv64" ;;
        s390x)             echo "s390x" ;;
        loongarch64)       echo "loong64" ;;
        *) fail "Неподдерживаемая архитектура: ${m}" ;;
    esac
}

is_musl() {
    # Alpine и другие musl-дистрибутивы -> musl-сборка
    if have ldd && ldd --version 2>&1 | grep -qi 'musl'; then return 0; fi
    if [[ -f /lib/ld-musl-x86_64.so.1 || -f /lib/ld-musl-aarch64.so.1 ]]; then return 0; fi
    if [[ -f /etc/alpine-release ]]; then return 0; fi
    return 1
}

download() { # download <url> <outfile>
    local url="$1" out="$2"
    if have curl; then
        curl -fL --retry 3 --connect-timeout 30 -o "${out}" "${url}"
    elif have wget; then
        wget -q --tries=3 --timeout=30 -O "${out}" "${url}"
    else
        fail "Нужен curl или wget для скачивания (установите один из них)"
    fi
}

# ---------------------------------------------------------------- версия
get_latest_tag() {
    local tag=""
    if have curl; then
        tag=$(curl -fsSL --connect-timeout 15 \
            -H 'User-Agent: sing-box-extended-installer' \
            "${API_URL}" 2>/dev/null | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -n1 | sed 's/.*"\(.*\)"$/\1/') || true
    fi
    if [[ -z "${tag}" ]]; then
        note "GitHub API недоступен, использую известную версию: ${FALLBACK_TAG}"
        tag="${FALLBACK_TAG}"
    fi
    echo "${tag}"
}

# ---------------------------------------------------------------- установка бинарника
install_binary() {
    local tag="$1" arch="$2" variant="" file tmp bin
    is_musl && variant="-musl"
    file="sing-box-${tag}-linux-${arch}${variant}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${tag}/${file}"

    info "Версия : ${tag}"
    info "Архитектура: linux-${arch}${variant}"
    info "Скачиваю: ${url}"

    tmp="$(mktemp -d /tmp/sing-box-ext.XXXXXX)"
    trap 'rm -rf "${tmp}"' RETURN

    download "${url}" "${tmp}/${file}"
    tar -xzf "${tmp}/${file}" -C "${tmp}"

    # ищем исполняемый файл sing-box в архиве (обычно лежит в корне)
    bin="$(find "${tmp}" -maxdepth 2 -type f -name 'sing-box' | head -n1)"
    [[ -n "${bin}" ]] || fail "В архиве не найден бинарник sing-box"

    install -m 0755 "${bin}" "${BIN_PATH}"
    info "Установлено: ${BIN_PATH}"

    # проверка запускаемости (glibc/musl, архитектура)
    if ! "${BIN_PATH}" version >/dev/null 2>&1; then
        note "Бинарник не запустился. Если ошибка glibc — попробуйте musl-вариант вручную:"
        note "  ${url/-glibc/-musl}"
        fail "Проверьте совместимость бинарника с вашей системой"
    fi
    info "Версия : $(${BIN_PATH} version | head -n1)"
}

# ---------------------------------------------------------------- конфиг
install_config() {
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cat > "${CONFIG_FILE}" <<'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8" }
    ],
    "rules": [
      { "outbound": "any", "server": "google" }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns",    "tag": "dns-out" }
  ]
}
EOF
        chmod 0644 "${CONFIG_FILE}"
        info "Создан стартовый конфиг: ${CONFIG_FILE} (замените на свой)"
    else
        note "Конфиг уже существует, не трогаю: ${CONFIG_FILE}"
    fi
}

# ---------------------------------------------------------------- systemd-юнит
install_unit() {
    cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=sing-box extended (SFA) — universal proxy platform
Documentation=https://github.com/${REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
# Права, необходимые для TUN/BPF (tun-инбаунд, bpf routing)
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_TIME
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${UNIT_PATH}"
    info "Systemd-юнит: ${UNIT_PATH}"

    systemctl daemon-reload
}

# ---------------------------------------------------------------- действия
do_install() {
    check_systemd
    local tag arch
    tag="$(get_latest_tag)"
    arch="$(detect_arch)"
    install_binary "${tag}" "${arch}"
    install_config
    install_unit

    if [[ -f "${CONFIG_FILE}" ]] && "${BIN_PATH}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
        info "Конфиг валиден. Запускаю сервис..."
        systemctl enable --now sing-box.service
        sleep 1
        systemctl --no-pager --lines=5 status sing-box.service || true
    else
        note "Конфиг ещё не готов (или невалиден) — сервис НЕ запущен."
        note "После заполнения конфига: systemctl start sing-box"
    fi

    echo
    info "Готово! Команда доступна как в оригинале:"
    echo "      sing-box run -c /etc/sing-box/config.json   # вручную"
    echo "      sing-box version                            # версия"
    echo "      systemctl start|stop|restart|status sing-box"
}

do_update() {
    check_systemd
    have "$BIN_PATH" 2>/dev/null || [[ -x "${BIN_PATH}" ]] || fail "sing-box не установлен, выполните сначала: $0 install"
    local tag arch cur
    cur="$("${BIN_PATH}" version | head -n1)"
    tag="$(get_latest_tag)"
    arch="$(detect_arch)"
    info "Текущая версия: ${cur}"
    install_binary "${tag}" "${arch}"
    systemctl daemon-reload
    if systemctl is-active --quiet sing-box.service; then
        info "Перезапускаю сервис..."
        systemctl restart sing-box.service
    fi
}

do_uninstall() {
    check_systemd
    systemctl disable --now sing-box.service 2>/dev/null || true
    rm -f "${UNIT_PATH}"
    systemctl daemon-reload
    rm -f "${BIN_PATH}"
    note "Удалены: ${BIN_PATH}, ${UNIT_PATH}"
    note "Конфиг сохранён в ${CONFIG_DIR} (удалите вручную, если не нужен)"
}

do_status() {
    check_systemd
    if [[ -x "${BIN_PATH}" ]]; then
        info "Бинарник: $("${BIN_PATH}" version | head -n1) (${BIN_PATH})"
    else
        note "Бинарник не установлен"
    fi
    systemctl --no-pager status sing-box.service || true
}

# ---------------------------------------------------------------- main
cmd="${1:-install}"
case "${cmd}" in
    install)   need_root; do_install ;;
    update)    need_root; do_update ;;
    uninstall) need_root; do_uninstall ;;
    status)    do_status ;;
    -h|--help|help)
        cat <<'HELP'
Использование: install.sh [install|update|uninstall|status]
  install    — скачать последнюю версию и установить (по умолчанию)
  update     — обновить до последней версии и перезапустить сервис
  uninstall  — удалить бинарник и systemd-юнит (конфиг в /etc/sing-box остаётся)
  status     — показать статус сервиса и версию

Быстрая установка одной командой:
  sudo bash <(curl -Ls https://raw.githubusercontent.com/ZloZloe39/SIng-box-Extended-install/main/install.sh)
HELP
        ;;
    *) fail "Неизвестная команда: ${cmd} (install|update|uninstall|status)" ;;
esac
