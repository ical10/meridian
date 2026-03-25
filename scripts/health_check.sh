#!/bin/bash
# Watchdog: restart meridian if its journal has gone silent while the unit claims active.
# The bot runs a management cycle every 3 min, so a quiet journal means a hung process —
# the failure mode systemd's Restart= can't see. Run via meridian-healthcheck.timer.
STALE_MINUTES=15

# Deliberately stopped (or mid-restart) is not our business — only catch silent hangs.
systemctl is-active --quiet meridian || exit 0

lines=$(journalctl -u meridian --since "${STALE_MINUTES} min ago" --no-pager -q 2>/dev/null | wc -l)
if [ "$lines" -gt 0 ]; then
  exit 0
fi

echo "meridian journal silent for ${STALE_MINUTES}m while unit active — restarting"
systemctl restart meridian

# Best-effort Telegram notify. Strip inline comments (#...) from .env values:
# systemd's EnvironmentFile keeps them, which broke Telegram on 2026-06-11 —
# don't repeat that here.
ENV_FILE=/root/meridian/meridian/.env
envval() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
    | sed 's/[[:space:]]*#.*$//' | tr -d '"' | xargs
}
TOKEN=$(envval TELEGRAM_BOT_TOKEN)
CHAT=$(envval TELEGRAM_CHAT_ID)
if [ -n "$TOKEN" ] && [ -n "$CHAT" ]; then
  curl -s -m 10 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="${CHAT}" \
    -d text="🩺 Watchdog: meridian was hung (journal silent ${STALE_MINUTES}m) — restarted it." \
    >/dev/null || true
fi
