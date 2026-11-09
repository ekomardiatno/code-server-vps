#!/bin/bash
# Issue the self-signed certificate for whatever this machine is currently
# called and wherever it currently is on the network. Needs no root — nothing
# it touches is outside ~/.config/code-server.
#
#   ./macos/issue-cert.sh
#
# Run it whenever the LAN address changes. The cert is disposable, so there is
# no backup: regenerating takes a second and the old one has no value.
set -euo pipefail

# Under sudo this would write a root-owned key into your home directory and then
# ask launchd for gui/0, which does not exist — "125: Domain does not support
# specified action". Refusing is clearer than half-working.
[[ $EUID -eq 0 ]] && { echo "do not run this with sudo: ${0#./}" >&2; exit 1; }

IFACE=${IFACE:-en0}
DIR=${DIR:-$HOME/.config/code-server/tls}
LABEL=id.my.ekomardiatno.code-server

NAME=$(scutil --get LocalHostName).local
IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
[[ -n $IP ]] || { echo "no address on $IFACE — join a network first" >&2; exit 1; }

mkdir -p "$DIR" && cd "$DIR"

# Three of these are requirements rather than preferences. Apple platforms want
# the serverAuth EKU present and reject anything over 825 days outright, and the
# IP SAN is load-bearing because .local is mDNS-only — non-Apple clients can
# only reach this machine by its literal address.
openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=$NAME" \
  -addext "subjectAltName=DNS:$NAME,DNS:localhost,IP:$IP,IP:127.0.0.1" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

chmod 600 key.pem
chmod 644 cert.pem

openssl x509 -in cert.pem -noout -subject -dates -ext subjectAltName

# config.yaml points at these by path and code-server reads them at startup, so
# a restart is the whole deployment step.
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3

echo
for u in "https://$NAME:8093" "https://$IP:8093"; do
  # Passing our own cert as the CA separates the two failure modes: verify=0
  # means the SANs are right, and the only complaint left for a browser to make
  # is the unknown issuer — which it offers to click past. A name mismatch is
  # the one iOS Safari will not.
  printf '  %-34s %s\n' "$u" \
    "$(curl -s --cacert cert.pem -m 6 -o /dev/null \
       -w 'http=%{http_code} verify=%{ssl_verify_result}' "$u/login")"
done
