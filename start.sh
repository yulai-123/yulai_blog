#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")"

npm ci
npm run build

echo "Static site generated in ./public"
