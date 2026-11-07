#!/bin/bash
# Creates (once) a stable self-signed code-signing identity so macOS TCC
# permissions (Accessibility, Microphone, Speech) survive rebuilds.
# Idempotent: exits early if the identity is already in the keychain.
set -euo pipefail

IDENTITY="LocalFlow Local Signing"
SIGN_DIR="$HOME/Library/Application Support/LocalFlow/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12="$SIGN_DIR/localflow-signing.p12"
CRT="$SIGN_DIR/localflow-signing.crt"
KEY="$SIGN_DIR/localflow-signing.key"
CONF="$SIGN_DIR/openssl.cnf"
PWFILE="$SIGN_DIR/localflow-signing.password"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Signing identity '$IDENTITY' already in keychain — nothing to do."
    exit 0
fi

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

if [[ ! -f "$P12" ]]; then
    if [[ ! -f "$PWFILE" ]]; then
        openssl rand -hex 24 > "$PWFILE"
    fi
    chmod 600 "$PWFILE"
    PW="$(cat "$PWFILE")"

    # Self-signed code-signing certificate: RSA 2048, 10 years, leaf (not a CA).
    cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY" -out "$CRT" -days 3650 \
        -config "$CONF" 2>/dev/null
    chmod 600 "$KEY" "$CRT" "$CONF"

    # Export PKCS#12. OpenSSL 3.x needs legacy PBE algorithms or `security import` fails.
    if openssl version | grep -q "^OpenSSL 3"; then
        openssl pkcs12 -export -out "$P12" -inkey "$KEY" -in "$CRT" \
            -name "$IDENTITY" -passout "pass:$PW" \
            -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    else
        openssl pkcs12 -export -out "$P12" -inkey "$KEY" -in "$CRT" \
            -name "$IDENTITY" -passout "pass:$PW"
    fi
    chmod 600 "$P12"
fi

PW="$(cat "$PWFILE")"
security import "$P12" -k "$KEYCHAIN" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign

# Best-effort: mark the cert trusted for code signing so `codesign -v` is clean.
# This can open a GUI authorization prompt; signing works without it, so don't fail.
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CRT" 2>/dev/null; then
    echo "note: could not mark the certificate trusted (GUI auth may be required);"
    echo "      signing still works — the designated requirement is certificate-based either way."
fi

if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "OK: '$IDENTITY' is now available for codesigning."
else
    echo "ERROR: p12 import did not produce a usable identity." >&2
    exit 1
fi
