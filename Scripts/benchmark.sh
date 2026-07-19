#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ITEM_COUNT=${1:-1000000}

case "$ITEM_COUNT" in
    *[!0-9]*|'')
        echo "usage: $0 [item-count]" >&2
        exit 2
        ;;
esac

cd "$ROOT_DIR"
OPENDISKTREE_BENCHMARK_ITEMS="$ITEM_COUNT" \
    swift test -c release --filter sqlitePersistenceBenchmark
