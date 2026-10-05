# Security Design: User Separation

The root/pi privilege model of tsOS-base, as of the next release. It describes the current state;
the change history is in [CHANGELOG.md](../CHANGELOG.md). "Known weaknesses" lists what is
knowingly left open, "Open items" the remaining follow-up work.

## Model

Two accounts, two trust levels:

- **`root`** — trackIT Systems (the manufacturer) and educated admins: full access for
  diagnostics, recovery and manual intervention.
- **`pi`** — the operator account. It can change application configuration, start/stop/restart
  application services, reboot, manage the network and trigger software updates. It cannot modify
  the code that runs on the device and has no sudo.

The boundary is **OS-level permissions** (file ownership/mode, polkit rules, group membership),
not sudo and not application checks. `tsconfig.service` runs as `pi`, so `tsconfig` (web, API,
web shell, BLE) is a convenience layer with exactly `pi`'s rights: a bug or injection in it is
capped at what `pi` could do anyway. The one way from `pi` to `root` is `su`, and only if the image
was built with a root password (see "Root password (build-time, optional)").

`pi` cannot read root-only files, with three deliberate exceptions: the boot partition, the **full
systemd journal**, and **every NetworkManager connection including its secrets** (Wi-Fi PSKs, the
hotspot password, GSM PIN/password).

**Non-goals:** protection against root or physical access (a manufacturer admin is trusted by
definition, and there is no secure boot); isolation between operators (there is one operator
account); protecting `/data` (collected field data is deliberately world-readable/writable — this
design protects the *system*, not the *dataset*).

## Filesystem & code boundary

- **Application source trees** (`/usr/local/src/*`) are `root:root`, not group/world-writable:
  `pi` can read them while debugging, not change them. `pip install -e` runs as root at build
  time, so it does not need `pi` ownership. System-wide `git safe.directory` entries let `pi` run
  read-only git commands there ([tsOS-base.Pifile](../tsOS-base.Pifile)).
- **Binaries and unit files** (`/usr/local/bin`, `/usr/local/sbin`, `/etc/systemd/system`) are
  root-owned — a `pi` who could edit a unit file could turn "restart this service" into "run code
  as root".
- **`/home/pi`** is `pi:pi`; **`/data`** stays world-accessible (see Non-goals).

### Boot partition (`/boot/firmware`)

Mounted `uid=0,gid=0,dmask=0022,fmask=0133` ([etc/fstab](../etc/fstab)): readable by everyone,
writable by root only. Root consumes much of it, so `pi` write access would be root access:
`cmdline.txt`/`config.txt`/kernel/initramfs (`init=/bin/sh` plus a reboot is a root shell),
`wireguard.conf` (`wg-quick` runs `PostUp` and friends as root), `tsupdate.yml` (selects the
update source), and `schedule.yml`, `envsense.yml`, `tsconfig.yml` (read by root services).

It stays readable on purpose: `copy-authorized-keys` runs as `pi` and must read `authorized_keys`,
and `pi` reading the WireGuard key is acceptable. Consequently **nothing on the boot partition is
secret from `pi`**; root-only secrets don't belong there.

### Configuration changes

`pi` changes configuration (network, schedule, MQTT, sensors, authorized keys, `userconf.txt`,
...) through `tsconfig`'s `write-config` privileged op
([app/privileged/ops.py](../usr/local/src/tsconfig/app/privileged/ops.py)), which re-runs the
target config class's own `validate()` as root instead of trusting the unprivileged caller.
`WireguardConfig.validate()` rejects `PreUp`/`PostUp`/`PreDown`/`PostDown`/`SaveConfig`
([wireguard.py](../usr/local/src/tsconfig/app/configs/wireguard.py)).

## Service control

There is no sudoers file. Each privileged capability uses the gate native to what it controls,
and the gate is the same whether the caller is `tsconfig.service` or an interactive `pi` shell:

| Capability | Gate | File |
|---|---|---|
| Unit start/stop/restart/reload/kill/... | polkit `org.freedesktop.systemd1.manage-units`, `subject.user == "pi"`, fixed unit allowlist | [20-tsos-systemctl.rules](../etc/polkit-1/rules.d/20-tsos-systemctl.rules) |
| Reboot | polkit `org.freedesktop.login1.reboot` | [21-tsos-reboot.rules](../etc/polkit-1/rules.d/21-tsos-reboot.rules) |
| Logs (full journal) | membership in `systemd-journal` (journald gates reads by file permission) | [tsOS-base.Pifile](../tsOS-base.Pifile) |
| Network management | polkit: every `org.freedesktop.NetworkManager.*` action for group `netdev` | [10-tsos-netdev.rules](../etc/polkit-1/rules.d/10-tsos-netdev.rules) |
| Config write/delete/stat, overlay wipe, GSM field removal | `pkexec` + custom polkit action for one executable | [30-tsos-privileged.rules](../etc/polkit-1/rules.d/30-tsos-privileged.rules), [tsconfig-privileged](../usr/local/sbin/tsconfig-privileged) |

