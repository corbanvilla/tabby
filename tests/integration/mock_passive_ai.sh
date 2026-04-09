#!/usr/bin/env bash
set -euo pipefail

busy_secs="${MOCK_AI_BUSY_SECS:-2}"
idle_secs="${MOCK_AI_IDLE_SECS:-6}"

exec -a codex bash -lc "
end=\$((SECONDS + ${busy_secs}))
while [ \$SECONDS -lt \$end ]; do
  :
done
sleep ${idle_secs}
"
