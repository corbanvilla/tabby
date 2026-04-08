#!/usr/bin/env bash
# refresh-client -S returns 1 when there is no attached client to refresh yet.
# That is normal during detach/reattach races, and should not surface as hook
# noise to the user.
tmux refresh-client -S 2>/dev/null || true
