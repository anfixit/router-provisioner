#!/bin/sh
# Interactive OpenWrt and NetShift provisioner for BusyBox ash.

set -u

PROGRAM_NAME='router-provisioner'
PROGRAM_VERSION='1.0.1'
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

DRY_RUN=0
DIAGNOSE_ONLY=0
ASSUME_YES=0
ROOT_PREFIX=${ROUTER_PROVISIONER_ROOT_PREFIX:-}
TMP_DIR=''
BOARD_JSON=''
OPENWRT_VERSION=''
OPENWRT_TARGET=''
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
    printf '%s' "$1" | sed 's,/,%2F,g'
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
    BACKUP_FILE="/tmp/${PROGRAM_NAME}-${timestamp}.tar.gz"

    print_line
    print_line '=== Резервная копия ==='

    if ! command_exists sysupgrade; then
        warn 'sysupgrade не найден. Копия не создана.'
        return 1
    fi

    if run sysupgrade -b "$BACKUP_FILE"; then
        info "Резервная копия: $BACKUP_FILE"
        router_address=$(uci -q get network.lan.ipaddr \
            2>/dev/null || true)
        router_address=${router_address:-router}
        ssh_port=$(uci -q get dropbear.@dropbear[0].Port \
            2>/dev/null || true)
        ssh_port=${ssh_port:-22}
        print_line 'Скопируйте её на компьютер:'
        printf '  scp -P %s root@%s:%s .\n' \
            "$ssh_port" "$router_address" "$BACKUP_FILE"
        return 0
    fi

    error 'Не удалось создать резервную копию.'
    return 1
}

configure_root_password() {
    print_line
    print_line '=== Пароль root ==='

    if ! ask_yes_no 'Изменить пароль root?' 'yes'; then
        warn 'Пароль root оставлен без изменений.'
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: passwd не запускался.'
        return 0
    fi

    passwd root || fatal 'Пароль root не изменён.'
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

    print_line 'Вставьте публичный SSH-ключ или оставьте поле пустым.'
    public_key=$(ask_value 'Публичный SSH-ключ' '')

    if [ -n "$public_key" ]; then
        if ! validate_public_key "$public_key"; then
            fatal 'Формат SSH-ключа не распознан.'
        fi

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
        if ! root_has_password; then
            fatal 'Нет ни SSH-ключа, ни рабочего пароля root.'
        fi
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
        ssid=$(ask_value 'SSID' "${current_ssid:-OpenWrt}")
        [ -n "$ssid" ] || fatal 'SSID не может быть пустым.'

        wifi_password=$(ask_secret 'Пароль Wi-Fi, 12-63 символа')
        if ! validate_wifi_password "$wifi_password"; then
            fatal 'Пароль Wi-Fi должен содержать 12-63 символа.'
        fi

        print_line 'Шифрование: 1 = WPA2, 2 = WPA2/WPA3 mixed'
        encryption_choice=$(ask_value 'Выбор' '1')
        case "$encryption_choice" in
            1)
                encryption='psk2'
                ;;
            2)
                encryption='sae-mixed'
                ;;
            *)
                fatal 'Неизвестный режим шифрования.'
                ;;
        esac

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
        info "DRY-RUN: sh $installer"
        return 0
    fi

    sh "$installer" || fatal 'Установка NetShift завершилась ошибкой.'
    [ -x /etc/init.d/netshift ] || \
        fatal 'Сервис /etc/init.d/netshift не найден.'
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
        print_netshift_luci_instructions
        return 0
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

    if ask_yes_no 'Весь внешний трафик через VPN?' 'yes'; then
        must_run uci set 'netshift.settings.global_proxy=1'
    else
        must_run uci set 'netshift.settings.global_proxy=0'
    fi

    must_run uci set 'netshift.main=section'
    must_run uci set 'netshift.main.connection_type=proxy'
    must_run uci set 'netshift.main.proxy_config_type=subscription'
    run uci -q delete 'netshift.main.subscription_url'
    run_redacted \
        'uci add_list netshift.main.subscription_url=[REDACTED]' \
        uci add_list \
        "netshift.main.subscription_url=$subscription_url" || {
            restore_netshift_config
            fatal 'Не удалось сохранить подписку.'
        }
    must_run uci set \
        'netshift.main.subscription_format_preference=xray'
    must_run uci set \
        'netshift.main.subscription_allow_insecure=0'
    must_run uci set \
        'netshift.main.subscription_update_interval=1h'
    must_run uci set 'netshift.main.subscription_group_mode=off'
    must_run uci set 'netshift.main.urltest_check_interval=3m'
    must_run uci set 'netshift.main.urltest_tolerance=50'
    must_run uci set \
        'netshift.main.urltest_testing_url=https://www.gstatic.com/generate_204'

    if ask_yes_no 'Российские сервисы, .ru и .su напрямую?' 'yes'; then
        user_domains=$(printf '.ru\n.su')
        must_run uci set 'netshift.ru_direct=section'
        must_run uci set 'netshift.ru_direct.connection_type=exclusion'
        run uci -q delete 'netshift.ru_direct.community_lists'
        must_run uci add_list \
            'netshift.ru_direct.community_lists=russia_outside'
        must_run uci set \
            'netshift.ru_direct.user_domain_list_type=text'
        must_run uci set \
            "netshift.ru_direct.user_domains_text=$user_domains"
        must_run uci set \
            'netshift.ru_direct.user_subnet_list_type=disabled'
    else
        run uci -q delete 'netshift.ru_direct'
    fi

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
    /usr/bin/netshift list_update || warn 'Списки не обновились.'
    /usr/bin/netshift subscription_update || \
        warn 'Подписка не обновилась.'
}

