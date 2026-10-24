#!/bin/sh
# Compila e roda os testes do nucleo e da sonda.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  Sources/Idioma.swift Sources/Nucleo.swift Sources/Sonda.swift Sources/Estado.swift Testes/main.swift -o build/testes
build/testes
