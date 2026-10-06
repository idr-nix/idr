#!/bin/sh
# idr-git-hook-launcher-v1
# idr-git-hook-payload: @payload@

# Keep this file and its manifest local: even its interpreter must work when
# another host installed the hook into this shared checkout.
hook_dir=$(CDPATH= cd -- "${0%/*}" && pwd) || exit 1
healthy() {
    [ "$(uname -sm)" = @platform@ ] || return 1
    [ -x "$hook_dir/@payload@" ] || return 1
    [ -e @config@ ] || return 1
    while IFS= read -r path; do
        [ -e "$path" ] || return 1
    done <<'IDR_HOOK_CLOSURE'
@closure@
IDR_HOOK_CLOSURE
}

if healthy; then
    unset IDR_GIT_HOOK_REPAIR
    exec "$hook_dir/@payload@" "$@"
fi

if [ "${IDR_GIT_HOOK_REPAIR:-}" = 1 ]; then
    echo 'idr: Git hook dependencies are still unavailable after shell regeneration.' >&2
    exit 1
fi
echo 'idr: regenerating Git hooks for this host.' >&2
# The shell installer takes the project lock. Do not hold it here, and do not
# let shell startup consume a pre-push hook's standard input.
export IDR_GIT_HOOK_REPAIR=1
nix develop -c true </dev/null >&2 || exit "$?"
exec "$0" "$@"
