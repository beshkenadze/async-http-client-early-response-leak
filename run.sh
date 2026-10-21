#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ -n "${AHC_PATH:-}" ]; then
    scratch=".build-local"
    ref="local@$(git -C "$AHC_PATH" rev-parse --short HEAD 2>/dev/null || echo unknown)"
elif [ -n "${AHC_REVISION:-}" ]; then
    scratch=".build-$AHC_REVISION"
    ref="$AHC_REVISION"
else
    export AHC_VERSION="${AHC_VERSION:-1.36.2}"
    scratch=".build-$AHC_VERSION"
    ref="$AHC_VERSION"
fi

mkdir -p "$scratch"
if [ -f "$scratch/Package.resolved" ]; then cp "$scratch/Package.resolved" Package.resolved; fi
swift build -c release --scratch-path "$scratch" --product early-response-repro 1>&2
if [ -f Package.resolved ]; then cp Package.resolved "$scratch/Package.resolved"; fi

AHC_REF="$ref" exec "$scratch/release/early-response-repro" "$@"
