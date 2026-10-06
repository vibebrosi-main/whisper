#!/bin/bash
# Lokalny certyfikat do podpisywania call-whisper.
#
# Bez konta Apple Developer `bundle.sh` podpisywał ad-hoc, a wtedy tożsamość
# aplikacji dla TCC to `cdhash`, czyli skrót samej binarki. Każda przebudowa
# dawała nowy skrót i zgoda na nagrywanie ekranu przepadała: przełącznik
# w Ustawieniach zostawał włączony, a aplikacja meldowała brak zgody.
#
# Z własnym certyfikatem wymaganie podpisu opiera się na certyfikacie, nie na
# binarce, więc zgoda przeżywa dowolną liczbę przebudów. Certyfikat trafia do
# pęku kluczy logowania i działa tylko lokalnie; nie nadaje się do
# dystrybucji aplikacji innym osobom.
#
#   bash macos/tools/make-cert.sh
set -euo pipefail

NAME="${CW_CERT_NAME:-call-whisper local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Certyfikat \"$NAME\" już jest w pęku kluczy."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Hasło p12 jest tylko na czas importu; plik znika razem z katalogiem.
# (`tr </dev/urandom | head` przy pipefail kończy się SIGPIPE i przerywa skrypt.)
PASS="$(/usr/bin/openssl rand -hex 16)"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Systemowe /usr/bin/openssl (LibreSSL): jego p12 `security import` przyjmuje.
# OpenSSL 3 z Homebrew domyślnie szyfruje p12 algorytmem, którego pęk kluczy
# nie czyta.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASS"

# -T: codesign może używać klucza bez pytania przy każdym podpisie.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Dodano certyfikat \"$NAME\" do pęku kluczy logowania."
echo "Przy pierwszym podpisie macOS może zapytać o dostęp do klucza: \"Zawsze pozwalaj\"."
