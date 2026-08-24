#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: RUNPOD_API_KEY=... $0 <public-or-authorized-image:tag>" >&2
  exit 2
fi
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  echo "RUNPOD_API_KEY is required" >&2
  exit 2
fi
if ! command -v jq >/dev/null; then
  echo "jq is required" >&2
  exit 2
fi

readonly image_name="$1"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(jq --arg image "$image_name" '.imageName = $image' "${script_dir}/template.json")"

curl --fail-with-body --silent --show-error \
  --request POST \
  --url https://rest.runpod.io/v1/templates \
  --header "Authorization: Bearer ${RUNPOD_API_KEY}" \
  --header 'Content-Type: application/json' \
  --data "$payload" | jq '{id, name, imageName, isServerless, ports}'

