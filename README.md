<div align="center">

# Router Provisioner

**Интерактивный POSIX shell-провижионер для OpenWrt 24.10+**

Ставит и настраивает NetShift, sing-box extended и youtubeUnblock одной командой —
с резервной копией, проверками и безопасным откатом.

[![CI](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml/badge.svg)](https://github.com/anfixit/router-provisioner/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%2B-00B5E2.svg)](https://openwrt.org/)
[![Shell: POSIX](https://img.shields.io/badge/shell-POSIX%20sh-89e051.svg)](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)

[Быстрый старт](#быстрый-старт) ·
[Что делает](#что-делает-скрипт) ·
[Конфигурация](#итоговая-конфигурация) ·
[Диагностика](#диагностика-и-восстановление) ·
[Разработка](#разработка)

</div>

> **English:** Router Provisioner is an interactive POSIX-shell provisioner for
> OpenWrt 24.10+. It installs the latest NetShift, sing-box extended and
> youtubeUnblock, wires up subscription-based proxying with a Russia-direct
> exclusion route, and installs a guarded boot service that fails open instead
> of leaving the router without DNS. Documentation is in Russian; the code and
> the audit notes in [`docs/AUDIT.md`](docs/AUDIT.md) are the reference.

---

## Содержание

- [Зачем это нужно](#зачем-это-нужно)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Режимы запуска](#режимы-запуска)
- [Что делает скрипт](#что-делает-скрипт)
- [Чего скрипт не делает](#чего-скрипт-не-делает)
- [Архитектура](#архитектура)
- [Итоговая конфигурация](#итоговая-конфигурация)
- [Холодный старт после reboot](#холодный-старт-после-reboot)
- [Обновление подписки](#обновление-подписки)
- [Диагностика и восстановление](#диагностика-и-восстановление)
- [Разработка](#разработка)
- [Безопасность](#безопасность)
- [Участие в проекте](#участие-в-проекте)
- [Лицензия](#лицензия)

---

## Зачем это нужно

Ручная настройка NetShift на OpenWrt — это десяток шагов, где легко ошибиться,
и один неудачный reboot, после которого роутер остаётся без DNS и без интернета.

Router Provisioner решает три задачи:

| Проблема | Решение |
|---|---|
| NetShift стартует раньше, чем поднялся WAN, и уходит в crash loop | Guard-сервис с `START=99`, преflight-проверками и fail-open остановкой |
| Обновление подписки ломает рабочую конфигурацию | Helper с бэкапом кеша и автоматическим откатом |
| YouTube не работает даже при рабочем прокси | youtubeUnblock на прямом маршруте + отдельный direct-список доменов |

## Требования

| Компонент | Требование |
|---|---|
| OpenWrt | 24.10 или новее |
| Пользователь | `root` |
| Терминал | интерактивный SSH с TTY |
| Пакетный менеджер | `apk` или `opkg` |
| Свободный overlay | не менее 25 MiB |
| RAM | не менее 64 MiB |
| Интернет | рабочий WAN на самом роутере |
| Подписка | одна или несколько HTTPS-ссылок |

## Быстрый старт

Все команды выполняются **на роутере** от `root`.

> [!IMPORTANT]
> Не запускайте установщик через `curl | sh`. Конвейер забирает стандартный
> ввод, и скрипт не сможет прочитать ваши ответы. Скачайте файл, потом запустите.

```sh
cd /tmp || exit 1
rm -f router-provisioner.sh

if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O router-provisioner.sh \
        https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh
elif command -v wget >/dev/null 2>&1; then
    wget -q -O router-provisioner.sh \
        https://raw.githubusercontent.com/anfixit/router-provisioner/main/router-provisioner.sh
else
    echo 'Не найден uclient-fetch или wget' >&2
    exit 1
fi

chmod 700 router-provisioner.sh
exec </dev/tty >/dev/tty 2>&1
./router-provisioner.sh
```

Сначала посмотрите, что произойдёт, ничего не меняя:

```sh
/tmp/router-provisioner.sh --dry-run
```

## Режимы запуска

| Флаг | Действие |
|---|---|
| `--diagnose` | Только диагностика устройства, без изменений |
| `--dry-run` | Показать все действия без изменения системы |
| `--yes` | Подтверждать обычные вопросы автоматически |
| `--version` | Показать версию |
| `--help` | Показать справку |

`--yes` подтверждает только да/нет-вопросы. Значения и секреты — ссылки подписок,
пароли, SSH-ключи — всегда вводятся интерактивно.

Для проверки pull request можно указать ветку:

```sh
ROUTER_PROVISIONER_REF=my-branch /tmp/router-provisioner.sh
```

## Что делает скрипт

**Диагностика**

- определяет модель, board, target, архитектуру и версию OpenWrt;
- проверяет свободный overlay и RAM;
- создаёт backup через `sysupgrade -b`.

**Базовая настройка (по выбору)**

- hostname и пароль `root`;
- публичный SSH-ключ, порт Dropbear и ограничение интерфейсом LAN;
- SSID и пароль существующих Wi-Fi AP-секций.

**NetShift**

- сравнивает установленную версию с последним релизом и обновляет при отставании;
- устанавливает и проверяет `sing-box extended`;
- принимает одну или несколько HTTPS-ссылок подписки;
- включает глобальный прокси и URLTest;
- направляет `russia_outside`, `.ru`, `.su` и локальную сеть напрямую.

**youtubeUnblock**

- ставит последний релиз под архитектуру роутера и формат пакета (`apk`/`ipk`);
- ставит `luci-app-youtubeUnblock` и модули ядра для nfqueue;
- настраивает DPI-обход для YouTube и доменов Google;
- создаёт прямой список YouTube-доменов, исключённый из прокси.

**Устойчивость**

- отключает штатный автозапуск NetShift и ставит guard-сервис;
- ставит helper обновления подписки с откатом и cron-задание.

## Чего скрипт не делает

Он не прошивает заводскую систему и не изменяет:

- U-Boot и загрузчик;
- MTD, UBI и внутреннюю GPT-разметку;
- `fw_env`;
- аппаратные radio-секции;
- конфигурацию другого маршрутизатора.

## Архитектура

```text
router-provisioner.sh      безопасный загрузчик, скачивает модули по версии
├── lib/common.sh          ввод, логирование, GitHub-релизы, общие функции
├── lib/system.sh          диагностика и базовая настройка OpenWrt
├── lib/netshift.sh        NetShift, подписки, маршрутизация
├── lib/youtubeunblock.sh  youtubeUnblock: установка и настройка
├── lib/lifecycle.sh       guard-сервис и helper обновления
├── lib/main.sh            порядок выполнения
└── runtime/               helper-скрипты, устанавливаемые на роутер
```

Загрузчик скачивает модули во временный каталог и запускает их через `exec`,
не расходуя стандартный ввод. Это позволяет обновлять логику независимо от
уже скачанного `router-provisioner.sh`.

Разбор инцидента, из-за которого появился guard-сервис, — в
[`docs/AUDIT.md`](docs/AUDIT.md).

## Итоговая конфигурация

### NetShift

| Параметр | Значение |
|---|---|
| DNS | DoH через `dns.adguard-dns.com` |
| Bootstrap DNS | `77.88.8.8` |
| Источник трафика | `br-lan` |
| IPv6 | выключен |
| Обновление списков | раз в сутки |
| Уровень журнала | `warn` |

Секция `VPN` — прокси по подписке, формат `xray`, URLTest каждые 3 минуты по
`https://www.gstatic.com/generate_204`, глобальный прокси включён.

Секция `RU_DIRECT` — исключение из прокси: список `russia_outside`, домены `.ru`
и `.su`, и локальный список YouTube-доменов
`/etc/netshift/rulesets/youtube-direct.lst`.

> [!NOTE]
> Штатное автообновление подписки NetShift выключено намеренно
> (`subscription_update_interval=disabled`). Его заменяет
> `router-provisioner-netshift-refresh`, который умеет откатываться. Оба
> механизма одновременно конфликтовали бы за один и тот же кеш.

### youtubeUnblock

| Параметр | Значение |
|---|---|
| nfqueue | `537` |
| Packet mark | `32768` |
| Стратегия | `pastseq`, фрагментация TCP, `sni_detection=parse` |
| QUIC | `udp_mode=drop`, `udp_filter_quic=parse` |

Обрабатываемые SNI: `googlevideo.com`, `ggpht.com`, `ytimg.com`, `youtube.com`,
`play.google.com`, `youtu.be`, `googleapis.com`, `googleusercontent.com`,
`gstatic.com`, `l.google.com`.

YouTube идёт **мимо прокси**, а youtubeUnblock чинит TLS-handshake на прямом
маршруте. Поэтому direct-список доменов и список SNI должны совпадать.

## Холодный старт после reboot

Обычный автозапуск NetShift отключается. Вместо него включается
`/etc/init.d/router-provisioner-netshift` с `START=99`, который запускает
`/usr/bin/router-provisioner-netshift-start`:

1. ждёт рабочий WAN и default route (до 120 секунд);
2. проверяет прямую загрузку `russia_outside.srs`;
3. обновляет списки при остановленном NetShift;
4. запускает NetShift;
5. проверяет процесс sing-box, валидность JSON и FakeIP;
6. допускает ровно одну повторную попытку;
7. при повторной неудаче **останавливает NetShift**, возвращая обычные DNS и
   маршрутизацию.

Последний шаг важен: лучше роутер без прокси, чем роутер без интернета.

Проверить guard:

```sh
/etc/init.d/router-provisioner-netshift enabled && echo enabled
logread -e router-provisioner-boot
```

## Обновление подписки

> [!WARNING]
> Не запускайте `netshift subscription_update` вручную — при неудаче он оставит
> нерабочую конфигурацию.

```sh
/usr/bin/router-provisioner-netshift-refresh
```

Helper сохраняет текущий кеш подписок и рабочий `config.json`. Если после
обновления sing-box и FakeIP не поднимаются, предыдущие файлы восстанавливаются.

Автоматически запускается каждый час в 17 минут через root-crontab.

## Диагностика и восстановление

### Проверка после установки

```sh
netshift global_check
/etc/init.d/youtubeUnblock status
pgrep -af 'netshift|sing-box|youtubeUnblock'
logread -e router-provisioner-boot
```

Ожидается:

- процесс sing-box запущен и слушает порты;
- DNS отвечает на роутере;
- FakeIP из диапазона `198.18.0.0/15`;
- активные NFT counters;
- отсутствие новых `FATAL`, `closed pipe` и crash loop.

### Аварийное восстановление интернета

```sh
/etc/init.d/router-provisioner-netshift stop
/etc/init.d/netshift stop
/etc/init.d/dnsmasq restart
```

Затем проверьте:

```sh
ubus call network.interface.wan status
ip route show default
nslookup openwrt.org
```

### Частые проблемы

<details>
<summary><b>Официальный установщик NetShift задаёт вопросы</b></summary>

Так и должно быть. Он предложит удалить конфликтующий `https-dns-proxy` и,
для версий ниже 0.8.0, сбросить конфигурацию. Отвечайте осознанно: при отказе
от удаления `https-dns-proxy` установщик завершится с ошибкой.

</details>

<details>
<summary><b>Нет сборки youtubeUnblock для моей архитектуры</b></summary>

Скрипт подбирает ассет по `DISTRIB_ARCH` из `/etc/openwrt_release`. Проверьте,
что для вашей архитектуры есть файл в
[релизах youtubeUnblock](https://github.com/Waujito/youtubeUnblock/releases).
Для экзотических платформ есть только static-сборки, которые ставятся вручную.

</details>

<details>
<summary><b>После установки пропал доступ по SSH</b></summary>

Dropbear намеренно **не перезапускается** автоматически. Не закрывайте текущую
сессию: перезапустите Dropbear вручную, проверьте вход во втором терминале и
только после успешной проверки закройте старый терминал.

</details>

<details>
<summary><b>Backup исчез после перезагрузки</b></summary>

Backup создаётся в `/tmp/router-provisioner-YYYYMMDD-HHMMSS.tar.gz`, а `/tmp`
на OpenWrt — это tmpfs. Копируйте архив на компьютер сразу, до reboot.

</details>

## Разработка

```sh
sh -n router-provisioner.sh lib/*.sh runtime/*
dash -n router-provisioner.sh lib/*.sh runtime/*
busybox ash -n router-provisioner.sh lib/*.sh runtime/*
shellcheck -x -e SC1090,SC2034,SC2317,SC2329 \
    router-provisioner.sh lib/*.sh runtime/* tests/*.sh
dash tests/test_router_provisioner.sh
busybox ash tests/test_router_provisioner.sh
```

Тот же набор проверок выполняет CI на каждый push и pull request.

Код на POSIX `sh`: без bash-измов, с проверкой в `dash` и BusyBox `ash`, потому
что на роутере выполняется именно BusyBox.

## Безопасность

Никогда не публикуйте:

- ссылки подписок, UUID и токены;
- приватные ключи и пароли;
- `/etc/shadow`;
- полные backup-архивы — в них есть учётные данные PPPoE и Wi-Fi.

Скрипт скрывает ввод подписок и паролей и не печатает их в `--dry-run`. В CI
работает регрессионный поиск секретов.

Об уязвимостях — [`SECURITY.md`](SECURITY.md).

## Участие в проекте

Pull request'ы приветствуются. Перед отправкой прочитайте
[`CONTRIBUTING.md`](CONTRIBUTING.md) и убедитесь, что локальные проверки
проходят. Правила общения — [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

История изменений — [`CHANGELOG.md`](CHANGELOG.md).

## Благодарности

- [NetShift](https://github.com/yandexru45/netshift) — маршрутизация и sing-box
- [youtubeUnblock](https://github.com/Waujito/youtubeUnblock) — DPI-обход
- [allow-domains](https://github.com/itdoginfo/allow-domains) — списки доменов

## Лицензия

[Apache License 2.0](LICENSE).
