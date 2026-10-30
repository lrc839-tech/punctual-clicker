#!/bin/zsh
set -eu
setopt PIPE_FAIL
umask 077

# Explicit one-time setup, never called by build.sh. Requires the user's consent
# to add a dedicated private code-signing key to their login keychain.
if [[ "${1:-}" != "--create" || $# != 1 ]]; then
  print -- "Usage: setup-local-signing.sh --create"
  print -- "Creates 准点点击器本机开发 in the login keychain; changes no trust settings."
  exit 2
fi
signing_dir="$HOME/Library/Application Support/PunctualClicker/Signing"
identity_file="$signing_dir/local-identity.sha1"
certificate_name="准点点击器本机开发"
if [[ -f "$identity_file" ]]; then
  print -- "A persistent local identity is already configured; refusing to rotate it."
  exit 0
fi
if /usr/bin/security find-certificate -c "$certificate_name" >/dev/null 2>&1; then
  print -u2 -- "The named certificate already exists. Recover its configuration rather than creating another key."
  exit 3
fi
keychain=$( /usr/bin/security default-keychain -d user | /usr/bin/sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//' )
[[ -f "$keychain" ]] || { print -u2 -- "No existing user login keychain found."; exit 3; }
signing_temp=$(mktemp -d "${TMPDIR:-/tmp}/punctual-local-signing.XXXXXX")
trap 'rm -rf "$signing_temp"' EXIT
cat > "$signing_temp/certificate.conf" <<'CONF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
utf8 = yes
string_mask = utf8only
[subject]
CN = 准点点击器本机开发
OU = PunctualClicker Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$signing_temp/certificate.conf" -keyout "$signing_temp/private.key" \
  -out "$signing_temp/certificate.pem" >/dev/null 2>&1
# An ephemeral transport password, not the user's login/keychain password.
/usr/bin/openssl rand -hex 32 > "$signing_temp/transport-password"
/usr/bin/openssl pkcs12 -export -name "$certificate_name" \
  -inkey "$signing_temp/private.key" -in "$signing_temp/certificate.pem" \
  -out "$signing_temp/identity.p12" -passout "file:$signing_temp/transport-password" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
transport_password=$(<"$signing_temp/transport-password")
/usr/bin/security import "$signing_temp/identity.p12" -k "$keychain" \
  -f pkcs12 -P "$transport_password" -T /usr/bin/codesign
unset transport_password
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
/usr/bin/openssl x509 -in "$signing_temp/certificate.pem" -outform DER -out "$signing_dir/local-certificate.cer"
fingerprint=$(/usr/bin/openssl x509 -in "$signing_temp/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g')
[[ "$fingerprint" =~ '^[A-Fa-f0-9]{40}$' ]] || { print -u2 -- "Invalid certificate fingerprint."; exit 3; }
print -r -- "$fingerprint" > "$identity_file"
print -r -- "$keychain" > "$signing_dir/local-keychain.path"
print -- "Created persistent local code-signing identity: $fingerprint"
print -- "Private key stays in the user keychain; no system/root trust was added."
print -- "Public certificate and identity configuration: $signing_dir"
