# Changelog

Все заметные изменения Router Provisioner документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), а версии следуют [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

### Added

- Полная пользовательская документация с разделением команд для macOS/Linux и OpenWrt.
- CONTRIBUTING, SECURITY, CODE_OF_CONDUCT и шаблоны GitHub.
- Явные инструкции по безопасной диагностике, dry-run, backup и проверке SSH.

## [1.0.1] - 2026-07-19

### Fixed

- Тесты больше не используют GNU-only параметр `find -maxdepth` и работают на macOS BSD `find`.
- Проверка секретоподобных файлов исключает `.venv`.

### Changed

- Добавлены исключения Python-кэшей и локального виртуального окружения в `.gitignore`.

## [1.0.0] - 2026-07-19

### Added

- Определение модели, `board_name`, target и версии OpenWrt.
- Формирование точной ссылки Firmware Selector.
- Проверка RAM и свободного места в overlay.
- Резервное копирование через `sysupgrade`.
- Интерактивная настройка root, hostname, Dropbear и Wi-Fi.
- Безопасный extroot для внешнего раздела.
- Установка и настройка NetShift.
- Скрытый ввод ссылки подписки и Wi-Fi-пароля.
- URLTest, автообновление подписки и прямой маршрут для российских сервисов.
- Диагностический и dry-run режимы.
- POSIX shell-тесты и GitHub Actions CI.

[Unreleased]: https://github.com/anfixit/router-provisioner/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.1
[1.0.0]: https://github.com/anfixit/router-provisioner/releases/tag/v1.0.0
