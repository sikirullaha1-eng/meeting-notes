#!/bin/bash
# Rebuild `meet` after you've changed Sources/meet.swift
set -e
cd "$(dirname "$0")"
echo "Building…"
swiftc -O -parse-as-library Sources/meet.swift -o meet
echo "Done. Run it with:  ./meet"
