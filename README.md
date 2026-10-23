# Sing-box-Extended install

Скрипт установки [sing-box-extended (SFA)](https://github.com/shtorm-7/sing-box-extended) в Linux с настройкой systemd.

После установки команда `sing-box` работает **как в оригинале**:

```bash
sing-box version
sing-box run -c /etc/sing-box/config.json   # запуск вручную
systemctl start|stop|restart|status sing-box  # через systemd
```

## Что делает скрипт

1. Определяет архитектуру (amd64, arm64, armv7, armv6, 386, riscv64, s390x, loong64) и libc (glibc/musl — для Alpine).
2. Достаёт тег последнего релиза с GitHub API (есть запасной тег на случай недоступности API).
3. Скачивает `sing-box-<tag>-linux-<arch>[-musl].tar.gz` из релизов и ставит бинарник в `/usr/local/bin/sing-box`.
4. Создаёт стартовый конфиг `/etc/sing-box/config.json` (mixed-инбаунд на 127.0.0.1:2080), если его ещё нет — существующий не затирается.
5. Устанавливает systemd-юнит `sing-box.service` с правами для TUN/BPF (`CAP_NET_ADMIN`, `CAP_NET_RAW`) и автозапуском.
6. Запоминает установленный тег релиза в `/etc/sing-box/version`.
7. Проверяет конфиг командой `sing-box check` и при успехе запускает сервис.

**Обновление:** повторный запуск скрипта (`install` или `update`) сравнивает установленную версию с последним релизом — если вышел новый, бинарник обновляется, а запущенный сервис перезапускается; если версия уже последняя, скрипт просто сообщит об этом.

**Уже стоит оригинальный sing-box из apt:** скрипт обнаружит пакет `sing-box` (через `dpkg-query`) и спросит — удалить его и поставить Extended или ничего не трогать. Конфиг `/etc/sing-box/config.json` сохраняется в обоих случаях: удаление идёт через `apt-get remove` (не `purge`), а существующий конфиг скрипт никогда не перезаписывает. Для неинтерактивного запуска есть флаги:

```bash
sudo bash install.sh --remove-apt   # без вопроса: удалить apt-версию и поставить Extended
sudo bash install.sh --keep-apt     # без вопроса: ничего не трогать, Extended не ставить
```

## Установка

Одной командой (Debian/Ubuntu/RHEL/Arch/... — нужен systemd и curl):

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/ZloZloe39/SIng-box-Extended-install/main/install.sh)
```

Или скачав скрипт:

```bash
git clone https://github.com/ZloZloe39/SIng-box-Extended-install.git
cd SIng-box-Extended-install
sudo bash install.sh              # установка последней версии
sudo bash install.sh update       # обновление до последней версии
sudo bash install.sh status       # статус сервиса и версия
sudo bash install.sh uninstall    # удаление; спросит, удалять ли конфиг подчистую
```

## Удаление

`uninstall` останавливает и отключает сервис, удаляет бинарник `/usr/local/bin/sing-box`, systemd-юнит и `/etc/sing-box/version`, затем спрашивает:

- **удалить всё подчистую** — вместе с конфигом и данными в `/etc/sing-box`;
- **оставить конфиг** — стандартное удаление, `/etc/sing-box` на месте.

Если рядом стоит оригинальный sing-box из apt, скрипт предупредит: он тоже использует `/etc/sing-box`, и полное удаление затронет и его конфиг.

Без вопроса (для неинтерактивного запуска):

```bash
sudo bash install.sh uninstall --purge        # удалить всё подчистую, включая /etc/sing-box
sudo bash install.sh uninstall --keep-config  # удалить только бинарник и юнит, конфиг оставить
```


## Файлы, которые создаются

| Путь | Назначение |
|---|---|
| `/usr/local/bin/sing-box` | бинарник (команда `sing-box`) |
| `/etc/sing-box/config.json` | конфигурация (замените на свою) |
| `/etc/sing-box/version` | тег установленного релиза (для авто-обновления) |
| `/etc/systemd/system/sing-box.service` | systemd-юнит |

