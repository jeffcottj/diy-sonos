#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${DIY_SONOS_REPO:-jeffcottj/diy-sonos}"
INSTALL_DIR_DEFAULT="${HOME}/diy-sonos"
TAG="${DIY_SONOS_TAG:-latest}"
INSTALL_DIR="$INSTALL_DIR_DEFAULT"
SKIP_SETUP=0

usage() {
  cat <<USAGE
DIY Sonos release installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<tag>/install.sh | bash
  ./install.sh [--tag vX.Y.Z|latest] [--install-dir DIR] [--repo owner/repo] [--skip-setup]

Options:
  --tag          Release tag to install (default: latest)
  --install-dir  Destination directory (default: ~/diy-sonos)
  --repo         GitHub repository slug (default: jeffcottj/diy-sonos)
  --skip-setup   Download/extract only; do not run guided setup prompt
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --skip-setup) SKIP_SETUP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need_bin() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }; }
need_bin curl
need_bin tar

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$TAG" == "latest" ]]; then
  RELEASE_META_URL="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
  echo "Resolving latest release for ${REPO_SLUG}..."
  TAG="$(curl -fsSL "$RELEASE_META_URL" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$TAG" ]] || { echo "Failed to resolve latest release tag from $RELEASE_META_URL" >&2; exit 1; }
fi

ARCHIVE_URL="https://github.com/${REPO_SLUG}/archive/refs/tags/${TAG}.tar.gz"
ARCHIVE_PATH="$TMP_DIR/release.tar.gz"
EXTRACT_DIR="$TMP_DIR/extracted"

mkdir -p "$EXTRACT_DIR"

echo "Downloading ${REPO_SLUG} release ${TAG}..."
curl -fL "$ARCHIVE_URL" -o "$ARCHIVE_PATH"

echo "Extracting release..."
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
ROOT_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$ROOT_DIR" ]] || { echo "Release archive did not contain a top-level directory" >&2; exit 1; }

mkdir -p "$INSTALL_DIR"

for file in config.yml .diy-sonos.generated.yml clients.yml; do
  if [[ -f "$INSTALL_DIR/$file" ]]; then
    cp "$INSTALL_DIR/$file" "$TMP_DIR/$file.backup"
  fi
done

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$ROOT_DIR"/. "$INSTALL_DIR"/

echo "$TAG" > "$INSTALL_DIR/.diy-sonos-version"

for file in config.yml .diy-sonos.generated.yml clients.yml; do
  if [[ -f "$TMP_DIR/$file.backup" ]]; then
    cp "$TMP_DIR/$file.backup" "$INSTALL_DIR/$file"
  fi
done

chmod +x "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/install.sh"

echo ""
echo "Installed DIY Sonos ${TAG} to ${INSTALL_DIR}"
echo "Version metadata stored at ${INSTALL_DIR}/.diy-sonos-version"

echo ""
echo "Next:"
echo "  cd ${INSTALL_DIR}"
echo "  ./setup.sh init"

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  echo ""
  read -r -p "Run guided setup now? [y/N]: " run_setup
  if [[ "${run_setup,,}" == "y" || "${run_setup,,}" == "yes" ]]; then
    (cd "$INSTALL_DIR" && ./setup.sh init)
  fi
fi
