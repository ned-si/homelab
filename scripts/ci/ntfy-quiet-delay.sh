#!/bin/bash
# ntfy-quiet-delay.sh -- the ntfy `Delay` for a post from GitHub Actions.
#
# Alertmanager mutes ntfy from 23:00 to 08:00 Europe/Zurich (docs/sre.md
# "Quiet hours"); Actions posts to the same topic directly. Inside that window
# this prints the minutes until 08:00 Zurich (ntfy holds the message and
# delivers it then); outside it prints nothing.
#
#   curl ... ${delay:+-H "Delay: ${delay}m"} ...
#
# Environment: NOW (epoch seconds, default now). GNU date on the runner, BSD
# date on a Mac.
set -euo pipefail

NOW=${NOW:-$(date +%s)}
hm=$(TZ=Europe/Zurich date -d "@$NOW" +%H:%M 2>/dev/null ||
  TZ=Europe/Zurich date -r "$NOW" +%H:%M)
min=$((10#${hm%:*} * 60 + 10#${hm#*:}))
if [ "$min" -ge $((23 * 60)) ]; then
  echo $((24 * 60 - min + 8 * 60))
elif [ "$min" -lt $((8 * 60)) ]; then
  echo $((8 * 60 - min))
fi