### Units

`manage-unit-files` (`enable`/`disable`/`mask`/`link`/...) is a separate polkit action
that is never granted, so persistent changes stay denied. The allowlist lives in the polkit rule,
not in anything operator-editable; the check against `tsconfig.yml`'s services list in
`app/routers/systemd.py`, and the API's narrower verb set (`ALLOWED_SYSTEMCTL_VERBS` =
start/stop/restart/reload, [app/utils/privileged.py](../usr/local/src/tsconfig/app/utils/privileged.py)),
are UI conveniences, not the boundary. The same goes for the configured-services check on log
streaming.

### Reboot

`schedule_reboot()` pre-checks authorization with `pkcheck` so an HTTP caller learns
about a denial before a success response, then runs `systemctl reboot` from an in-process
`asyncio` task after the requested delay.

### Network management

`tsconfig` calls `nmcli` directly. The polkit grant is all-or-nothing:
`pi` can create, modify, activate and read the secrets of *any* connection, not only the three
`tsconfig` manages. One exception is root-mediated: clearing a cellular connection's GSM
password/PIN means editing netplan's YAML in root-owned `/etc/netplan` (`unset-gsm-fields`).

### `tsconfig-privileged` via `pkexec`

Operations with no D-Bus service to attach to go through a
root-owned wrapper that execs `tsconfig`'s `app.privileged` module in Python isolated mode (`-I`)
with a reset environment, so nothing from `pi`'s environment reaches it except argv/stdin.
[systems.trackit.tsos.tsconfig-privileged.policy](../usr/share/polkit-1/actions/systems.trackit.tsos.tsconfig-privileged.policy)
pins the action to that executable path (`org.freedesktop.policykit.exec.path`); the rule grants
`pi` passwordless use. Whether `pi` may call the wrapper is polkit's decision; argument validation
is `app.privileged.ops`'s. Notes:

- *Not setuid:* the wrapper is a shell script, and Linux ignores the setuid bit on scripts.
- *Headless works:* `pkexec` checks a `unix-process` subject before any session/agent lookup,
  and with an unconditional `YES` no authentication challenge (which would need a session) occurs.
- *Build time:* the Pifile's `tsconfig zip` step runs as root in a chroot with no `polkitd`, so
  `run_privileged_op()` calls the op in-process when `euid == 0`. `tsconfig.service` never runs as
  root, so only the build uses this path.
- `polkitd` and `pkexec` are installed explicitly; they are not in the base image.

## Accounts & credentials

### `pi`

- **Password:** from `userconf.txt` on the boot partition, default `natur` (seeded at build time).
  `userconfig.service` applies and deletes it on boot; a config bundle can ship a new one
  (`pi:<sha512-crypt>` only, no renaming — [userconf.py](../usr/local/src/tsconfig/app/configs/userconf.py)).
  `usr/lib/userconf-pi/userconf-service` is patched to reassert `zsh` afterwards, because upstream
  resets the shell to bash unconditionally (`RPi-Distro/userconf-pi` commit `e58fd5ca`).
- **Groups:** removed from `sudo` and `adm`; member of `netdev` and `systemd-journal`.
- **SSH keys:** `copy-authorized-keys.service` runs as `pi` and copies `/boot/firmware/authorized_keys`
  to `pi` only ([copy-authorized-keys.service](../etc/systemd/system/copy-authorized-keys.service)).
  Running as `pi` also means a symlink planted in `~/.ssh` can only redirect the write to
  somewhere `pi` could write anyway.

### `root`

- **SSH keys** are manufacturer-controlled, committed in
  [root/.ssh/authorized_keys](../root/.ssh/authorized_keys) and baked in at build time,
  independent of the boot partition: an operator can add operator keys, never root keys. Key-based
  root SSH always works.

### Root password (build-time, optional)

The image build reads `TSOS_ROOT_PASSWORD` (passed through `docker-compose.yml`, never committed):

- **Unset** (default): `passwd -l root`. No `su`, no console or password login, no staff login,
  no path from `pi` to `root`. If SSH is unavailable, recovery needs physical access, which is root
  anyway.
