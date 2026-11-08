#!/bin/sh
# EveryAI installer for macOS and Linux.
#
#   curl -fsSL https://get.everyai.dev/install.sh | sh
#   curl -fsSL https://get.everyai.dev/install.sh | sh -s -- --uninstall
#
# macOS: the signed, notarized DMG, checked (SHA-256, code signature from team 2MGLZ5685D, Gatekeeper) and copied to
#   /Applications (or ~/Applications when /Applications isn't writable). It updates itself from then on.
# Linux (x86_64): the .deb through apt on Debian/Ubuntu-style systems, otherwise the AppImage under
#   ~/.local/share/everyai with a menu entry, icons, the everyai:// link handler and an `everyai` command. Both are
#   checked against SHA256SUMS, whose GPG signature is checked when gpg is installed. The AppImage updates itself.
#
# Settings (environment):
#   EVERYAI_VERSION   a version to install instead of the latest (e.g. 0.1.0-alpha.6)
#   EVERYAI_METHOD    Linux only: deb or appimage
#   EVERYAI_PREFIX    macOS only: the folder the app goes in
# Your settings, chats and sessions are never touched, also not by --uninstall.
set -eu

BASE="${EVERYAI_BASE:-https://get.everyai.dev}"
REPO="https://github.com/xuckless/everyai-mono"
KEY_FPR="970FF42742E8F2DB941CC2D3FFA1060BBEB384CE"
TEAM_ID="2MGLZ5685D"
APP_ID="dev.alidirect.everyai"

if [ -t 1 ]; then B="$(printf '\033[1m')"; R="$(printf '\033[0m')"; Y="$(printf '\033[33m')"; else B=; R=; Y=; fi
say() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$R" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

fetch() { # url [file]: to the file, or to stdout without one
  if has curl; then
    if [ $# -gt 1 ]; then curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1" --progress-bar
    else curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$1"; fi
  elif has wget; then
    if [ $# -gt 1 ]; then wget -q --https-only -O "$2" "$1"; else wget -q --https-only -O - "$1"; fi
  else die "needs curl or wget"; fi
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "needs sha256sum or shasum"; fi
}

TMP=
MOUNT=
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

resolve_version() {
  if [ -n "${EVERYAI_VERSION:-}" ]; then VERSION="${EVERYAI_VERSION#v}"; return; fi
  VERSION="$(fetch "$BASE/latest/version" | tr -d ' \r\n')" || die "couldn't look up the latest version"
  case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) die "unexpected version '$VERSION'";; esac
}

download() { # asset name -> $TMP/name
  fetch "$REPO/releases/download/v$VERSION/$1" "$TMP/$1" || die "couldn't download $1"
}

# check_sum <sums file> <file>: checks the file against its line in the sums file (downloaded from the release).
# SHA256SUMS (Linux) is first checked against its GPG signature when gpg is there; the DMG has its own .sha256 file.
check_sum() {
  sums="$1"; file="$2"; name="$(basename "$file")"
  [ -f "$TMP/$sums" ] || download "$sums"
  if [ "$sums" = SHA256SUMS ]; then verify_sums_signature; fi
  want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$TMP/$sums")"
  [ -n "$want" ] || die "$name isn't listed in $sums"
  got="$(sha256_of "$file")"
  [ "$want" = "$got" ] || die "$name doesn't match its SHA-256 (expected $want, got $got)"
  say "SHA-256 matches"
}

verify_sums_signature() {
  [ -z "${SUMS_CHECKED:-}" ] || return 0
  SUMS_CHECKED=1
  if ! has gpg; then warn "gpg isn't installed, so only the SHA-256 is checked (over HTTPS)"; return; fi
  download SHA256SUMS.asc
  fetch "$BASE/key.asc" "$TMP/key.asc" || die "couldn't fetch the release key"
  GNUPGHOME="$TMP/gnupg"; export GNUPGHOME
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --import "$TMP/key.asc" 2>/dev/null || die "couldn't read the release key"
  if gpg --batch --status-fd 1 --verify "$TMP/SHA256SUMS.asc" "$TMP/SHA256SUMS" 2>/dev/null | grep -q "VALIDSIG $KEY_FPR "; then
    say "SHA256SUMS signed by the EveryAI release key ($KEY_FPR)"
  else
    die "SHA256SUMS isn't signed by the EveryAI release key"
  fi
  unset GNUPGHOME
}

# --- macOS --------------------------------------------------------------------------------------------------------

mac_dest() {
  if [ -n "${EVERYAI_PREFIX:-}" ]; then DEST="$EVERYAI_PREFIX"; mkdir -p "$DEST"; return; fi
  if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
}

mac_from_brew() {
  has brew || return 1
  brew list --cask everyai >/dev/null 2>&1
}

mac_quit_running() {
  pgrep -xq EveryAI 2>/dev/null || return 0
  say "Quitting the running EveryAI"
  osascript -e 'quit app id "dev.alidirect.everyai"' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq EveryAI 2>/dev/null; do
    i=$((i + 1)); [ $i -lt 30 ] || die "EveryAI is still running; quit it and run the installer again"
    sleep 1
  done
}

mac_install() {
  if mac_from_brew; then
    say "EveryAI was installed with Homebrew; it updates itself, or run: brew upgrade --cask everyai"
    exit 0
  fi
  has hdiutil || die "hdiutil not found"
  resolve_version
  mac_dest
  dmg="EveryAI-$VERSION.dmg"
  say "Downloading EveryAI $VERSION for macOS"
  download "$dmg"
  check_sum "$dmg.sha256" "$TMP/$dmg"

  MOUNT="$TMP/mnt"; mkdir "$MOUNT"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$TMP/$dmg" || { MOUNT=; die "couldn't open the DMG"; }
  app="$MOUNT/EveryAI.app"
  [ -d "$app" ] || die "no EveryAI.app in the DMG"
  codesign --verify --deep --strict "$app" 2>/dev/null || die "the app's code signature doesn't verify"
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$team" = "$TEAM_ID" ] || die "the app is signed by team '$team', not EveryAI's ($TEAM_ID)"
  spctl --assess --type execute "$app" 2>/dev/null || die "Gatekeeper doesn't accept the app"
  say "Signed by EveryAI ($TEAM_ID), notarized"

  mac_quit_running
  say "Installing to $DEST/EveryAI.app"
  rm -rf "$DEST/.EveryAI.app.new"
  ditto "$app" "$DEST/.EveryAI.app.new" || die "couldn't copy into $DEST (try EVERYAI_PREFIX=\$HOME/Applications)"
  rm -rf "$DEST/EveryAI.app"
  mv "$DEST/.EveryAI.app.new" "$DEST/EveryAI.app"
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  MOUNT=
  say "Done. Open EveryAI from $DEST (or run: open -a EveryAI). It updates itself."
}

mac_uninstall() {
  if mac_from_brew; then say "Installed with Homebrew; run: brew uninstall --cask everyai"; exit 0; fi
  mac_quit_running
  # With EVERYAI_PREFIX, only that folder.
  if [ -n "${EVERYAI_PREFIX:-}" ]; then dirs="$EVERYAI_PREFIX"; else dirs="/Applications $HOME/Applications"; fi
  for d in $dirs; do
    if [ -d "$d/EveryAI.app" ]; then rm -rf "$d/EveryAI.app" && say "Removed $d/EveryAI.app"; fi
  done
  say "Your settings and chats stay in ~/Library/Application Support/$APP_ID"
}

# --- Linux --------------------------------------------------------------------------------------------------------

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPIMAGE_DIR="$DATA/everyai"
BIN_DIR="$HOME/.local/bin"

linux_sudo() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=; return 0; fi
  if has sudo; then SUDO=sudo; return 0; fi
  if has doas; then SUDO=doas; return 0; fi
  return 1
}

