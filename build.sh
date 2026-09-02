#!/usr/bin/env bash
# Compiles the two native helpers. Needs the Xcode Command Line Tools (swiftc).
set -eu
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O popover/PulsePopover.swift -o bin/pulse-popover
swiftc -O menubar/MenuBarImage.swift -o bin/pulse-menubar
echo "built bin/pulse-popover bin/pulse-menubar"
