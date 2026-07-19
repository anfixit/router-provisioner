#!/bin/sh
# Interactive OpenWrt and NetShift provisioner for BusyBox ash.

set -u

PROGRAM_NAME='router-provisioner'
PROGRAM_VERSION='1.1.0'
MIN_OPENWRT_VERSION='24.10.0'
MIN_OVERLAY_FREE_KIB=25600
MIN_RAM_KIB=65536
RECOMMENDED_RAM_KIB=131072
OPENWRT_FALLBACK_VERSION='25.12.5'
OPENWRT_VERSIONS_URL='https://downloads.openwrt.org/.versions.json'
FIRMWARE_SELECTOR_URL='https://firmware-selector.openwrt.org'
NETSHIFT_REPOSITORY='https://github.com/yandexru45/netshift'
NETSHIFT_INSTALLER_URL='https://raw.githubusercontent.com/'\
'yandexru45/netshift/refs/heads/main/install.sh'
YOUTUBE_UNBLOCK_REPOSITORY='https://github.com/Waujito/youtubeUnblock'
YOUTUBE_UNBLOCK_RELEASE_TAG='v1.3.1'
YOUTUBE_UNBLOCK_RELEASE_COMMIT='4a223b0'
YOUTUBE_UNBLOCK_RELEASE_API='https://api.github.com/repos/'\
'Waujito/youtubeUnblock/releases/tags/v1.3.1'
YOUTUBE_DIRECT_LIST='/etc/netshift/rulesets/youtube-direct.lst'
NETSHIFT_FACADE='/usr/lib/netshift/sing_box_config_facade.sh'
NETSHIFT_REFRESH_HELPER='/usr/bin/router-provisioner-netshift-refresh'

DRY_RUN=0
DIAGNOSE_ONLY=0
ASSUME_YES=0
ROOT_PREFIX=${ROUTER_PROVISIONER_ROOT_PREFIX:-}
TMP_DIR=''
BOARD_JSON=''
OPENWRT_VERSION=''
OPENWRT_TARGET=''
OPENWRT_ARCH=''
BOARD_NAME=''
MODEL=''
PACKAGE_MANAGER='none'
OVERLAY_MOUNT='/'
OVERLAY_FREE_KIB=0
OVERLAY_TOTAL_KIB=0
RAM_TOTAL_KIB=0
RAM_AVAILABLE_KIB=0
ROOTFS_TYPE='unknown'
BACKUP_FILE=''
ROOT_PASSWORD_AVAILABLE=0

print_line() {
    printf '%s\n' "$*"
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fatal() {
    error "$*"
    exit 1
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup 0 HUP INT TERM

root_path() {
    printf '%s%s\n' "$ROOT_PREFIX" "$1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN]'
        for argument in "$@"; do
            printf ' %s' "$argument"
        done
        printf '\n'
        return 0
    fi

    "$@"
}

must_run() {
    command_name=$1

    if ! run "$@"; then
        fatal "Ошибка команды: $command_name"
    fi
}

run_redacted() {
    redacted=$1
    shift

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN] %s\n' "$redacted"
        return 0
    fi

    "$@"
}

ask_yes_no() {
    prompt=$1
    default=${2:-no}

    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi

    while :; do
        if [ "$default" = 'yes' ]; then
            printf '%s [Y/n]: ' "$prompt"
        else
            printf '%s [y/N]: ' "$prompt"
        fi

        IFS= read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            '')
                [ "$default" = 'yes' ]
                return
                ;;
            *)
                warn 'Введите y или n.'
                ;;
        esac
    done
}

ask_value() {
    prompt=$1
    default=${2:-}

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi

    IFS= read -r answer || return 1
    if [ -z "$answer" ]; then
        answer=$default
    fi
    printf '%s\n' "$answer"
}

ask_secret() {
    prompt=$1
    secret=''

    printf '%s: ' "$prompt" >&2
    if [ -t 0 ] && command_exists stty; then
        stty -echo
        IFS= read -r secret || {
            stty echo
            printf '\n' >&2
            return 1
        }
        stty echo
        printf '\n' >&2
    else
        IFS= read -r secret || return 1
    fi

    printf '%s\n' "$secret"
}

require_root() {
    if [ "$(id -u 2>/dev/null || printf '1')" -ne 0 ]; then
        fatal 'Запустите скрипт от root.'
    fi
}

require_interactive_terminal() {
    if [ "$DIAGNOSE_ONLY" -eq 0 ] && [ ! -t 0 ]; then
        fatal 'Нужен интерактивный SSH-сеанс с TTY.'
    fi
}

parse_release_value() {
    key=$1
    release_file=$(root_path '/etc/openwrt_release')

    [ -r "$release_file" ] || return 1

    sed -n "s/^${key}=['\"]\{0,1\}\([^'\"]*\).*/\1/p" \
        "$release_file" | head -n 1
}

read_board_json() {
    if command_exists ubus; then
        BOARD_JSON=$(ubus call system board 2>/dev/null || true)
    else
        BOARD_JSON=''
    fi
}

