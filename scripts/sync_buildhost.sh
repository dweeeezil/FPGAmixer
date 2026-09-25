#!/usr/bin/env bash
# =============================================================================
# sync_buildhost.sh -- copy the repo's Yocto layer and board software to the
# EDF build VM, as an exact replacement (no stale files survive).
#
#   repo yocto/  ->  <vm>:~/edf/2026.1/sources/fpgamixer/yocto/
#   repo tools/  ->  <vm>:~/edf/2026.1/sources/fpgamixer/tools/
#
# The layer finds tools/ through a relative path (FPGAMIXER_TOOLS in
# yocto/meta-fpgamixer/conf/layer.conf), so the two must travel together and
# keep this layout. bblayers.conf on the VM points at
# ~/edf/2026.1/sources/fpgamixer/yocto/meta-fpgamixer (one-time setup, see
# docs/phase6_status_2026-09-25.md).
#
# Copies the WORKING TREE (git-tracked files only), so uncommitted changes can
# be built; the commit and a dirty flag are written to .synced-from next to
# them, and bitbake-built images can be traced back with it.
#
# Usage (repo root, Git Bash on Windows or any Linux):
#     scripts/sync_buildhost.sh [ssh-host]        # default host: edfvm
# =============================================================================
set -euo pipefail

HOST="${1:-edfvm}"
DEST='~/edf/2026.1/sources/fpgamixer'

cd "$(git rev-parse --show-toplevel)"

rev="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain -- yocto tools)" ]; then
    rev="$rev-dirty"
fi

files="$(git ls-files -- yocto tools)"
count="$(printf '%s\n' "$files" | wc -l)"
echo "Syncing $count files (yocto/, tools/) at $rev to $HOST:$DEST"

# Stream a tar of exactly the tracked files; replace the destination in one go.
printf '%s\n' "$files" | tar -cf - -T - | ssh "$HOST" "
    set -e
    rm -rf $DEST.new
    mkdir -p $DEST.new
    tar -xf - -C $DEST.new
    printf '%s\n' '$rev' > $DEST.new/.synced-from
    rm -rf $DEST
    mv $DEST.new $DEST
    # CRLF would break bitbake parsing and shebangs; .gitattributes should
    # already prevent it, this makes it certain.
    find $DEST -type f \\( -name '*.py' -o -name '*.bb*' -o -name '*.conf' \\
        -o -name '*.dtsi' -o -name '*.service' -o -name '*.network' \\) \
        -exec sed -i 's/\\r\$//' {} +
    echo \"VM now has: \$(cat $DEST/.synced-from), \$(find $DEST -type f | wc -l) files\"
"
