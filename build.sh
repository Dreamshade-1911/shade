#!/bin/sh
set -u

mkdir -p bin data

if ! command -v odin >/dev/null 2>&1; then
    echo "Error: odin was not found in PATH." >&2
    exit 1
fi

# Rebuild meta only when the executable is missing or meta.odin is newer than it.
if [ ! -x bin/meta ] || [ meta.odin -nt bin/meta ]; then
    echo "Building meta program..."
    if ! odin build meta.odin -file -out:bin/meta; then
        echo "Meta program compilation failed." >&2
        exit 1
    fi
fi

exec bin/meta "$@"
