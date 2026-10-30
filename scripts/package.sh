#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
release_version="$(bin/adaptive --version)"
release_directory="${ADAPTIVE_DIST_DIR:-$project_root/dist}"
mkdir -p "$release_directory"
release_directory="$(cd "$release_directory" && pwd)"
release_name="adaptive-cr-v${release_version}.tar.gz"
tar -czf "$release_directory/$release_name" \
  --exclude='*/.git' --exclude='*/__pycache__' --exclude='*.pyc' \
  --exclude='*/lib/pod5/vendor/cache' --exclude='*/.libpod5_format.a.*' --exclude='*.o' --exclude='*.a' \
  --exclude='adaptive-cr/.venv' --exclude='adaptive-cr/dist' \
  --transform='s,^\.,adaptive-cr,' \
  ./src ./spec ./tests ./scripts ./examples ./bin ./docs \
  ./README.md ./LICENSE ./NOTICE.md ./shard.yml ./shard.lock ./mise.toml \
  ./requirements.txt ./.ameba.yml ./.gitignore
cd "$release_directory"
sha256sum "$release_name" > "$release_name.sha256"
printf '%s\n' "$release_directory/$release_name"
