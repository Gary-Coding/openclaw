#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.artifacts/npm}"

if command -v pnpm >/dev/null 2>&1; then
  PNPM_BIN=(pnpm)
else
  PNPM_BIN=(corepack pnpm)
fi

PACKAGE_NAME="$("${PNPM_BIN[@]}" pkg get name | tr -d '"[:space:]')"
PACKAGE_VERSION="$("${PNPM_BIN[@]}" pkg get version | tr -d '"[:space:]')"
BIN_NAME="$(
  node -e 'const pkg = require("./package.json"); const entries = Object.entries(pkg.bin ?? {}); if (entries.length === 0) process.exit(1); process.stdout.write(entries[0][0]);'
)"
BUNDLE_BASENAME="${PACKAGE_NAME}-${PACKAGE_VERSION}-offline"
BUNDLE_DIR="$OUTPUT_DIR/$BUNDLE_BASENAME"
DEPLOY_DIR="$BUNDLE_DIR/payload/$PACKAGE_NAME"
ARCHIVE_PATH="$OUTPUT_DIR/$BUNDLE_BASENAME.tar.gz"

cleanup() {
  rm -rf "$BUNDLE_DIR"
}

trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/openclaw-*.tgz "$OUTPUT_DIR"/openclaw-*-offline.tar.gz

cd "$ROOT_DIR"

echo "[1/5] Installing dependencies"
"${PNPM_BIN[@]}" install --frozen-lockfile

echo "[2/5] Preparing packaged artifacts"
node --import tsx scripts/openclaw-prepack.ts

echo "[3/5] Assembling offline payload"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/payload"

PACKLIST_FILE="$BUNDLE_DIR/packlist.json"
npm pack --json --dry-run --ignore-scripts >"$PACKLIST_FILE"

node - "$ROOT_DIR" "$DEPLOY_DIR" "$PACKLIST_FILE" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");

const [rootDir, deployDir, packlistFile] = process.argv.slice(2);
const entries = JSON.parse(fs.readFileSync(packlistFile, "utf8"));
const files = entries[0]?.files ?? [];

fs.mkdirSync(deployDir, { recursive: true });

for (const file of files) {
  const relativePath = file.path;
  const sourcePath = path.join(rootDir, relativePath);
  const targetPath = path.join(deployDir, relativePath);
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.copyFileSync(sourcePath, targetPath);
}
EOF

cp -R "$ROOT_DIR/node_modules" "$DEPLOY_DIR/node_modules"

echo "[4/5] Finalizing offline payload"
(
  cd "$DEPLOY_DIR"
  node scripts/postinstall-bundled-plugins.mjs
)

cat >"$BUNDLE_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(find "$SCRIPT_DIR/payload" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [[ -z "${PAYLOAD_DIR:-}" ]]; then
  echo "Missing offline payload under $SCRIPT_DIR/payload" >&2
  exit 1
fi

PACKAGE_NAME="$(node -p "require(process.argv[1] + '/package.json').name" "$PAYLOAD_DIR")"
PACKAGE_VERSION="$(node -p "require(process.argv[1] + '/package.json').version" "$PAYLOAD_DIR")"
BIN_NAME="$(node -p "Object.keys(require(process.argv[1] + '/package.json').bin ?? {})[0] ?? ''" "$PAYLOAD_DIR")"
BIN_ENTRY="$(node -p "Object.values(require(process.argv[1] + '/package.json').bin ?? {})[0] ?? ''" "$PAYLOAD_DIR")"
GLOBAL_ROOT="$(npm root -g)"
GLOBAL_PREFIX="$(npm prefix -g)"
TARGET_DIR="$GLOBAL_ROOT/$PACKAGE_NAME"
BIN_DIR="$GLOBAL_PREFIX/bin"
BIN_LINK="$BIN_DIR/$BIN_NAME"

if [[ -z "$BIN_NAME" || -z "$BIN_ENTRY" ]]; then
  echo "Missing bin metadata in $PAYLOAD_DIR/package.json" >&2
  exit 1
fi

mkdir -p "$GLOBAL_ROOT" "$BIN_DIR"
rm -rf "$TARGET_DIR"
cp -R "$PAYLOAD_DIR" "$TARGET_DIR"
chmod +x "$TARGET_DIR/$BIN_ENTRY"
ln -sfn "$TARGET_DIR/$BIN_ENTRY" "$BIN_LINK"

echo "Installed $PACKAGE_NAME@$PACKAGE_VERSION"
echo "Package root: $TARGET_DIR"
echo "Binary: $BIN_LINK"
echo
echo "Recommended next steps:"
echo "  openclaw gateway stop || true"
echo "  openclaw gateway start"
echo "  openclaw channels status --probe"
EOF

cat >"$BUNDLE_DIR/README.txt" <<EOF
Offline OpenClaw bundle
=======================

Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION

This bundle already includes production dependencies and does not require
\`npm install -g <tarball>\` on the target machine.

Install on the Raspberry Pi with:

  tar -xzf $(basename "$ARCHIVE_PATH")
  cd $BUNDLE_BASENAME
  sudo ./install.sh
EOF

chmod +x "$BUNDLE_DIR/install.sh"

echo "[5/5] Creating offline archive"
COPYFILE_DISABLE=1 tar -C "$OUTPUT_DIR" -czf "$ARCHIVE_PATH" "$BUNDLE_BASENAME"

echo
echo "Offline bundle ready:"
echo "  $ARCHIVE_PATH"
echo
echo "Install on the Raspberry Pi with:"
echo "  tar -xzf $(basename "$ARCHIVE_PATH")"
echo "  cd $BUNDLE_BASENAME"
echo "  sudo ./install.sh"
echo
echo "Installed binary name:"
echo "  $BIN_NAME"
