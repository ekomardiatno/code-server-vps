# code-server on macOS

The local twin of `code.jalanpintas.web.id`, on an Intel Mac (macOS 15.8.1,
x86_64), reachable from any device on the same wifi:

```
https://ekomardiatno.local:8093     Apple devices
https://192.168.1.2:8093            everything else
```

Same editor, same login theme, same config shape as the VPS. What differs
follows from one fact: **there is no nginx here, so code-server is its own
edge.**

| | VPS | this Mac |
| --- | --- | --- |
| bind | `127.0.0.1:8080` behind nginx | `0.0.0.0:8093`, nothing in front |
| port | 443, nginx proxies | 8093, in the URL |
| name | DNS A record | mDNS / Bonjour (§4) |
| TLS | Let's Encrypt, terminated by nginx | self-signed, terminated by code-server |
| process manager | systemd unit | launchd LaunchAgent |
| install | `dpkg -i` the `.deb` | standalone tarball under `$HOME` |

> **`0.0.0.0` is every network the laptop joins, not just home wifi.** A café
> hotspot counts. code-server hands out a terminal, so whoever gets the password
> owns the machine. The macOS application firewall (§5) is what keeps this
> honest — if it is ever switched off, put `bind-addr` back to `127.0.0.1` until
> it is on again.

Sections 4 and 5 need root, so they are one readable script rather than lines
pasted out of this file:

```sh
cd ~/Desktop/projects/code-server-vps && sudo ./macos/setup-lan.sh
```

It is idempotent, and re-running it is the fix after a code-server upgrade. The
rest of this page explains what it does and why.

---

## 1. Install — the standalone tarball, not Homebrew

`brew install code-server` **compiles the entire dependency tree from source on
Intel macOS.** Homebrew no longer ships bottles for x86_64 Sequoia, so the
formula pulls in `openssl@4`, `python@3.15` and `node@22` and builds each one.
It is not broken, just very slow, and it leaves three large formulae installed
to run an editor that ships its own Node.

The official release is a tarball with Node bundled:

```sh
VER=4.145.2
cd /tmp
curl -fLO "https://github.com/coder/code-server/releases/download/v$VER/code-server-$VER-macos-amd64.tar.gz"
shasum -a 256 "code-server-$VER-macos-amd64.tar.gz"
# compare against the checksum on the release page before extracting
# 4.145.2 = 5fb7ac2bd60538400244d942f649559e0ff4fb3d8792979287f504780f357af6

mkdir -p ~/.local/lib
tar -xzf "code-server-$VER-macos-amd64.tar.gz" -C ~/.local/lib
```

### Put the symlink in `/usr/local/bin`, not `~/.local/bin`

```sh
ln -sfn ~/.local/lib/code-server-$VER/bin/code-server /usr/local/bin/code-server
code-server --version   # 4.145.2 … with Code 1.145.2
```

> **`~/.local/bin` on this machine is owned by root** (`drwxr-xr-x root staff`,
> created by a `sudo` install of something else), so `ln` there fails with
> *Permission denied*. `/usr/local/bin` is `ekomardiatno:admin` and
> group-writable thanks to Homebrew, so it needs no `sudo`.

Everything downstream points at the **symlink**, so a version bump is a re-link
and nothing else has to change.

---

## 2. Config

```sh
mkdir -p ~/.config/code-server
cp ~/Desktop/projects/code-server-vps/config.yaml.example ~/.config/code-server/config.yaml
chmod 600 ~/.config/code-server/config.yaml
```

Generate the password and its hash:

```sh
brew install argon2          # already present on this machine

PW=$(openssl rand -base64 18)
SALT=$(openssl rand -hex 8)
printf '%s' "$PW" | argon2 "$SALT" -id -e -t 3 -m 12 -p 1
echo "$PW"                   # put this in the password manager, then clear it
```

> **The `-id` flag is not optional.** The reference `argon2` CLI defaults to
> **argon2i**, and code-server only accepts **argon2id**. A correct hash starts
> `$argon2id$v=19$m=4096,t=3,p=1$…` — if yours says `$argon2i$`, you will get a
> login page that rejects the right password with no useful error.

Paste the hash into `hashed-password:`. The live file:

