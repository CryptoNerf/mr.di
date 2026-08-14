#!/bin/bash
# Создаёт постоянный самоподписанный сертификат для подписи MrDi.
#
# Зачем: macOS привязывает разрешение «Универсальный доступ» к подписи приложения.
# Ad-hoc-подпись меняется при каждой пересборке, и разрешение каждый раз слетает —
# в списке галочка стоит, а доступа фактически нет. С постоянным сертификатом
# разрешение выдаётся один раз и переживает любое количество пересборок.
#
# Удалить потом: security delete-certificate -c "MrDi Dev"
set -euo pipefail

NAME="MrDi Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "сертификат «$NAME» уже есть"
    exit 0
fi

OPENSSL=/usr/bin/openssl        # системный LibreSSL даёт PKCS12 в формате, который понимает security(1)
PASS=mrdi-dev
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ генерация ключа и сертификата"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$PASS"

echo "→ импорт в связку ключей"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -A -T /usr/bin/codesign

echo "→ доверие сертификату для подписи кода"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME" || {
    echo "сертификат создан, но codesign его не видит"; exit 1; }
echo "готово"
