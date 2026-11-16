#!/bin/bash
# Build and run the Prism endpoint tests (macOS).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    Sources/CursorProfiles/Gateway{Models,Keychain,Canon,Stream,Router,Server,Engine,Usage}.swift \
    tests/gateway/GatewayTests.swift \
    -o build/gateway-tests
./build/gateway-tests