json_value() {
    expression=$1

    [ -n "$BOARD_JSON" ] || return 1

    if command_exists jsonfilter; then
        printf '%s' "$BOARD_JSON" | jsonfilter -e "$expression" \
            2>/dev/null
        return
    fi

    key=$(printf '%s' "$expression" | sed 's/^@\.//')
    printf '%s' "$BOARD_JSON" | tr -d '\n' | sed -n \
        "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

profile_from_board_name() {
    printf '%s' "$1" | tr ',' '_'
}

encode_target() {
    printf '%s' "$1" | sed 's,/,\%2F,g'
}

strip_cidr() {
    printf '%s\n' "${1%%/*}"
}

version_ge() {
    first=$1
    second=$2

    awk -v first="$first" -v second="$second" '
        function number(value) {
            sub(/[^0-9].*$/, "", value)
            return value == "" ? 0 : value + 0
        }
        BEGIN {
            count_a = split(first, a, ".")
            count_b = split(second, b, ".")
            count = count_a > count_b ? count_a : count_b
            for (part = 1; part <= count; part++) {
                left = number(a[part])
                right = number(b[part])
                if (left > right) {
                    exit 0
                }
                if (left < right) {
                    exit 1
                }
            }
            exit 0
        }
    '
}

fetch_to_file() {
    url=$1
    destination=$2

    if command_exists uclient-fetch; then
        uclient-fetch -q -O "$destination" "$url"
    elif command_exists wget; then
        wget -q -O "$destination" "$url"
    elif command_exists curl; then
        curl -fsSL "$url" -o "$destination"
    else
        return 127
    fi
}

get_latest_openwrt_version() {
    versions_file="$TMP_DIR/openwrt-versions.json"

    if fetch_to_file \
        "$OPENWRT_VERSIONS_URL" "$versions_file" 2>/dev/null; then
        version=$(sed -n \
            's/.*"stable_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$versions_file" | head -n 1)
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    warn "Актуальный релиз не определён, используется резервный."
    printf '%s\n' "$OPENWRT_FALLBACK_VERSION"
}

read_meminfo_value() {
    key=$1
    meminfo=$(root_path '/proc/meminfo')

    [ -r "$meminfo" ] || {
        printf '0\n'
        return
    }

    awk -v key="$key" '$1 == key ":" {print $2; exit}' "$meminfo"
}

detect_overlay_mount() {
    overlay_path=$(root_path '/overlay')

    if [ -d "$overlay_path" ] && \
        df -Pk "$overlay_path" >/dev/null 2>&1; then
        OVERLAY_MOUNT=$overlay_path
    else
        OVERLAY_MOUNT=$(root_path '/')
    fi
}

read_disk_value() {
    field=$1

    df -Pk "$OVERLAY_MOUNT" 2>/dev/null | awk \
        -v field="$field" 'NR == 2 {print $field; exit}'
}

detect_rootfs_type() {
    mounts=$(root_path '/proc/mounts')

    if [ -r "$mounts" ]; then
        root_type=$(awk '$2 == "/" {print $3; exit}' "$mounts")
        overlay_type=$(awk '$2 == "/overlay" {print $3; exit}' \
            "$mounts")
        if [ -n "$overlay_type" ]; then
            ROOTFS_TYPE=$overlay_type
        elif [ -n "$root_type" ]; then
            ROOTFS_TYPE=$root_type
        fi
    fi
}

detect_package_manager() {
    if command_exists apk; then
        PACKAGE_MANAGER='apk'
    elif command_exists opkg; then
        PACKAGE_MANAGER='opkg'
    else
        PACKAGE_MANAGER='none'
    fi
}

detect_system() {
    release_file=$(root_path '/etc/openwrt_release')

    read_board_json
    OPENWRT_VERSION=$(parse_release_value DISTRIB_RELEASE \
        2>/dev/null || true)
    OPENWRT_TARGET=$(parse_release_value DISTRIB_TARGET \
        2>/dev/null || true)
    OPENWRT_ARCH=$(parse_release_value DISTRIB_ARCH \
        2>/dev/null || true)
    BOARD_NAME=$(json_value '@.board_name' 2>/dev/null || true)
    MODEL=$(json_value '@.model' 2>/dev/null || true)

    if [ -z "$BOARD_NAME" ]; then
        board_file=$(root_path '/tmp/sysinfo/board_name')
        [ -r "$board_file" ] && BOARD_NAME=$(cat "$board_file")
    fi
    if [ -z "$MODEL" ]; then
        model_file=$(root_path '/tmp/sysinfo/model')
        [ -r "$model_file" ] && MODEL=$(cat "$model_file")
    fi

    detect_package_manager
    detect_overlay_mount
    OVERLAY_TOTAL_KIB=$(read_disk_value 2)
    OVERLAY_FREE_KIB=$(read_disk_value 4)
    OVERLAY_TOTAL_KIB=${OVERLAY_TOTAL_KIB:-0}
    OVERLAY_FREE_KIB=${OVERLAY_FREE_KIB:-0}
    RAM_TOTAL_KIB=$(read_meminfo_value MemTotal)
    RAM_AVAILABLE_KIB=$(read_meminfo_value MemAvailable)
    RAM_TOTAL_KIB=${RAM_TOTAL_KIB:-0}
    RAM_AVAILABLE_KIB=${RAM_AVAILABLE_KIB:-0}
    detect_rootfs_type

    if [ ! -r "$release_file" ] && [ -z "$OPENWRT_VERSION" ]; then
        warn 'Установленный OpenWrt не обнаружен.'
    fi
}

kib_to_mib() {
    awk -v value="$1" 'BEGIN {printf "%.1f", value / 1024}'
}

print_diagnostics() {
    profile=$(profile_from_board_name "$BOARD_NAME")

    print_line
    print_line '=== Диагностика устройства ==='
    printf 'Модель:                 %s\n' \
        "${MODEL:-не определена}"
    printf 'Board name:             %s\n' \
        "${BOARD_NAME:-не определён}"
    printf 'OpenWrt:                %s\n' \
        "${OPENWRT_VERSION:-не определён}"
    printf 'Target:                 %s\n' \
        "${OPENWRT_TARGET:-не определён}"
    printf 'Architecture:           %s\n' \
        "${OPENWRT_ARCH:-не определена}"
    printf 'Firmware profile:       %s\n' \
        "${profile:-не определён}"
    printf 'Менеджер пакетов:       %s\n' "$PACKAGE_MANAGER"
    printf 'Тип root/overlay:       %s\n' "$ROOTFS_TYPE"
    printf 'Overlay всего:          %s MiB\n' \
        "$(kib_to_mib "$OVERLAY_TOTAL_KIB")"
    printf 'Overlay свободно:       %s MiB\n' \
        "$(kib_to_mib "$OVERLAY_FREE_KIB")"
    printf 'RAM всего:              %s MiB\n' \
        "$(kib_to_mib "$RAM_TOTAL_KIB")"
    printf 'RAM доступно сейчас:    %s MiB\n' \
        "$(kib_to_mib "$RAM_AVAILABLE_KIB")"
}

firmware_profile_exists() {
    version=$1
    target=$2
    profile=$3
    profiles_file="$TMP_DIR/firmware-profiles.json"
    profiles_url='https://downloads.openwrt.org/releases'
    profiles_url="${profiles_url}/${version}/targets"
    profiles_url="${profiles_url}/${target}/profiles.json"

    fetch_to_file "$profiles_url" "$profiles_file" 2>/dev/null || \
        return 1
    grep -F "\"$profile\"" "$profiles_file" >/dev/null 2>&1
}

print_firmware_plan() {
    latest_version=$1
    profile=$(profile_from_board_name "$BOARD_NAME")
    encoded_target=$(encode_target "$OPENWRT_TARGET")

    print_line
    print_line '=== План OpenWrt ==='

    if [ -z "$OPENWRT_VERSION" ]; then
        warn 'Для заводской прошивки универсальная автопрошивка запрещена.'
        warn 'Нужны точная модель, аппаратная ревизия и инструкция OpenWrt.'
        print_line 'Firmware Selector:'
        print_line "$FIRMWARE_SELECTOR_URL"
        return 1
    fi

    if [ -z "$BOARD_NAME" ] || [ -z "$OPENWRT_TARGET" ]; then
        warn 'Не удалось построить точную ссылку без board_name и target.'
        return 1
    fi

    selector_url="${FIRMWARE_SELECTOR_URL}/?version=${latest_version}"
    selector_url="${selector_url}&target=${encoded_target}&id=${profile}"

    printf 'Стабильный релиз: %s\n' "$latest_version"
    printf 'Точная страница образа:\n%s\n' "$selector_url"

    if firmware_profile_exists \
        "$latest_version" "$OPENWRT_TARGET" "$profile"; then
        info 'Профиль найден в официальном каталоге OpenWrt.'
    else
        warn 'Профиль не подтверждён через официальный profiles.json.'
        warn 'Не прошивайте устройство до ручной проверки модели.'
    fi

    if version_ge "$OPENWRT_VERSION" "$MIN_OPENWRT_VERSION"; then
        print_line
        print_line 'Безопасное обновление установленного OpenWrt:'
        case "$PACKAGE_MANAGER" in
            apk)
                print_line '  apk -U add owut'
                ;;
            opkg)
                print_line '  opkg update && opkg install owut'
                ;;
            *)
                warn 'Менеджер пакетов не найден.'
                return 0
                ;;
        esac
        printf '  owut check -V %s\n' "$latest_version"
        printf '  owut upgrade -V %s\n' "$latest_version"
        warn 'Перед обновлением выгрузите резервную копию.'
    else
        warn "NetShift требует OpenWrt от $MIN_OPENWRT_VERSION."
        warn 'Сначала обновите OpenWrt и запустите скрипт повторно.'
    fi
}

check_resources() {
    result=0

    print_line
    print_line '=== Проверка ресурсов ==='

    if [ "$OVERLAY_FREE_KIB" -lt "$MIN_OVERLAY_FREE_KIB" ]; then
        required_mib=$(kib_to_mib "$MIN_OVERLAY_FREE_KIB")
        error "Нужно не менее $required_mib MiB свободного overlay."
        result=1
    else
        info 'Места достаточно для NetShift.'
    fi

    if [ "$RAM_TOTAL_KIB" -gt 0 ] && \
        [ "$RAM_TOTAL_KIB" -lt "$MIN_RAM_KIB" ]; then
        error 'RAM меньше 64 MiB. Установка остановлена.'
        result=1
    elif [ "$RAM_TOTAL_KIB" -gt 0 ] && \
        [ "$RAM_TOTAL_KIB" -lt "$RECOMMENDED_RAM_KIB" ]; then
        warn 'RAM меньше 128 MiB. Возможны OOM и нестабильность.'
    else
        info 'Объём RAM приемлем.'
    fi

    return "$result"
}