```yaml
bind-addr: 0.0.0.0:8093
auth: password
hashed-password: "$argon2id$v=19$m=4096,t=3,p=1$…"
cert: /Users/ekomardiatno/.config/code-server/tls/cert.pem
cert-key: /Users/ekomardiatno/.config/code-server/tls/key.pem
disable-telemetry: true
disable-update-check: true
```

`disable-update-check` because upgrades here are a deliberate re-download, not a
nag. Everything else that could be a CLI flag lives in this file so there is one
source of truth — the LaunchAgent passes **no** arguments.

---

## 3. TLS for the LAN

code-server has a `cert: true` shortcut that generates a certificate for you.
**Don't use it here.** The cert it generates names `localhost` and nothing else,
so reaching the machine as `ekomardiatno.local` or `192.168.1.2` fails *name
validation* on top of being untrusted — and iOS Safari offers no "visit this
website anyway" for a name mismatch, only for an unknown issuer. You end up
locked out of the exact devices you opened the port for.

Issue one with the right names instead. `macos/issue-cert.sh` reads the hostname
and the current address off the machine rather than taking arguments, so it is
also the fix after either one changes — it re-issues, restarts code-server, and
verifies both URLs:

```sh
./macos/issue-cert.sh          # no root; everything is under ~/.config
```

> **Not with `sudo`** — the script refuses. `launchctl` would be asked for
> `gui/0`, which does not exist (`125: Domain does not support specified
> action`), and the key would land in your home directory owned by root.

```
NAME=$(scutil --get LocalHostName).local
IP=$(ipconfig getifaddr en0)

openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=$NAME" \
  -addext "subjectAltName=DNS:$NAME,DNS:localhost,IP:$IP,IP:127.0.0.1" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "basicConstraints=critical,CA:FALSE"
```

Three details that are requirements, not preferences:

- **825 days** is Apple's ceiling for server certificates. Longer and iOS/macOS
  reject it outright.
- **`extendedKeyUsage=serverAuth`** — Apple platforms require the EKU to be
  present.
- **The IP SAN is load-bearing, not a convenience.** Non-Apple clients cannot
  resolve `.local` at all (§4), so the literal address is the only one they can
  use — which also means **the certificate goes stale the moment the address
  moves.** `setup-lan.sh` checks for exactly that and tells you to re-issue.

The cert is disposable, so `issue-cert.sh` keeps no backup. Check it by hand
with:

```sh
cd ~/.config/code-server/tls
openssl x509 -in cert.pem -noout -subject -dates -ext subjectAltName,extendedKeyUsage
openssl rsa  -in key.pem  -noout -modulus | shasum
openssl x509 -in cert.pem -noout -modulus | shasum   # same digest = a real pair
```

Each device shows a one-time "this connection is not private" warning — that is
the unknown issuer, and it is expected. Accept it once per device. To remove the
warning entirely you would need a local CA (`mkcert`) installed on every device.

---

## 4. The LAN name

`LocalHostName` is the name mDNSResponder advertises as `<name>.local`, and
Bonjour keeps it pointing at the current address by itself:

```sh
sudo scutil --set LocalHostName ekomardiatno
```

> `ComputerName` ("Eko's MacBook Pro") is only the Finder-visible label and
> `HostName` is the static one, unset here. Neither affects mDNS. Changing
> `LocalHostName` is what moves the `.local` name.

### `.local` is an Apple-only address

**`.local` is mDNS-only, and Android has no mDNS resolver.** Chrome on Android
will not resolve *any* `.local` name — not `ekomardiatno.local`, not a
subdomain of it, not with a port. The namespace is the problem, not the name.
Non-Apple clients get the literal address instead:

```
https://ekomardiatno.local:8093     macOS, iOS, iPadOS
https://192.168.1.2:8093            Android, Windows, Linux
```

Which makes the address load-bearing: it is baked into the certificate and typed
into a tablet, and a two-hour DHCP lease is no foundation for either.

**Make it stable on the router, not on the Mac.** A DHCP reservation for this
machine's wifi MAC means the Mac stays on plain DHCP and roams freely, while the
address stays put at home:

```sh
networksetup -getmacaddress Wi-Fi     # the MAC to reserve
```

