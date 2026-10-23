#!/usr/bin/env bash
#
# install.sh — установка sing-box-extended (SFA) в Linux c systemd
# Репозиторий: https://github.com/shtorm-7/sing-box-extended
#
# Использование:
#   sudo ./install.sh [install|update|uninstall|status] [--remove-apt|--keep-apt]
#     install    — установка последней версии (по умолчанию);
#                  при повторном запуске проверяет наличие нового релиза
#                  и обновляет, если он есть
#     update     — обновить до последней версии и перезапустить сервис
#     uninstall  — удалить бинарник и systemd-юнит (конфиг в /etc/sing-box остаётся)
#     status     — показать статус сервиса и версию
#
# Флаги (если оригинальный sing-box установлен через apt):
#   --remove-apt — не спрашивать: удалить apt-пакет и установить Extended
#   --keep-apt   — не спрашивать: ничего не трогать, Extended не ставить
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
VERSION_FILE="${CONFIG_DIR}/version"   # тег последнего установленного релиза
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

# ---------------------------------------------------------------- версии
# version_ge A B -> 0, если A >= B (сравнение тегов вида v1.14.3-extended-2.7.3)
version_ge() {
    local a="${1#v}" b="${2#v}"
    [[ "$(printf '%s\n%s\n' "${b}" "${a}" | sort -rV | head -n1)" == "${a}" ]]
}

save_version() { # save_version <tag>
    mkdir -p "${CONFIG_DIR}"
    echo "$1" > "${VERSION_FILE}"
}

ensure_running() {
    if [[ -f "${CONFIG_FILE}" ]] && "${BIN_PATH}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
        if systemctl is-active --quiet sing-box.service; then
            info "Перезапускаю сервис с новой версией..."
            systemctl restart sing-box.service
        else
            info "Конфиг валиден. Запускаю сервис..."
            systemctl enable --now sing-box.service
        fi
        sleep 1
        systemctl --no-pager --lines=5 status sing-box.service || true
    else
        note "Конфиг ещё не готов (или невалиден) — сервис НЕ запущен."
        note "После заполнения конфига: systemctl start sing-box"
    fi
}

# ---------------------------------------------------------------- установка бинарника
install_binary() {
    local tag="$1" arch="$2" variant="" file tmp bin
    is_musl && variant="-musl"
    # в ассетах этого форка версия без префикса v: sing-box-1.14.3-extended-...-linux-amd64.tar.gz
    file="sing-box-${tag#v}-linux-${arch}${variant}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${tag}/${file}"

    info "Версия : ${tag}"
    info "Архитектура: linux-${arch}${variant}"
    info "Скачиваю: ${url}"

    tmp="$(mktemp -d /tmp/sing-box-ext.XXXXXX)"

    download "${url}" "${tmp}/${file}" || { rm -rf "${tmp}"; fail "Не удалось скачать: ${url}"; }
    tar -xzf "${tmp}/${file}" -C "${tmp}" || { rm -rf "${tmp}"; fail "Не удалось распаковать архив"; }

    # ищем исполняемый файл sing-box в архиве (обычно лежит в корне)
    bin="$(find "${tmp}" -maxdepth 2 -type f -name 'sing-box' | head -n1)"
    [[ -n "${bin}" ]] || { rm -rf "${tmp}"; fail "В архиве не найден бинарник sing-box"; }

    install -m 0755 "${bin}" "${BIN_PATH}"
    rm -rf "${tmp}"
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

# ---------------------------------------------------------------- apt-пакет (оригинальный sing-box)
handle_apt_package() {
    # Если оригинальный sing-box стоит как apt-пакет — спрашиваем, удалять ли его.
    # Конфиг /etc/sing-box в обоих случаях сохраняется:
    #   - apt-get remove (не purge!) не трогает /etc;
    #   - скрипт существующий config.json никогда не перезаписывает.
    have dpkg-query || return 0
    local status ans="${APT_ANSWER:-}"
    status="$(dpkg-query -W -f='${Status}' sing-box 2>/dev/null || true)"
    [[ "${status}" == *"install ok installed"* ]] || return 0

    echo
    note "Обнаружен оригинальный sing-box, установленный через apt (пакет 'sing-box')."
    if [[ -z "${ans}" ]]; then
        # читаем строго с /dev/tty: при запуске bash <(curl ...) stdin занят самим скриптом
        [[ -r /dev/tty && -w /dev/tty ]] || fail \
            "Нечем задать вопрос (нет интерактивного терминала). Повторите с флагом --remove-apt (удалить apt-версию) или --keep-apt (не трогать)."
        echo "  [y] Удалить apt-версию и установить sing-box-extended"
        echo "  [n] Ничего не трогать (Extended не будет установлен)"
        echo "Конфиг ${CONFIG_FILE} сохранится в любом случае."
        printf "Ваш выбор: "
        read -r ans < /dev/tty || fail "Не удалось прочитать ответ с терминала"
    else
        note "Ответ взят из флага: ${ans}"
    fi

    case "${ans}" in
        [yY]*)
            have apt-get || fail "Найден dpkg, но нет apt-get для удаления пакета"
            info "Удаляю apt-пакет 'sing-box' (конфиг в ${CONFIG_DIR} сохраню)..."
            DEBIAN_FRONTEND=noninteractive apt-get remove -y sing-box \
                || fail "Не удалось удалить apt-пакет 'sing-box'"
            ;;
        *)
            note "Хорошо, установленную версию не трогаю. Extended не будет установлен."
            exit 0
            ;;
    esac
}

