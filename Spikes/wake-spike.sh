#!/bin/bash
# wake-spike.sh: throwaway experiment for the Wake Up Scheduler. Not part of the app.
#
# It answers, on this Mac, the questions the whole design depends on:
#   1. Does a booked `pmset schedule wake` really wake the Mac, and does a resident LaunchAgent
#      carry on (and how late)?
#   2. Is it a full wake or a DarkWake (screen off)?
#   3. Does `caffeinate -ims` hold the Mac awake for the whole job (no re-sleep)?
#   4. Does `pmset sleepnow` put it back to sleep afterwards?
#
# It mimics the planned design: a resident agent, a booked wake a little before the start time,
# the agent holds the Mac awake while the "job" runs, then releases and sleeps the Mac if idle.
# The "job" is just a heartbeat log; nothing else is touched.
#
# Usage (run from Terminal, not from inside Desktop/Documents/Downloads at run time; `install` copies
# the script to ~/wakeup-spike, which launchd is allowed to use):
#   ./wake-spike.sh install            copy to ~/wakeup-spike and load the resident agent
#   ./wake-spike.sh start [min] [hold] book a wake and a test job `min` minutes ahead (default 4),
#                                      holding the Mac awake for `hold` minutes (default 5)
#   ./wake-spike.sh report             PASS/FAIL summary plus the macOS power log for the run
#   ./wake-spike.sh cleanup            remove the agent, cancel our booked wake (logs are kept)
#
# Needs the existing passwordless rule for `sudo pmset schedule *` and `sudo pmset sleepnow`
# (already installed by ClaudeWriter's nightshift setup). Our wake uses the owner tag "wakeupspike".

set -u