device_is_critical() {
    device=$1
    mounts_file=$(root_path '/proc/mounts')
    swaps_file=$(root_path '/proc/swaps')

    if [ -r "$mounts_file" ]; then
        if awk -v device="$device" '
            $1 == device &&
            ($2 == "/" || $2 == "/rom" || $2 == "/overlay" ||
             $2 == "/boot" || $2 == "/boot/efi") {
                found = 1
            }
            END {exit found ? 0 : 1}
        ' "$mounts_file"; then
            return 0
        fi
    fi

    if [ -r "$swaps_file" ]; then
        if awk -v device="$device" '
            NR > 1 && $1 == device {found = 1}
            END {exit found ? 0 : 1}
        ' "$swaps_file"; then
            return 0
        fi
    fi

    return 1
}

device_size_mib() {
    device=$1
    device_name=$(basename "$device")
    sectors_file="/sys/class/block/${device_name}/size"

    if [ ! -r "$sectors_file" ]; then
        printf '?\n'
        return
    fi

    sectors=$(cat "$sectors_file")
    awk -v sectors="$sectors" '
        BEGIN {printf "%.1f", sectors * 512 / 1024 / 1024}
    '
}

list_extroot_candidates() {
    for device in \
        /dev/sd[a-z][0-9]* \
        /dev/mmcblk[1-9]p[0-9]* \
        /dev/nvme[0-9]n[0-9]p[0-9]*; do
        [ -b "$device" ] || continue
        device_is_critical "$device" && continue
        printf '%s\n' "$device"
    done
}

print_extroot_candidates() {
    candidates_file=$1

    print_line 'Доступные разделы для extroot:'
    while IFS= read -r device; do
        size=$(device_size_mib "$device")
        metadata=''
        if command_exists block; then
            metadata=$(block info "$device" 2>/dev/null || true)
        fi
        printf '  %s, %s MiB\n' "$device" "$size"
        [ -n "$metadata" ] && printf '    %s\n' "$metadata"
    done < "$candidates_file"
}

install_extroot_dependencies() {
    if command_exists block && command_exists mkfs.ext4; then
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apk)
            must_run apk update
            must_run apk add block-mount kmod-fs-ext4
            must_run apk add e2fsprogs kmod-usb-storage
            ;;
        opkg)
            must_run opkg update
            must_run opkg install block-mount kmod-fs-ext4
            must_run opkg install e2fsprogs kmod-usb-storage
            ;;
        *)
            fatal 'Для extroot нужен apk или opkg.'
            ;;
    esac

    command_exists block || fatal 'Команда block не найдена.'
    command_exists mkfs.ext4 || fatal 'Команда mkfs.ext4 не найдена.'
}

copy_overlay_to_extroot() {
    device=$1
    mount_dir='/tmp/router-provisioner-extroot'

    rm -rf "$mount_dir"
    mkdir -p "$mount_dir"
    must_run mount "$device" "$mount_dir"

    if ! tar -C /overlay -cf - . | tar -C "$mount_dir" -xf -; then
        umount "$mount_dir" >/dev/null 2>&1 || true
        fatal 'Не удалось скопировать overlay.'
    fi

    sync
    must_run umount "$mount_dir"
    rmdir "$mount_dir" 2>/dev/null || true
}

configure_extroot_fstab() {
    device=$1
    uuid=$(block info "$device" 2>/dev/null | sed -n \
        's/.*UUID="\([^"]*\)".*/\1/p' | head -n 1)

    [ -n "$uuid" ] || fatal 'UUID extroot не определён.'

    timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown')
    if [ -f /etc/config/fstab ]; then
        cp /etc/config/fstab \
            "/etc/config/fstab.before-extroot-${timestamp}"
    fi

    run uci -q delete fstab.extroot
    must_run uci set 'fstab.extroot=mount'
    must_run uci set "fstab.extroot.uuid=$uuid"
    must_run uci set 'fstab.extroot.target=/overlay'
    must_run uci set 'fstab.extroot.enabled=1'
    must_run uci set 'fstab.extroot.enabled_fsck=0'
    must_run uci commit fstab

    if [ -x /etc/init.d/fstab ]; then
        /etc/init.d/fstab enable || \
            warn 'Не удалось включить fstab service.'
    fi
}

configure_extroot_interactively() {
    if [ "$OPENWRT_TARGET" != "${OPENWRT_TARGET#x86/}" ]; then
        warn 'Для x86 используйте расширение root-раздела OpenWrt.'
        return 1
    fi
    if [ ! -d /overlay ]; then
        warn 'Каталог /overlay не найден. Extroot неприменим.'
        return 1
    fi

    candidates_file="$TMP_DIR/extroot-candidates"
    list_extroot_candidates > "$candidates_file"
    if [ ! -s "$candidates_file" ]; then
        warn 'Подходящий внешний раздел не найден.'
        return 1
    fi

    print_extroot_candidates "$candidates_file"
    device=$(ask_value 'Путь готового раздела' '')
    if ! grep -Fx "$device" "$candidates_file" >/dev/null 2>&1; then
        warn 'Раздел не входит в список безопасных кандидатов.'
        return 1
    fi

    print_line
    warn "ВСЕ ДАННЫЕ НА $device БУДУТ УДАЛЕНЫ."
    expected="ERASE $device"
    printf 'Для подтверждения введите: %s\n' "$expected"
    confirmation=$(ask_value 'Подтверждение' '')
    if [ "$confirmation" != "$expected" ]; then
        warn 'Подтверждение не совпало.'
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: раздел $device не форматировался."
        return 1
    fi

    if ! create_backup; then
        fatal 'Перед extroot не удалось создать резервную копию.'
    fi
    if ! ask_yes_no 'Копия уже сохранена на компьютере?' 'no'; then
        warn 'Extroot отменён.'
        return 1
    fi

    install_extroot_dependencies

    if awk -v device="$device" '
        $1 == device {found = 1}
        END {exit found ? 0 : 1}
    ' /proc/mounts; then
        must_run umount "$device"
    fi

    must_run mkfs.ext4 -F -L extroot "$device"
    copy_overlay_to_extroot "$device"
    configure_extroot_fstab "$device"

    info 'Extroot настроен. После перезагрузки запустите скрипт снова.'
    if ask_yes_no 'Перезагрузить сейчас?' 'yes'; then
        reboot
    fi
    return 0
}

