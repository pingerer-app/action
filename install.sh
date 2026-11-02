#!/usr/bin/env bash
# Puts the pingerer command line tool on the runner's PATH for action.yml's
# next step: the build for this runner from the CLI's GitHub Releases
# (PINGERER_CLI_VERSION, like 0.3.0, or latest). PINGERER_BIN uses a
# binary already here instead (the tests' own build).
set -euo pipefail

fail() {
  printf '::error title=Pingerer::%s\n' "$*" >&2
  exit 1
}

if [[ -n "${PINGERER_BIN:-}" ]]; then
  dirname "$PINGERER_BIN" >>"${GITHUB_PATH:-/dev/null}"
  exit 0
fi

repo="${PINGERER_CLI_REPO:-pingerer-app/pingerer}"
version="${PINGERER_CLI_VERSION:-latest}"
case "${RUNNER_OS:-$(uname -s)}/${RUNNER_ARCH:-$(uname -m)}" in
  Linux/X64 | Linux/x86_64) target=x86_64-unknown-linux-gnu ext=tar.xz ;;
  Linux/ARM64 | Linux/aarch64) target=aarch64-unknown-linux-gnu ext=tar.xz ;;
  macOS/ARM64 | Darwin/arm64) target=aarch64-apple-darwin ext=tar.xz ;;
  macOS/X64 | Darwin/x86_64) target=x86_64-apple-darwin ext=tar.xz ;;
  Windows/X64) target=x86_64-pc-windows-msvc ext=zip ;;
  *) fail "There's no pingerer build for ${RUNNER_OS:-this system} ${RUNNER_ARCH:-}." ;;
esac

if [[ "$version" == latest ]]; then
  url="https://github.com/$repo/releases/latest/download/pingerer-$target.$ext"
else
  url="https://github.com/$repo/releases/download/v${version#v}/pingerer-$target.$ext"
fi

dir="${RUNNER_TEMP:-$(mktemp -d)}/pingerer-cli"
mkdir -p "$dir"
curl -fsSL --retry 3 "$url" -o "$dir/pingerer.$ext" || fail "Couldn't download the pingerer tool from $url."
if [[ "$ext" == zip ]]; then
  unzip -qo "$dir/pingerer.$ext" -d "$dir"
else
  tar -xJf "$dir/pingerer.$ext" -C "$dir"
fi
binary="$(find "$dir" -type f \( -name pingerer -o -name pingerer.exe \) | head -n 1)"
[[ -n "$binary" ]] || fail "The download from $url had no pingerer in it."
chmod +x "$binary"
dirname "$binary" >>"${GITHUB_PATH:-/dev/null}"
"$binary" --version
