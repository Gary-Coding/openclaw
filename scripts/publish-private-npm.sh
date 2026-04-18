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

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

resolve_pnpm_cmd() {
  if [[ -n "${npm_execpath:-}" ]]; then
    printf '%s\n' "${NODE:-node}" "${npm_execpath}" "pnpm"
    return
  fi

  if command -v pnpm >/dev/null 2>&1; then
    printf '%s\n' "pnpm"
    return
  fi

  if command -v corepack >/dev/null 2>&1; then
    printf '%s\n' "corepack" "pnpm"
    return
  fi

  printf '%s\n' "pnpm"
}

control_ui_assets_ready() {
  [[ -f "dist/control-ui/index.html" ]] || return 1
  find "dist/control-ui/assets" -maxdepth 1 -type f | grep -q .
}

prepared_artifacts_ready() {
  [[ -f "dist/index.js" || -f "dist/index.mjs" ]] || return 1
  control_ui_assets_ready
}

ensure_prepared_artifacts() {
  if prepared_artifacts_ready; then
    echo "Prepared build artifacts already present."
    return
  fi

  echo "Prepared artifacts missing; running build and Control UI build..."
  local pnpm_cmd=()
  while IFS= read -r line; do
    pnpm_cmd+=("$line")
  done < <(resolve_pnpm_cmd)
  run_cmd "${pnpm_cmd[@]}" build
  run_cmd "${pnpm_cmd[@]}" ui:build

  if ! prepared_artifacts_ready; then
    echo "Prepared artifacts are still missing after build. Expected dist/index.js or dist/index.mjs plus dist/control-ui assets." >&2
    exit 1
  fi
}

cd "${ROOT_DIR}"

package_name="$(node -p "require('./package.json').name")"
package_version="$(node -p "require('./package.json').version")"

mkdir -p "${PACK_DIR}"
rm -f "${PACK_DIR}/${package_name}-"*.tgz

echo "Resolved package name: ${package_name}"
echo "Resolved package version: ${package_version}"
echo "Resolved registry: ${REGISTRY}"
echo "Resolved pack dir: ${PACK_DIR}"

ensure_prepared_artifacts

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