- **Set:** root gets that password (`openssl passwd -6`, `chpasswd -e`). It then opens:
  - `su` from **any** `pi` session — SSH, or `tsconfig`'s web shell, which anyone with `pi`'s
    password can reach over the network;
  - **password SSH** as root: [10-tsos.conf](../etc/ssh/sshd_config.d/10-tsos.conf) ships
    `PermitRootLogin prohibit-password`, and the build switches it to `yes` only in this case.
    Rate-limited only by sshd's defaults;
  - the **staff login** on the web form, WebDAV and BLE (below).

The builder owns uniqueness and rotation. One value reused across a fleet (e.g. one CI secret) is
a fleet-wide secret: whoever learns it has root on every device built with it.

## Operator authentication

Every network entry point requires one credential: `pi`'s password. Staff may use `root` and its
password instead, if one exists. Every web entry point is available over plain HTTP and,
optionally, over HTTPS with a device-local certificate (see "HTTPS (optional)").

### HTTPS (optional)

Caddy serves the same site on `:443` with certificates from its own local CA (`tls internal`).
Plain HTTP on `:80` stays and is never redirected ([Caddyfile](../etc/caddy/Caddyfile)).

- **Names.** The certificates cover `<hostname>`, `<hostname>.local`, `localhost` and
  `169.254.0.1` (the hotspot address). Clients that send no SNI, i.e. anything connecting by IP
  address, get the `.local` certificate. Any other name (e.g. a router's DNS suffix) fails the TLS
  handshake: use the IP or `.local` instead. Caddy gets the hostname from
  [caddy.service.d/tsos-hostname.conf](../etc/systemd/system/caddy.service.d/tsos-hostname.conf).
- **Trust.** Each device has its own CA, created on Caddy's first start and kept in Caddy's
  storage (`/var/lib/caddy/.local/share/caddy`, readable by `caddy` only, persistent on the
  overlay). An overlay wipe creates a new one. Nothing trusts it by default, so browsers warn.
  HTTPS always stops passive sniffing. It stops an active man-in-the-middle only for clients that
  verify the device, by importing its root (`pki/authorities/local/root.crt` in that storage, read
  as root) or by checking its fingerprint.
- **Lifetime.** Leaf certificates last 12 hours and renew automatically. Caddy 2.6 (Trixie) can't
  change that, so a device clock that is far off makes them look invalid to verifying clients.
- **Sessions.** tsconfig learns the scheme from `X-Forwarded-Proto`, which Caddy always sets and
  overwrites. A login over HTTPS gets the `Secure` cookie `__Host-tsconfig_session`, which the
  browser never sends over HTTP; logins over HTTP keep `tsconfig_session`
  ([app/auth/session.py](../usr/local/src/tsconfig/app/auth/session.py)). WebDAV's Basic
  credentials are encrypted over HTTPS.

### Web: tsconfig

- **Login.** Tracker-mode tsconfig checks `pi`'s password through PAM
  ([app/auth/pam_auth.py](../usr/local/src/tsconfig/app/auth/pam_auth.py),
  [etc/pam.d/tsconfig](../etc/pam.d/tsconfig): `pam_unix`, no `nullok`). `pam_unix` verifies the
  caller's own password via `unix_chkpwd` without root. Only `pi` and `root` can log in. Server
  mode (OIDC) is unchanged.
- **Session.** Signed HttpOnly cookie, 8-hour sliding expiry, signing key in memory only
  ([app/auth/session.py](../usr/local/src/tsconfig/app/auth/session.py)): a restart or reboot (which
  is also when a new `pi` password takes effect) logs everyone out.
- **Guessing.** Exponential backoff per client (`X-Forwarded-For` from Caddy) and, more loosely,
  device-wide: three free attempts, then 1 s, 2 s, ... up to 30 s. No hard lockout, because that
  would let anyone lock an unattended device's operator out.
- **Gated:** every route, the API docs, and the shell websocket (checked on the handshake). Public:
  login form, static assets, `/auth/status`, `/api/server-mode`.
- **Trusted local requests.** A request whose TCP peer is loopback **and** that carries none of the
  forwarding headers Caddy always sets is exempt. Remote traffic always passes through Caddy, so it
  can never qualify. This is how `mqttutil` (`127.0.0.1:8000`,
  [boot/firmware/mqttutil.conf](../boot/firmware/mqttutil.conf)) and `tsconfig-ble` call the API.
  The cost: **any local process gets the whole API, including the shell websocket** — a `pi`
  shell — so a compromised sandboxed service (Mosquitto, `envsense`) is no longer contained.

### Staff login (`root`)

`root` + root's password works on the web form, WebDAV and BLE. It grants **nothing extra**: the
session, API, web shell and Filebrowser stay `pi`-level. Log lines record which account was used.

- **Check.** `unix_chkpwd` only verifies the caller's own account, and joining `shadow` would
  expose every hash, so tsconfig runs the setuid `su -s /bin/sh -c true root` under a pty, writes
  the password after the `Password:` prompt, and treats exit status 0 as success. None of our code
  runs as root, and `pi` gains nothing it couldn't do by running `su` itself.
- **Throttling** is stricter and separate from `pi`'s: two free attempts, then up to 120 s per
  client, plus a root-wide bucket (five free, up to 60 s). At most two `su` checks run concurrently;
  further attempts are refused.
- **Limits.** Passwords with control characters or DEL don't work (the tty line discipline would
  interpret them). The check follows `/etc/pam.d/su`, so a stricter stack (e.g. `pam_wheel`)
  silently disables it. Each success logs `session opened for user root by pi`.
