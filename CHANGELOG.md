# Changelog

Все заметные изменения Router Provisioner документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии следуют [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

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

[Unreleased]: https://github.com/anfixit/router-provisioner/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/anfixit/router-provisioner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/anfixit/router-provisioner/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/anfixit/router-provisioner/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.1
[1.0.0]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.0
