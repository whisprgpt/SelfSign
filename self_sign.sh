#!/bin/bash
set -e

#################################
# Pretty printing (output only)
#################################
bold() { tput bold 2>/dev/null || true; }
norm() { tput sgr0 2>/dev/null || true; }
grn()  { tput setaf 2 2>/dev/null || true; }
ylw()  { tput setaf 3 2>/dev/null || true; }
red()  { tput setaf 1 2>/dev/null || true; }
note() { echo "$(bold)$(ylw)[•]$(norm) $*"; }
ok()   { echo "$(bold)$(grn)[✓]$(norm) $*"; }
err()  { echo "$(bold)$(red)[x]$(norm) $*" >&2; }
bar()  { printf "\n%s\n" "$(bold)── $* ──$(norm)"; }

#################################
# Config (unchanged)
#################################
APP="/Applications/wTerm.app"
KC_FILE_NAME="ldb.keychain-db"
KC_PASSWORD="whisprgpt"
KC_FILE_PATH="$HOME/Library/Keychains/$KC_FILE_NAME"

USER_NAME="$(whoami)"
HOST_NAME="$(hostname | cut -d. -f1)"
P12_PASS="$KC_PASSWORD"
KEYCHAIN="$KC_FILE_PATH"
KEY_LABEL="MyCodeSigningKey"
CERT_CN="$HOST_NAME-$USER_NAME"
OU="$USER_NAME"
O="$HOST_NAME"
C="US"
DAYS=365

CSR_FILE="MyCodeSigningCert.csr"
CER_FILE="MyCodeSigningCert.cer"

#################################
# Steps (commands preserved)
#################################
create_keychain_if_missing() {
  bar "Keychain"
  if [ ! -f "$KC_FILE_PATH" ]; then
    note "Creating keychain: $KC_FILE_PATH"
    security create-keychain -p "$KC_PASSWORD" "$KC_FILE_NAME"
    ok "Keychain created"
  else
    ok "Keychain already exists: $KC_FILE_PATH (skipping create)"
  fi
}

