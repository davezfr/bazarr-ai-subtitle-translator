#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
RUNTIME_DIR="${SUBTRANS_RUNTIME_DIR:-$PROJECT_DIR/.runtime}"
UPSTREAM_DIR="${SUBTRANS_UPSTREAM_DIR:-$RUNTIME_DIR/chatgpt-subtitle-translator}"
UPSTREAM_REPO="${SUBTRANS_UPSTREAM_REPO:-https://github.com/Cerlancism/chatgpt-subtitle-translator.git}"
UPSTREAM_REF="${SUBTRANS_UPSTREAM_REF:-1c86a8a36a8900e5476b7b035d6e991a6870214c}"

mkdir -p "$RUNTIME_DIR"

if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  rm -rf "$UPSTREAM_DIR"
  git clone --no-checkout "$UPSTREAM_REPO" "$UPSTREAM_DIR"
fi

cd "$UPSTREAM_DIR"
git fetch --depth 1 origin "$UPSTREAM_REF"
git checkout --detach FETCH_HEAD
npm install --omit=dev

echo "subtitle-translator: upstream installed at $UPSTREAM_DIR"
echo "subtitle-translator: upstream commit $(git rev-parse HEAD)"

