# Router Provisioner

[![CI](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml/badge.svg)](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/anfixit/router-provisioner)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%2B-00B5E2)](https://openwrt.org/)
[![Shell](https://img.shields.io/badge/shell-POSIX-4EAA25)](router-provisioner.sh)

Интерактивный POSIX shell-установщик для подготовки роутера с OpenWrt и развёртывания NetShift с VPN-подпиской.

Проект состоит из одного исполняемого файла и не требует Python, Docker или отдельного рантайма на роутере. Скрипт рассчитан на BusyBox `ash`, выполняет предварительную диагностику и не изменяет загрузчик или внутреннюю разметку вслепую.

## Возможности

- определение модели, `board_name`, target и версии OpenWrt;
- формирование ссылки на Firmware Selector для обнаруженного устройства;
- рекомендации по обновлению через `owut`;
- проверка RAM и свободного места в overlay;
- создание резервной копии через `sysupgrade`;
- безопасная настройка hostname, root-пароля, SSH и Wi-Fi;
- установка и базовая настройка NetShift;
- скрытый ввод ссылки VPN-подписки;
- URLTest и автоматический выбор доступного узла;
- автоматическое обновление подписки;
- глобальная VPN-маршрутизация по выбору пользователя;
- прямой маршрут для российских сервисов, `.ru` и `.su`;
- безопасный extroot на отдельном внешнем разделе;
- режимы диагностики и предварительного просмотра.

## Важное ограничение

Router Provisioner не устанавливает OpenWrt поверх заводской прошивки автоматически.

Скрипт запускается после того, как на роутере уже работает OpenWrt. Он может определить установленную версию, модель и target, а затем показать подходящую страницу Firmware Selector и рекомендации по обновлению.

Скрипт намеренно не изменяет:

- U-Boot;
- MTD и UBI;
- внутреннюю GPT-разметку;
- `fw_env`;
- аппаратные Wi-Fi radio-секции;
- сетевую конфигурацию от другого роутера.

Универсальная переразметка внутренней памяти невозможна без отдельного профиля конкретной модели и аппаратной ревизии. Ошибка в этой части может сделать устройство незагружаемым.

## Требования

- OpenWrt 24.10 или новее;
- запуск от `root`;
- интерактивный SSH-сеанс с TTY;
- `opkg` или `apk`;
- не менее 25 MiB свободного overlay;
- проводное подключение при изменении Wi-Fi.

Менее 64 MiB RAM считается небезопасной конфигурацией. При объёме менее 128 MiB скрипт выводит предупреждение.

## Быстрый старт

### Вариант 1. Одна команда на Mac или Linux

Команда подключится к роутеру, скачает скрипт непосредственно на OpenWrt и запустит только диагностику:

```bash
ssh -t root@192.168.1.1 'cd /tmp && uclient-fetch -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh && chmod 700 router-provisioner.sh && ./router-provisioner.sh --diagnose'
```

Для SSH-порта `2810`:

```bash
ssh -t -p 2810 root@192.168.1.1 'cd /tmp && uclient-fetch -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh && chmod 700 router-provisioner.sh && ./router-provisioner.sh --diagnose'
```

`uclient-fetch` выполняется на роутере, а не на macOS. Поэтому команда запускается через `ssh`.

### Вариант 2. Команда внутри SSH-сеанса OpenWrt

Сначала подключитесь к роутеру:

```bash
ssh -t root@192.168.1.1
```

Затем выполните на роутере одной строкой:

```sh
cd /tmp && uclient-fetch -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh && chmod 700 router-provisioner.sh && ./router-provisioner.sh --diagnose
```

### Вариант 3. Если на роутере нет `uclient-fetch`

Скопируйте файл с компьютера и запустите диагностику одной командой:

```bash
scp router-provisioner.sh root@192.168.1.1:/tmp/router-provisioner.sh && ssh -t root@192.168.1.1 'chmod 700 /tmp/router-provisioner.sh && /tmp/router-provisioner.sh --diagnose'
```

Для SSH-порта `2810`:

```bash
scp -P 2810 router-provisioner.sh root@192.168.1.1:/tmp/router-provisioner.sh && ssh -t -p 2810 root@192.168.1.1 'chmod 700 /tmp/router-provisioner.sh && /tmp/router-provisioner.sh --diagnose'
```

## Рекомендуемый порядок запуска

### 1. Диагностика

Ничего не изменяет:

```sh
/tmp/router-provisioner.sh --diagnose
```

### 2. Предварительный просмотр

Показывает предполагаемые действия без изменения конфигурации:

```sh
/tmp/router-provisioner.sh --dry-run
```

### 3. Реальное развёртывание

Запускает интерактивную настройку:

```sh
/tmp/router-provisioner.sh
```

Не запускайте реальное развёртывание, пока не проверили вывод `--diagnose` и `--dry-run`.

## Параметры командной строки

| Параметр | Назначение |
|---|---|
| `--diagnose` | Только диагностика устройства и план обновления OpenWrt |
| `--dry-run` | Показать действия без изменения конфигурации |
| `--yes` | Автоматически подтвердить обычные вопросы |
| `--version` | Показать версию |
| `--help` | Показать справку |

`--yes` не отменяет точное текстовое подтверждение форматирования extroot.

## Что настраивается в NetShift

При автоматической настройке создаются:

- DoH через AdGuard DNS;
- bootstrap DNS `77.88.8.8`;
- VPN-секция с подпиской;
- формат подписки Xray для Remnawave и XHTTP;
- URLTest с проверкой узлов каждые 3 минуты;
- обновление подписки каждый час;
- глобальный VPN-режим по выбору пользователя;
- исключение `russia_outside`, `.ru` и `.su` по выбору пользователя.

Для VLESS XHTTP после установки откройте:

```text
LuCI -> Services -> NetShift -> Component Manager
```

Установите `sing-box extended`, обновите подписку и перезапустите NetShift.

## Безопасность SSH

Dropbear не перезапускается во время работы установщика. Это защищает текущий SSH-сеанс от обрыва после смены порта или отключения парольной аутентификации.

После завершения настройки:

1. оставьте текущий SSH-сеанс открытым;
2. примените перезапуск Dropbear;
3. откройте вторую SSH-сессию;
4. убедитесь, что вход работает;
5. только после этого закрывайте первую сессию.

Ссылка подписки и пароль Wi-Fi не выводятся в `--dry-run` и не хранятся в репозитории.

## Extroot

Extroot поддерживается только для отдельного внешнего раздела USB, SD, SATA или NVMe.

Скрипт:

- исключает root, overlay, boot и swap;
- требует точного подтверждения вида `ERASE /dev/sda1`;
- создаёт резервную копию до форматирования;
- форматирует только явно выбранный внешний раздел;
- копирует текущий overlay;
- настраивает `/etc/config/fstab`.

Для x86 рекомендуется расширять root-раздел штатными средствами, а не использовать этот сценарий extroot.

## Восстановление

Перед изменениями скрипт предлагает создать резервную копию OpenWrt через `sysupgrade -b`.

Дополнительно рекомендуется сохранить её на компьютер:

```bash
scp root@192.168.1.1:/tmp/router-provisioner-backup-*.tar.gz .
```

Для нестандартного SSH-порта:

```bash
scp -P 2810 root@192.168.1.1:/tmp/router-provisioner-backup-*.tar.gz .
```

Не храните единственную резервную копию только во временном каталоге `/tmp` роутера.

## Диагностика проблем

Проверить версию скрипта:

```sh
/tmp/router-provisioner.sh --version
```

Проверить свободное место:

```sh
df -h /overlay
```

Проверить память:

```sh
free -m
```

Проверить NetShift:

```sh
/etc/init.d/netshift status
```

Последние сообщения журнала:

```sh
logread -e netshift | tail -n 100
```

Проверить конфигурацию UCI:

```sh
uci show netshift
```

## Разработка

Структура репозитория:

```text
router-provisioner.sh             основной скрипт для OpenWrt
tests/test_router_provisioner.sh  тесты POSIX shell
.github/workflows/ci.yml          CI: syntax, dash, BusyBox ash, ShellCheck
VERSION                           версия проекта
LICENSE                           Apache License 2.0
```

Локальная проверка на macOS или Linux:

```bash
sh -n router-provisioner.sh
```

```bash
dash tests/test_router_provisioner.sh
```

Проверка BusyBox `ash` через Docker:

```bash
docker run --rm -v "$PWD:/repo" -w /repo busybox:1.36 ash tests/test_router_provisioner.sh
```

ShellCheck:

```bash
shellcheck router-provisioner.sh tests/test_router_provisioner.sh
```

## Как внести вклад

Перед созданием pull request:

1. создайте отдельную ветку;
2. внесите минимальные и понятные изменения;
3. добавьте или обновите тесты;
4. выполните локальные проверки;
5. не добавляйте ссылки подписок, пароли, приватные ключи и дампы конфигурации;
6. опишите модель роутера, версию OpenWrt и сценарий проверки.

Подробности находятся в [CONTRIBUTING.md](CONTRIBUTING.md).

## Сообщение об уязвимости

Не публикуйте данные об уязвимости, секреты или конфигурацию реального роутера в открытом issue.

Используйте инструкции из [SECURITY.md](SECURITY.md).

## Кодекс поведения

Участие в проекте регулируется [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Лицензия

Проект распространяется по лицензии [Apache License 2.0](LICENSE).

Использование скрипта выполняется на ваш риск. Перед изменением конфигурации убедитесь, что у вас есть резервная копия и физический доступ к роутеру.