`setup-lan.sh` therefore only *reports* the address by default, and warns if a
previously pinned one no longer belongs to the network you are on. It detects
rather than hardcodes, so it is correct on any network.

> **`--pin` exists for a machine that never moves.** It keeps whatever DHCP had
> just handed out, via `networksetup -setmanualwithdhcprouter` — macOS's "Using
> DHCP with manual address", router and DNS still from DHCP. The catch is that a
> manual address only means anything on the subnet it came from, so on a laptop
> every other network becomes "wifi is broken for no visible reason", with an
> `--unpin` needed by hand each time:
>
> ```sh
> sudo ./macos/setup-lan.sh --pin       # fixed machines only
> sudo ./macos/setup-lan.sh --unpin     # back to plain DHCP
> ./macos/issue-cert.sh                 # re-issue for the new address
> ```

> **Two routes that look tempting and are not worth it.** `dns-sd -P` can
> publish a *subdomain* like `code.ekomardiatno.local`, which mDNSResponder
> refuses to do on its own — but it needs a literal address, dies with its
> process, and still does not help Android, so it buys nothing. And a `pf`
> redirect can move 443 to 8093 so the port disappears from the URL, at the cost
> of an `/etc/pf.conf` edit that macOS updates revert plus a root LaunchDaemon
> to enable pf at boot. A port number is cheaper than either.
>
> If you ever do want one name that works everywhere, the answer is real DNS: an
> A record on a domain you own pointing at the LAN address. Verified that this
> router does not strip private IPs from public answers (`localtest.me` resolves
> to `127.0.0.1` through it), so it would work — and it would also make a
> trusted Let's Encrypt certificate possible via DNS-01.

---

## 5. Firewall

Binding to `0.0.0.0` without this is the part that turns a convenience into a
liability, because it applies on every network the laptop ever joins.

```sh
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
NODE=~/.local/lib/code-server-4.145.2/lib/node

sudo $FW --setglobalstate on
sudo $FW --add "$NODE"
sudo $FW --unblockapp "$NODE"
sudo $FW --setstealthmode on      # don't answer pings and probes from strangers

$FW --getglobalstate && $FW --getblockall
```

> **The rule has to name the `node` binary, not `/usr/local/bin/code-server`.**
> `code-server` is a shell wrapper; the thing that holds the socket is the
> bundled Node, and the firewall matches on the executable that actually
> listens. That path contains the version number, so **re-run `setup-lan.sh`
> after every upgrade** — a rule pointing at a deleted binary silently stops
> matching, and the new binary gets the default prompt instead.

> `--getblockall` must say **off**. "Block all incoming connections" overrides
> per-app allows, so the editor would be unreachable with no error anywhere
> except a timeout.

`--setstealthmode on` stops the Mac announcing itself to anything scanning the
network. It also means **`ping ekomardiatno.local` gets no reply** — use `curl`
to test reachability, not ping.

---

## 6. Autostart — a LaunchAgent

The systemd equivalent. Lives at
`~/Library/LaunchAgents/id.my.ekomardiatno.code-server.plist` — the label is the
reverse-DNS of `ekomardiatno.my.id`, which is the convention that keeps it
obviously yours in `launchctl list`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>id.my.ekomardiatno.code-server</string>

	<!-- The symlink, not the versioned path: an upgrade is then just a re-link. -->
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/code-server</string>
	</array>

	<!-- Everything else (bind-addr, auth, hash) comes from
	     ~/.config/code-server/config.yaml so there is one source of truth. -->

	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>

	<key>WorkingDirectory</key>
	<string>/Users/ekomardiatno</string>

	<!-- A LaunchAgent inherits almost no environment. HOME is what code-server
	     uses to find its config and extensions; the PATH is a sane default for
	     tasks and the integrated terminal before a login shell overrides it. -->
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>/Users/ekomardiatno</string>
		<key>PATH</key>
		<string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>

	<key>StandardOutPath</key>
	<string>/Users/ekomardiatno/Library/Logs/code-server.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/ekomardiatno/Library/Logs/code-server.log</string>

	<!-- It is an editor you type into, so keep it out of the background
	     CPU/IO throttling tiers. -->
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
```

Load it:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/id.my.ekomardiatno.code-server.plist
```

