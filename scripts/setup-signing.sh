#!/bin/zsh
# Creates a stable self-signed code signing identity so macOS privacy grants
# (Accessibility) survive rebuilds. Ad-hoc signatures change on every build.
# Lives in a dedicated keychain whose password is local-only, so codesign never prompts.
set -euo pipefail
name="StepBar Local Signing"
keychain="$HOME/Library/Keychains/stepbar-signing.keychain-db"
password="stepbar-local-signing"
if [[ -f "$keychain" ]] && security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "Signing identity already exists: $name"; exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
p12pass=$(uuidgen)
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/identity.p12" -passout "pass:$p12pass"
[[ -f "$keychain" ]] || security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$p12pass" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# codesign only finds identities in keychains on the user search list.
if ! security list-keychains -d user | grep -q "stepbar-signing"; then
  security list-keychains -d user -s ${(f)"$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')"} "$keychain"
fi
echo "Created signing identity: $name ($keychain)"
