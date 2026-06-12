#!/bin/bash
cd "$(dirname "$0")"
# The bot is managed by systemd (meridian.service, Restart=always + watchdog
# timer). Starting a nohup copy alongside it creates two live instances that
# race each other on closes — always restart through systemd when the unit
# exists.
if systemctl list-unit-files meridian.service --no-legend 2>/dev/null | grep -q meridian; then
  systemctl restart meridian
  echo "Meridian restarted via systemd (PID $(systemctl show -p MainPID --value meridian))"
else
  kill $(pgrep -f "node index.js") 2>/dev/null
  sleep 2
  nohup node index.js > /tmp/meridian-out.log 2>&1 &
  echo "Meridian started (PID $!)"
fi
