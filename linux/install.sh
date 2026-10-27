#!/usr/bin/env bash
# Adds Halcyn to your app launcher, running it from wherever this folder is.
# Run it again after moving the folder; `./install.sh --remove` takes it out again.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
id=io.github.varixxl.halcyn
apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
icons=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps

if [[ ${1:-} == --remove ]]; then
  rm -f "$apps/$id.desktop" "$icons/$id.png"
  echo "Removed Halcyn from the launcher."
  exit
fi

mkdir -p "$apps" "$icons"
cp "$here/data/halcyn.png" "$icons/$id.png"
cat > "$apps/$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Halcyn
GenericName=Music Player
Comment=Bit-perfect music player
Exec="$here/halcyn"
Icon=$id
Terminal=false
Categories=AudioVideo;Audio;Player;
StartupWMClass=$id
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database "$apps" || true
echo "Halcyn is in your app launcher."
