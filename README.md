<div align="center">

# Router Provisioner

Интерактивная подготовка OpenWrt: NetShift, VLESS XHTTP, прямой доступ к российским сервисам и YouTube через youtubeUnblock.

[![CI](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml/badge.svg)](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/anfixit/router-provisioner)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%2B-00B5E2)](https://openwrt.org/)
[![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25)](router-provisioner.sh)

</div>

Router Provisioner — один POSIX shell-скрипт для уже установленного OpenWrt. Он проверяет устройство и ресурсы, создаёт резервную копию, настраивает базовую безопасность, устанавливает NetShift и `sing-box extended`, подключает VPN-подписку только с VLESS XHTTP-нодами и настраивает прямой маршрут для российских сервисов и YouTube.

На роутере не нужны Python, Docker или Git. Скрипт рассчитан на BusyBox `ash` и штатные механизмы OpenWrt.

> [!IMPORTANT]
> Все команды ниже выполняются на самом роутере от `root` в интерактивном терминале. При изменении Wi-Fi подключите компьютер к роутеру по Ethernet.

> [!WARNING]
> Скрипт изменяет системную конфигурацию, устанавливает пакеты и перезапускает сетевые службы. Не закрывайте текущий терминал до завершения установки и проверки повторного входа.

## Что настраивается

### Базовая подготовка OpenWrt

- определение модели, `board_name`, target, архитектуры и версии OpenWrt;
- проверка профиля устройства через официальный `profiles.json`;
- проверка RAM и свободного места в overlay;
- резервная копия конфигурации через `sysupgrade -b`;
- изменение hostname и root-пароля по запросу;
- настройка Dropbear: LAN-привязка, порт, публичный ключ и парольный вход;
- изменение существующих Wi-Fi AP-секций;
- безопасный extroot на заранее подготовленном внешнем разделе.

### NetShift и VPN

- установка NetShift официальным установщиком;
- автоматическая установка и проверка `sing-box extended`;
- скрытый ввод ссылки подписки;
- формат подписки `xray`;
- глобальный VPN для внешнего трафика;
- URLTest и автоматический выбор доступной ноды;
- допуск только VLESS с `transport.type = xhttp`;
- исключение TCP/Vision и любых других VLESS-транспортов;
- проверка итогового JSON через `sing-box check`;
- ожидание процесса sing-box и рабочего FakeIP;
- резервирование кеша подписки и откат при неудачном обновлении;
- безопасное периодическое обновление через отдельный helper.

### Прямой трафик

Секция `RU_DIRECT` объединяет независимые источники правил:

- community-список `russia_outside`;
- доменные зоны `.ru` и `.su`;
- локальный файл `/etc/netshift/rulesets/youtube-direct.lst`.

Файл `youtube-direct.lst` содержит только YouTube и связанные домены. Российские правила находятся не в этом файле, а подключаются отдельно через `russia_outside`, `.ru` и `.su`.

### YouTube

- установка `youtubeUnblock` и LuCI-приложения;
- настройка одной рабочей секции без дубликатов;
- прямой маршрут YouTube в обход VPN;
- обработка YouTube-трафика локально через nftables/NFQUEUE;
- автозапуск и проверка процесса и nftables-цепочки.

## Что скрипт не делает

Router Provisioner запускается только после установки OpenWrt. Он не прошивает заводскую систему и не изменяет:

- U-Boot;
- MTD, UBI и внутреннюю GPT-разметку;
- `fw_env`;
- загрузчик;
- аппаратные Wi-Fi radio-секции;
- конфигурацию другого маршрутизатора.

Такие действия зависят от точной модели и аппаратной ревизии.

## Требования

| Компонент | Требование |
|---|---|
| OpenWrt | 24.10 или новее |
| Пользователь | `root` |
| Терминал | Интерактивный TTY |
| Менеджер пакетов | `apk` или `opkg` |
| Свободный overlay | Не менее 25 MiB |
| RAM | Минимум 64 MiB, рекомендуется 128 MiB и больше |
| Интернет | Доступен с самого роутера |
| VPN-подписка | Хотя бы одна рабочая VLESS XHTTP-нода |
| Wi-Fi | Ethernet при смене SSID или пароля |

NetShift находится в стадии beta. Поведение его внутренних файлов может измениться между релизами. Router Provisioner проверяет ожидаемую структуру перед применением совместимых патчей и прекращает установку при несовпадении.

## Быстрый старт

Одна команда скачивает актуальный скрипт и сразу запускает интерактивную установку:

```sh
cd /tmp && rm -f router-provisioner.sh && uclient-fetch -q -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh && chmod 700 router-provisioner.sh && ./router-provisioner.sh
```

Не добавляйте к этой команде `--diagnose`, `--dry-run` или `--version`, когда нужна именно установка.

## Диагностика и предварительный просмотр

Скачать скрипт без запуска установки:

```sh
cd /tmp && rm -f router-provisioner.sh && uclient-fetch -q -O router-provisioner.sh https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh && chmod 700 router-provisioner.sh
```

Только диагностика устройства:

```sh
/tmp/router-provisioner.sh --diagnose
```

Предварительный просмотр без сохранения конфигурации и установки пакетов:

```sh
/tmp/router-provisioner.sh --dry-run
```

Версия:

```sh
/tmp/router-provisioner.sh --version
```

Справка:

```sh
/tmp/router-provisioner.sh --help
```

## Этапы установки

1. Проверка OpenWrt, модели, архитектуры, RAM и overlay.
2. Формирование плана обновления OpenWrt без автоматической прошивки.
3. Создание резервной копии конфигурации.
4. Настройка root, hostname, Dropbear и Wi-Fi.
5. Установка или обновление NetShift.
6. Установка и проверка `sing-box extended`.
7. Установка и настройка youtubeUnblock.
8. Создание `youtube-direct.lst`.
9. Сохранение конфигурации `VPN` и `RU_DIRECT`.
10. Обновление списков и подписки.
11. Ожидание валидного XHTTP-only JSON, sing-box и FakeIP.
12. Проверка youtubeUnblock и вывод итогового состояния.

Скрипт не считает фиксированную задержку признаком готовности. Он опрашивает фактическое состояние с ограниченным тайм-аутом. Обычно NetShift поднимается быстрее, но при медленном роутере или сети проверка может занять до минуты. При первой неудаче выполняется один контролируемый перезапуск.

## Маршрутизация после установки

| Трафик | Маршрут |
|---|---|
| Локальная сеть и служебные подсети | Напрямую |
| Российские сервисы из `russia_outside` | Напрямую |
| Домены `.ru` и `.su` | Напрямую |
| YouTube и связанные домены | Напрямую через youtubeUnblock |
| Остальной внешний трафик | Через лучшую доступную XHTTP-ноду |
| TCP/Vision-ноды из подписки | Не допускаются |

## Безопасное обновление подписки

Не запускайте обычный `subscription_update` вручную. Используйте helper Router Provisioner:

```sh
/usr/bin/router-provisioner-netshift-refresh
```

Helper:

1. сохраняет текущий кеш подписки и рабочий JSON;
2. обновляет подписку;
3. ждёт завершения перезапуска NetShift;
4. проверяет XHTTP-only политику;
5. запускает `sing-box check`;
6. проверяет FakeIP через локальный DNS sing-box;
7. при ошибке восстанавливает предыдущий кеш и конфигурацию.

Планировщик использует тот же helper, поэтому автоматическое обновление не обходит проверки.

## Проверка после установки

Версия ядра sing-box:

```sh
/usr/bin/sing-box version
```

В первой строке должно присутствовать `extended`.

Полная проверка NetShift:

```sh
/usr/bin/netshift global_check
```

Процессы:

```sh
pgrep -af 'netshift|sing-box|youtubeUnblock'
```

Проверка итоговых VLESS-транспортов:

```sh
jq -r '.outbounds[]? | select(.type == "vless") | [.tag, (.transport.type // "none")] | @tsv' /etc/sing-box/config.json
```

У всех VLESS-нод транспорт должен быть `xhttp`.

Проверка JSON:

```sh
/usr/bin/sing-box check -c /etc/sing-box/config.json
```

Проверка FakeIP:

```sh
nslookup www.gstatic.com 127.0.0.42
```

Ожидается адрес из диапазона `198.18.0.0/15`.

Проверка youtubeUnblock:

```sh
/etc/init.d/youtubeUnblock status
```

Последние сообщения NetShift:

```sh
logread -e netshift | tail -n 100
```

Сообщения защищённого обновления:

```sh
logread -e router-provisioner-xhttp | tail -n 100
```

## Резервные копии и откат

Основной backup создаётся до системных изменений:

```text
/tmp/router-provisioner-YYYYMMDD-HHMMSS.tar.gz
```

Сохраните его вне `/tmp`, потому что этот каталог очищается после перезагрузки.

Перед изменением внутренних файлов NetShift скрипт также сохраняет исходные версии:

```text
/usr/lib/netshift/helpers.sh.before-router-provisioner
/usr/lib/netshift/sing_box_config_facade.sh.before-router-provisioner
```

При неудачном обновлении подписки helper автоматически возвращает предыдущий кеш. Если рабочей предыдущей конфигурации не было, новая невалидная подписка удаляется и NetShift не объявляется готовым.

## Безопасность SSH

- Dropbear не перезапускается во время основного сценария.
- Парольный вход отключается только после добавления корректного публичного ключа.
- Если ключ не указан, сохраняется парольный вход на LAN.
- `authorized_keys` создаётся с правами `0600`.
- После завершения скрипт предлагает вручную применить настройки и проверить новый сеанс, не закрывая текущий.

README намеренно не содержит готовых команд подключения и частных сетевых параметров. Используйте фактический адрес и порт своего роутера.

## Частые ошибки

### `No supported proxy outbounds remained in subscription JSON`

NetShift отфильтровал все ноды как несовместимые. Для этого проекта поддерживаются только VLESS XHTTP и `sing-box extended`. Router Provisioner проверяет extended по фактическому бинарнику `/usr/bin/sing-box` и исправляет определение в сервисном окружении NetShift.

### `Sing-box configuration ... is invalid. Aborted.`

Сформирован невалидный временный JSON. Защищённый helper ждёт завершения пересборки, запускает `sing-box check`, пишет точную причину в журнал и возвращает предыдущий кеш при неудаче.

### `Прокси-трафик не маршрутизируется через FakeIP`

Это не отдельная настройка, а признак того, что рабочий proxy outbound или DNS sing-box ещё не поднялся. Установка считается успешной только после ответа FakeIP из диапазона `198.18.0.0/15`.

### `Command failed: Not found` во время обновления подписки

NetShift может вернуть эту строку во время внутреннего restart/reload. Helper не принимает код возврата за окончательный результат: он проверяет фактический процесс, JSON и FakeIP. Если сервис не восстановился, выполняется один контролируемый перезапуск и откат.

### NetShift долго запускается

Во время первого запуска обновляются community-списки, загружается подписка, строится JSON, перезапускается sing-box и инициализируется FakeIP. Router Provisioner ограничивает ожидание и не запускает бесконечные recovery-циклы.

### После обновления NetShift пропала XHTTP-only защита

Обновление пакета может заменить внутренние файлы NetShift. Повторный запуск Router Provisioner или защищённого helper восстанавливает совместимые патчи идемпотентно.

### Недостаточно места в overlay

Удалите ненужные пакеты, используйте образ с большим rootfs или заранее подготовьте внешний раздел для extroot. Универсальная переразметка внутренней памяти не выполняется.

## Extroot

Extroot предлагается только при нехватке overlay и наличии подходящего внешнего раздела.

Защитные меры:

- исключаются root, overlay, boot и swap;
- показываются только допустимые кандидаты;
- требуется точная строка `ERASE /dev/...`;
- перед форматированием создаётся backup;
- отдельно подтверждается сохранение backup;
- форматируется только выбранный раздел;
- текущий overlay копируется на новый extroot;
- на x86 вместо extroot рекомендуется расширение root-раздела.

## Разработка

Клонирование и переход в каталог:

```bash
git clone https://github.com/anfixit/router-provisioner.git && cd router-provisioner
```

Проверка синтаксиса:

```bash
sh -n router-provisioner.sh && dash -n router-provisioner.sh && busybox ash -n router-provisioner.sh
```

Тесты:

```bash
dash tests/test_router_provisioner.sh && busybox ash tests/test_router_provisioner.sh
```

ShellCheck:

```bash
shellcheck -x router-provisioner.sh tests/*.sh
```

## Структура репозитория

```text
.github/                         GitHub Actions и шаблоны сообщества
router-provisioner.sh            основной runtime-скрипт
README.md                        пользовательская документация
CHANGELOG.md                     история изменений
CONTRIBUTING.md                  правила участия
SECURITY.md                      политика безопасности
CODE_OF_CONDUCT.md               кодекс поведения
LICENSE                          Apache License 2.0
VERSION                          текущая версия
tests/test_router_provisioner.sh POSIX shell-тесты
```

## Участие и безопасность

Перед pull request прочитайте [CONTRIBUTING.md](CONTRIBUTING.md). Не публикуйте в Issues ссылки подписок, UUID, токены, приватные ключи, пароли, `/etc/shadow` и полные backup-архивы.

Уязвимости сообщайте по инструкции из [SECURITY.md](SECURITY.md), а не через публичный Issue.

## Лицензия

Проект распространяется по [Apache License 2.0](LICENSE).

## Благодарности

- [OpenWrt](https://openwrt.org/)
- [NetShift](https://github.com/yandexru45/netshift)
- [sing-box](https://github.com/SagerNet/sing-box)
- [youtubeUnblock](https://github.com/Waujito/youtubeUnblock)
