#!/usr/bin/env bash
# push-to-github.sh — создаёт репозиторий "Sing-box-Extended install" и пушит сюда.
# Использование:
#   GITHUB_TOKEN=ghp_xxx bash push-to-github.sh
# Токен: Settings → Developer settings → Personal access tokens (scope: repo).
set -euo pipefail

REPO_NAME="Sing-box-Extended install"

curl -fsSL >/dev/null 2>&1 || { echo "Нужен curl"; exit 1; }
git --version >/dev/null 2>&1 || { echo "Нужен git"; exit 1; }
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "Укажите токен: GITHUB_TOKEN=ghp_xxx bash $0"; exit 1; }

api() { curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H 'Accept: application/vnd.github+json' "$@"; }

echo "[+] Проверяю токен..."
USER_NAME="$(api https://api.github.com/user | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\(.*\)"$/\1')"
[[ -n "${USER_NAME}" ]] || { echo "[-] Не удалось получить имя пользователя (неверный токен?)"; exit 1; }
echo "[+] Пользователь: ${USER_NAME}"

# URL-кодированное имя (пробел -> %20), т.к. в имени репозитория есть пробел
REPO_ENC="Sing-box-Extended%20install"

if api "https://api.github.com/repos/${USER_NAME}/${REPO_ENC}" >/dev/null 2>&1; then
    echo "[!] Репозиторий уже существует — просто запушу в него"
else
    echo "[+] Создаю репозиторий: ${USER_NAME}/${REPO_NAME}"
    api -X POST https://api.github.com/user/repos \
        -d "{\"name\": \"${REPO_NAME}\", \"description\": \"Installer for sing-box-extended (SFA) with systemd support\", \"private\": false}" >/dev/null
fi

echo "[+] Инициализирую git и пушу..."
git init -q -b main .
git add install.sh push-to-github.sh README.md
git -c user.name="${USER_NAME}" -c user.email="${USER_NAME}@users.noreply.github.com" \
    commit -qm "sing-box-extended installer with systemd"
git push -q "https://x-access-token:${GITHUB_TOKEN}@github.com/${USER_NAME}/${REPO_ENC}.git" main

echo "[+] Готово: https://github.com/${USER_NAME}/${REPO_NAME}"