SRC="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WORK="$HOME/wakeup-spike"
LABEL="nz.wakeupmanager.spike"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
OWNER="wakeupspike"
PMSET=/usr/bin/pmset
LOG="$WORK/spike.log"
LEAD=${SPIKE_LEAD:-60}      # seconds before the start time that the wake is booked
TICK=10                     # agent loop, seconds
GAP=45                      # a loop gap longer than this means the Mac was asleep

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }
hm() { date -r "$1" '+%H:%M:%S'; }
pm_fmt() { date -r "$1" '+%m/%d/%y %H:%M:%S'; }
idle_secs() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
lid_state() { ioreg -r -k AppleClamshellState -d 4 | awk -F'= ' '/AppleClamshellState/ {print $2; exit}'; }
power_line() { pmset -g batt | head -1 | tr -d '\n'; }
sleep_now() { sudo -n "$PMSET" sleepnow >/dev/null 2>&1 || "$PMSET" sleepnow >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------- install

cmd_install() {
  mkdir -p "$WORK" "$HOME/Library/LaunchAgents"
  [ "$SRC" = "$WORK/wake-spike.sh" ] || cp "$SRC" "$WORK/wake-spike.sh"
  chmod +x "$WORK/wake-spike.sh"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$WORK/wake-spike.sh</string><string>agent</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$WORK/launchd.log</string>
  <key>StandardErrorPath</key><string>$WORK/launchd.log</string>
</dict></plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  if launchctl bootstrap "$DOMAIN" "$PLIST"; then
    echo "Agent installed and running. Next:  $WORK/wake-spike.sh start"
  else
    echo "Could not load the agent ($PLIST)"; exit 1
  fi
}

# ---------------------------------------------------------------------------------- start

cmd_start() {
  local mins=${1:-4} hold=${2:-5} now target wake
  [ -f "$PLIST" ] || { echo "Run './wake-spike.sh install' first."; exit 1; }
  if [ "$(( mins * 60 ))" -le "$(( LEAD + 120 ))" ]; then
    echo "Use at least $(( (LEAD + 120) / 60 + 1 )) minutes, so there is time to put the Mac to sleep."; exit 1
  fi
  now=$(date +%s); target=$(( now + mins * 60 )); wake=$(( target - LEAD ))
  [ -f "$LOG" ] && mv "$LOG" "$LOG.prev"
  rm -f "$WORK/done"
  echo "$target" > "$WORK/target"
  echo "$(( hold * 60 ))" > "$WORK/hold"
  echo "$now" > "$WORK/started"
  if ! sudo -n "$PMSET" schedule wake "$(pm_fmt "$wake")" "$OWNER"; then
    echo "Could not book the wake (the passwordless sudo rule for pmset may be missing)."; exit 1
  fi
  pm_fmt "$wake" > "$WORK/booked"
  log "=== RUN START: wake booked for $(hm "$wake"), job target $(hm "$target"), hold $hold min"
  log "SETUP power: $(power_line)  lid: $(lid_state)  filevault: $(fdesetup status 2>/dev/null | head -1)"
  echo "Wake booked for $(hm "$wake"); the test job starts at $(hm "$target") and holds the Mac awake for $hold min."
  echo
  echo "NOW: lock the screen (Ctrl-Cmd-Q), then Apple menu > Sleep, and leave the Mac alone."
  echo "Come back after $(hm $(( target + hold * 60 + 180 ))), wake the Mac (press a key), then run:"
  echo "    $WORK/wake-spike.sh report"
}

# ---------------------------------------------------------------------------------- agent

run_job() {
  local now target hold end last t gap
  now=$(date +%s); target=$(cat "$WORK/target"); hold=$(cat "$WORK/hold")
  touch "$WORK/done"
  log "JOB START late=$(( now - target ))s"
  log "STATE power: $(power_line)  lid: $(lid_state)  user idle: $(idle_secs)s"
  log "STATE last wake: $(pmset -g log | grep -E '^[0-9-]+ [0-9:]+ [+-][0-9]+ (Wake|DarkWake) ' | tail -1 | cut -c1-190)"
  caffeinate -ims -w $$ &
  local caf=$!
  log "HOLD ON (caffeinate -ims, pid $caf)"
  sleep 3
  pmset -g assertions | grep -E 'caffeinate|PreventSystemSleep +[01]|PreventUserIdleSystemSleep +[01]' | sed 's/^ */STATE assertion: /' | while read -r l; do log "$l"; done
  end=$(( now + hold )); last=$(date +%s); local n=0
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 15
    t=$(date +%s); gap=$(( t - last )); last=$t; n=$(( n + 1 ))
    if [ "$gap" -gt "$GAP" ]; then
      log "HOLD GAP ${gap}s: the Mac slept or stalled while it should have been held awake"
    elif [ $(( n % 4 )) -eq 0 ]; then
      log "heartbeat ok (user idle $(idle_secs)s, lid $(lid_state))"
    fi
  done
  kill "$caf" 2>/dev/null; wait "$caf" 2>/dev/null
  log "HOLD OFF"
  log "JOB END"
  if [ "$(idle_secs)" -ge 120 ]; then
    log "SLEEPNOW: nobody has used the Mac for 2 minutes, putting it to sleep"
    sleep_now
  else
    log "NOT SLEEPING: the Mac was used in the last 2 minutes"
  fi
}

cmd_agent() {
  mkdir -p "$WORK"
  log "agent started (pid $$)"
  local last now gap target
  last=$(date +%s)
  while true; do
    now=$(date +%s); gap=$(( now - last )); last=$now
    [ "$gap" -gt "$GAP" ] && log "TICK GAP ${gap}s: the Mac was asleep or suspended (now $(hm "$now"))"
    if [ -f "$WORK/target" ] && [ ! -f "$WORK/done" ]; then
      target=$(cat "$WORK/target")
      if [ "$now" -ge "$target" ]; then
        run_job
        last=$(date +%s)   # run_job blocks for the whole hold; don't report that as a sleep gap
      fi
    fi
    sleep "$TICK"
  done
}

# ---------------------------------------------------------------------------------- report

cmd_report() {
  [ -f "$LOG" ] || { echo "No log yet: run start first."; exit 1; }
  local started target start_s end_s late before holdgaps after
  started=$(cat "$WORK/started" 2>/dev/null || echo 0)
  target=$(cat "$WORK/target" 2>/dev/null || echo 0)
  if [ "$(date +%s)" -lt "$target" ]; then
    echo "Too early: the test job isn't due until $(hm "$target"). Waking the Mac yourself before then spoils the test."
    exit 0
  fi
  echo "== Spike log"
  cut -c1-200 "$LOG"
  echo
  echo "== macOS power log (Sleep / Wake / DarkWake) for this run"
  start_s=$(date -r "$started" '+%Y-%m-%d %H:%M:%S'); end_s=$(date '+%Y-%m-%d %H:%M:%S')
  pmset -g log | awk -v a="$start_s" -v b="$end_s" \
    'substr($0,1,19) >= a && substr($0,1,19) <= b && ($4=="Sleep" || $4=="DarkWake" || $4=="Clamshell" || ($4=="Wake" && $5!="Requests")) {print}' | cut -c1-190
  echo
  echo "== Verdicts"
  before=$(awk '/JOB START/ {exit} /TICK GAP/ {c++} END {print c+0}' "$LOG")
  after=$(awk '/JOB END/ {f=1} f && /TICK GAP/ {c++} END {print c+0}' "$LOG")
  holdgaps=$(grep -c "HOLD GAP" "$LOG")
  if ! grep -q "JOB START" "$LOG"; then
    echo "WAKE:  FAIL. The job never started. If the Mac only woke when you pressed a key, the booked wake did not work."
  else
    late=$(grep "JOB START" "$LOG" | sed -E 's/.*late=(-?[0-9]+)s.*/\1/')
    if [ "$before" -eq 0 ]; then
      echo "WAKE:  INCONCLUSIVE. The Mac never slept before the job (it was awake all along). Redo and sleep it first."
    elif [ "$late" -le 120 ]; then
      echo "WAKE:  PASS. The Mac slept, woke itself, and the job started ${late}s after its target time."
    else
      echo "WAKE:  LATE. The job started ${late}s after its target. Check the power log above for who woke the Mac."
    fi
    if ! grep -q "JOB END" "$LOG"; then
      echo "HOLD:  still running (or the Mac went back to sleep mid-job; look for HOLD GAP above)."
    elif [ "$holdgaps" -eq 0 ]; then
      echo "HOLD:  PASS. No gaps: the Mac stayed awake for the whole job."
    else
      echo "HOLD:  FAIL. $holdgaps gap(s): the Mac went to sleep while it should have been held awake."
    fi
    if grep -q "SLEEPNOW" "$LOG"; then
      if [ "$after" -gt 0 ]; then echo "SLEEP: PASS. The Mac went to sleep after the job (and you woke it later)."
      else echo "SLEEP: not seen yet. Did you leave it alone and wake it afterwards? Check the power log above."; fi
    elif grep -q "NOT SLEEPING" "$LOG"; then
      echo "SLEEP: skipped, the Mac had been used within 2 minutes of the job ending."
    fi
    if grep -q "STATE last wake:.*DarkWake" "$LOG"; then
      echo "NOTE:  the wake was a DarkWake (screen stays off); the job still ran."
    fi
  fi
}

# ---------------------------------------------------------------------------------- cleanup

cmd_cleanup() {
  local booked w
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  rm -f "$PLIST"
  booked=$(cat "$WORK/booked" 2>/dev/null)
  [ -n "$booked" ] && sudo -n "$PMSET" schedule cancel wake "$booked" "$OWNER" >/dev/null 2>&1
  # also cancel anything of ours still listed (the listing shows MM/dd/yyyy; pmset wants MM/dd/yy)
  "$PMSET" -g sched | grep "'$OWNER'" | sed -E "s/.*wake at ([0-9/]+) ([0-9:]+) by.*/\1 \2/" \
    | sed -E 's#^([0-9]{2}/[0-9]{2}/)20([0-9]{2})#\1\2#' | while read -r w; do
      sudo -n "$PMSET" schedule cancel wake "$w" "$OWNER" >/dev/null 2>&1
    done
  rm -f "$WORK/target" "$WORK/hold" "$WORK/done" "$WORK/booked"
  echo "Agent removed and our booked wake cancelled. Logs kept in $WORK."
  "$PMSET" -g sched | grep -i "$OWNER" || echo "No '$OWNER' wakes left in: pmset -g sched"
}

case "${1:-}" in
  install) cmd_install ;;
  start) shift; cmd_start "$@" ;;
  agent) cmd_agent ;;
  report) cmd_report ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '2,25p' "$SRC" ;;
esac