linux_method() {
  case "${EVERYAI_METHOD:-}" in
    deb|appimage) METHOD="$EVERYAI_METHOD"; return;;
    '') ;;
    *) die "EVERYAI_METHOD must be deb or appimage";;
  esac
  if has apt-get && has dpkg && linux_sudo; then METHOD=deb; else METHOD=appimage; fi
}

linux_install() {
  case "$(uname -m)" in x86_64|amd64) ;; *) die "EveryAI has Linux builds for x86_64 only, not $(uname -m)";; esac
  resolve_version
  linux_method
  if [ "$METHOD" = deb ]; then linux_deb; else linux_appimage; fi
}

linux_deb() {
  linux_sudo || die "installing the .deb needs root, sudo or doas (or use EVERYAI_METHOD=appimage)"
  deb="everyai_${VERSION}_amd64.deb"
  say "Downloading EveryAI $VERSION (.deb)"
  download "$deb"
  check_sum SHA256SUMS "$TMP/$deb"
  # apt reads the file as its own user.
  chmod 755 "$TMP"; chmod 644 "$TMP/$deb"
  say "Installing with apt${SUDO:+ (asks for your password)}"
  $SUDO apt-get install -y "$TMP/$deb" || die "apt couldn't install the package"
  say "Done. EveryAI is in your applications menu (or run: everyai)."
}

