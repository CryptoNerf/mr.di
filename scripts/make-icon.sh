#!/bin/bash
# Пересобирает Resources/AppIcon.icns из icon.svg
set -euo pipefail
cd "$(dirname "$0")/.."

# icon.png имеет приоритет над icon.svg
if [[ -f icon.png ]]; then
    SOURCE=icon.png
    RATIO=1.0        # свободная форма: поля уже есть в самом рисунке
else
    SOURCE=icon.svg
    RATIO=0.8047     # плашка: тело 824 на холсте 1024, как у системных иконок
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
echo "→ источник: $SOURCE"
swift scripts/render-icon.swift "$SOURCE" "$ICONSET" "$RATIO"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "готово: Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
