#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
ref="${1:-1.36.2}"
source="${AHC_URL:-https://github.com/swift-server/async-http-client.git}"
work="$(mktemp -d "${TMPDIR:-/tmp}/ahc-early-response-offline.XXXXXX")"
checkout="$work/async-http-client"

echo "cloning $source at $ref into $checkout" 1>&2
git clone --quiet "$source" "$checkout"
commit="$(git -C "$checkout" rev-parse --verify --quiet "origin/$ref^{commit}" || git -C "$checkout" rev-parse --verify "$ref^{commit}")"
git -C "$checkout" checkout --quiet --detach "$commit"
echo "testing async-http-client $(git -C "$checkout" describe --tags --always)" 1>&2
cp "$here/EarlyResponseBodyLeakTests.swift" "$checkout/Tests/AsyncHTTPClientTests/"
cd "$checkout"
swift test --filter EarlyResponseBodyLeakTests
