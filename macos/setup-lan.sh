#!/bin/bash
# The root half of putting code-server on the LAN. Three things that each need
# sudo, so they are one script you can read before running rather than lines
# pasted out of a README.
#
#   sudo ./macos/setup-lan.sh            set it up / repair it
#   sudo ./macos/setup-lan.sh --pin      nail the address down on this network
#   sudo ./macos/setup-lan.sh --unpin    hand it back to DHCP
#
# Safe to re-run on any network; that is the point. After a code-server upgrade
# the firewall rule names a path that no longer exists, so re-running is the fix.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "needs root: sudo $0" >&2; exit 1; }
: "${SUDO_USER:?run this with sudo from your own account, not as root}"

HOSTNAME_SHORT=ekomardiatno
WIFI_SERVICE=Wi-Fi
IFACE=en0
MODE=${1:-setup}

say() { printf '  %s\n' "$*"; }

# 1. Bonjour name ------------------------------------------------------------
# LocalHostName is the one mDNSResponder advertises as <name>.local. ComputerName
# is only the Finder-visible label and HostName is the (unset) static one; both
# are left alone, because neither affects mDNS.
echo "[1/3] Bonjour name"
if [[ $(scutil --get LocalHostName) == "$HOSTNAME_SHORT" ]]; then
  say "already $HOSTNAME_SHORT.local"
else
  scutil --set LocalHostName "$HOSTNAME_SHORT"
  say "LocalHostName -> $HOSTNAME_SHORT.local"
fi

# 2. The address -------------------------------------------------------------
# Bonjour tracks the address by itself, so .local survives a new lease. The
# certificate's IP SAN does not — and since Android has no mDNS resolver, the
# literal IP is the only address some clients can use. So the address wants to
# be stable.
#
# It does not want to be stable by being *pinned here*, though. A manual address
# is only valid on the subnet it came from, so pinning turns every other network
# the laptop joins into "wifi is broken for no visible reason". The right place
# to make it stable is a DHCP reservation on the router: the Mac stays on plain
# DHCP and roams freely, while the address stays put at home.
#
# Hence this step only reports by default. --pin is there for a machine that
# never moves.
echo "[2/3] address"
IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
ROUTER=$(ipconfig getoption "$IFACE" router 2>/dev/null || true)
PINNED=$(networksetup -getinfo "$WIFI_SERVICE" | grep -q 'Manually Using DHCP Router' && echo yes || echo no)

case $MODE in
  --unpin)
    if [[ $PINNED == yes ]]; then
      networksetup -setdhcp "$WIFI_SERVICE"
      say "$WIFI_SERVICE back on plain DHCP"
      say "re-issue the cert once the new address settles: ./macos/issue-cert.sh"
    else
      say "already on DHCP"
    fi
    ;;
  --pin)
    [[ -n $IP ]] || { echo "no address on $IFACE — join a network first" >&2; exit 1; }
    # Whatever DHCP just handed out, kept. Detecting it beats taking an argument:
    # the script is then correct on any network instead of only on one.
    networksetup -setmanualwithdhcprouter "$WIFI_SERVICE" "$IP"
    say "$WIFI_SERVICE pinned to $IP (the address DHCP had just given it)"
    say "this will break on other networks — undo with: sudo $0 --unpin"
    ;;
  *)
    [[ -n $IP ]] || { echo "no address on $IFACE — join a network first" >&2; exit 1; }
    if [[ $PINNED == yes && -n $ROUTER && ${IP%.*} != "${ROUTER%.*}" ]]; then
      say "WARNING: pinned to $IP but this network's router is $ROUTER"
      say "         run: sudo $0 --unpin"
    elif [[ $PINNED == yes ]]; then
      say "$IP (pinned on this machine — a router reservation would roam better)"
    else
      say "$IP (from DHCP; reserve it in the router to keep it)"
    fi
    ;;
esac

# 3. Application firewall ----------------------------------------------------
# bind-addr is 0.0.0.0, which means every network the laptop ever joins and not
# just this one. The firewall is what keeps that from meaning "every café".
echo "[3/3] application firewall"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

# The rule has to name the binary that actually holds the socket. `code-server`
# is a shell wrapper; the listener is the node it execs, at a version-numbered
# path — which is why this script needs re-running after an upgrade.
CS_LINK=$(readlink /usr/local/bin/code-server)
NODE=$(cd "$(dirname "$CS_LINK")/.." && pwd)/lib/node
[[ -x $NODE ]] || { echo "no node at $NODE" >&2; exit 1; }

"$FW" --setglobalstate on >/dev/null
"$FW" --setstealthmode on >/dev/null
"$FW" --add "$NODE" >/dev/null
"$FW" --unblockapp "$NODE" >/dev/null

say "$("$FW" --getglobalstate)"
say "$("$FW" --getblockall)        <- must be off, it overrides per-app allows"
say "$("$FW" --getstealthmode)  <- so ping will not answer; test with curl"
say "node: $NODE"

[[ $MODE == --unpin ]] && exit 0

# The certificate names an address and a hostname, and both of them just moved
# if either step above changed anything. A stale IP SAN is a name mismatch, and
# iOS Safari offers no way past one.
CERT=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory \
       | awk '{print $2}')/.config/code-server/tls/cert.pem
if [[ -f $CERT ]]; then
  # Trailing comma so the comparison respects item boundaries: a bare substring
  # test would accept IP Address:192.168.1.25 as covering 192.168.1.2.
  SANS="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | tail -1),"
  echo
  if [[ $SANS == *"IP Address:$IP,"* && $SANS == *"DNS:$HOSTNAME_SHORT.local,"* ]]; then
    say "certificate covers $HOSTNAME_SHORT.local and $IP"
  else
    say "certificate does NOT cover $HOSTNAME_SHORT.local + $IP — re-issue it:"
    say "  ./macos/issue-cert.sh"
  fi
fi

echo
echo "done — https://$HOSTNAME_SHORT.local:8093   (Apple devices)"
echo "       https://$IP:8093            (Android, Windows, anything)"
