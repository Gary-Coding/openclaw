#!/usr/bin/env bash

set -euo pipefail

mode="${1:-}"

if [[ "${mode}" != "--dry-run" && "${mode}" != "--publish" ]]; then
  echo "usage: bash scripts/publish-private-npm.sh [--dry-run|--publish]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${OPENCLAW_PRIVATE_NPM_REGISTRY:-https://packages.aliyun.com/6616664158b06f87bcc6affb/npm/npm-registry/}"
PACK_DIR="${OPENCLAW_PRIVATE_NPM_PACK_DIR:-$ROOT_DIR/.artifacts/npm-private}"

cd "${ROOT_DIR}"

package_name="$(node -p "require('./package.json').name")"
package_version="$(node -p "require('./package.json').version")"

mkdir -p "${PACK_DIR}"
rm -f "${PACK_DIR}/${package_name}-"*.tgz

echo "Resolved package name: ${package_name}"
echo "Resolved package version: ${package_version}"
echo "Resolved registry: ${REGISTRY}"
echo "Resolved pack dir: ${PACK_DIR}"

echo "Checking registry reachability..."
npm ping --registry="${REGISTRY}" >/dev/null

echo "Checking npm auth..."
whoami_result="$(npm whoami --registry="${REGISTRY}")"
echo "Authenticated as: ${whoami_result}"

echo "Checking whether ${package_name}@${package_version} already exists..."
if npm view "${package_name}@${package_version}" version --registry="${REGISTRY}" >/dev/null 2>&1; then
  if [[ "${mode}" == "--publish" ]]; then
    echo "${package_name}@${package_version} already exists in ${REGISTRY}" >&2
    exit 1
  fi
  echo "Warning: ${package_name}@${package_version} already exists in ${REGISTRY}" >&2
fi

echo "Packing tarball with scripts disabled..."
pack_json="$(npm pack --ignore-scripts --json --pack-destination "${PACK_DIR}")"
pack_file="$(
  PACK_JSON="${pack_json}" node -e '
    const entries = JSON.parse(process.env.PACK_JSON ?? "[]");
    const filename = entries[0]?.filename;
    if (!filename) process.exit(1);
    process.stdout.write(filename);
  '
)"
publish_target="${PACK_DIR}/${pack_file}"

echo "Resolved publish target: ${publish_target}"

publish_cmd=(npm publish "${publish_target}" --registry="${REGISTRY}")
printf 'Publish command:'
printf ' %q' "${publish_cmd[@]}"
printf '\n'

if [[ "${mode}" == "--dry-run" ]]; then
  exit 0
fi

"${publish_cmd[@]}"
