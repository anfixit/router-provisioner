#!/bin/sh
# Router Provisioner runtime entrypoint.

set -eu

RUNTIME_DIR=${ROUTER_PROVISIONER_RUNTIME_DIR:-}
[ -n "$RUNTIME_DIR" ] || {
    printf '[ERROR] Runtime directory is not set. Use router-provisioner.sh.\n' >&2
    exit 1
}

# shellcheck source=lib/common.sh
. "$RUNTIME_DIR/common.sh"
# shellcheck source=lib/system.sh
. "$RUNTIME_DIR/system.sh"
# shellcheck source=lib/netshift.sh
. "$RUNTIME_DIR/netshift.sh"
# shellcheck source=lib/youtubeunblock.sh
. "$RUNTIME_DIR/youtubeunblock.sh"
# shellcheck source=lib/adblock.sh
. "$RUNTIME_DIR/adblock.sh"
# shellcheck source=lib/lifecycle.sh
. "$RUNTIME_DIR/lifecycle.sh"

usage() {
    cat <<EOF_USAGE
Использование: $PROGRAM [--diagnose] [--dry-run] [--yes] [--version]

  --diagnose  Только диагностика устройства.
  --dry-run   Показать действия без изменения системы.
  --yes       Автоматически подтверждать обычные вопросы.
  --version   Показать версию.
  --help      Показать справку.
EOF_USAGE
}

print_final_report() {
    printf '\n=== Готово ===\n'
    [ -n "$CONFIG_BACKUP" ] && printf 'Backup: %s\n' "$CONFIG_BACKUP"

    if [ "$SUBSCRIPTION_COUNT" -eq 0 ]; then
        printf '\nПодписка не задана. NetShift настроен, но остановлен.\n'
        printf 'Добавьте ссылку: LuCI -> Services -> NetShift -> Секции -> VPN,\n'
        printf 'затем запустите этот скрипт повторно.\n\n'
    fi

    printf 'Проверка NetShift: netshift global_check\n'
    printf 'Проверка youtubeUnblock: %s status\n' "$YOUTUBEUNBLOCK_SERVICE"
    printf 'Журнал старта: logread -e router-provisioner-boot\n'
    printf 'Безопасное обновление: %s\n' "$REFRESH_HELPER"
    warn 'Dropbear не перезапущен. Проверьте новый вход во втором терминале.'
}

main() {
    parse_arguments "$@"
    require_environment

    TMP_DIR=$(mktemp -d "/tmp/${PROGRAM}.runtime.XXXXXX") || \
        fatal 'Не удалось создать временный каталог.'
    trap cleanup_runtime 0 HUP INT TERM

    printf '%s v%s\n' "$PROGRAM" "$VERSION"
    print_diagnostics

    [ "$DIAGNOSE_ONLY" -eq 1 ] && exit 0

    create_configuration_backup
    install_required_packages
    configure_identity
    configure_ssh
    configure_wifi
    install_netshift
    install_extended_sing_box
    configure_netshift
    install_youtubeunblock
    configure_youtubeunblock
    start_youtubeunblock
    configure_adblock
    install_lifecycle_helpers
    start_and_validate_netshift
    print_final_report
}

main "$@"
