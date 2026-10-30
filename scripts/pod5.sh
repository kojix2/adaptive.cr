#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec sh "$root/lib/pod5/scripts/with_native.sh" "$root/bin/adaptive-pod5" "$@"