print_storage_options() {
    print_line
    print_line '=== Варианты увеличения хранилища ==='

    case "$OPENWRT_TARGET" in
        x86/*)
            print_line '1. На x86 расширьте root-раздел по инструкции OpenWrt.'
            ;;
        *)
            print_line '1. Внутренняя разметка зависит от модели роутера.'
            ;;
    esac

    candidates_file="$TMP_DIR/extroot-candidates"
    list_extroot_candidates > "$candidates_file"
    if [ -s "$candidates_file" ]; then
        print_line '2. Найден внешний раздел для безопасного extroot.'
    else
        print_line '2. Подключите USB, SD, SATA или NVMe для extroot.'
    fi

    warn 'MTD, UBI, GPT, fw_env и U-Boot автоматически не меняются.'
    warn 'Для внутренней переразметки нужен профиль конкретной модели.'
}

create_backup() {
    timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown')
    planned_backup="/tmp/${PROGRAM_NAME}-${timestamp}.tar.gz"

    print_line
    print_line '=== Резервная копия ==='

    if ! command_exists sysupgrade; then
        warn 'sysupgrade не найден. Копия не создана.'
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: была бы создана копия $planned_backup."
        return 0
    fi

    BACKUP_FILE=$planned_backup
    if sysupgrade -b "$BACKUP_FILE"; then
        info "Резервная копия: $BACKUP_FILE"
        print_line 'Скопируйте резервную копию на компьютер.'
        return 0
    fi

    BACKUP_FILE=''
    error 'Не удалось создать резервную копию.'
    return 1
}

configure_root_password() {
    print_line
    print_line '=== Пароль root ==='

    if ! ask_yes_no 'Изменить пароль root?' 'yes'; then
        if root_has_password; then
            ROOT_PASSWORD_AVAILABLE=1
        fi
        warn 'Пароль root оставлен без изменений.'
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        ROOT_PASSWORD_AVAILABLE=1
        info 'DRY-RUN: passwd не запускался.'
        return 0
    fi

    passwd root || fatal 'Пароль root не изменён.'
    ROOT_PASSWORD_AVAILABLE=1
}

validate_public_key() {
    case "$1" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_ssh_key_help() {
    cat >&2 <<'EOF_SSH_KEY_HELP'
SSH-ключ создаётся на вашем компьютере, не на роутере.
Создать ключ на macOS, Linux или Windows:
  ssh-keygen -t ed25519
Показать публичный ключ:
  macOS / Linux:       cat ~/.ssh/id_ed25519.pub
  Windows PowerShell:  Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
  Windows cmd.exe:     type %USERPROFILE%\.ssh\id_ed25519.pub
Скопируйте всю строку, начинающуюся с ssh-ed25519.
EOF_SSH_KEY_HELP
}

ask_public_key() {
    print_ssh_key_help

    while :; do
        public_key=$(ask_value \
            'Публичный SSH-ключ (Enter - оставить вход по паролю)' '') || \
            return 1

        if [ -z "$public_key" ]; then
            if [ "$ROOT_PASSWORD_AVAILABLE" -eq 1 ] || \
                root_has_password; then
                printf '\n'
                return 0
            fi
            warn 'Сначала добавьте SSH-ключ: рабочего пароля root нет.'
            continue
        fi

        if validate_public_key "$public_key"; then
            printf '%s\n' "$public_key"
            return 0
        fi

        warn 'Ключ не распознан. Вставьте содержимое файла .pub целиком.'
    done
}

root_has_password() {
    shadow_file=$(root_path '/etc/shadow')

    [ -r "$shadow_file" ] || return 1
    password_hash=$(awk -F: '$1 == "root" {print $2; exit}' \
        "$shadow_file")

    case "$password_hash" in
        ''|'!'|'!!'|'*')
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

port_is_listening() {
    port=$1

    if command_exists ss; then
        ss -lnt 2>/dev/null | awk -v port="$port" '
            NR > 1 {
                address = $4
                sub(/^.*:/, "", address)
                if (address == port) {
                    found = 1
                }
            }
            END {exit found ? 0 : 1}
        '
        return
    fi

    if command_exists netstat; then
        netstat -lnt 2>/dev/null | awk -v port="$port" '
            NR > 2 {
                address = $4
                sub(/^.*:/, "", address)
                if (address == port) {
                    found = 1
                }
            }
            END {exit found ? 0 : 1}
        '
        return
    fi

    return 1
}

ensure_dropbear_section() {
    if uci -q get 'dropbear.@dropbear[0]' >/dev/null 2>&1; then
        return 0
    fi

    must_run uci add dropbear dropbear >/dev/null
}

configure_ssh() {
    print_line
    print_line '=== SSH / Dropbear ==='

    command_exists uci || fatal 'Команда uci не найдена.'
    ensure_dropbear_section
    current_port=$(uci -q get dropbear.@dropbear[0].Port \
        2>/dev/null || true)
    current_port=${current_port:-22}
    ssh_port=$(ask_value 'Порт SSH' "$current_port")

    case "$ssh_port" in
        ''|*[!0-9]*)
            fatal 'Порт SSH должен быть числом.'
            ;;
    esac
    if [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
        fatal 'Порт SSH должен быть от 1 до 65535.'
    fi
    if [ "$ssh_port" != "$current_port" ] && \
        port_is_listening "$ssh_port"; then
        fatal 'Выбранный SSH-порт уже занят.'
    fi

    must_run uci set "dropbear.@dropbear[0].Port=$ssh_port"
    if uci -q get network.lan >/dev/null 2>&1; then
        must_run uci set 'dropbear.@dropbear[0].Interface=lan'
    else
        warn 'Интерфейс lan не найден. SSH не ограничен интерфейсом.'
    fi

    public_key=$(ask_public_key) || fatal 'Ввод SSH-ключа прерван.'

    if [ -n "$public_key" ]; then
        key_dir='/etc/dropbear'
        key_file="$key_dir/authorized_keys"
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY-RUN: ключ будет записан в $key_file."
        else
            mkdir -p "$key_dir"
            umask 077
            printf '%s\n' "$public_key" > "$key_file"
            chmod 600 "$key_file"
        fi

        if ask_yes_no 'Отключить парольный SSH-вход root?' 'yes'; then
            must_run uci set 'dropbear.@dropbear[0].PasswordAuth=off'
            must_run uci set \
                'dropbear.@dropbear[0].RootPasswordAuth=off'
        else
            must_run uci set 'dropbear.@dropbear[0].PasswordAuth=on'
            must_run uci set \
                'dropbear.@dropbear[0].RootPasswordAuth=on'
        fi
    else
        warn 'SSH-ключ не задан, пароль останется включён на LAN.'
        must_run uci set 'dropbear.@dropbear[0].PasswordAuth=on'
        must_run uci set 'dropbear.@dropbear[0].RootPasswordAuth=on'
    fi

    must_run uci commit dropbear
    info "SSH-порт после перезапуска: $ssh_port"
}

configure_hostname() {
    print_line
    print_line '=== Имя роутера ==='

    current_hostname=$(uci -q get system.@system[0].hostname \
        2>/dev/null || true)
    current_hostname=${current_hostname:-OpenWrt}
    hostname_value=$(ask_value 'Hostname' "$current_hostname")

    case "$hostname_value" in
        ''|*[!A-Za-z0-9._-]*)
            fatal 'Недопустимый hostname.'
            ;;
    esac

    must_run uci set "system.@system[0].hostname=$hostname_value"
    must_run uci commit system
}

list_wifi_ap_sections() {
    uci -q show wireless 2>/dev/null | sed -n \
        "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p" | \
        while IFS= read -r section; do
            mode=$(uci -q get "wireless.${section}.mode" \
                2>/dev/null || true)
            [ "$mode" = 'ap' ] && printf '%s\n' "$section"
        done
}

validate_wifi_password() {
    length=${#1}
    [ "$length" -ge 12 ] && [ "$length" -le 63 ]
}

ask_wifi_password() {
    while :; do
        wifi_password=$(ask_secret \
            'Новый пароль Wi-Fi (12-63 символа)') || return 1

        if ! validate_wifi_password "$wifi_password"; then
            warn 'Нужно от 12 до 63 символов. Попробуйте ещё раз.'
            wifi_password=''
            continue
        fi

        confirmation=$(ask_secret 'Повторите пароль Wi-Fi') || return 1
        if [ "$wifi_password" != "$confirmation" ]; then
            warn 'Пароли не совпадают. Попробуйте ещё раз.'
            wifi_password=''
            confirmation=''
            continue
        fi

        printf '%s\n' "$wifi_password"
        wifi_password=''
        confirmation=''
        return 0
    done
}

ask_wifi_encryption() {
    print_line 'Шифрование: 1 = WPA2, 2 = WPA2/WPA3 mixed' >&2

    while :; do
        encryption_choice=$(ask_value 'Выбор' '1') || return 1
        case "$encryption_choice" in
            1)
                printf 'psk2\n'
                return 0
                ;;
            2)
                printf 'sae-mixed\n'
                return 0
                ;;
            *)
                warn 'Введите 1 или 2.'
                ;;
        esac
    done
}

configure_wifi() {
    print_line
    print_line '=== Wi-Fi ==='
    warn 'Wi-Fi меняйте только при подключении по Ethernet.'

    if ! ask_yes_no 'Настроить существующие Wi-Fi AP?' 'yes'; then
        return 0
    fi

    sections_file="$TMP_DIR/wifi-sections"
    list_wifi_ap_sections > "$sections_file"
    if [ ! -s "$sections_file" ]; then
        warn 'Секции Wi-Fi AP не найдены. Аппаратные radio не создаются.'
        return 0
    fi

    while IFS= read -r section; do
        current_ssid=$(uci -q get "wireless.${section}.ssid" \
            2>/dev/null || true)
        device=$(uci -q get "wireless.${section}.device" \
            2>/dev/null || true)
        band=$(uci -q get "wireless.${device}.band" \
            2>/dev/null || true)
        label="${section}${band:+ ($band)}"

        print_line
        printf 'Точка доступа: %s\n' "$label"
        ssid=$(ask_value \
            'Новое имя Wi-Fi (Enter - оставить текущее)' \
            "${current_ssid:-OpenWrt}") || fatal 'Ввод SSID прерван.'
        [ -n "$ssid" ] || fatal 'SSID не может быть пустым.'

        wifi_password=$(ask_wifi_password) || \
            fatal 'Ввод пароля Wi-Fi прерван.'
        encryption=$(ask_wifi_encryption) || \
            fatal 'Выбор шифрования прерван.'

        must_run uci set "wireless.${section}.ssid=$ssid"
        must_run uci set \
            "wireless.${section}.encryption=$encryption"
        run_redacted \
            "uci set wireless.${section}.key=[REDACTED]" \
            uci set "wireless.${section}.key=$wifi_password" || \
            fatal 'Не удалось сохранить пароль Wi-Fi.'
        must_run uci set "wireless.${section}.disabled=0"
        wifi_password=''
    done < "$sections_file"

    must_run uci commit wireless
    info 'Настройки Wi-Fi сохранены.'
}

validate_subscription_url() {
    case "$1" in
        http://*|https://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_netshift_installer() {
    installer=$1

    [ -s "$installer" ] || return 1
    first_line=$(head -n 1 "$installer" 2>/dev/null || true)
    case "$first_line" in
        '#!'*)
            ;;
        *)
            return 1
            ;;
    esac

    grep -F 'yandexru45/netshift' "$installer" >/dev/null 2>&1
}

install_netshift() {
    print_line
    print_line '=== Установка NetShift ==='

    if command_exists netshift && [ -x /etc/init.d/netshift ]; then
        if ! ask_yes_no 'NetShift уже установлен. Обновить?' 'no'; then
            info 'Используется установленный NetShift.'
            return 0
        fi
    fi

    case "$PACKAGE_MANAGER" in
        apk|opkg)
            ;;
        *)
            fatal 'Для NetShift нужен apk или opkg.'
            ;;
    esac

    installer="$TMP_DIR/netshift-install.sh"
    if ! fetch_to_file "$NETSHIFT_INSTALLER_URL" "$installer"; then
        fatal 'Официальный установщик NetShift не скачан.'
    fi
    if ! validate_netshift_installer "$installer"; then
        fatal 'Скачанный установщик не прошёл базовую проверку.'
    fi

    printf 'Источник: %s\n' "$NETSHIFT_REPOSITORY"
    printf 'Installer URL: %s\n' "$NETSHIFT_INSTALLER_URL"
    chmod 700 "$installer"
    if command_exists sha256sum; then
        installer_hash=$(sha256sum "$installer" | awk '{print $1}')
        printf 'SHA-256 установщика: %s\n' "$installer_hash"
    fi

    warn 'NetShift находится в beta. Проверьте источник и хеш.'
    if ! ask_yes_no 'Запустить официальный установщик?' 'yes'; then
        fatal 'Установка NetShift отменена.'
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: установщик NetShift не запускался.'
        return 0
    fi

    sh "$installer" || fatal 'Установка NetShift завершилась ошибкой.'
    [ -x /etc/init.d/netshift ] || \
        fatal 'Сервис /etc/init.d/netshift не найден.'
    [ -x /usr/bin/netshift ] || fatal 'Команда netshift не найдена.'
}

sing_box_extended_active() {
    system_info=$(/usr/bin/netshift get_system_info 2>/dev/null || true)
    printf '%s' "$system_info" | \
        jq -e '.sing_box_extended == 1' >/dev/null 2>&1
}

install_sing_box_extended() {
    print_line
    print_line '=== Установка sing-box extended ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: sing-box extended не устанавливался.'
        return 0
    fi

    command_exists jq || fatal 'Для проверки sing-box extended нужен jq.'
    [ -x /usr/bin/netshift ] || fatal 'Команда netshift не найдена.'

    if sing_box_extended_active; then
        info 'sing-box extended уже активен.'
        return 0
    fi

    if ! /usr/bin/netshift component_action \
        sing_box install_extended; then
        fatal 'NetShift не смог установить sing-box extended.'
    fi

    if ! sing_box_extended_active; then
        fatal 'sing-box extended не активировался.'
    fi

    info 'sing-box extended установлен и проверен.'
}

patch_netshift_xhttp_policy() {
    facade=${1:-$NETSHIFT_FACADE}

    [ -r "$facade" ] || {
        error "Файл NetShift не найден: $facade"
        return 1
    }

    if grep -F \
        'select($ob.type == "vless" and' \
        "$facade" >/dev/null 2>&1; then
        return 0
    fi

    temporary="${facade}.router-provisioner.$$"
    backup="${facade}.before-router-provisioner"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: в $facade была бы включена XHTTP-only политика."
        return 0
    fi

    [ -e "$backup" ] || cp -p "$facade" "$backup" || return 1

    if ! awk '
        {
            print
            if (index($0, "| [ $candidates[]") > 0) {
                in_candidates = 1
                next
            }
            if (in_candidates &&
                index($0, "| . as $ob") > 0) {
                print "            | select($ob.type == \"vless\" and"
                print "                     (($ob.transport.type // \"\") == \"xhttp\"))"
                inserted = inserted + 1
                in_candidates = 0
            }
        }
        END {
            if (inserted != 1) {
                exit 42
            }
        }
    ' "$facade" > "$temporary"; then
        rm -f "$temporary"
        error 'Структура NetShift изменилась: XHTTP-only патч не применён.'
        return 1
    fi

    chmod 644 "$temporary"
    if ! mv "$temporary" "$facade"; then
        rm -f "$temporary"
        return 1
    fi

    grep -F \
        'select($ob.type == "vless" and' \
        "$facade" >/dev/null 2>&1
}

validate_xhttp_config() {
    config_file=${1:-/etc/sing-box/config.json}

    [ -s "$config_file" ] || return 1
    jq -e '
        [.outbounds[]?
            | select(
                .type == "vless" and
                (.transport.type // "") == "xhttp"
            )
            | .tag
        ] as $xhttp_tags
        | [.outbounds[]?
            | select(.type == "urltest")
            | .tag
        ] as $urltest_tags
        | ($xhttp_tags | length) > 0
        and all(
            .outbounds[]?;
            if .type == "vless" then
                (.transport.type // "") == "xhttp"
            elif .type == "urltest" then
                all(.outbounds[]?; . as $tag |
                    ($xhttp_tags | index($tag)) != null)
            elif .type == "selector" then
                all(.outbounds[]?; . as $tag |
                    (($xhttp_tags | index($tag)) != null) or
                    (($urltest_tags | index($tag)) != null))
            else
                true
            end
        )
    ' "$config_file" >/dev/null 2>&1
}

install_xhttp_refresh_helper() {
    print_line
    print_line '=== Защита XHTTP-only ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: был бы создан $NETSHIFT_REFRESH_HELPER."
        return 0
    fi

    cat > "$NETSHIFT_REFRESH_HELPER" <<'EOF_XHTTP_REFRESH'
#!/bin/ash

set -u

FACADE='/usr/lib/netshift/sing_box_config_facade.sh'
CONFIG='/etc/sing-box/config.json'

log() {
    logger -t router-provisioner-xhttp "$*"
}

patch_policy() {
    if grep -F \
        'select($ob.type == "vless" and' \
        "$FACADE" >/dev/null 2>&1; then
        return 0
    fi

    temporary="${FACADE}.router-provisioner.$$"
    if ! awk '
        {
            print
            if (index($0, "| [ $candidates[]") > 0) {
                in_candidates = 1
                next
            }
            if (in_candidates &&
                index($0, "| . as $ob") > 0) {
                print "            | select($ob.type == \"vless\" and"
                print "                     (($ob.transport.type // \"\") == \"xhttp\"))"
                inserted = inserted + 1
                in_candidates = 0
            }
        }
        END {
            if (inserted != 1) {
                exit 42
            }
        }
    ' "$FACADE" > "$temporary"; then
        rm -f "$temporary"
        log 'XHTTP-only policy could not be applied'
        return 1
    fi

    chmod 644 "$temporary"
    mv "$temporary" "$FACADE"
}

validate_config() {
    jq -e '
        [.outbounds[]?
            | select(
                .type == "vless" and
                (.transport.type // "") == "xhttp"
            )
            | .tag
        ] as $xhttp_tags
        | [.outbounds[]?
            | select(.type == "urltest")
            | .tag
        ] as $urltest_tags
        | ($xhttp_tags | length) > 0
        and all(
            .outbounds[]?;
            if .type == "vless" then
                (.transport.type // "") == "xhttp"
            elif .type == "urltest" then
                all(.outbounds[]?; . as $tag |
                    ($xhttp_tags | index($tag)) != null)
            elif .type == "selector" then
                all(.outbounds[]?; . as $tag |
                    (($xhttp_tags | index($tag)) != null) or
                    (($urltest_tags | index($tag)) != null))
            else
                true
            end
        )
    ' "$CONFIG" >/dev/null 2>&1
}

patch_policy || exit 1
/usr/bin/netshift subscription_update || exit 1
sleep 2

if ! validate_config; then
    log 'Unsafe subscription rejected: non-XHTTP or no XHTTP nodes'
    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    exit 1
fi

log 'Subscription updated: XHTTP-only validation passed'
EOF_XHTTP_REFRESH

    chmod 700 "$NETSHIFT_REFRESH_HELPER"
    patch_netshift_xhttp_policy || \
        fatal 'Не удалось включить XHTTP-only политику.'
}

prepare_root_crontab() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: root crontab был бы подготовлен.'
        return 0
    fi

    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    chmod 600 /etc/crontabs/root
}

configure_netshift_cron() {
    cron_file='/etc/crontabs/root'

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: cron NetShift не изменялся.'
        return 0
    fi

    prepare_root_crontab
    temporary="${cron_file}.router-provisioner.$$"
    grep -v '/usr/bin/netshift list_update' "$cron_file" | \
        grep -v '/usr/bin/netshift subscription_update' | \
        grep -v "$NETSHIFT_REFRESH_HELPER" > "$temporary" || true

    {
        cat "$temporary"
        print_line '13 9 * * * /usr/bin/netshift list_update'
        printf '17 * * * * %s\n' "$NETSHIFT_REFRESH_HELPER"
    } > "$cron_file"
    rm -f "$temporary"
    chmod 600 "$cron_file"

    /etc/init.d/cron restart >/dev/null 2>&1 || \
        warn 'Не удалось перезапустить cron.'
}

write_youtube_direct_list() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: был бы создан $YOUTUBE_DIRECT_LIST."
        return 0
    fi

    mkdir -p "$(dirname "$YOUTUBE_DIRECT_LIST")"
    cat > "$YOUTUBE_DIRECT_LIST" <<'EOF_YOUTUBE_DOMAINS'
youtube.com
ytimg.com
yting.com
ggpht.com
googlevideo.com
youtubekids.com
youtu.be
yt.be
youtube-nocookie.com
wide-youtube.l.google.com
ytimg.l.google.com
youtubei.googleapis.com
youtubeembeddedplayer.googleapis.com
youtube-ui.l.google.com
yt-video-upload.l.google.com
jnn-pa.googleapis.com
returnyoutubedislikeapi.com
yt3.googleusercontent.com
EOF_YOUTUBE_DOMAINS
    chmod 644 "$YOUTUBE_DIRECT_LIST"
}

openwrt_release_series() {
    printf '%s\n' "$OPENWRT_VERSION" | \
        awk -F. '{print $1 "." $2}'
}

youtube_unblock_asset_name() {
    component=$1
    package_extension=$2
    release_version=${YOUTUBE_UNBLOCK_RELEASE_TAG#v}

    case "$component" in
        core)
            series=$(openwrt_release_series)
            printf 'youtubeUnblock-%s-1-%s-%s-openwrt-%s.%s\n' \
                "$release_version" \
                "$YOUTUBE_UNBLOCK_RELEASE_COMMIT" \
                "$OPENWRT_ARCH" \
                "$series" \
                "$package_extension"
            ;;
        luci)
            printf 'luci-app-youtubeUnblock-%s-1-%s.%s\n' \
                "$release_version" \
                "$YOUTUBE_UNBLOCK_RELEASE_COMMIT" \
                "$package_extension"
            ;;
        *)
            return 1
            ;;
    esac
}

youtube_unblock_known_sha256() {
    case "$1" in
        youtubeUnblock-1.3.1-1-4a223b0-aarch64_cortex-a53-openwrt-25.12.apk)
            print_line \
                '15372a5cce3781b48b2d2b0668287686fecca3e203dfe8eb4ca5cfa3a1a17a1c'
            ;;
        luci-app-youtubeUnblock-1.3.1-1-4a223b0.apk)
            print_line \
                '8815ea38bf45bad011f65f43f5a3afeeccf0df4f34c7eaad839663454598a9a7'
            ;;
        youtubeUnblock-1.3.1-1-4a223b0-aarch64_cortex-a53-openwrt-24.10.ipk)
            print_line \
                'a364d193e54792f94dd1c1cdcae63747e10a1723ef50c3981155f1911bb3e1a3'
            ;;
        luci-app-youtubeUnblock-1.3.1-1-4a223b0.ipk)
            print_line \
                '53f770f4197f755fff8bee9b45f040d04418cdb62480d901c2af170f95eb0299'
            ;;
        *)
            return 1
            ;;
    esac
}

download_youtube_unblock_asset() {
    release_json=$1
    asset_name=$2
    destination=$3

    asset_url=$(jq -r --arg name "$asset_name" '
        .assets[]?
        | select(.name == $name)
        | .browser_download_url
    ' "$release_json" | head -n 1)
    [ -n "$asset_url" ] && [ "$asset_url" != 'null' ] || {
        error "В релизе не найден пакет: $asset_name"
        return 1
    }

    expected_hash=$(jq -r --arg name "$asset_name" '
        .assets[]?
        | select(.name == $name)
        | (.digest // "")
    ' "$release_json" | head -n 1 | sed 's/^sha256://')
    if [ -z "$expected_hash" ]; then
        expected_hash=$(youtube_unblock_known_sha256 \
            "$asset_name" 2>/dev/null || true)
    fi
    [ -n "$expected_hash" ] || {
        error "Для $asset_name нет SHA-256."
        return 1
    }

    fetch_to_file "$asset_url" "$destination" || return 1
    actual_hash=$(sha256sum "$destination" | awk '{print $1}')
    [ "$actual_hash" = "$expected_hash" ] || {
        error "SHA-256 не совпал для $asset_name."
        return 1
    }
}

configure_youtube_unblock() {
    must_run uci set \
        'youtubeUnblock.youtubeUnblock=youtubeUnblock'
    must_run uci set \
        'youtubeUnblock.youtubeUnblock.conf_strat=ui_flags'
    must_run uci set \
        'youtubeUnblock.youtubeUnblock.packet_mark=32768'
    must_run uci set \
        'youtubeUnblock.youtubeUnblock.queue_num=537'

    must_run uci set 'youtubeUnblock.default=section'
    must_run uci set 'youtubeUnblock.default.name=Default section'
    must_run uci set 'youtubeUnblock.default.enabled=1'
    must_run uci set 'youtubeUnblock.default.tls_enabled=1'
    must_run uci set 'youtubeUnblock.default.fake_sni=0'
    must_run uci set \
        'youtubeUnblock.default.faking_strategy=pastseq'
    must_run uci set \
        'youtubeUnblock.default.fake_sni_seq_len=1'
    must_run uci set \
        'youtubeUnblock.default.fake_sni_type=default'
    must_run uci set 'youtubeUnblock.default.frag=tcp'
    must_run uci set \
        'youtubeUnblock.default.frag_sni_reverse=1'
    must_run uci set \
        'youtubeUnblock.default.frag_sni_faked=0'
    must_run uci set \
        'youtubeUnblock.default.frag_middle_sni=1'
    must_run uci set \
        'youtubeUnblock.default.frag_sni_pos=1'
    must_run uci set 'youtubeUnblock.default.seg2delay=0'
    must_run uci set 'youtubeUnblock.default.fk_winsize=0'
    must_run uci set 'youtubeUnblock.default.synfake=0'
    must_run uci set \
        'youtubeUnblock.default.sni_detection=parse'
    must_run uci set 'youtubeUnblock.default.all_domains=0'
    must_run uci set 'youtubeUnblock.default.quic_drop=0'
    must_run uci set 'youtubeUnblock.default.udp_mode=drop'
    must_run uci set \
        'youtubeUnblock.default.udp_fake_seq_len=6'
    must_run uci set 'youtubeUnblock.default.udp_fake_len=64'
    must_run uci set \
        'youtubeUnblock.default.udp_filter_quic=parse'
    must_run uci set \
        'youtubeUnblock.default.udp_faking_strategy=none'

    run uci -q delete 'youtubeUnblock.default.sni_domains'
    for domain in \
        googlevideo.com \
        ggpht.com \
        ytimg.com \
        youtube.com \
        play.google.com \
        youtu.be \
        googleapis.com \
        googleusercontent.com \
        gstatic.com \
        l.google.com; do
        must_run uci add_list \
            "youtubeUnblock.default.sni_domains=$domain"
    done

    must_run uci commit youtubeUnblock
}

install_youtube_unblock() {
    print_line
    print_line '=== Установка youtubeUnblock ==='
    printf 'Источник: %s\n' "$YOUTUBE_UNBLOCK_REPOSITORY"

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: youtubeUnblock не устанавливался.'
        configure_youtube_unblock
        return 0
    fi

    command_exists jq || fatal 'Для установки youtubeUnblock нужен jq.'
    command_exists sha256sum || \
        fatal 'Для проверки youtubeUnblock нужен sha256sum.'

    if [ -z "$OPENWRT_ARCH" ]; then
        case "$PACKAGE_MANAGER" in
            apk)
                OPENWRT_ARCH=$(apk --print-arch 2>/dev/null || true)
                ;;
            opkg)
                OPENWRT_ARCH=$(opkg print-architecture 2>/dev/null | \
                    awk 'END {print $2}')
                ;;
        esac
    fi
    [ -n "$OPENWRT_ARCH" ] || \
        fatal 'Архитектура OpenWrt не определена.'

    case "$PACKAGE_MANAGER" in
        apk)
            package_extension='apk'
            must_run apk update
            must_run apk add kmod-nft-queue kmod-nf-conntrack
            ;;
        opkg)
            package_extension='ipk'
            must_run opkg update
            must_run opkg install kmod-nft-queue kmod-nf-conntrack
            ;;
        *)
            fatal 'Для youtubeUnblock нужен apk или opkg.'
            ;;
    esac

    release_json="$TMP_DIR/youtubeUnblock-release.json"
    fetch_to_file "$YOUTUBE_UNBLOCK_RELEASE_API" "$release_json" || \
        fatal 'Метаданные релиза youtubeUnblock не скачаны.'

    core_asset=$(youtube_unblock_asset_name core "$package_extension") || \
        fatal 'Имя пакета youtubeUnblock не построено.'
    luci_asset=$(youtube_unblock_asset_name luci "$package_extension") || \
        fatal 'Имя пакета LuCI youtubeUnblock не построено.'
    core_package="$TMP_DIR/$core_asset"
    luci_package="$TMP_DIR/$luci_asset"

    download_youtube_unblock_asset \
        "$release_json" "$core_asset" "$core_package" || \
        fatal 'Пакет youtubeUnblock не прошёл проверку.'
    download_youtube_unblock_asset \
        "$release_json" "$luci_asset" "$luci_package" || \
        fatal 'LuCI-пакет youtubeUnblock не прошёл проверку.'

    case "$PACKAGE_MANAGER" in
        apk)
            apk add --allow-untrusted \
                "$core_package" "$luci_package" || \
                fatal 'APK-пакеты youtubeUnblock не установлены.'
            ;;
        opkg)
            opkg install "$core_package" "$luci_package" || \
                fatal 'IPK-пакеты youtubeUnblock не установлены.'
            ;;
    esac

    [ -x /etc/init.d/youtubeUnblock ] || \
        fatal 'Сервис youtubeUnblock не найден.'
    configure_youtube_unblock

    /etc/init.d/youtubeUnblock enable || \
        fatal 'Автозапуск youtubeUnblock не включён.'
    /etc/init.d/firewall reload || \
        fatal 'Firewall не применил правило youtubeUnblock.'
    /etc/init.d/youtubeUnblock restart || \
        fatal 'youtubeUnblock не запустился.'
}

validate_youtube_unblock() {
    print_line
    print_line '=== Проверка youtubeUnblock ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: проверка youtubeUnblock пропущена.'
        return 0
    fi

    pgrep -f '[y]outubeUnblock' >/dev/null 2>&1 || \
        fatal 'Процесс youtubeUnblock не запущен.'
    nft list chain inet fw4 youtubeUnblock >/dev/null 2>&1 || \
        fatal 'NFT-цепочка youtubeUnblock не создана.'

    info 'youtubeUnblock запущен, NFT-цепочка активна.'
}

backup_netshift_config() {
    config_file='/etc/config/netshift'
    backup_file="$TMP_DIR/netshift.config.before"

    if [ -f "$config_file" ]; then
        cp "$config_file" "$backup_file" || \
            fatal 'Не удалось сохранить конфигурацию NetShift.'
    else
        : > "$backup_file"
    fi
}

restore_netshift_config() {
    backup_file="$TMP_DIR/netshift.config.before"

    if [ -s "$backup_file" ]; then
        cp "$backup_file" /etc/config/netshift
    else
        rm -f /etc/config/netshift
    fi
    uci revert netshift >/dev/null 2>&1 || true
}

configure_netshift() {
    print_line
    print_line '=== Настройка NetShift ==='

    if ! ask_yes_no 'Добавить ссылку подписки сейчас?' 'yes'; then
        fatal 'Для XHTTP-only настройки нужна ссылка подписки.'
    fi

    subscription_url=$(ask_secret 'Ссылка подписки VPN')
    if ! validate_subscription_url "$subscription_url"; then
        fatal 'Подписка должна начинаться с http:// или https://.'
    fi

    dns_server=$(ask_value 'DoH-сервер' 'dns.adguard-dns.com')
    bootstrap_dns=$(ask_value 'Bootstrap DNS' '77.88.8.8')
    source_interface=$(uci -q get network.lan.device \
        2>/dev/null || true)
    source_interface=${source_interface:-br-lan}

    backup_netshift_config
    write_youtube_direct_list
    prepare_root_crontab
    install_xhttp_refresh_helper

    must_run uci set 'netshift.settings=settings'
    must_run uci set 'netshift.settings.dns_type=doh'
    must_run uci set "netshift.settings.dns_server=$dns_server"
    must_run uci set \
        "netshift.settings.bootstrap_dns_server=$bootstrap_dns"
    run uci -q delete \
        'netshift.settings.source_network_interfaces'
    must_run uci add_list \
        "netshift.settings.source_network_interfaces=$source_interface"
    must_run uci set 'netshift.settings.update_interval=1d'
    must_run uci set 'netshift.settings.enable_ipv6=0'
    must_run uci set 'netshift.settings.block_doh=0'
    must_run uci set 'netshift.settings.dns_via_outbound=0'
    must_run uci set 'netshift.settings.disable_quic=0'

    run uci -q delete 'netshift.main'
    run uci -q delete 'netshift.ru_direct'

    must_run uci set 'netshift.VPN=section'
    must_run uci set 'netshift.VPN.connection_type=proxy'
    must_run uci set \
        'netshift.VPN.proxy_config_type=subscription'
    run uci -q delete 'netshift.VPN.subscription_url'
    run_redacted \
        'uci add_list netshift.VPN.subscription_url=[REDACTED]' \
        uci add_list \
        "netshift.VPN.subscription_url=$subscription_url" || {
            restore_netshift_config
            fatal 'Не удалось сохранить подписку.'
        }
    must_run uci set \
        'netshift.VPN.subscription_format_preference=xray'
    must_run uci set \
        'netshift.VPN.subscription_allow_insecure=0'
    must_run uci set \
        'netshift.VPN.subscription_update_interval=disabled'
    must_run uci set \
        'netshift.VPN.subscription_group_mode=off'
    must_run uci set \
        'netshift.VPN.urltest_check_interval=3m'
    must_run uci set 'netshift.VPN.urltest_tolerance=50'
    must_run uci set \
        'netshift.VPN.urltest_testing_url=https://www.gstatic.com/generate_204'
    must_run uci set 'netshift.VPN.enable_udp_over_tcp=0'
    must_run uci set 'netshift.VPN.global_proxy=1'
    must_run uci set \
        'netshift.VPN.user_domain_list_type=disabled'
    must_run uci set \
        'netshift.VPN.user_subnet_list_type=disabled'
    must_run uci set 'netshift.VPN.mixed_proxy_enabled=0'
    must_run uci set \
        'netshift.VPN.resolve_real_ip_for_routing=0'

    must_run uci set 'netshift.RU_DIRECT=section'
    must_run uci set \
        'netshift.RU_DIRECT.connection_type=exclusion'
    must_run uci set 'netshift.RU_DIRECT.global_proxy=0'
    run uci -q delete 'netshift.RU_DIRECT.community_lists'
    must_run uci add_list \
        'netshift.RU_DIRECT.community_lists=russia_outside'
    must_run uci set \
        'netshift.RU_DIRECT.user_domain_list_type=text'
    must_run uci set \
        "netshift.RU_DIRECT.user_domains_text=.ru
.su"
    must_run uci set \
        'netshift.RU_DIRECT.user_subnet_list_type=disabled'
    run uci -q delete 'netshift.RU_DIRECT.local_domain_lists'
    must_run uci add_list \
        "netshift.RU_DIRECT.local_domain_lists=$YOUTUBE_DIRECT_LIST"

    if ! run uci commit netshift; then
        restore_netshift_config
        fatal 'Не удалось сохранить конфигурацию NetShift.'
    fi
    subscription_url=''

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: NetShift не перезапускался.'
        return 0
    fi

    /etc/init.d/netshift enable || {
        restore_netshift_config
        fatal 'Не удалось включить автозапуск NetShift.'
    }
    if ! /etc/init.d/netshift restart; then
        restore_netshift_config
        /etc/init.d/netshift restart >/dev/null 2>&1 || true
        fatal 'NetShift не запустился. Конфигурация восстановлена.'
    fi

    sleep 2
    /usr/bin/netshift list_update || \
        fatal 'Списки NetShift не обновились.'
    "$NETSHIFT_REFRESH_HELPER" || \
        fatal 'Подписка не прошла XHTTP-only проверку.'
    configure_netshift_cron
}

validate_netshift() {
    print_line
    print_line '=== Проверка NetShift ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: проверка NetShift пропущена.'
        return 0
    fi

    sing_box_extended_active || \
        fatal 'Активен не sing-box extended.'
    pgrep -f '[s]ing-box' >/dev/null 2>&1 || \
        fatal 'Процесс sing-box не запущен.'
    validate_xhttp_config /etc/sing-box/config.json || \
        fatal 'Конфигурация содержит TCP-ноды или не содержит XHTTP.'

    info 'NetShift работает только с VLESS XHTTP-нодами.'
}

apply_services() {
    print_line
    print_line '=== Применение базовых настроек ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: службы не перезапускались.'
        return 0
    fi

    wifi reload || warn 'Не удалось перезагрузить Wi-Fi.'
    /etc/init.d/system reload >/dev/null 2>&1 || true

    info 'Dropbear не перезапущен, чтобы не оборвать SSH-сеанс.'
}

print_final_instructions() {
    if [ "$DRY_RUN" -eq 1 ]; then
        print_line
        print_line '=== DRY-RUN завершён ==='
        print_line 'Настройки не применялись.'
        print_line 'NetShift, sing-box extended и youtubeUnblock не устанавливались.'
        return 0
    fi

    hostname_value=$(uci -q get system.@system[0].hostname \
        2>/dev/null || true)
    hostname_value=${hostname_value:-OpenWrt}
    lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
    lan_ip=${lan_ip:-192.168.1.1}
    lan_ip=$(strip_cidr "$lan_ip")

    print_line
    print_line '=== Готово ==='
    printf 'LuCI: http://%s/\n' "$lan_ip"
    printf 'Hostname: %s\n' "$hostname_value"
    if [ -n "$BACKUP_FILE" ]; then
        printf 'Backup: %s\n' "$BACKUP_FILE"
    fi
    print_line 'NetShift: только VLESS XHTTP, TCP-ноды запрещены.'
    print_line 'YouTube: прямой маршрут через youtubeUnblock.'
    print_line 'Российские сервисы и локальная сеть: напрямую.'
    print_line
    warn 'Dropbear ещё работает со старыми активными настройками.'
    print_line 'Не закрывая текущий SSH-сеанс, выполните:'
    print_line '  /etc/init.d/dropbear restart'
    print_line 'Затем проверьте вход во второй SSH-сессии.'
    print_line 'Текущую сессию закрывайте только после успешного входа.'
}

print_safety_notice() {
    print_line 'Скрипт не клонирует sysupgrade-архив другого роутера.'
    print_line 'Он не меняет U-Boot, MTD, UBI и внутреннюю разметку.'
    print_line 'Сеть и аппаратные radio-конфиги не копируются.'
}

usage() {
    cat <<EOF_USAGE
Использование:
  $PROGRAM_NAME [--diagnose] [--dry-run] [--yes] [--version]

Параметры:
  --diagnose  Только диагностика и точная ссылка OpenWrt.
  --dry-run   Показать действия без изменения конфигурации.
  --yes       Подтверждать обычные вопросы автоматически.
  --version   Показать версию.
  --help      Показать справку.
EOF_USAGE
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --diagnose)
                DIAGNOSE_ONLY=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --yes)
                ASSUME_YES=1
                ;;
            --version|-V)
                print_line "$PROGRAM_VERSION"
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fatal "Неизвестный параметр: $1"
                ;;
        esac
        shift
    done
}

main() {
    parse_arguments "$@"
    require_root
    require_interactive_terminal

    TMP_DIR=$(mktemp -d "/tmp/${PROGRAM_NAME}.XXXXXX") || \
        fatal 'Временный каталог не создан.'

    print_line "$PROGRAM_NAME v$PROGRAM_VERSION"
    print_safety_notice
    detect_system
    print_diagnostics

    latest_openwrt=$(get_latest_openwrt_version)
    print_firmware_plan "$latest_openwrt" || true

    if [ "$DIAGNOSE_ONLY" -eq 1 ]; then
        exit 0
    fi

    if [ -z "$OPENWRT_VERSION" ]; then
        fatal 'Сначала установите OpenWrt по инструкции вашей модели.'
    fi
    if ! version_ge "$OPENWRT_VERSION" "$MIN_OPENWRT_VERSION"; then
        fatal "Нужен OpenWrt от $MIN_OPENWRT_VERSION."
    fi

    if ! check_resources; then
        print_storage_options
        if ask_yes_no 'Настроить extroot на готовом разделе?' 'no'; then
            if configure_extroot_interactively; then
                exit 0
            fi
        fi
        fatal 'Недостаточно ресурсов для безопасной установки.'
    fi

    create_backup || {
        if ! ask_yes_no 'Продолжить без резервной копии?' 'no'; then
            fatal 'Операция отменена.'
        fi
    }

    configure_root_password
    configure_hostname
    configure_ssh
    configure_wifi
    install_netshift
    install_sing_box_extended
    install_youtube_unblock
    configure_netshift
    validate_netshift
    validate_youtube_unblock
    apply_services
    print_final_instructions
}

if [ "${ROUTER_PROVISIONER_SOURCE_ONLY:-0}" -ne 1 ]; then
    main "$@"
fi