- **Without a root password** root is locked, the check fails, and the staff login doesn't exist.

### Filebrowser and WebDAV

[Filebrowser Quantum](https://github.com/gtsteffaniak/filebrowser) v1.5.6 serves `/data` at
`/data/` and WebDAV at **`/data/dav/data/`**. It doesn't check passwords: it uses
`auth.methods.proxy` and trusts `X-Forwarded-User` from Caddy
([filebrowser.yml](../etc/filebrowser/filebrowser.yml), whose comments list the configuration
traps to avoid). Caddy ([Caddyfile](../etc/caddy/Caddyfile)):

1. deletes any client-supplied `X-Forwarded-User`;
2. asks tsconfig `GET /auth/check` (`forward_auth`): the session cookie for the web UI, or — for
   `/data/dav/*` only — HTTP Basic `pi`/`root` + password, checked like the login (with the same
   backoff; `429`/`401` + `WWW-Authenticate`). A password verified in the last 60 s is cached in
   memory as a keyed digest, so a changed password stops working within a minute;
3. replaces the Basic header with a dummy, so the real password never reaches Filebrowser;
4. forwards with `X-Forwarded-User: pi`.

Filebrowser listens on loopback only and must never be reachable except through Caddy; any local
process can reach `127.0.0.1:8080` and claim to be `pi` (the same exposure as trusted local
requests). It runs as `pi` ([filebrowser.service](../etc/systemd/system/filebrowser.service)), so
uploaded files belong to the operator. A Filebrowser compromise is a `pi` compromise, limited by
`ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths=/data`, `PrivateTmp` and
`NoNewPrivileges`.

There is no SMB share: Samba is removed, because SMB needs an NT hash that can't be derived from
the crypt hash in `userconf.txt`. `/data` is reached over HTTP, WebDAV or SSH/SFTP as `pi`.

### BLE

`tsconfig-ble` runs as `pi`:

- **Encrypted link.** Gated characteristics (and the login one) use BlueZ's `encrypt-*` flags, so
  BlueZ forces LE pairing. The device has no display or keypad, so pairing is Just Works
  (`NoInputNoOutput` agent): this protects against passive sniffing, **not** against an active
  man-in-the-middle during pairing.
- **Login.** Writing `{"password": "..."}` (optional `"username"`: `"pi"` default, or `"root"`) to
  the Authenticate characteristic (`00001005-...`) uses the same check as the web. It unlocks that
  connection only and ends on disconnect, after 8 hours, or on gateway restart. Failures back off
  per device and device-wide. Gated: all writes (service actions, reboot, logs, config and zip
  upload) and the systemd service list. Open: the status characteristics (system status, server
  mode, timedatectl, available services), so devices can be identified before pairing.
  `--no-auth` (alias `--no-pairing`) disables both layers.

### Hotspot password via the config bundle

A bundle (`tsconfig zip`, `POST /api/configs.zip`, BLE zip upload) may contain
`hotspot.nmconnection` ([app/configs/hotspot.py](../usr/local/src/tsconfig/app/configs/hotspot.py)),
which is how a server sets the hotspot password (default `BirdsAndBats`).

- The bundle's `[connection]` section and `[wifi] ssid` are discarded (the SSID follows the
  hostname). Everything else is the bundle's. The profile must parse, stay under 8 KiB and be
  `[wifi] mode=ap`.
- The file is root-only (`/etc/NetworkManager/system-connections`, 0600) and is written via
  `write-config`. tsconfig's config download endpoints skip it. This keeps the PSK out of the
  config API only; `pi` can still read it with `nmcli -s` (see "Network management").
