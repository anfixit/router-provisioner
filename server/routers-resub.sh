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

set -u

HUB_URL="${HUB_URL:-https://kanbanfi.ru/hub}"
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

status() {
    curl -sf -m 20 "$HUB_URL/status?key=$HUB_KEY"
}

# The status page is the hub's own list of routers, one per line, label first.
labels() {
    status | sed -n 's/^\([A-Za-z0-9_-]\{1,32\}\):.*/\1/p'
}

push() {
    action="$1"
    for label in $LABELS; do
        if curl -sf -m 20 "$HUB_URL/set/$label/$action?key=$HUB_KEY" \
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
    echo 'Хаб не отдал ни одного роутера: проверь ключ и адрес хаба.' >&2
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