print_netshift_luci_instructions() {
    print_line
    print_line 'Настройка подписки через LuCI:'
    print_line '1. Откройте Services -> NetShift.'
    print_line '2. Создайте секцию типа Proxy.'
    print_line '3. Выберите Subscription URL.'
    print_line '4. Вставьте ссылку подписки.'
    print_line '5. Для Remnawave/XHTTP выберите формат Xray.'
    print_line '6. Интервал проверки URLTest: 3m.'
    print_line '7. Интервал обновления подписки: 1h.'
    print_line '8. Сохраните и примените настройки.'
}

validate_netshift() {
    print_line
    print_line '=== Проверка NetShift ==='

    if [ "$DRY_RUN" -eq 1 ]; then
        info 'DRY-RUN: проверка сервиса пропущена.'
        return 0
    fi

    if /etc/init.d/netshift status >/dev/null 2>&1; then
        info 'Сервис NetShift запущен.'
    else
        warn 'NetShift не сообщил состояние running.'
    fi

    if command_exists logread; then
        print_line 'Последние сообщения NetShift:'
        logread -e netshift | tail -n 30 || true
    fi

    print_line
    print_line 'Для подписок с VLESS XHTTP:'
    print_line '1. LuCI -> Services -> NetShift.'
    print_line '2. Откройте Component Manager.'
    print_line '3. Нажмите Install extended для sing-box.'
    print_line '4. Обновите подписку и перезапустите NetShift.'
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
    hostname_value=$(uci -q get system.@system[0].hostname \
        2>/dev/null || true)
    hostname_value=${hostname_value:-OpenWrt}
    lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
    lan_ip=${lan_ip:-192.168.1.1}
    ssh_port=$(uci -q get dropbear.@dropbear[0].Port \
        2>/dev/null || true)
    ssh_port=${ssh_port:-22}

    print_line
    print_line '=== Готово ==='
    printf 'LuCI: http://%s/\n' "$lan_ip"
    printf 'SSH:  ssh -p %s root@%s\n' "$ssh_port" "$lan_ip"
    printf 'Hostname: %s\n' "$hostname_value"
    if [ -n "$BACKUP_FILE" ]; then
        printf 'Backup: %s\n' "$BACKUP_FILE"
    fi
    print_line 'Проверьте локальную сеть и прямой доступ к сервисам РФ.'
    print_line 'Проверьте внешний IP, DNS и переключение VPN-узлов.'
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
    configure_netshift
    validate_netshift
    apply_services
    print_final_instructions
}

if [ "${ROUTER_PROVISIONER_SOURCE_ONLY:-0}" -ne 1 ]; then
    main "$@"
fi
