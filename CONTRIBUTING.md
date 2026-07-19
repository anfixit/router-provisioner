# Вклад в Router Provisioner

Спасибо за интерес к проекту.

## Основные правила

- одно изменение должно решать одну понятную задачу;
- сохраняйте совместимость с POSIX shell и BusyBox `ash`;
- не используйте Bash-only синтаксис;
- не добавляйте зависимости, которых обычно нет в OpenWrt;
- опасные операции должны требовать явного подтверждения;
- изменения MTD, UBI, U-Boot и внутренней разметки допустимы только в отдельных профилях конкретных устройств;
- секреты, подписки, пароли и приватные ключи запрещено добавлять в репозиторий.

## Подготовка окружения

Клонируйте репозиторий:

```bash
git clone https://github.com/anfixit/router-provisioner.git && cd router-provisioner
```

Создайте ветку:

```bash
git switch -c feature/short-description
```

## Проверки

Синтаксис:

```bash
sh -n router-provisioner.sh
```

Тесты через `dash`:

```bash
dash tests/test_router_provisioner.sh
```

BusyBox `ash` через Docker:

```bash
docker run --rm -v "$PWD:/repo" -w /repo busybox:1.36 ash tests/test_router_provisioner.sh
```

ShellCheck:

```bash
shellcheck router-provisioner.sh tests/test_router_provisioner.sh
```

## Требования к pull request

В описании укажите:

- что изменено;
- зачем это требуется;
- модель роутера;
- аппаратную ревизию, если она важна;
- версию OpenWrt;
- способ проверки;
- возможные риски и способ восстановления.

Для исправления ошибки добавьте тест, который воспроизводит проблему до исправления и проходит после него.

## Стиль shell-кода

- используйте `#!/bin/sh`;
- заключайте подстановки переменных в двойные кавычки;
- проверяйте коды возврата;
- используйте понятные имена функций и переменных;
- не скрывайте критические ошибки через безусловный `|| true`;
- временные файлы удаляйте через `trap`;
- все изменения UCI завершайте явным `uci commit`;
- перед перезапуском сетевых служб предупреждайте о возможном разрыве SSH.

## Коммиты

Рекомендуемый формат:

```text
feat: add device capability check
fix: prevent SSH lockout
refactor: simplify NetShift configuration
test: cover low-overlay scenario
docs: clarify OpenWrt installation
```

## Лицензирование вклада

Отправляя вклад, вы соглашаетесь распространять его на условиях Apache License 2.0.