linux_appimage() {
  name="EveryAI-$VERSION-x86_64.AppImage"
  say "Downloading EveryAI $VERSION (AppImage)"
  download "$name"
  check_sum SHA256SUMS "$TMP/$name"
  chmod 755 "$TMP/$name"

  mkdir -p "$APPIMAGE_DIR" "$BIN_DIR" "$DATA/applications"
  image="$APPIMAGE_DIR/EveryAI.AppImage"
  # A new file renamed over the old one, so a running copy keeps working.
  cp "$TMP/$name" "$image.new" && mv -f "$image.new" "$image"

  # FUSE mounts the AppImage; without it the runtime can unpack to a temp folder on each start instead.
  extract_env=
  if ! has fusermount3 && ! has fusermount; then
    extract_env="APPIMAGE_EXTRACT_AND_RUN=1 "
    warn "FUSE isn't installed, so EveryAI unpacks itself on each start (slower). Install fuse3 to avoid that."
  fi

  say "Adding the menu entry, icons and the everyai command"
  (cd "$TMP" && "$TMP/$name" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1) ||
    (cd "$TMP" && "$TMP/$name" --appimage-extract >/dev/null 2>&1) || true
  if [ -d "$TMP/squashfs-root/usr/share/icons/hicolor" ]; then
    mkdir -p "$DATA/icons"
    cp -R "$TMP/squashfs-root/usr/share/icons/." "$DATA/icons/"
  else # the AppImage couldn't run here (e.g. under emulation): the same icons from get.everyai.dev
    mkdir -p "$DATA/icons/hicolor/256x256/apps" "$DATA/icons/hicolor/scalable/apps"
    fetch "$BASE/icon-256.png" "$DATA/icons/hicolor/256x256/apps/$APP_ID.png" 2>/dev/null &&
      fetch "$BASE/icon.svg" "$DATA/icons/hicolor/scalable/apps/$APP_ID.svg" 2>/dev/null ||
      warn "couldn't fetch the icons"
  fi

  launcher="$BIN_DIR/everyai"
  env_line=
  if [ -n "$extract_env" ]; then env_line="export $extract_env"; fi
  cat > "$launcher" <<EOF
#!/bin/sh
# Installed by https://get.everyai.dev/install.sh
$env_line
exec "$image" "\$@"
EOF
  chmod 755 "$launcher"

  desktop="$DATA/applications/$APP_ID.desktop"
  cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=EveryAI
Comment=Every AI model in one app: chat, research and coding agents
Exec="$launcher" %U
TryExec=$launcher
Icon=$APP_ID
Terminal=false
Categories=Development;
Keywords=AI;LLM;chat;agent;code;
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/everyai;
EOF
  if has update-desktop-database; then update-desktop-database -q "$DATA/applications" 2>/dev/null || true; fi
  if has gtk-update-icon-cache; then gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true; fi
  if has xdg-mime; then xdg-mime default "$APP_ID.desktop" x-scheme-handler/everyai 2>/dev/null || true; fi

  say "Done. EveryAI is in your applications menu. It updates itself."
  case ":$PATH:" in
    *":$BIN_DIR:"*) say "Run it from a terminal with: everyai";;
    *) say "To run it from a terminal, add $BIN_DIR to your PATH";;
  esac
  if ! ldd --version 2>&1 | head -1 | awk '{ v = $NF; split(v, p, "."); exit !(p[1] > 2 || (p[1] == 2 && p[2] >= 35)) }'; then
    warn "EveryAI needs glibc 2.35 or newer (Ubuntu 22.04, Fedora 36, Debian 12 and later)"
  fi
}

linux_uninstall() {
  if has dpkg && dpkg -s everyai >/dev/null 2>&1; then
    linux_sudo || die "removing the package needs root, sudo or doas"
    say "Removing the everyai package"
    $SUDO apt-get remove -y everyai || $SUDO dpkg -r everyai
  fi
  if [ -f "$APPIMAGE_DIR/EveryAI.AppImage" ] || [ -f "$DATA/applications/$APP_ID.desktop" ]; then
    rm -f "$APPIMAGE_DIR/EveryAI.AppImage" "$DATA/applications/$APP_ID.desktop"
    if grep -q 'get.everyai.dev' "$BIN_DIR/everyai" 2>/dev/null; then rm -f "$BIN_DIR/everyai"; fi
    find "$DATA/icons/hicolor" -name "$APP_ID.*" -delete 2>/dev/null || true
    rmdir "$APPIMAGE_DIR" 2>/dev/null || true
    if has update-desktop-database; then update-desktop-database -q "$DATA/applications" 2>/dev/null || true; fi
    say "Removed the AppImage, its menu entry and icons"
  fi
  say "Your settings and chats stay in ~/.local/share/$APP_ID"
}

# ------------------------------------------------------------------------------------------------------------------

main() {
  action=install
  for arg in "$@"; do
    case "$arg" in
      --uninstall) action=uninstall;;
      -h|--help) sed -n '2,20p' "$0" 2>/dev/null || echo "see https://get.everyai.dev/install.sh"; exit 0;;
      *) die "unknown option $arg";;
    esac
  done
  TMP="$(mktemp -d 2>/dev/null || mktemp -d -t everyai)"
  case "$(uname -s)" in
    Darwin) if [ $action = install ]; then mac_install; else mac_uninstall; fi;;
    Linux) if [ $action = install ]; then linux_install; else linux_uninstall; fi;;
    *) die "this installer is for macOS and Linux; on Windows run: irm https://get.everyai.dev/install.ps1 | iex";;
  esac
}

main "$@"
