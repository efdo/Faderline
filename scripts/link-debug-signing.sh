#!/bin/bash
# Links this checkout's git-ignored Config/DebugLocal.xcconfig to the per-user
# Debug signing file, so every checkout and worktree signs Debug builds with
# the same stable certificate. No-op when the per-user file does not exist.
set -euo pipefail

shared="${FADERLINE_DEBUG_SIGNING:-$HOME/.config/faderline/DebugSigning.xcconfig}"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
link="$root/Config/DebugLocal.xcconfig"

if [[ ! -f "$shared" ]]; then
    echo "No $shared; Debug builds stay ad-hoc signed (see Config/DebugSigning.xcconfig.example)."
    exit 0
fi
if [[ -e "$link" && ! -L "$link" ]]; then
    echo "Keeping existing non-symlink $link"
    exit 0
fi
ln -sfn "$shared" "$link"
echo "Linked $link -> $shared"