# ---------------------------------------------------------------- действия
do_install() {
    check_systemd
    handle_apt_package
    local tag arch installed
    tag="$(get_latest_tag)"
    arch="$(detect_arch)"

    # повторный запуск: если стоит новая версия — обновляем, иначе выходим
    if [[ -x "${BIN_PATH}" && -f "${VERSION_FILE}" ]]; then
        installed="$(<"${VERSION_FILE}")"
        if version_ge "${installed}" "${tag}"; then
            info "Уже установлена последняя версия: ${installed}. Обновлять нечего."
            if [[ ! -f "${UNIT_PATH}" ]]; then
                note "Systemd-юнит не найден — доустанавливаю его и конфиг..."
                install_config
                install_unit
            fi
            return 0
        fi
        note "Доступна новая версия: ${installed} -> ${tag}. Обновляю..."
    elif [[ -x "${BIN_PATH}" ]]; then
        note "Обнаружена существующая установка: $("${BIN_PATH}" version | head -n1) — ставлю последнюю версию"
    fi

    install_binary "${tag}" "${arch}"
    save_version "${tag}"
    install_config
    install_unit
    ensure_running

    echo
    info "Готово! Команда доступна как в оригинале:"
    echo "      sing-box run -c /etc/sing-box/config.json   # вручную"
    echo "      sing-box version                            # версия"
    echo "      systemctl start|stop|restart|status sing-box"
}

do_update() {
    check_systemd
    [[ -x "${BIN_PATH}" ]] || fail "sing-box не установлен, выполните сначала: $0 install"
    local tag arch cur
    tag="$(get_latest_tag)"
    if [[ -f "${VERSION_FILE}" ]]; then
        cur="$(<"${VERSION_FILE}")"
        if version_ge "${cur}" "${tag}"; then
            info "Уже установлена последняя версия: ${cur}. Обновлять нечего."
            return 0
        fi
        note "Доступна новая версия: ${cur} -> ${tag}"
    else
        cur="$("${BIN_PATH}" version | head -n1)"
        info "Текущая версия: ${cur}"
    fi
    arch="$(detect_arch)"
    install_binary "${tag}" "${arch}"
    save_version "${tag}"
    systemctl daemon-reload
    if systemctl is-active --quiet sing-box.service; then
        info "Перезапускаю сервис..."
        systemctl restart sing-box.service
    fi
}

do_uninstall() {
    check_systemd
    systemctl disable --now sing-box.service 2>/dev/null || true
    rm -f "${UNIT_PATH}" "${VERSION_FILE}"
    systemctl daemon-reload
    rm -f "${BIN_PATH}"
    note "Удалены: ${BIN_PATH}, ${UNIT_PATH}, ${VERSION_FILE}"
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
cmd=""
APT_ANSWER=""
for a in "$@"; do
    case "${a}" in
        --remove-apt) APT_ANSWER="y" ;;
        --keep-apt)   APT_ANSWER="n" ;;
        -h|--help|help) cmd="help" ;;
        *)
            if [[ -z "${cmd}" ]]; then cmd="${a}"; else fail "Неизвестный аргумент: ${a}"; fi
            ;;
    esac
done
cmd="${cmd:-install}"

case "${cmd}" in
    install)   need_root; do_install ;;
    update)    need_root; do_update ;;
    uninstall) need_root; do_uninstall ;;
    status)    do_status ;;
    -h|--help|help)
        cat <<'HELP'
Использование: install.sh [install|update|uninstall|status] [--remove-apt|--keep-apt]
  install    — скачать последнюю версию и установить (по умолчанию)
  update     — обновить до последней версии и перезапустить сервис
  uninstall  — удалить бинарник и systemd-юнит (конфиг в /etc/sing-box остаётся)
  status     — показать статус сервиса и версию

Флаги (если оригинальный sing-box установлен через apt):
  --remove-apt   не спрашивать: удалить apt-пакет и установить Extended
  --keep-apt     не спрашивать: ничего не трогать, Extended не ставить

Быстрая установка одной командой:
  sudo bash <(curl -Ls https://raw.githubusercontent.com/ZloZloe39/SIng-box-Extended-install/main/install.sh)
HELP
        ;;
    *) fail "Неизвестная команда: ${cmd} (install|update|uninstall|status)" ;;
esac
