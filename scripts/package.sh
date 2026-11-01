#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
release_version="$(bin/adaptive --version)"
release_directory="${ADAPTIVE_DIST_DIR:-$project_root/dist}"
mkdir -p "$release_directory"
release_directory="$(cd "$release_directory" && pwd)"
release_name="adaptive-cr-v${release_version}.tar.gz"
# Stage a named root instead of using GNU tar's --transform (absent on macOS).
release_stage=$(mktemp -d)
trap 'rm -rf "$release_stage"' EXIT
mkdir "$release_stage/adaptive-cr"
cp -R ./src ./spec ./tests ./scripts ./examples ./bin ./docs ./.github \
  ./README.md ./LICENSE ./NOTICE.md ./shard.yml ./shard.lock ./mise.toml \
  ./requirements.txt ./.ameba.yml ./.gitignore "$release_stage/adaptive-cr/"
tar -czf "$release_directory/$release_name" \
  --exclude='*/.git' --exclude='*/__pycache__' --exclude='*.pyc' \
  --exclude='*/lib/pod5/vendor/cache' --exclude='*/.libpod5_format.a.*' --exclude='*.o' --exclude='*.a' \
  --exclude='adaptive-cr/.venv' --exclude='adaptive-cr/dist' \
  -C "$release_stage" adaptive-cr
cd "$release_directory"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$release_name" > "$release_name.sha256"
else
  shasum -a 256 "$release_name" > "$release_name.sha256"
fi
printf '%s\n' "$release_directory/$release_name"
