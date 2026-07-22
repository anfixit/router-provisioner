# Router Provisioner

Интерактивный POSIX shell-провижионер для уже установленного OpenWrt 24.10+.

Router Provisioner проверяет устройство и ресурсы, создаёт резервную копию, помогает настроить базовую безопасность, устанавливает NetShift и sing-box extended, подключает одну или несколько VPN-подписок и настраивает устойчивый запуск после перезагрузки.

## Что изменилось в версии 2.0

Предыдущая версия выросла в монолит более чем на 2200 строк и напрямую патчила внутренние файлы NetShift. Это усложняло аудит и делало поведение зависимым от конкретной версии NetShift.

Версия 2.0 разделена на модули:

```text
router-provisioner.sh  безопасный загрузчик
lib/common.sh          ввод, логирование и общие функции
lib/system.sh          диагностика и базовая настройка OpenWrt
lib/netshift.sh        NetShift, подписки, запуск и откат
lib/main.sh            порядок выполнения
```

Главное исправление: NetShift больше не запускается вслепую во время загрузки роутера. Поздний guard-сервис:

1. ждёт рабочий WAN и default route;
2. проверяет прямую загрузку `russia_outside.srs`;
3. запускает NetShift;
4. проверяет процесс sing-box, валидность JSON и FakeIP;
5. допускает только одну повторную попытку;
6. при повторной неудаче останавливает NetShift, возвращая обычные DNS и маршрутизацию.

Это защищает от цикла `russia_outside.srs: io: read/write on closed pipe`, который может возникать при старте NetShift до полной готовности WAN.

## Что делает скрипт

- определяет модель, board, target, архитектуру и версию OpenWrt;
- проверяет свободное место и RAM;
- создаёт backup через `sysupgrade -b`;
- по выбору меняет hostname и root-пароль;
- добавляет публичный SSH-ключ и ограничивает Dropbear интерфейсом LAN;
- по выбору меняет существующие Wi-Fi AP-секции;
- устанавливает NetShift официальным установщиком;
- устанавливает и проверяет sing-box extended;
- принимает несколько HTTPS-ссылок подписки;
- включает глобальный VPN и URLTest;
- направляет `russia_outside`, `.ru`, `.su` и локальную сеть напрямую;
- создаёт отдельный прямой список доменов YouTube;
- устанавливает безопасный helper обновления подписки с откатом;
- устанавливает поздний guard-сервис для холодного старта.

## Что скрипт не делает

Он не прошивает заводскую систему и не изменяет:

- U-Boot;
- MTD, UBI и внутреннюю GPT-разметку;
- загрузчик;
- `fw_env`;
- аппаратные radio-секции;
- конфигурацию другого маршрутизатора.

## Требования

| Компонент | Требование |
|---|---|
| OpenWrt | 24.10 или новее |
| Пользователь | root |
| Терминал | интерактивный SSH с TTY |
| Пакетный менеджер | apk или opkg |
| Свободный overlay | не менее 25 MiB |
| RAM | не менее 64 MiB |
| Интернет | рабочий WAN на самом роутере |
| Подписка | одна или несколько HTTPS-ссылок |

## Правильный запуск

Все команды выполняются на роутере от `root`.

Не запускайте интерактивный установщик через конвейер вида `curl | sh`. Конвейер забирает стандартный ввод, поэтому установщик не сможет читать ответы.

Скопируйте блок целиком:

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

Для проверки pull request можно указать ветку:

```sh
ROUTER_PROVISIONER_REF=agent/rebuild-provisioner-v2 \
    /tmp/router-provisioner.sh
```

## Режимы

```sh
/tmp/router-provisioner.sh --diagnose
/tmp/router-provisioner.sh --dry-run
/tmp/router-provisioner.sh --version
/tmp/router-provisioner.sh --help
```

`--yes` подтверждает обычные вопросы, но значения и секреты всё равно вводятся интерактивно.

## Холодный старт после reboot

Обычный автозапуск NetShift отключается. Вместо него включается:

```text
/etc/init.d/router-provisioner-netshift
```

Он имеет `START=99` и запускает:

```text
/usr/bin/router-provisioner-netshift-start
```

Проверить guard:

```sh
/etc/init.d/router-provisioner-netshift enabled && echo enabled
logread -e router-provisioner-boot
```

## Проверка после установки

```sh
netshift global_check
pgrep -af 'netshift|sing-box'
logread -e router-provisioner-boot
logread -e netshift -e sing-box | tail -n 100
```

Ожидается:

- sing-box process running;
- sing-box listening ports;
- DNS on router;
- FakeIP из диапазона `198.18.0.0/15`;
- активные NFT counters;
- отсутствие новых `FATAL`, `closed pipe` и crash loop.

## Безопасное обновление подписки

Не используйте обычный `netshift subscription_update` вручную. Запускайте:

```sh
/usr/bin/router-provisioner-netshift-refresh
```

Helper сохраняет текущий кеш подписок и рабочий JSON. Если после обновления не поднимаются sing-box и FakeIP, предыдущие файлы восстанавливаются.

Автоматическое обновление выполняется каждый час в 17 минут через root-crontab.

## Backup

Перед изменениями создаётся:

```text
/tmp/router-provisioner-YYYYMMDD-HHMMSS.tar.gz
```

Скопируйте архив на компьютер до перезагрузки. Каталог `/tmp` очищается при reboot.

## SSH

Dropbear намеренно не перезапускается автоматически.

После завершения:

1. не закрывайте текущую SSH-сессию;
2. вручную перезапустите Dropbear;
3. проверьте вход во втором терминале;
4. только после успешной проверки закройте старый терминал.

## Аварийное восстановление интернета

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

## Разработка

```sh
sh -n router-provisioner.sh lib/*.sh
dash -n router-provisioner.sh lib/*.sh
busybox ash -n router-provisioner.sh lib/*.sh
shellcheck -x router-provisioner.sh lib/*.sh tests/*.sh
dash tests/test_router_provisioner.sh
busybox ash tests/test_router_provisioner.sh
```

## Безопасность

Не публикуйте:

- ссылки подписок;
- UUID и токены;
- приватные ключи;
- пароли;
- `/etc/shadow`;
- полные backup-архивы.

Скрипт скрывает ввод подписок и не печатает их в dry-run.

## Лицензия

Apache License 2.0.
