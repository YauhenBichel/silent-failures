#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# reachability-watch (macOS): record when a server comes and goes, and say so when it stays down.
#
#   reachability-watch.sh NAME    one check; launchd runs it every 30 s (see reachability-watch.plist)
#
# Settings for NAME come from ~/.config/reachability-watch/NAME.env:
#   SSH_HOST=myserver             an ssh host that answers `ssh HOST true` with no password prompt
#   ADDRESS=192.168.1.10          the server's LAN address, to tell "off or hung" from "ssh is broken"
#   DOWN_NOTIFY_SECONDS=300       notify after this long down (default 300)
#
# States, written to ~/Library/Logs/reachability-watch-NAME.log only when they change:
#   up            ssh works
#   ssh-down      the server answers on the LAN, but ssh does not
#   unreachable   the server does not answer ARP: it is off, hung, or off the network
# After DOWN_NOTIFY_SECONDS down a macOS notification follows, and another when the server is back.
# Away from home (the default gateway's hardware address is not the one seen while the server was up)
# nothing is counted. NOTIFY=0 logs the notifications without showing them.
#
# Run it from launchd. macOS's Local Network privacy blocks LAN traffic from processes started by some
# apps (IDE terminals, AI agents), and there every LAN check fails.
#
# Why: a server froze late one evening and its own alerting froze with it. The Mac saw it go, and told
# nobody.
set -uo pipefail

name=${1:-}
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: reachability-watch.sh NAME" >&2; exit 2; }
conf=${REACHABILITY_WATCH_CONF:-$HOME/.config/reachability-watch}/$name.env
[ -r "$conf" ] || { echo "reachability-watch: no settings in $conf" >&2; exit 2; }
# shellcheck source=/dev/null
. "$conf"
: "${SSH_HOST:?SSH_HOST is not set in $conf}" "${ADDRESS:?ADDRESS is not set in $conf}"
DOWN_NOTIFY_SECONDS=${DOWN_NOTIFY_SECONDS:-300}
NOTIFY=${NOTIFY:-1}

LOG=$HOME/Library/Logs/reachability-watch-$name.log
CACHE=$HOME/Library/Caches/reachability-watch/$name
STATE=$CACHE/state SINCE=$CACHE/down-since NOTIFIED=$CACHE/down-notified HOME_GATEWAY=$CACHE/home-gateway
mkdir -p "$CACHE" "$(dirname "$LOG")"

stamp() { date -u +%FT%TZ; }
notify() {  # title, message
  echo "$(stamp) notified: $1: $2" >> "$LOG"
  [ "$NOTIFY" = 1 ] || return 0
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1 || true
}
duration() { printf '%dh %02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }

if /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=4 -o ControlMaster=no -o ControlPath=none "$SSH_HOST" true 2>/dev/null; then
  now=up
else
  # A ping fills the ARP cache; "(incomplete)" afterwards means nothing answered at the link layer.
  ping -c 1 -t 2 "$ADDRESS" >/dev/null 2>&1
  if arp -n "$ADDRESS" 2>/dev/null | grep -qE "incomplete|no entry"; then now=unreachable; else now=ssh-down; fi
fi

previous=$(cat "$STATE" 2>/dev/null || echo unknown)
if [ "$now" != "$previous" ]; then
  echo "$(stamp) $previous -> $now" >> "$LOG"
  echo "$now" > "$STATE"
fi

# Home or away: the default gateway's hardware address, learnt while the server is up.
gateway=$(route -n get default 2>/dev/null | awk '/gateway:/ { print $2 }')
gateway_mac=""
[ -n "$gateway" ] && gateway_mac=$(arp -n "$gateway" 2>/dev/null | awk '{ print $4 }')
case "$gateway_mac" in *incomplete*) gateway_mac="" ;; esac
if [ "$now" = up ] && [ -n "$gateway_mac" ]; then echo "$gateway_mac" > "$HOME_GATEWAY"; fi
at_home=1
if [ "$now" != up ]; then
  if [ -z "$gateway_mac" ] || { [ -s "$HOME_GATEWAY" ] && [ "$gateway_mac" != "$(cat "$HOME_GATEWAY")" ]; }; then
    at_home=0
  fi
fi

t=$(date +%s)
if [ "$now" = up ]; then
  if [ -f "$NOTIFIED" ]; then
    notify "$name is back" "It was $(cat "$NOTIFIED") for $(duration $(( t - $(cat "$SINCE" 2>/dev/null || echo "$t") )))."
  fi
  rm -f "$SINCE" "$NOTIFIED"
elif [ "$at_home" = 0 ]; then
  rm -f "$SINCE"   # away from home, or no network: the server's state cannot be judged from here
else
  [ -f "$SINCE" ] || echo "$t" > "$SINCE"
  since=$(cat "$SINCE")
  if [ ! -f "$NOTIFIED" ] && [ $(( t - since )) -ge "$DOWN_NOTIFY_SECONDS" ]; then
    notify "$name is down" "$now since $(date -r "$since" +%H:%M)"
    echo "$now" > "$NOTIFIED"
  fi
fi
