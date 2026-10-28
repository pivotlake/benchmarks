#!/bin/bash
# Sourced by the scripts that build a tool with cargo: installs a C toolchain
# and Rust when the machine has none, and puts cargo on PATH.

if ! command -v cc >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y build-essential
fi
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
export PATH="$HOME/.cargo/bin:$PATH"
