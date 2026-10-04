#!/bin/bash
# Установка и обновление Mr.Di. одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/CryptoNerf/mr.di/main/scripts/install.sh | bash
#
# Файл, скачанный через curl, не получает пометку карантина — поэтому macOS не скажет
# «приложение повреждено», и команда xattr не нужна. Тот же скрипт обновляет
# уже установленную версию.
set -euo pipefail

REPO="CryptoNerf/mr.di"
APP="/Applications/MrDi.app"

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]]; then
    echo "Нужна macOS 15 Sequoia или новее." >&2
    exit 1
fi

echo "→ ищу последнюю версию"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
if [[ -z "$URL" ]]; then
    echo "Не нашёл .dmg в последнем релизе: https://github.com/$REPO/releases" >&2
    exit 1
fi

TMP="$(mktemp -d)"
MOUNT="$TMP/mnt"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "→ скачиваю $(basename "$URL")"
curl -fL --progress-bar "$URL" -o "$TMP/MrDi.dmg"

mkdir -p "$MOUNT"
hdiutil attach "$TMP/MrDi.dmg" -mountpoint "$MOUNT" -nobrowse -quiet

echo "→ устанавливаю в /Applications"
pkill -x MrDi 2>/dev/null || true
rm -rf "$APP"
ditto "$MOUNT/MrDi.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ запускаю"
open "$APP"
echo "Готово. Иконка с шапочкой — в меню-баре справа вверху."