- After writing, the profile is loaded and, if the hotspot is up, re-activated, which drops
  connected clients. An unchanged bundle touches nothing. If NetworkManager rejects the profile,
  the previous file is restored (the hotspot is the recovery path); a valid but useless profile is
  the bundle author's responsibility.
- `delete-config` refuses to delete it.
- "Only overwrite if newer" uses `stat-config` (existence and mtime via the wrapper, never content),
  and the bundle's mtime is stamped on the file after every apply.

## Software updates (`tsupdate`)

`pi` has full control of `tsupdate`, including source and channel — a deliberate exception to
"no code modification", since updates are atomic, logged and versioned. Sources are restricted to
the `trackIT-Systems` GitHub org: `ALLOWED_OWNER` and fully anchored `https`-only patterns in
[github.py](../usr/local/src/tsupdate/src/tsupdate/github.py), re-checked by
`is_allowed_source_url()` in [utils.py](../usr/local/src/tsupdate/src/tsupdate/utils.py) before
any download. Downgrades aren't supported. The download cache `/data/tsupdate` is world-writable,
so files are verified against the GitHub asset digest (size if there is none), and asset names are
reduced to a basename. A malicious release *within* the org is still trusted; signed releases would
close that gap.

## Known weaknesses

- **SSH host key MITM.** The host private keys are committed to this public repo
  (`etc/ssh/ssh_host_*`), identical on every device, with regeneration disabled. Anyone can
  impersonate a device. Whatever happens in a session is exposed, and agent forwarding (`ssh -A`)
  hands the attacker a manufacturer key. **Never use agent forwarding to devices.**
- **One public password, in clear.** The defaults are kept on purpose: the initial setup with a
  config bundle sets real values. Until it does, `pi`'s password (`natur`) and the
  hotspot PSK (`BirdsAndBats`) are published in this repo, and `pi`'s password opens tsconfig, its
  web shell, `/data`, WebDAV, BLE and SSH. There is one account for everyone, so no per-person audit
  trail. Over plain HTTP, which stays available, anyone who can sniff the hotspot, the LAN or the
  cellular path sees the login, and **WebDAV resends it with every request**. HTTPS stops that, but
  its certificate is self-signed per device: a client that doesn't verify the device's CA can
  still be man-in-the-middled. Prefer HTTPS, the hotspot's WPA2 link or WireGuard for WebDAV.
- **What `pi` reaches is broad.** Through the above: the full journal and every NetworkManager
  secret, and — if a root password is set — root via `su`.
- **Local processes are trusted** by tsconfig (including the shell) and Filebrowser; see "Trusted
  local requests". Accepted for tsOS's scope: a compromised local service ends up `pi`-level.
- **Secrets in the journal.** `pi` reads the whole journal. No service was found logging secrets
  when this was checked, but any future log line that includes one is readable by `pi` (and so by
  anyone with `pi`'s password).
- **A configured root password** is guessable over SSH, the web form, WebDAV (in clear) and BLE,
  limited only by backoff (sshd: its defaults). If reused across the fleet, it compromises every
  device at once. Use a strong per-device value, or leave it unset.
- **Mosquitto.** The broker has no authentication or TLS; it binds loopback unless an
  operator-supplied `mosquitto.d` adds a listener.
- **Physical access is root** (no secure boot).

## Migration

This design applies to newly built images only. Already released images are not patched: they
keep their old model (shared root/`pi` keys, passwordless sudo, `pi`-owned source trees, the
world-writable `tsconfig.yml` service allowlist, the guest-writable Samba share) until they are
reinstalled. The 2027 release is a fresh install on every device; there is no in-place
migration. CI skips delta update generation until `DELTA_BASELINE` in
`.github/workflows/build.yml` is set to this release's tag, so no delta is ever published across
this boundary.

## Open items

- **Admin keys.** `root/.ssh/authorized_keys` holds the one checked-in key for now; more admins
  will be added later. Write access to that file is the power to grant root, so it should get
  CODEOWNERS/branch protection. Revoking a key needs a rebuild and reinstall; an SSH CA with
  short-lived certificates (`TrustedUserCAKeys`) would avoid that.
- **Verifiable HTTPS.** Certificates that clients can check without importing each device's CA,
  e.g. a fleet CA distributed through the config bundle.
- **Root SSH restricted to the WireGuard interface**, so manufacturer access requires the VPN.
- **Per-device SSH host keys** (generated at first boot, removed from the repo).
