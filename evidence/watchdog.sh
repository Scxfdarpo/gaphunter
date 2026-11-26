#!/bin/bash
# Temporary watchdog for the GapHunter 300-run batch driver.
# Restarts the driver if it dies; retires itself once the batch hits 300.
E=/home/hatch/workspace/dorahacks/reactive-omni/gaphunter/evidence
PROG=$E/batch200_progress.txt
LOG=$E/watchdog.log
export PATH="/home/hatch/.foundry/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ts() { date '+%F %T'; }
echo "$(ts) watchdog started" >> "$LOG"
while true; do
  done_n=$(grep -oP 'completed_total:\s*\K[0-9]+' "$PROG" 2>/dev/null || echo 0)
  if [ "${done_n:-0}" -ge 300 ]; then
    echo "$(ts) batch complete ($done_n/300) - watchdog retiring" >> "$LOG"
    systemctl disable --now gaphunter-watchdog.service >/dev/null 2>&1
    exit 0
  fi
  if ! pgrep -f 'batch_driver300.py' >/dev/null; then
    echo "$(ts) driver not running (at $done_n/300) - restarting" >> "$LOG"
    cd "$E" && setsid nohup python3 batch_driver300.py >> "$E/driver300w.log" 2>&1 &
  fi
  sleep 60
done