Day-to-day:

```sh
launchctl kickstart -k gui/$(id -u)/id.my.ekomardiatno.code-server   # restart
launchctl print     gui/$(id -u)/id.my.ekomardiatno.code-server      # state + pid
launchctl bootout   gui/$(id -u)/id.my.ekomardiatno.code-server      # stop + unload
tail -f ~/Library/Logs/code-server.log
```

> **There is no macOS equivalent of the `MemoryHigh`/`MemoryMax` caps in
> `systemd/`.** launchd has no memory cgroup. The VPS needs them because it has
> 2 GB and other tenants; a laptop does not.

---

## 7. The login theme

Identical files to the VPS, different destination. `apply.sh` takes an override:

```sh
cd ~/Desktop/projects/code-server-vps
CODE_SERVER_PAGES=~/.local/lib/code-server-4.145.2/src/browser/pages ./apply.sh
```

The standalone release uses the same `src/browser/pages` layout as the `.deb`,
so nothing else changes. That directory is **user-owned** here, so apply.sh's
`sudo` is unnecessary — harmless, but it will prompt.

One install-time edit afterwards, in `login.html`:

```html
<div class="wordmark-sub">ekomardiatno.local:8093</div>   <!-- was code.jalanpintas.web.id -->
```

**Do not commit that.** It is a local edit and `apply.sh` reverts it on every
run, which is the correct behaviour — the repo describes the VPS.

---

## 8. The editor theme

[`ekomardiatno/pingwin-vscode-theme`](https://github.com/ekomardiatno/pingwin-vscode-theme)
— colours, file icons and the workbench UI font. Cloned once and **symlinked**
into the extensions folder, so edits to the repo are live after a reload:

```sh
ln -sfn ~/Desktop/projects/pingwin-vscode-theme \
        ~/.local/share/code-server/extensions/ekomardiatno.pingwin-vscode-theme

cd ~/Desktop/projects/pingwin-vscode-theme && ./workbench/apply.sh
```

`~/.local/share/code-server/User/settings.json`:

```json
{
  "workbench.colorTheme": "Pingwin",
  "workbench.iconTheme": "pingwin",
  "editor.fontFamily": "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
  "editor.fontLigatures": true,
  "editor.fontSize": 13,
  "terminal.integrated.fontFamily": "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
  "terminal.integrated.fontSize": 12
}
```

JetBrains Mono does **not** need to be installed on the machine: `apply.sh`
declares it as an `@font-face` in the same document the editor renders into.

---

## 9. Verify

The moving parts, in the order a request meets them:

```sh
# the name resolves, and to this machine
dns-sd -timeout -G v4 ekomardiatno.local           # Add … 192.168.1.2
ipconfig getifaddr en0                             # and matches the cert's IP SAN

# the editor is listening on every interface (deliberately — see the warning up top)
lsof -nP -iTCP:8093 -sTCP:LISTEN                   # *:8093
launchctl print gui/$(id -u)/id.my.ekomardiatno.code-server | grep -E '^\s+(state|pid) '

# the firewall is on and is not blocking everything
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
$FW --getglobalstate && $FW --getblockall          # enabled / off
```

Then the certificate. Passing our own cert as the CA is the trick that separates
the two failure modes: **`verify=0` means the SANs are right** and the only
remaining complaint a browser will make is the unknown issuer, which it offers
to bypass. A name mismatch is the one iOS Safari will *not* let you past.

```sh
CA=~/.config/code-server/tls/cert.pem
for u in https://ekomardiatno.local:8093 https://192.168.1.2:8093 https://localhost:8093; do
  printf '%-34s %s\n' "$u" \
    "$(curl -s --cacert $CA -o /dev/null -w 'http=%{http_code} verify=%{ssl_verify_result}' "$u/login")"
done
```

Login over curl — **302 to `/` means success**; a wrong password re-renders
`/login` as **200**:

```sh
U=https://ekomardiatno.local:8093
curl -s --cacert $CA -c /tmp/cs.jar -o /dev/null "$U/login"
curl -s --cacert $CA -b /tmp/cs.jar -o /dev/null -w '%{http_code}\n' -X POST "$U/login" \
  --data-urlencode 'base=.' --data-urlencode "href=$U/login" \
  --data-urlencode "password=$PW"
```

> The session cookie is `code-server-session` and is **HttpOnly**, so curl
> writes it to the jar as `#HttpOnly_ekomardiatno.local…`. A `grep -v '^#'`
> over the jar makes a successful login look like it failed.

Prove the theme actually landed, rather than trusting that the copy succeeded:

```sh
for f in global.css login.css space_grotesk.woff2 manrope.woff2 jetbrains_mono.woff2 \
         pingwin-workbench.css; do
  printf '%-24s %s\n' "$f" \
    "$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' \
       "https://ekomardiatno.local:8093/_static/src/browser/pages/$f")"
done
```

> **`ping` is not a reachability test here.** Stealth mode drops ICMP echo, so a
> perfectly healthy setup does not answer it. Use the `curl` loop above.

### Screenshots

**Headless Chrome's `--screenshot` hangs on this box** — Chrome for Testing 1243
loops on GCM registration (`DEPRECATED_ENDPOINT`) and never exits, with or
without `--headless=old|new`, `--virtual-time-budget` or
`--disable-background-networking`. Don't burn time on the flags.

Playwright's **node API** works fine (`~/Library/Caches/ms-playwright`; the
package is in `embiz/node_modules`). Launch, screenshot, and `await
browser.close()` in a `finally`. Note macOS has no `timeout(1)` to wrap it in.

