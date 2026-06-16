#!/bin/bash
# Creates a stable, self-signed code-signing identity for Glance so macOS
# remembers the Accessibility permission across rebuilds.
#
# Why: by default build.sh ad-hoc-signs the app, which gives it a *new* code
# hash every build. macOS TCC (Privacy & Security) keys Accessibility on the
# signature, so each rebuild looks like a brand-new app and you're re-prompted.
# Signing with one fixed self-signed certificate keeps the signature stable, so
# you grant Accessibility ONCE and it sticks.
#
# Run this once: ./setup-signing.sh   (then ./build.sh signs with it)
# To undo:       security delete-keychain glance-signing.keychain
set -e
cd "$(dirname "$0")"

ID="Glance Self-Signed"
KC="glance-signing.keychain"
PW="glance-build"
KC_PATH="$HOME/Library/Keychains/${KC}-db"

if security find-certificate -c "$ID" "$KC" >/dev/null 2>&1; then
    echo "✓ Signing identity '$ID' already exists — nothing to do."
    echo "  (build.sh will use it automatically.)"
    exit 0
fi

echo "→ Generating a self-signed code-signing certificate…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Glance Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

# Export PKCS#12 with legacy algorithms so macOS's `security import` accepts it
# (OpenSSL 3's modern MAC/cipher defaults are rejected by Apple's importer).
if ! openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW" 2>/dev/null; then
    openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW" 2>/dev/null
fi

echo "→ Importing into a dedicated keychain (your login keychain is untouched)…"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign -A >/dev/null 2>&1
# Let codesign use the key without popping a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1
# Add to the keychain search list (preserving the existing list) so codesign finds it.
EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s $EXISTING "$KC"

echo "✓ Created signing identity '$ID' in $KC_PATH"
echo "  Next: ./build.sh   (it will sign with this identity)"
echo "  You'll need to grant Accessibility ONE more time after the next build,"
echo "  then it will stick across future rebuilds."
