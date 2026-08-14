#!/bin/bash
# Собирает MrDi.app. Запуск: ./scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP="build/MrDi.app"

if [[ ! -f Resources/AppIcon.icns || icon.png -nt Resources/AppIcon.icns || icon.svg -nt Resources/AppIcon.icns ]]; then
    echo "→ пересборка иконки"
    ./scripts/make-icon.sh
fi

echo "→ сборка ($CONFIG)"
swift build -c "$CONFIG"

echo "→ упаковка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/MrDi" "$APP/Contents/MacOS/MrDi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Подпись постоянным сертификатом — иначе разрешение «Универсальный доступ»
# слетает после каждой пересборки. Сертификат создаёт ./scripts/setup-signing.sh.
SIGN_ID="${MRDI_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    if security find-identity -v -p codesigning | grep -q "MrDi Dev"; then
        SIGN_ID="MrDi Dev"
    else
        SIGN_ID="-"
        echo "  ⚠️  постоянного сертификата нет — запустите ./scripts/setup-signing.sh,"
        echo "     иначе macOS будет спрашивать разрешение после каждой сборки"
    fi
fi
echo "→ подпись ($SIGN_ID)"
if ! codesign --force --sign "$SIGN_ID" --identifier com.mrdi.app --timestamp=none "$APP" 2>&1; then
    # связка ключей может спросить разрешение на использование приватного ключа;
    # если диалог отклонили, сборка не должна разваливаться
    echo "  ⚠️  подпись сертификатом не прошла — подписываю ad-hoc"
    echo "     разрешение «Универсальный доступ» после этого придётся выдать заново"
    echo "     чтобы диалог больше не появлялся, один раз выполните:"
    echo "     security set-key-partition-list -S apple-tool:,apple: -s -k ПАРОЛЬ_МАКА ~/Library/Keychains/login.keychain-db"
    codesign --force --sign - --identifier com.mrdi.app --timestamp=none "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
    echo "→ установка в /Applications"
    pkill -x MrDi || true
    rm -rf /Applications/MrDi.app
    cp -R "$APP" /Applications/
    open /Applications/MrDi.app
else
    echo "готово: $APP"
fi
