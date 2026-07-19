<div align="center">

# Router Provisioner

Интерактивная подготовка OpenWrt и развёртывание NetShift одним POSIX shell-скриптом.

[![CI](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml/badge.svg)](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/anfixit/router-provisioner)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%2B-00B5E2)](https://openwrt.org/)
[![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25)](router-provisioner.sh)

</div>

Router Provisioner проверяет совместимость устройства, оценивает ресурсы, создаёт резервную копию, помогает настроить базовую безопасность роутера и разворачивает NetShift с VPN-подпиской.

Проект состоит из одного исполняемого файла. На роутере не нужны Python, Docker, Git или отдельный рантайм. Скрипт рассчитан на BusyBox `ash` и использует штатные механизмы OpenWrt.

> [!IMPORTANT]
> Все команды из разделов установки, диагностики и эксплуатации выполняются на самом роутере внутри SSH-сеанса OpenWrt от пользователя `root`. Сначала подключитесь к роутеру привычным способом и убедитесь, что видите приглашение вида `root@OpenWrt:~#`.

> [!WARNING]
> Скрипт изменяет конфигурацию роутера. Сначала запустите диагностику, затем предварительный просмотр и только после проверки переходите к реальному развёртыванию.

## Возможности

- определение модели, `board_name`, target и версии OpenWrt;
- построение точной ссылки OpenWrt Firmware Selector;
- проверка профиля устройства через официальный `profiles.json`;
- рекомендации по безопасному обновлению через `owut`;
- проверка RAM и свободного места в overlay;
- создание резервной копии через `sysupgrade`;
- безопасный extroot на заранее подготовленном внешнем разделе;
- настройка root-пароля, hostname, Dropbear SSH и существующих Wi-Fi AP;
- установка NetShift официальным установщиком;
- скрытый ввод ссылки VPN-подписки и Wi-Fi-паролей;
- URLTest и автоматический выбор доступного узла;
- автоматическое обновление подписки и community-списков;
- глобальный VPN-режим по выбору пользователя;
- прямой маршрут для российских сервисов, `.ru` и `.su`;
- DoH через AdGuard DNS;
- проверка запуска NetShift и вывод последних сообщений журнала;
- режимы диагностики и предварительного просмотра без изменений.

## Границы проекта

Router Provisioner работает после установки OpenWrt. Он не выполняет универсальную прошивку поверх заводской системы и не изменяет:

- U-Boot;
- MTD и UBI;
- внутреннюю GPT-разметку;
- `fw_env`;
- загрузчик устройства;
- аппаратные Wi-Fi radio-секции;
- сетевую конфигурацию от другого роутера.

Такие операции зависят от точной модели и аппаратной ревизии. Ошибка в загрузчике или разметке может сделать устройство незагружаемым.

## Требования

| Компонент | Требование |
|---|---|
| OpenWrt | 24.10 или новее |
| Пользователь | `root` |
| Терминал | Интерактивный SSH-сеанс с TTY |
| Менеджер пакетов | `opkg` или `apk` |
| Свободный overlay | Не менее 25 MiB |
| RAM | Минимум 64 MiB, рекомендуется 128 MiB и больше |
| Интернет | Доступен с самого роутера |
| Wi-Fi | Проводное подключение при изменении SSID или пароля |

NetShift находится в стадии beta. Перед использованием на критичной сети ознакомьтесь с его текущими ограничениями и журналом изменений.

## Быстрый старт

Ниже каждая команда выполняется на роутере внутри уже открытого SSH-сеанса.

### 1. Скачать скрипт и выполнить диагностику

```sh
cd /tmp && if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh; elif command -v wget >/dev/null 2>&1; then wget -qO router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh; elif command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh -o router-provisioner.sh; else echo 'Не найден uclient-fetch, wget или curl' >&2; exit 1; fi && chmod 700 router-provisioner.sh && ./router-provisioner.sh --diagnose
```

Диагностика ничего не изменяет. Она показывает модель, target, версию OpenWrt, профиль Firmware Selector, доступную память и свободное место.

### 2. Выполнить предварительный просмотр

```sh
/tmp/router-provisioner.sh --dry-run
```

`--dry-run` показывает план действий без сохранения конфигурации и без перезапуска сервисов.

### 3. Запустить реальное развёртывание

```sh
/tmp/router-provisioner.sh
```

Не используйте `--yes` при первом запуске. Интерактивные подтверждения являются частью защиты от случайных изменений.

## Режимы запуска

| Параметр | Назначение |
|---|---|
| `--diagnose` | Только диагностика устройства и план OpenWrt |
| `--dry-run` | Показ действий без изменения конфигурации |
| `--yes` | Автоматическое подтверждение обычных вопросов |
| `--version` | Вывод версии Router Provisioner |
| `--help` | Справка по параметрам |

`--yes` не отменяет точное текстовое подтверждение форматирования extroot.

## Рекомендуемый порядок работы

1. Подключить компьютер к роутеру по Ethernet.
2. Открыть SSH-сеанс OpenWrt от `root`.
3. Запустить `--diagnose`.
4. Проверить модель, target, версию OpenWrt, RAM и overlay.
5. При необходимости обновить OpenWrt отдельно.
6. После обновления снова запустить `--diagnose`.
7. Запустить `--dry-run`.
8. Проверить план изменений.
9. Запустить установщик без параметров.
10. Сохранить созданный backup вне роутера.
11. Проверить VPN, DNS, прямую маршрутизацию и повторный SSH-вход.

## Что изменяет скрипт

| Область | Изменения |
|---|---|
| Backup | Создаётся архив `/tmp/router-provisioner-*.tar.gz` |
| System | По запросу меняется hostname |
| Root | По запросу запускается `passwd root` |
| Dropbear | Настраиваются порт, LAN-привязка, публичный ключ и парольный вход |
| Wi-Fi | Меняются только существующие AP-секции |
| NetShift | Устанавливается пакет, создаётся UCI-конфигурация и включается автозапуск |
| DNS | Настраивается DoH и bootstrap DNS внутри NetShift |
| Routing | Настраиваются global proxy и исключения по выбору пользователя |
| Extroot | Только после явного подтверждения форматируется выбранный внешний раздел |

## Настройки NetShift по умолчанию

| Параметр | Значение |
|---|---|
| DNS type | `doh` |
| DoH server | `dns.adguard-dns.com` |
| Bootstrap DNS | `77.88.8.8` |
| Subscription format | `xray` |
| Allow insecure TLS | `0` |
| Subscription update | `1h` |
| URLTest interval | `3m` |
| URLTest tolerance | `50` |
| URLTest URL | `https://www.gstatic.com/generate_204` |
| Прямой community-список | `russia_outside` |
| Дополнительные прямые домены | `.ru`, `.su` |
| IPv6 | Отключён в создаваемой конфигурации |

Значения, влияющие на маршрутизацию, подтверждаются в интерактивном диалоге.

## Подписки VLESS XHTTP

После установки откройте в LuCI:

```text
Services -> NetShift -> Component Manager
```

Установите `sing-box extended`, затем обновите подписку и перезапустите NetShift.

## Резервная копия

До основных изменений скрипт вызывает `sysupgrade -b` и создаёт архив:

```text
/tmp/router-provisioner-YYYYMMDD-HHMMSS.tar.gz
```

Сохраните архив на другом устройстве через привычный SCP или SFTP-клиент. Не храните единственную копию в `/tmp`, потому что этот каталог очищается после перезагрузки.

Перед обновлением прошивки или настройкой extroot обязательно убедитесь, что backup читается и находится вне роутера.

## Безопасность SSH

- Dropbear не перезапускается во время работы установщика.
- Текущий SSH-сеанс не обрывается сразу после записи нового порта.
- Парольный вход отключается только после добавления корректного публичного ключа.
- Если ключ не указан, скрипт проверяет наличие рабочего root-пароля.
- `authorized_keys` создаётся с правами `0600`.
- Dropbear перезапускается вручную после завершения настройки.

Безопасный порядок проверки:

1. Не закрывайте текущий SSH-сеанс.
2. Выполните на роутере `/etc/init.d/dropbear restart`.
3. Откройте второй терминал на компьютере.
4. Проверьте вход с новыми настройками.
5. Закрывайте исходный сеанс только после успешного входа.

## Extroot

Extroot предлагается только при нехватке overlay и только для существующего внешнего раздела USB, SD, SATA или NVMe.

Защитные меры:

- исключаются root, overlay, boot и swap;
- показывается список допустимых кандидатов;
- требуется точная строка подтверждения `ERASE /dev/...`;
- перед форматированием создаётся backup;
- пользователь отдельно подтверждает сохранение backup вне роутера;
- форматируется только выбранный раздел;
- текущий overlay копируется на новый extroot;
- для x86 extroot не предлагается как замена расширению root-раздела.

## Обновление OpenWrt

Router Provisioner не прошивает устройство автоматически. Он определяет `board_name`, target и профиль, после чего показывает:

- текущую версию OpenWrt;
- актуальный стабильный релиз;
- точную страницу Firmware Selector;
- результат проверки профиля в официальном `profiles.json`;
- команды `owut` для установленного менеджера пакетов.

Перед обновлением всегда создавайте и выгружайте backup.

## Проверка после установки

Все команды ниже выполняются на роутере.

Статус NetShift:

```sh
/etc/init.d/netshift status
```

Последние сообщения NetShift:

```sh
logread -e netshift | tail -n 100
```

Обновление списков:

```sh
/usr/bin/netshift list_update
```

Обновление подписки:

```sh
/usr/bin/netshift subscription_update
```

Проверка конфигурации без публикации ссылки подписки:

```sh
uci show netshift | sed 's/\(subscription_url=\).*/\1[REDACTED]/'
```

Проверка свободного места:

```sh
df -h /overlay
```

Проверка памяти:

```sh
free -m
```

## Частые ошибки

### `command not found: uclient-fetch`

Команда была запущена не на OpenWrt либо в сборке отсутствует `uclient-fetch`. Используйте однострочную команду из быстрого старта, которая автоматически проверяет `uclient-fetch`, `wget` и `curl`.

### `Запустите скрипт от root`

Откройте SSH-сеанс OpenWrt от `root`. Обычный пользователь без полного доступа к UCI, Dropbear и init-скриптам не поддерживается.

### `Нужен интерактивный SSH-сеанс с TTY`

Скрипт должен запускаться в обычной интерактивной SSH-сессии, а не через неинтерактивный пайплайн или планировщик.

### Недостаточно места в overlay

Удалите ненужные пакеты, используйте поддерживаемый образ с большим rootfs либо подготовьте внешний раздел для extroot. Не изменяйте MTD, UBI или U-Boot по универсальной инструкции.

### NetShift не запускается

```sh
/etc/init.d/netshift status
```

```sh
logread -e netshift | tail -n 100
```

```sh
uci show netshift | sed 's/\(subscription_url=\).*/\1[REDACTED]/'
```

Для XHTTP проверьте, что установлен `sing-box extended`.

### После смены SSH-настроек не удаётся подключиться

Не закрывайте исходный сеанс. Проверьте сохранённую конфигурацию и журнал Dropbear:

```sh
uci -q get dropbear.@dropbear[0].Port
```

```sh
logread -e dropbear | tail -n 50
```

## Совместимость

CI проверяет проект с помощью:

- POSIX `sh` syntax check;
- Debian `dash`;
- BusyBox `ash`;
- ShellCheck.

Фактическая поддержка конкретного роутера зависит от наличия официального образа OpenWrt, объёма памяти, драйверов накопителя и текущей схемы разделов.

## Разработка

Команды этого раздела выполняются в локальном клоне репозитория на компьютере разработчика, а не на роутере.

Клонирование:

```bash
git clone https://github.com/anfixit/router-provisioner.git
```

Переход в каталог:

```bash
cd router-provisioner
```

Проверка синтаксиса:

```bash
sh -n router-provisioner.sh
```

Тесты через `dash`:

```bash
dash tests/test_router_provisioner.sh
```

Проверка BusyBox `ash` через Docker:

```bash
docker run --rm -v "$PWD:/repo" -w /repo busybox:1.36 ash tests/test_router_provisioner.sh
```

ShellCheck:

```bash
shellcheck router-provisioner.sh tests/*.sh
```

Полная локальная проверка:

```bash
sh -n router-provisioner.sh && dash tests/test_router_provisioner.sh && docker run --rm -v "$PWD:/repo" -w /repo busybox:1.36 ash tests/test_router_provisioner.sh && shellcheck router-provisioner.sh tests/*.sh
```

## Структура репозитория

```text
.github/                         GitHub Actions и шаблоны сообщества
router-provisioner.sh            основной runtime-скрипт
README.md                        пользовательская документация
CONTRIBUTING.md                  правила участия в разработке
SECURITY.md                      политика сообщения об уязвимостях
CODE_OF_CONDUCT.md               правила взаимодействия
CHANGELOG.md                     история заметных изменений
LICENSE                          Apache License 2.0
VERSION                          текущая версия проекта
tests/test_router_provisioner.sh POSIX shell-тесты
```

## Участие в разработке

Перед созданием pull request прочитайте [CONTRIBUTING.md](CONTRIBUTING.md). Для ошибок используйте GitHub Issues и обязательно удаляйте из логов:

- ссылки подписок;
- UUID пользователей;
- токены;
- приватные ключи;
- Wi-Fi-пароли;
- содержимое `/etc/shadow`;
- публичные IP, если они не нужны для воспроизведения.

## Сообщение об уязвимости

Не публикуйте уязвимости и секреты в обычных Issues. Следуйте [SECURITY.md](SECURITY.md) и используйте приватный канал GitHub, если он доступен.

## Версионирование

Проект использует Semantic Versioning:

- `MAJOR` для несовместимых изменений поведения;
- `MINOR` для новых обратно совместимых возможностей;
- `PATCH` для исправлений.

Текущая версия хранится в `VERSION` и в `PROGRAM_VERSION` внутри скрипта.

## Лицензия

Проект распространяется по [Apache License 2.0](LICENSE).

## Отказ от ответственности

Проект не является частью OpenWrt Project или NetShift и не поддерживается их разработчиками. Использование выполняется на ваш риск. Перед изменениями сохраните конфигурацию и убедитесь, что знаете способ восстановления конкретной модели роутера.

## Благодарности

- [OpenWrt](https://openwrt.org/) за открытую платформу маршрутизаторов;
- [NetShift](https://github.com/yandexru45/netshift) за маршрутизацию на базе sing-box;
- [sing-box](https://github.com/SagerNet/sing-box) за сетевое ядро.
