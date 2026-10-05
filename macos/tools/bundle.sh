#!/bin/bash
# Składa .app z produktu SwiftPM.
#
# Sam plik wykonywalny nie wystarczy: ScreenCaptureKit i mikrofon chodzą przez
# TCC, a TCC identyfikuje aplikację po bundle ID i podpisie. Uruchomiony
# „gołym" binarnym plikiem program nigdy nie dostanie zgody na nagrywanie.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/call-whisper.app"
BUNDLE_ID="ai.callwhisper.mac"

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/call-whisper"

echo "==> składam $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/call-whisper"

# Silnik mowy w paczce: statyczny whisper-server z OpenWhispr (3,6 MB, tylko
# frameworki systemowe). Dzięki temu aplikacja nie potrzebuje Homebrew.
# Pobiera go sama aplikacja (`--install-engines`), więc adresy i sumy
# kontrolne są w jednym miejscu: Sources/CallWhisperKit/Engines.swift.
# Cache w macos/vendor, żeby nie pobierać przy każdym buildzie.
VENDOR="$ROOT/vendor"
if [ ! -x "$VENDOR/bin/whisper-server" ]; then
  echo "==> pobieram silnik mowy do $VENDOR"
  "$BIN" --install-engines "$VENDOR" whisper-server
fi
mkdir -p "$APP/Contents/Resources/bin"
cp "$VENDOR/bin/whisper-server" "$APP/Contents/Resources/bin/whisper-server"
# Diaryzacja (~100 MB) celowo nie jedzie w paczce: jest opcjonalna
# i aplikacja pobiera ją sama przy pierwszym użyciu.

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>call-whisper</string>
  <key>CFBundleDisplayName</key><string>call-whisper</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>call-whisper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Nagranie albo wideo</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.movie</string><string>public.audio</string></array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>Mikrofon służy do zapisania Twoich wypowiedzi w transkrypcie. Dźwięk nie opuszcza urządzenia — rozpoznawanie mowy działa lokalnie.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Rozpoznawanie mowy zamienia rozmowę na tekst. Model działa na urządzeniu.</string>
</dict>
</plist>
PLIST

# Podpis: stała tożsamość zamiast ad-hoc.
#
# To nie jest kosmetyka. TCC (zgody na nagrywanie ekranu i mikrofon) oraz
# Keychain identyfikują aplikację po *designated requirement* podpisu. Przy
# podpisie ad-hoc jest nim `cdhash H"..."`, czyli hash konkretnej binarki —
# każda przebudowa daje nowy hash, więc wydana zgoda przestaje obowiązywać
# i system prosi o nią od nowa (albo, gorzej, cicho odmawia mimo włączonego
# przełącznika w Ustawieniach).
#
# Z certyfikatem deweloperskim requirement opiera się na tożsamości certyfikatu
# i przeżywa dowolną liczbę przebudów.
IDENTITY="${CW_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -E "Apple Development|Developer ID Application|Apple Distribution" \
    | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

# Najpierw zagnieżdżona binarka, potem całość - podpis aplikacji pieczętuje
# zasoby, więc kolejność odwrotna unieważniłaby go.
HELPER="$APP/Contents/Resources/bin/whisper-server"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --options runtime "$HELPER" 2>&1 | sed 's/^/    /'
else
  codesign --force --sign - "$HELPER" 2>&1 | sed 's/^/    /'
fi

if [ -n "$IDENTITY" ]; then
  echo "==> podpisuję jako: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$ROOT/tools/entitlements.plist" \
    "$APP" 2>&1 | sed 's/^/    /'
else
  echo "==> podpisuję ad-hoc (brak certyfikatu deweloperskiego)"
  echo "    UWAGA: przy ad-hoc każda przebudowa unieważnia zgody TCC."
  codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP" 2>&1 | sed 's/^/    /'
fi

echo
echo "Gotowe: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Identifier=" | sed 's/^/    /'
echo
echo "Uruchom:  open $APP"
echo
echo "Przy pierwszym starcie macOS poprosi o dwie zgody:"
echo "  • Nagrywanie ekranu — potrzebne, bo ScreenCaptureKit tak wydaje dźwięk systemu"
echo "  • Mikrofon — tylko jeśli włączone w ustawieniach"