---

## 10. Upgrading

A new tarball is a new directory, which means the install tree — and everything
patched into it — is replaced.

```sh
VER=<new>
cd /tmp && curl -fLO "https://github.com/coder/code-server/releases/download/v$VER/code-server-$VER-macos-amd64.tar.gz"
shasum -a 256 "code-server-$VER-macos-amd64.tar.gz"     # check it
tar -xzf "code-server-$VER-macos-amd64.tar.gz" -C ~/.local/lib

ln -sfn ~/.local/lib/code-server-$VER/bin/code-server /usr/local/bin/code-server

# re-apply both themes — an upgrade reverts both
cd ~/Desktop/projects/code-server-vps
CODE_SERVER_PAGES=~/.local/lib/code-server-$VER/src/browser/pages ./apply.sh
# then re-patch the .wordmark-sub line in login.html

cd ~/Desktop/projects/pingwin-vscode-theme && ./workbench/apply.sh

# the firewall rule names the *old* version's node binary, which no longer exists
cd ~/Desktop/projects/code-server-vps && sudo ./macos/setup-lan.sh

launchctl kickstart -k gui/$(id -u)/id.my.ekomardiatno.code-server
```

> **`setup-lan.sh` is the step that is easy to forget and hard to diagnose.** A
> firewall rule pointing at a deleted binary does not error — it simply stops
> matching, and the new `node` falls back to the default "block incoming". The
> editor then works perfectly on this machine and times out on every other
> device.

Hard-reload the browser (`cmd-shift-r`) — `workbench.html` is cached hard, and a
soft reload will show the old fonts.

Keep the previous `~/.local/lib/code-server-*` directory until the new one is
confirmed working; rolling back is then just pointing the symlink back.

---

## Where everything lives

```
/usr/local/bin/code-server                     symlink -> the versioned install
~/.local/lib/code-server-<ver>/                the install tree (replaced on upgrade)
  src/browser/pages/                             login theme + workbench CSS + fonts
  lib/node                                       the binary the firewall rule names
  lib/vscode/out/vs/code/browser/workbench/      workbench.html (+ .orig backup)
~/.config/code-server/
  config.yaml                                  bind, auth, hash — mode 0600
  tls/{cert,key}.pem                            self-signed, SANs for name + IP
~/.local/share/code-server/
  User/settings.json                           theme + font settings
  extensions/                                  symlink to pingwin-vscode-theme
~/Library/LaunchAgents/id.my.ekomardiatno.code-server.plist
~/Library/Logs/code-server.log
```

Nothing is installed outside `$HOME`. The root-only settings — `LocalHostName`
and the firewall rule — live in system preference stores, and
`macos/setup-lan.sh` is the record of what they should be. The repo copy of the plist is the source of truth; if you edit the installed
one, copy it back.
