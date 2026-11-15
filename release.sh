#!/bin/bash
# ./release.sh 1.1.0 "qué cambió"
# Builds the universal app, signs the zip with the release key, tags and publishes the
# GitHub release (which every installed copy picks up), and bumps the Homebrew cask.
# Needs: gh logged in, a clean git tree, and the private key from tools/keygen.swift.
set -euo pipefail
cd "$(dirname "$0")"

V="${1:?uso: ./release.sh <versión> [notas]}"
NOTES="${2:-v$V}"
KEY="${POMO_RELEASE_KEY:-$HOME/.config/notch-pomodoro/release-ed25519.key}"
[ -f "$KEY" ] || { echo "falta la clave de firma en $KEY"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "hay cambios sin commitear: commitea primero"; exit 1; }
git rev-parse "v$V" >/dev/null 2>&1 && { echo "v$V ya existe"; exit 1; }

echo "$V" > VERSION
./build.sh share
mkdir -p build/tools
swiftc -O tools/sign.swift -o build/tools/sign
build/tools/sign "$KEY" build/Pomodoro.zip > build/Pomodoro.zip.sig
SHA=$(shasum -a 256 build/Pomodoro.zip | cut -d' ' -f1)

git add VERSION
git diff --cached --quiet || git commit -q -m "v$V"
git tag "v$V"
git push -q origin HEAD --tags
gh release create "v$V" build/Pomodoro.zip build/Pomodoro.zip.sig --title "v$V" --notes "$NOTES"

TAP=$(mktemp -d)
gh repo clone ignaciobernardo/homebrew-tap "$TAP" -- -q
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/pomodoro.rb"
git -C "$TAP" commit -q -am "pomodoro $V"
git -C "$TAP" push -q
rm -rf "$TAP"
echo "publicado v$V: las apps instaladas lo ofrecen en el notch; brew upgrade --cask pomodoro también"
