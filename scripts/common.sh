# Sourced by the deploy/install scripts. Ensures:
#  - a stable self-signed code-signing identity (so TCC / Local Network grants survive rebuilds),
#    kept in its own throwaway keychain so the login keychain is never touched
#  - the pre-shared key both Macs use to authenticate the connection
KC=$HOME/Library/Keychains/uc-signing.keychain-db
KCPW=uc

if ! security find-certificate -c "Unified Control Dev" "$KC" >/dev/null 2>&1; then
  echo "creating signing identity"
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Unified Control Dev" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/uc.p12" -passout pass:$KCPW
  security create-keychain -p $KCPW "$KC" 2>/dev/null || true
  security set-keychain-settings "$KC"
  security unlock-keychain -p $KCPW "$KC"
  security import "$T/uc.p12" -k "$KC" -P $KCPW -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $KCPW "$KC" >/dev/null
fi
security unlock-keychain -p $KCPW "$KC"

if [ ! -f ~/.unified-control/psk ]; then
  mkdir -p ~/.unified-control && chmod 700 ~/.unified-control
  (umask 077; openssl rand -hex 32 > ~/.unified-control/psk)
fi

sign() { codesign --force --sign "Unified Control Dev" --keychain "$KC" "$1"; }

# bundle <path.app> <bundle-id> <name> <executable> [extra plist xml]
bundle() {
  rm -rf "$1" && mkdir -p "$1/Contents/MacOS"
  cp ".build/release/$4" "$1/Contents/MacOS/"
  cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundleExecutable</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  ${5:-}
</dict></plist>
EOF
  sign "$1"
}