ensure_in_search_list() {
  bar "Keychain Search List"
  current_list=$(security list-keychains -d user | sed 's/^"//; s/"$//')
  if echo "$current_list" | grep -qx "$KC_FILE_PATH"; then
    ok "Already in keychain search list: $KC_FILE_PATH"
  else
    note "Adding to keychain search list: $KC_FILE_PATH"
    security list-keychains -d user -s $(security list-keychains -d user | sed -e s/\"//g) "$KC_FILE_PATH"
    ok "Added to search list"
  fi
}

unlock_and_show_list() {
  bar "Unlock & Show Search List"
  security unlock-keychain -p "$KC_PASSWORD" "$KC_FILE_PATH"
  ok "Unlocked $KC_FILE_PATH"
  note "Active search list:"
  security list-keychains
}

generate_cert_materials() {
  bar "Generate Code Signing Cert (openssl → import)"
  note "Generating private key"
  openssl genrsa -out codesign.key 2048

  note "Generating CSR → $CSR_FILE"
  openssl req -new -key codesign.key -out "$CSR_FILE" \
    -subj "/CN=${CERT_CN}/OU=${OU}/O=${O}/C=${C}"

  note "Self-signing cert → $CER_FILE"
  openssl x509 -req -in "$CSR_FILE" -signkey codesign.key -days "$DAYS" \
    -out "$CER_FILE" \
    -extfile <(printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\nbasicConstraints=CA:false\n")

  if openssl version 2>/dev/null | grep -q 'OpenSSL 3'; then
    PKCS12_COMPAT_FLAGS="-legacy"
  else
    PKCS12_COMPAT_FLAGS=""
  fi

  if [ -n "$PKCS12_COMPAT_FLAGS" ]; then
    note "Packaging key+cert into PKCS#12 (OpenSSL 3.x → using -legacy) → codesign.p12"
  else
    note "Packaging key+cert into PKCS#12 (modern) → codesign.p12"
  fi

  openssl pkcs12 -export $PKCS12_COMPAT_FLAGS \
    -inkey codesign.key -in "$CER_FILE" \
    -name "${CERT_CN}" -out codesign.p12 \
    -passout pass:"$P12_PASS"

  ok "Key / CSR / Cert / P12 generated"
}

import_identity_and_cert() {
  bar "Import Identity"
  note "Importing PKCS#12 into $KC_FILE_PATH"
  security import codesign.p12 -k "$KC_FILE_PATH" -P "$P12_PASS" -A -T /usr/bin/codesign
  ok "PKCS#12 imported"

  if ! security find-certificate -c "$CERT_CN" "$KC_FILE_PATH" >/dev/null 2>&1; then
    note "Importing CER into $KC_FILE_PATH"
    security import "$CER_FILE" -k "$KC_FILE_PATH" -A -T /usr/bin/codesign
    ok "CER imported"
  else
    ok "CER already present (skipping)"
  fi

  bar "Trust Settings"
  note "Marking cert as user trust root"
  security add-trusted-cert -d -r trustRoot -k "$KC_FILE_PATH" "$CER_FILE"
  ok "Trust applied"
}

show_identities() {
  bar "Available Code Signing Identities"
  security find-identity -v -p codesigning "$KC_FILE_PATH"
  echo
  echo "▶ Using keychain: $KEYCHAIN"
  echo "▶ Key label:      $KEY_LABEL"
  echo "▶ Cert CN:        $CERT_CN"
  echo "▶ App to sign:    $APP"
  echo
}

grant_key_access() {
  bar "Key Access (Partition List)"
  note "Granting Apple tools access to private key for '$CERT_CN'"
  security set-key-partition-list \
    -S apple-tool:,apple: -s \
    -D "$CERT_CN" \
    -t private \
    -k "$KC_PASSWORD" \
    "$KEYCHAIN"
  ok "Partition list updated"
}

sign_app() {
  bar "Sign App"
  if [ ! -d "$APP" ]; then
    err "App not found at: $APP"
    exit 1
  fi

  note "Finding identity SHA for CN: $CERT_CN"
  IDENT_SHA=$(security find-identity -v -p codesigning "$KC_FILE_PATH" \
    | awk -v cn="$CERT_CN" '$0 ~ cn {print $2; exit}')

  if [ -z "$IDENT_SHA" ]; then
    err "No matching codesigning identity found for CN: $CERT_CN in $KC_FILE_PATH"
    security find-identity -v -p codesigning "$KC_FILE_PATH" || true
    exit 1
  fi

  note "Using identity SHA-1: $IDENT_SHA"
  codesign --force --deep --timestamp=none \
    --keychain "$KC_FILE_PATH" \
    --sign "$IDENT_SHA" "$APP"
  ok "App signed"
}

clear_quarantine_if_needed() {
  bar "Quarantine"
  if xattr "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    note "Clearing com.apple.quarantine from app"
    xattr -dr com.apple.quarantine "$APP"
    ok "Quarantine cleared"
  else
    ok "No quarantine attribute detected"
  fi
}

verify_signature_and_gatekeeper() {
  bar "Verify Signature"
  note "codesign -dv --verbose=4"
  codesign -dv --verbose=4 "$APP" || true

  echo
  note "Gatekeeper assessment (not notarized is expected for self-signed)"
  spctl --assess --type execute --verbose=4 "$APP" || true
  ok "Verification step done"
}

#################################
# Main (order preserved)
#################################
main() {
  bar "Config"
  cat <<EOF
  App:           $APP
  Keychain:      $KC_FILE_PATH
  Cert CN:       $CERT_CN
  OU / O / C:    $OU / $O / $C
  Valid (days):  $DAYS
EOF

  create_keychain_if_missing
  ensure_in_search_list
  unlock_and_show_list
  generate_cert_materials
  import_identity_and_cert
  show_identities
  grant_key_access
  sign_app
  clear_quarantine_if_needed
  verify_signature_and_gatekeeper

  bar "Done"
  rm -f codesign.key "$CSR_FILE" "$CER_FILE" codesign.p12
  ok "Removed generated files"
  echo "✅ Your user keychain now trusts \"$CERT_CN\" for code signing, and the app is signed."
  echo "⚠️ On THIS Mac, first launch may still require right-click → Open once (self-signed, not notarized)."
}

main "$@"
