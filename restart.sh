#!/bin/bash
cd "$(dirname "$0")"
kill $(pgrep -f "node index.js") 2>/dev/null
sleep 2
nohup node index.js > /tmp/meridian-out.log 2>&1 &
echo "Meridian started (PID $!)"
