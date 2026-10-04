#!/bin/bash
# Собирает MrDi-<версия>.dmg для распространения.
#
# Здесь намеренно ad-hoc-подпись, а не сертификат «MrDi Dev»: самоподписанный
# сертификат существует только в вашей связке ключей, и на чужом маке такая
# подпись не проходит проверку. Ad-hoc — это просто хэши кода, они валидны везде.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
DMG="build/MrDi-$VERSION.dmg"

MRDI_SIGN_ID=- ./scripts/build-app.sh

echo "→ сборка образа"
STAGING="$(mktemp -d)"
cp -R build/MrDi.app "$STAGING/MrDi.app"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/ПРОЧТИ МЕНЯ.txt" <<'NOTE'
Mr.Di. — установка
==================

Проще всего — одной командой в Терминале, без шагов ниже:

   curl -fsSL https://raw.githubusercontent.com/CryptoNerf/mr.di/main/scripts/install.sh | bash

Вручную:

1. Перетащите MrDi в папку «Программы» слева.

2. Откройте Терминал и выполните одну команду:

   xattr -d com.apple.quarantine /Applications/MrDi.app

3. Запустите приложение.

Зачем шаг 2
-----------
Приложение не заверено в Apple: заверение стоит 99$ в год, и автор пока
не может себе этого позволить. Из-за этого macOS помечает скачанный файл
карантином и при первом запуске говорит, что приложение «повреждено».
Оно не повреждено — команда выше просто снимает эту пометку.

Исходный код открыт, его можно прочитать и собрать самому:
https://github.com/CryptoNerf/mr.di
NOTE

rm -f "$DMG"
hdiutil create -volname "Mr.Di." -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "готово: $DMG ($(du -h "$DMG" | cut -f1))"
