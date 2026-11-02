#!/bin/sh
# Ask every router the hub knows to re-fetch its subscription.
#
# The addresses a router dials live in the subscription, and it pulls that once
# a day. When the addresses change under us - a node gets a new IP, or the DNS
# holding their names goes down and the panel starts handing out IPs instead -
# every router keeps dialing yesterday's config until its next daily pull, and
# the routers sit behind NAT where nobody can ssh in and say otherwise. The hub
# is the one channel that still works then, so this walks every router it knows
# rather than asking the owner to remember the list.
#
# Two stages, because the `resub` task only exists in a helper the router may
# not have yet: `update` pulls the current helpers from GitHub, then `resub`
# re-reads the subscription. Pass --quick to skip the first stage when every
# router is already up to date.
#
#   HUB_KEY=... server/routers-resub.sh
#   HUB_KEY=... server/routers-resub.sh --quick
#
# The hub's address and the key live in ~/.config/router-hub/owner.conf so that
# one owner's server does not end up in everyone's repository:
#
#   HUB_URL=https://hub.example.org/hub
#   HUB_IP=203.0.113.10
#   HUB_KEY=...
#
# HUB_IP is what makes this work on the day it is needed. The hub is reached by
# name like everything else, so the DNS outage that makes the routers dial the
# wrong addresses is the same one that hides the hub from the owner. Pinning the
# name to its address keeps the one channel that can fix the routers open.

set -u

OWNER_CONF="${OWNER_CONF:-$HOME/.config/router-hub/owner.conf}"
# shellcheck source=/dev/null
[ -r "$OWNER_CONF" ] && . "$OWNER_CONF"

HUB_URL="${HUB_URL:-}"
HUB_IP="${HUB_IP:-}"
# The routers poll every two minutes, and `update` has to download and install
# the helpers before the next task is read. Three minutes covers both without
# making an emergency feel like a maintenance window.
WAIT_UPDATE="${WAIT_UPDATE:-200}"
WAIT_RESUB="${WAIT_RESUB:-200}"
QUICK=0

[ "${1:-}" = '--quick' ] && QUICK=1

if [ -z "${HUB_KEY:-}" ]; then
    echo 'Нужен ключ хаба: HUB_KEY=... server/routers-resub.sh' >&2
    exit 2
fi

if [ -z "$HUB_URL" ]; then
    echo "Не задан HUB_URL: впиши его в $OWNER_CONF" >&2
    exit 2
fi

# Pin the hub's name to its address when we know it, so a DNS failure does not
# take away the channel. curl still sends the name in SNI and in Host, so the
# certificate and the nginx server block keep working.
HUB_HOST=$(printf '%s\n' "$HUB_URL" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')
PIN=''
[ -n "$HUB_IP" ] && PIN="--resolve $HUB_HOST:443:$HUB_IP"

status() {
    # shellcheck disable=SC2086
    curl -sf $PIN -m 20 "$HUB_URL/status?key=$HUB_KEY"
}

# The status page is the hub's own list of routers, one per line, label first.
labels() {
    status | sed -n 's/^\([A-Za-z0-9_-]\{1,32\}\):.*/\1/p'
}

push() {
    action="$1"
    for label in $LABELS; do
        # shellcheck disable=SC2086
        if curl -sf $PIN -m 20 "$HUB_URL/set/$label/$action?key=$HUB_KEY" \
            >/dev/null 2>&1
        then
            echo "  $label: задание «$action» поставлено"
        else
            echo "  $label: хаб не принял задание «$action»" >&2
        fi
    done
}

LABELS=$(labels)

if [ -z "$LABELS" ]; then
    echo 'Хаб не отдал ни одного роутера.' >&2
    if [ -z "$HUB_IP" ]; then
        echo "Если не резолвится имя хаба, впиши HUB_IP в $OWNER_CONF." >&2
    else
        echo 'Проверь ключ: адрес хаба задан, но ответа нет.' >&2
    fi
    exit 1
fi

echo "Роутеров в хабе: $(echo "$LABELS" | wc -w | tr -d ' ')"
echo

if [ "$QUICK" -eq 0 ]; then
    echo 'Шаг 1: обновляю хелперы (нужно, если «resub» на роутере ещё нет).'
    push update
    echo "Жду ${WAIT_UPDATE} с, пока роутеры заберут задание и поставят обновление."
    sleep "$WAIT_UPDATE"
    echo
fi

echo 'Шаг 2: прошу перекачать подписку.'
push resub
echo "Жду ${WAIT_RESUB} с, пока роутеры заберут задание."
sleep "$WAIT_RESUB"
echo

echo 'Что говорит хаб сейчас (задание «-» значит, что роутер его уже забрал):'
status | sed 's/^/  /'
