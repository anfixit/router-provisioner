# Changelog

Все заметные изменения Router Provisioner документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии следуют [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

## [2.1.2] - 2026-07-30

### Fixed

- Аплинк определяется по фактическому default-маршруту, а не по интерфейсу с именем `wan`. Установка падала с «WAN не поднялся за 120 секунд» на Wi-Fi-клиенте, `wwan` и PPPoE, а guard-сервис останавливал NetShift после каждой перезагрузки.

### Added

- Строка `Аплинк:` в блоке диагностики — показывает устройство и имя интерфейса.
- Раздел README про ошибку «За 120 секунд не появился default-маршрут».

## [2.1.1] - 2026-07-29

### Fixed

- Загрузка файлов принудительно идёт по IPv4 с откатом на обычный вызов. На роутерах без рабочего IPv6-маршрута попытка по AAAA обрывалась с `Failed to send request: Operation not permitted` ещё до отправки запроса — падал и bootstrap-блок из README, и скачивание модулей внутри скрипта.

### Changed

- Быстрый старт в README сведён к одной команде вместо копирования многострочного блока.
- Добавлен раздел «Роутер не может скачать скрипт» с разбором трёх причин ошибки загрузки.

## [2.1.0] - 2026-07-29

### Added

- Возвращена установка и настройка youtubeUnblock (`lib/youtubeunblock.sh`), потерянная при переходе на 2.0.
- youtubeUnblock ставится последним релизом с GitHub по архитектуре роутера и формату пакета (`apk`/`ipk`), вместе с `luci-app-youtubeUnblock`.
- Общие helper-функции `github_latest_tag` и `github_asset_url` для работы с релизами GitHub.
- Тесты на выбор ассета по архитектуре, на сценарий обновления NetShift и на соответствие настроек референсу.

### Fixed

- NetShift больше не пропускается, если уже установлен: версия сравнивается с последним релизом, и при отставании запускается официальный установщик.
- Исправлено имя опции `netshift.VPN.subscription_insecure`; ранее записывалась несуществующая `subscription_allow_insecure`.
- Убрана несуществующая опция `netshift.settings.global_proxy` (`global_proxy` задаётся в секции, а не в `settings`).
- `VERSION` синхронизирован с версией в скриптах.

### Changed

- Настройки NetShift приведены к референсной конфигурации: DoH через `dns.adguard-dns.com`, `dns_rewrite_ttl`, `update_interval`, `log_level`, пути конфигурации и кеша.
- Удалён мёртвый код `install_boot_guard` и `install_refresh_helper` из `lib/netshift.sh`; lifecycle живёт только в `lib/lifecycle.sh` и `runtime/`.
- README переписан по структуре типового open-source проекта.

## [1.2.0] - 2026-07-21

### Fixed

- Исправлено ложное определение `sing-box extended` в сервисном окружении NetShift 0.9.6.
- Убрана преждевременная XHTTP-проверка через фиксированный `sleep 2`.
- Установка больше не запускает NetShift с пустым кешем подписки.
- Добавлено ограниченное ожидание процесса sing-box, валидного JSON и FakeIP.
- При невалидном временном JSON журнал получает фактический вывод `sing-box check`.
- Неудачное обновление подписки восстанавливает предыдущий кеш и конфигурацию.
- Перед настройкой youtubeUnblock удаляются дублирующиеся секции.

### Changed

- Обновление подписки выполняется через `/usr/bin/router-provisioner-netshift-refresh`.
- После первой неудачи допускается только один контролируемый перезапуск NetShift.
- Проверка одного цикла готовности ограничена 60 секундами вместо бесконечного recovery-цикла.
- README полностью переписан под фактический сценарий XHTTP-only, FakeIP и youtubeUnblock.

## [1.1.0] - 2026-07-19

### Added

- Автоматическая установка `sing-box extended`.
- Фильтрация подписки по фактическому VLESS-транспорту.
- Установка и настройка youtubeUnblock.
- Локальный список YouTube-доменов для прямой маршрутизации.
- Защищённый cron обновления подписки.

### Fixed

- Исправлен вывод LAN-адреса с CIDR.
- Исправлено создание root-crontab.
- Dry-run больше не сообщает о несуществующих изменениях.

## [1.0.2] - 2026-07-19

### Fixed

- Улучшен интерактивный ввод SSH-ключа.
- Добавлена повторная проверка Wi-Fi-пароля и шифрования.

## [1.0.1] - 2026-07-19

### Fixed

- Тесты совместимы с macOS BSD `find`.
- Проверка секретоподобных файлов исключает `.venv`.

### Changed

- Добавлены исключения Python-кэшей и локального окружения в `.gitignore`.

## [1.0.0] - 2026-07-19

### Added

- Определение модели, `board_name`, target и версии OpenWrt.
- Формирование ссылки Firmware Selector.
- Проверка RAM и overlay.
- Backup через `sysupgrade`.
- Настройка root, hostname, Dropbear и Wi-Fi.
- Безопасный extroot.
- Установка и настройка NetShift.
- Скрытый ввод подписки и Wi-Fi-пароля.
- URLTest, автообновление и прямой маршрут российских сервисов.
- Диагностический и dry-run режимы.
- POSIX shell-тесты и GitHub Actions CI.

[Unreleased]: https://github.com/anfixit/router-provisioner/compare/v2.1.2...HEAD
[2.1.2]: https://github.com/anfixit/router-provisioner/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/anfixit/router-provisioner/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/anfixit/router-provisioner/compare/v1.2.0...v2.1.0
[1.2.0]: https://github.com/anfixit/router-provisioner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/anfixit/router-provisioner/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/anfixit/router-provisioner/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.1
[1.0.0]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.0
