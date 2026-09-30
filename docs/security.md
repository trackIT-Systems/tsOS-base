# Security Design: User Separation

This document describes the root/pi privilege model implemented for the next tsOS-base
release. Most of it is implemented, as noted throughout — see "Migration" for how this rolls
out relative to devices already in the field, "Known weaknesses" for what is knowingly left
open, and "Open items" for decisions that still need to be made (mostly follow-on work, not
this document's core design).

## Goals

Two accounts, two trust levels:

- **`root`** — controlled by trackIT Systems (the manufacturer). Full system access, intended
  for us and for educated admins doing deep diagnostics, recovery, or manual intervention.
- **`pi`** — the operator account, used by field operators day to day. It can do the things an
  operator legitimately needs (change application configuration, restart application
  services, trigger software updates) but cannot read arbitrary files on disk and cannot
  modify the code that runs on the device. Two long-standing, deliberate exceptions to "cannot
  read arbitrary files": the boot partition (world-readable by design, see below) and, as of
  this session, the full systemd journal (see "Service control" — broadened from a per-unit
  allowlist for debugging convenience).

The enforcement boundary is **OS-level permissions** (Unix file ownership/mode, polkit rules,
and plain group membership) — not sudo, and not application-level checks. `pi` has the same
capabilities whether it acts over SSH or through the `tsconfig` web/BLE interface — `tsconfig`
is a convenience layer on top of the same underlying rights, not a separate, wider privilege
domain:

- Every privileged action `tsconfig` performs on `pi`'s behalf goes through the same gate an
  interactive `pi` shell session would hit (see "Service control" below). A bug or injection in
  `tsconfig` is capped at what `pi` could already do, not instant root.
- **Implemented:** `tsconfig.service` runs as `pi` and has **no sudo access of any kind** —
  `etc/sudoers.d/tsos-pi` doesn't exist. Every privileged operation is authorized by one of
  three mechanisms, whichever is native to what's being controlled: a native polkit action
  (NetworkManager, systemd unit actions, reboot), plain group membership (journal log reads —
  journald gates these by file permission, not polkit), or `pkexec` plus a custom polkit action
  for the one genuinely bespoke case (config writes, overlay wipe, netplan edits — operations
  with no D-Bus-native service to attach to). See "Service control" below for all three.

  This resolves the tension the design originally had with the boot partition becoming
  root-owned (`tsconfig` is also the operator's path to that configuration): rather than
  `tsconfig` becoming the privileged party, it stays `pi` throughout.

## Non-goals

- Protecting the device against an attacker with root or physical access — a manufacturer
  admin is trusted by definition.
- Multi-tenant isolation between operators — there's one operator account, not one per person.
- Hardening `/data`: collected field data is explicitly fine to be world-readable/writable.
  This design is about protecting the *system*, not the *dataset*.

## Filesystem & code boundary

`pi` must not be able to modify the code that runs on the device:

- **Application source trees** (`/usr/local/src/*` — `tsconfig`, `tsschedule`, `mqttutil`,
  `wittypi4`, etc.) are `root:root`, mode `755` (`pi` can read/traverse, e.g. to inspect
  installed code while debugging, but cannot write) — [tsOS-base.Pifile](../tsOS-base.Pifile),
  "Application source trees" section. The earlier `chown -R pi:pi` was there on the theory
  that `pip install -e` needed it; it doesn't, since every `pip install -e` in this Pifile
  runs as root regardless of directory ownership. Per-submodule `git safe.directory` entries
  let `pi` still run read-only git commands there without a "dubious ownership" error.
- **System binaries and unit files** (`/usr/local/bin`, `/usr/local/sbin`,
  `/etc/systemd/system/*.service`) are root-owned by default and were never reassigned to
  `pi` — a `pi` who could edit a unit file could turn "restart this service" into "run
  arbitrary code as root."
- **`/home/pi`** stays `pi:pi` — it's the operator's own space.
- **`/data`** stays permissive/world-accessible — explicitly out of scope (see Non-goals).

### Boot partition (`/boot/firmware`)

`bootfs` is mounted root-owned, `uid=0,gid=0,dmask=0022,fmask=0133` — 0755, readable by
everyone, writable by root only ([etc/fstab](../etc/fstab)). It was previously
`umask=000,fmask=111` (world-writable) with the `user` mount option, and bind-mounted to
`/media/boot` (now removed, since nothing needs a second mount point once the real one is
readable).

It couldn't stay writable by `pi` because root consumes far more than application config from
it:

- `cmdline.txt`, `config.txt`, the kernel and the initramfs — adding `init=/bin/sh` to
  `cmdline.txt` and rebooting gives a root shell, and `pi` is allowed to trigger reboots.
- `wireguard.conf` — `wg-quick` executes `PreUp`/`PostUp`/`PreDown`/`PostDown` lines as root.
- `tsupdate.yml` — its `github_url` selects the update source for the root-run updater
  ([daemon.py:439](../usr/local/src/tsupdate/src/tsupdate/daemon.py#L439)).
- `schedule.yml`, `envsense.yml`, `tsconfig.yml` — read by services running as root.

`pi` can no longer edit these files directly from a shell; `tsconfig`'s `write-config`
privileged op writes them on the operator's behalf (see "Service control" below), and treats
operator input as untrusted — in particular, `WireguardConfig.validate()` rejects
`PreUp`/`PostUp`/`PreDown`/`PostDown`/`SaveConfig` keys before any write happens
([wireguard.py](../usr/local/src/tsconfig/app/configs/wireguard.py)).

Readability for `pi` is deliberate, and the design relies on it: `copy-authorized-keys` runs as
`pi` and must read `/boot/firmware/authorized_keys` (see below), and `pi` reading the WireGuard
key is explicitly acceptable. A stricter `0700` was considered and rejected because it would
break both. The flip side is that nothing on the boot partition is secret from `pi` — secrets
that must stay root-only don't belong there.

**WireGuard config:** the key itself is not considered sensitive — `pi` reading or holding it is
acceptable. Writing the file is a different matter (see the `PostUp` note above).

## Network shares (Samba)

Only `/data` is shared via SMB ([etc/samba/smb.conf](../etc/samba/smb.conf)) — previously the
`[media]` share exposed all of `/media` (guest, writeable), which included the boot partition
and a read-only root filesystem mount, so an unauthenticated network peer could read the root
filesystem and write the boot partition. `/data` is world-accessible by design (see Non-goals),
so guest access to that one share is consistent with that; authentication for it belongs with
the operator-password work (see Open items).

## SSH & key provisioning

**SSH keys for `root` are provisioned by the manufacturer, independent of the operator-editable
boot partition, and individually issued per admin.**

- `copy-authorized-keys.service` copies **only `pi`'s keys** and runs as **`User=pi`**
  ([copy-authorized-keys.service](../etc/systemd/system/copy-authorized-keys.service)). It
  previously also ran as root and copied into `/root/.ssh`, which meant anyone who could write
  the boot partition (the whole point of that file) could grant themselves root SSH access.
  Running it as `pi` also closes a second issue: as root, its `cp` would follow a symlink `pi`
  planted at `~/.ssh/authorized_keys2` and write root-derived content wherever that symlink
  pointed; as `pi`, the copy can only reach what `pi` could write directly anyway.
- `root`'s `authorized_keys` is a manufacturer-controlled file in this repo
  ([root/.ssh/authorized_keys](../root/.ssh/authorized_keys)), baked into the image at build
  time, independent of `/boot/firmware` — an operator can add operator keys, but can never
  grant themselves root. It currently has **one entry** (the existing
  `hoechst@trackit.systems` key); more admins should be added here, one line each, before a
  real release ships (see Open items for the process question).
- `sshd_config` enforces `PermitRootLogin prohibit-password`
  ([etc/ssh/sshd_config.d/10-tsos.conf](../etc/ssh/sshd_config.d/10-tsos.conf)) — root can
  only authenticate over SSH with one of the manufacturer keys above.

### No root password

**SSH with a manufacturer key is the only way to become `root`.** `root`'s password is locked
(`passwd -l root`), so `su` to root, root console login and password-based SSH are all
impossible. Together with the next point, there is no path from a `pi` session to `root` at
all — an admin who is logged in as `pi` opens a separate SSH session as `root` with their own
key.

- **`pi` has no sudo access at all.** `pi` is removed from the `sudo` group (`deluser pi sudo`)
  — Raspberry Pi OS adds it by default, and `%sudo ALL=(ALL:ALL) ALL` plus `pi`'s known
  password would otherwise be a direct path to root. There is no sudoers drop-in for `pi`
  either — `etc/sudoers.d/tsos-pi` was removed once every capability it granted moved to
  polkit or plain group membership (see "Service control" below); `pi` reaches root exactly
  once, for one narrow, still-root-mediated case, and that's through `pkexec`, not sudo.
- `pi` is also removed from `adm` (would grant broad `/var/log/*.log` text-file access) but
  **added to `systemd-journal`** — narrower than `adm` (journal reads only), but still a real
  broadening from this design's original stance: full journal read access for every unit,
  kernel included, not a per-unit allowlist. See "Service control" below for why. `pi` also
  stays in `netdev` for NetworkManager access — see [tsOS-base.Pifile](../tsOS-base.Pifile),
  "no general sudo" section.
- There is no local fallback. If SSH to `root` is unavailable (network down, `sshd` broken),
  recovery means physical access — taking out the SD card, or re-flashing. Since physical
  access already equals root (see Non-goals), this doesn't give up any security.
- This also removes a whole class of risk: no shared secret to leak or rotate, nothing for a
  compromised `pi` session to capture, and no password hash in the image to attack offline.

## Service control: polkit and group membership, not sudo

**`tsconfig.service` runs as `pi`, not root**
([etc/systemd/system/tsconfig.service](../etc/systemd/system/tsconfig.service)). Every
privileged action it performs is authorized by whichever mechanism is native to what's being
controlled — there is no sudoers file at all any more. Five capability domains, each with its
own gate, but all hit identically whether the caller is `tsconfig.service` itself or an
admin's interactive `pi` SSH shell:

### Systemd unit actions

`pi` has direct, unprivileged access to `systemctl` for a fixed allowlist of units — no root
mediation, no wrapper. Authorized by a polkit rule
([etc/polkit-1/rules.d/20-tsos-systemctl.rules](../etc/polkit-1/rules.d/20-tsos-systemctl.rules))
granting `org.freedesktop.systemd1.manage-units` — every *non-persistent* systemd verb
(`start`/`stop`/`restart`/`reload`/`kill`/`reset-failed`/...) — for that allowlist, keyed on
`subject.user == "pi"` rather than a group (there's no pre-existing group with these
semantics). It deliberately never grants `org.freedesktop.systemd1.manage-unit-files` — a
categorically separate action id that covers `enable`/`disable`/`mask`/`link`/`preset`/
`revert` — so persistent unit-file changes stay denied (the vendor default, `auth_admin`)
regardless of what's granted for `manage-units`; no verb-by-verb filtering is needed to get
"any temporary action, never a persistent one."

This also closed a real gap found while writing this doc: `tsconfig`'s systemd-control endpoint
used to validate the requested service against a list read from the (then world-writable)
`/boot/firmware/tsconfig.yml`, so anyone who could write that file could add an arbitrary unit
name and `start`/`stop`/`restart` it as root through the network-reachable, unauthenticated
`tsconfig` API. The boot partition is root-owned now, and the real fix regardless is that the
unit allowlist lives in the polkit rule above, not in anything operator-editable — `pi`
attempting `systemctl restart <unit-not-on-the-list>` is refused by systemd/polkit itself no
matter what `tsconfig.yml` says; `/api/systemd/action`'s own check against the configured
services list (`app/routers/systemd.py`) is a UI nicety, not the security boundary.

`tsconfig`'s HTTP API (`POST /api/systemd/action`) exposes a curated, narrower subset of what
the polkit rule itself permits —
`ALLOWED_SYSTEMCTL_VERBS = {"start", "stop", "restart", "reload"}`
([app/utils/privileged.py](../usr/local/src/tsconfig/app/utils/privileged.py)) — never
`enable`/`disable`/`mask`. An interactive `pi` shell can still `systemctl kill`/`reset-failed`/
etc. directly on an allowlisted unit; that's the polkit rule's business, not this app-level
constant's.

### Reboot

`pi` can reboot directly via `systemctl reboot`, which delegates to `systemd-logind`'s
`org.freedesktop.login1.reboot` polkit action — authorized by a separate rule
([etc/polkit-1/rules.d/21-tsos-reboot.rules](../etc/polkit-1/rules.d/21-tsos-reboot.rules), a
different action namespace than the systemd-unit rule above). `tsconfig`'s `schedule_reboot()`
([app/utils/privileged.py](../usr/local/src/tsconfig/app/utils/privileged.py)) first checks
authorization synchronously with `pkcheck` (a read-only polkit query, no side effects) so a
caller — typically finishing an HTTP request — learns about a denial before getting a success
response, then schedules the actual `systemctl reboot` as an in-process `asyncio` task after
the requested delay, rather than the previous root-side `systemd-run --on-active=<delay>s`
transient-unit trick; `tsconfig.service` is already a long-running daemon, so it can hold that
delay itself with no separate root-owned timer needed.

### Logs

`pi` is a member of the `systemd-journal` group, which grants **full journal read access —
every unit, kernel, everything** — at the file-permission level (journald gates journal reads
this way, not via any polkit action; there is nothing here for polkit to authorize).
`tsconfig`'s log-streaming endpoint (`app/routers/systemd.py`) runs `journalctl` directly, no
wrapper, no elevation.

This is a real, deliberate broadening from this design's original stance: `pi` used to be kept
out of unrestricted log access entirely (see the removed `logs` privileged op, which
re-validated the requested unit against `tsconfig.yml`'s configured-services list before ever
running `journalctl` as root). `systemd-journal` is narrower than the `adm` group would have
been — journal reads only, not arbitrary `/var/log/*.log` text files — but it is still
materially broader than a per-unit allowlist: `pi` (and, per the "`pi` access is network
access" known weakness below, anyone who can reach `tsconfig`'s unauthenticated API) can now
read any unit's logs, kernel messages included, not just the units `tsconfig.yml` configures.
The "service must be in the configured list" check that remains in the router is a UI nicety
for the same reason the systemd-unit one is — the real gate is group membership, which doesn't
care what `tsconfig.yml` says.

### NetworkManager

`pi` has direct, unprivileged access to NetworkManager — `tsconfig`'s network router
([app/routers/network.py](../usr/local/src/tsconfig/app/routers/network.py)) shells out to
`nmcli` itself, with no root mediation. This is authorized by an explicit polkit rule
([etc/polkit-1/rules.d/10-tsos-netdev.rules](../etc/polkit-1/rules.d/10-tsos-netdev.rules))
granting every `org.freedesktop.NetworkManager.*` action, without a password, to members of
the `netdev` group — `pi` stays in that group specifically for this.

This replaces an earlier design where `pi` had no NetworkManager access at all and every
nmcli write went through a root-mediated `nm-*` wrapper, which re-validated connection names
against a fixed allowlist (`station`/`hotspot`/`cellular`) and property names against an
explicit per-connection allowlist before ever touching `nmcli`. That gave defense-in-depth
against a compromised or buggy `tsconfig` process, at the cost of `pi` (including an admin
debugging over SSH as `pi`, not just `tsconfig` itself) being unable to touch NetworkManager at
all outside of what `tsconfig`'s own API exposed. Restoring native `nmcli` access was a
deliberate trade-off for operator/debugging flexibility — **the consequence is that `pi` (and,
per the "`pi` access is network access" known weakness below, anyone who can reach
`tsconfig`'s unauthenticated API) can now modify, create, or inspect any NetworkManager
connection and its secrets, not just the three `tsconfig` manages** — polkit's authorization
here is coarse (all-or-nothing per group), not property- or connection-scoped the way the old
root-mediated allowlist was.

One nmcli-adjacent operation remains root-mediated: `unset-gsm-fields` (below). Clearing a
cellular connection's GSM password/PIN requires editing netplan's generated YAML directly
(`nmcli` itself cannot unset those two fields), and `/etc/netplan` is root-owned — polkit's
NetworkManager grant doesn't reach it, so this is a config write like any other, not a
NetworkManager permission gap.

### `tsconfig-privileged`: the one bespoke case, via `pkexec`

Config file writes/deletes, the overlay wipe, and `unset-gsm-fields` have no D-Bus-native
service to attach to — there's no "polkit action for writing an arbitrary config file." These
stay a bespoke root-owned wrapper
([usr/local/sbin/tsconfig-privileged](../usr/local/sbin/tsconfig-privileged), execing into the
tsconfig source's `app.privileged` module), but reached via **`pkexec`**, not sudo:

Unlike `sudo`, `polkitd`/`pkexec` don't ship with the base Raspberry Pi OS image — `pi` never
had any polkit-mediated access before this design, so nothing already pulled them in as a
dependency. [tsOS-base.Pifile](../tsOS-base.Pifile) installs both explicitly (`apt-get install
-y polkitd pkexec`); Debian Trixie splits what used to be one `policykit-1` package into
`polkitd` (the daemon that evaluates every `.rules` file - all of them, not just this one - and
provides `pkcheck`) and a separate `pkexec` binary package.

- A custom polkit action
  ([usr/share/polkit-1/actions/systems.trackit.tsos.tsconfig-privileged.policy](../usr/share/polkit-1/actions/systems.trackit.tsos.tsconfig-privileged.policy))
  pins itself to that one executable path via the `org.freedesktop.policykit.exec.path`
  annotation — `pkexec` refuses to run anything whose canonicalized path doesn't match an
  installed action's annotation, the same role a non-wildcarded sudoers command would play.
  Vendor defaults are restrictive (`auth_admin`).
- A rule
  ([etc/polkit-1/rules.d/30-tsos-privileged.rules](../etc/polkit-1/rules.d/30-tsos-privileged.rules))
  grants `pi` passwordless authorization for that action. This decides only whether `pi` may
  invoke the wrapper at all — exactly the role sudoers played before. It is not the
  argument-validation layer: `app.privileged.ops` re-validates every argument itself regardless
  of what's passed here, same as always.

**Why `pkexec` rather than making the wrapper itself setuid-root** (considered and ruled out):
it's a `#!/bin/sh` script, and Linux's kernel deliberately ignores the setuid bit on any script
with a shebang line — a long-standing hardening measure against a classic TOCTOU exploit class.
`chmod u+s` on it would silently do nothing. `sudo` and `pkexec` both exist specifically to run
an arbitrary script as root *despite* this restriction (real compiled setuid binaries that
assume root first, then `execve()` the target); a genuine setuid replacement would mean
rewriting the wrapper as a compiled C binary and reimplementing the environment/PATH
sanitization `sudo`/`pkexec` currently provide for free.

**Why `pkexec` works from a headless `tsconfig.service` at all** (verified, not assumed): the
concrete risk was that `tsconfig.service` has no registered login/session, and `pkexec` has a
well-documented failure mode when it needs to find or spawn an *interactive* authentication
agent ("Cannot determine your session"). Checked against `pkexec`'s own source
(`src/programs/pkexec.c`): the authorization subject it checks is a plain `unix-process`
(pid + start-time + uid), resolved and checked *before* any session/agent lookup; the
session-dependent code only runs on the `is_challenge()` path. Since the rule above returns an
unconditional `polkit.Result.YES` for `pi`, no challenge ever occurs and that path is never
reached.

**Why `pkexec` does *not* work at image-build time, and the bypass that fixes it**: found by
actually running the build, not by inspection. `tsOS-base.Pifile`'s `RUN tsconfig zip -f -b
forbid ...` step pre-generates a default config bundle by calling the exact same
`write_config()` code path `tsconfig.service` uses at runtime — but that `RUN` step executes
`tsconfig`'s CLI *as root, inside a chroot*, during image assembly. There is no live
D-Bus/`polkitd` authority to reach there at all (a chroot has no init system actually running
services) — `pkexec` fails with "Error initializing authority: Could not connect", a different,
harder failure than the session issue above: `sudo` never had this problem, since it's pure
static file permission checks with zero live-service dependency. `run_privileged_op()`
(`app/utils/privileged.py`) handles this with an explicit `os.geteuid() == 0` bypass: when
already root, it calls `app.privileged.cli.dispatch_op()` directly, in-process, skipping
`pkexec` (and the whole subprocess boundary) entirely — there's no privilege to cross and no
authority daemon to ask even if there were. `tsconfig.service` itself always runs as `pi`, so
this branch is exercised only by the one-shot build-time CLI invocation, never by the live
service.

It execs with Python isolated mode (`-I`) and a reset environment, so nothing in `pi`'s own
environment (not even a planted `~/.local` `.pth` file) reaches the privileged process except
its argv/stdin — unchanged from before, since this is `app.privileged`'s own behavior, not
something sudo or `pkexec` provided.

## Configuration changes

`pi` can change application/runtime configuration — network, schedule, MQTT, sensor configs,
authorized keys, etc. — through `tsconfig`'s `write-config` privileged op
([app/privileged/ops.py](../usr/local/src/tsconfig/app/privileged/ops.py)), which independently
re-validates the config (re-running the target config class's own `validate()`) before saving,
rather than trusting that `tsconfig`'s unprivileged side already did — the whole point is to
survive a compromised or buggy caller, not just a well-behaved one.

## Software updates (`tsupdate`)

`pi` has **full control** of `tsupdate`, including changing the update source/channel, not
just triggering a pull from a fixed manufacturer channel. This is a deliberate exception to
"no code modification": updates are an explicit, sanctioned replacement mechanism (atomic,
logged, versioned) rather than ad hoc file edits — but it's worth being explicit that it is
an exception, not an oversight.

**Mitigation, implemented:** `tsupdate` only accepts sources within the `trackIT-Systems`
GitHub org — enforced in code
([github.py](../usr/local/src/tsupdate/src/tsupdate/github.py): `ALLOWED_OWNER`, fully-anchored
`https`-only regexes) and independently re-checked in `ensure_file()`
([utils.py](../usr/local/src/tsupdate/src/tsupdate/utils.py):
`is_allowed_source_url()`) before any network access, so a source that doesn't even match the
expected GitHub-release-URL shape can't fall through to being downloaded as-is. `pi` can still
pick any repo/tag/channel within that org.

- `tsupdate` does not support downgrades, so installing an older `trackIT-Systems` release
  isn't a concern.
- A compromised or malicious release *within* `trackIT-Systems` is still fully trusted. Signed
  releases would close that gap and are worth a future pass.
- Also fixed along the way: `/data/tsupdate` (the download cache) is world-writable, and a
  cached or resumed file used to be trusted by name with no verification — a pre-placed or
  tampered file there would have been silently used. Downloads and cache hits are now verified
  against the GitHub API's asset digest (falling back to size if no digest is available) before
  being trusted; asset filenames are reduced to a bare basename everywhere they're used, so a
  crafted name can't write outside the cache directory.

## Known weaknesses

Accepted for now, documented so they aren't mistaken for solved:

- **SSH host key MITM.** The SSH host *private* keys are committed to this public repo
  (`etc/ssh/ssh_host_*`), installed identically on every device, and host key regeneration is
  disabled ([tsOS-base.Pifile](../tsOS-base.Pifile)). Anyone can impersonate any device or
  man-in-the-middle an admin's SSH session. Key-based authentication doesn't leak the admin's
  key, but anything typed or shown in the session is exposed, and an admin who connects with
  agent forwarding (`ssh -A`) hands the attacker their agent — which then logs into real
  devices as `root`. Admins should never use agent forwarding to devices.
- **`pi` access is network access.** Until operator authentication lands (see Open items), the
  `pi` boundary doesn't keep anyone out: `tsconfig` is unauthenticated on `:80` on every
  interface (no firewall), including its web shell (which now execs `pi`'s own login shell
  directly rather than `su`-ing to a configurable user, but is still reachable by anyone who
  can reach the device); some BLE services don't require pairing; and `pi`'s password is
  public ([tsOS-base.Pifile](../tsOS-base.Pifile)). Every `pi` capability in this document is
  available to anyone who can reach the device — now including over cellular. The `pi`/`root`
  boundary still matters, because it caps what that access yields. This now explicitly
  includes the **full systemd journal** (every unit's logs, kernel messages included, not just
  the app-service subset `tsconfig.yml` configures — see "Service control") and **any
  NetworkManager connection and secret**, not just the three `tsconfig` manages — both
  deliberate broadenings made this session, worth naming plainly here since this bullet is
  where "how much does that access actually yield" is meant to be tallied honestly.
- **Physical access is root.** There is no secure boot, so anyone holding the SD card can read
  or change anything, including every secret stored on the device (see Non-goals).

## Summary: before vs. after

| Aspect | Before | After |
|---|---|---|
| `root` SSH keys | Same `authorized_keys` as `pi`, operator-editable | Individually-issued per-admin public keys, committed to this repo, baked in at build time, independent of boot partition; key-only, no password login |
| `root` password | Locked; root reachable via `pi`'s passwordless sudo | Locked, no password at all; no path from `pi` to `root` — SSH with a manufacturer key is the only way in |
| `pi` sudo | Member of `sudo`, passwordless (`do_sudo_pass 1`) | **No sudo access at all** — `etc/sudoers.d/tsos-pi` removed entirely; every privileged capability goes through polkit, group membership, or `pkexec` |
| NetworkManager access | Member of `netdev`; access via whatever polkit rule the OS happened to ship | Member of `netdev`; access via an explicit, repo-committed polkit rule (`etc/polkit-1/rules.d/10-tsos-netdev.rules`), passwordless — `pi` calls `nmcli` directly, no root mediation except netplan GSM field removal |
| Systemd unit actions | Sudoers allowlist, restart-only, 13 exact command lines | Polkit rule (`20-tsos-systemctl.rules`), every non-persistent verb (start/stop/restart/reload/...), same unit allowlist — `enable`/`disable`/`mask` categorically excluded (different polkit action) |
| Reboot | Root-mediated `tsconfig-privileged reboot`, root-side `systemd-run` delay timer | Direct `systemctl reboot` via logind's `org.freedesktop.login1.reboot` polkit action (`21-tsos-reboot.rules`); delay held in-process, authorization pre-checked with `pkcheck` |
| Log reads | Root-mediated `tsconfig-privileged logs`, allowlisted to `tsconfig.yml`'s configured services | `pi` in `systemd-journal` group; direct `journalctl`, full journal access (every unit, kernel) — a deliberate broadening, see "Service control" |
| `tsconfig-privileged` wrapper | Reached via `sudo -n`, sudoers is the "may pi invoke this" gate | Reached via `pkexec`, a custom polkit action (`systems.trackit.tsos.tsconfig-privileged`) is the "may pi invoke this" gate; scope narrowed to just config writes/deletes, overlay wipe, netplan GSM field removal |
| `/usr/local/src` ownership | `pi:pi` | `root:root`, mode `755` — `pi` can read, not write |
| `/boot/firmware` | VFAT, world-writable, bind-mounted to `/media/boot` | Root-owned mount, `0755` (readable by all, writable by root only); operator changes go through `tsconfig`'s privileged write-config op |
| Samba | Guest-writable share of all of `/media` | Only `/data` is shared |
| `copy-authorized-keys` | Runs as root, copies keys to `pi` and `root` | Runs as `pi`, copies `pi`'s keys only |
| `tsconfig.service` | Runs as root, no explicit `User=` | `User=pi`; every privileged action goes through polkit, group membership, or `pkexec` |
| `tsconfig`'s service allowlist | Read from world-writable `/boot/firmware/tsconfig.yml`, trusted directly (unauthenticated `start`/`stop`/`restart` on any listed unit) | No longer operator-writable (boot partition is root-owned); the real gate is the systemd polkit rule's hardcoded unit list |
| `tsupdate` | `User=root`, any source URL from `tsupdate.yml` | Full trigger/source control retained, restricted in code to `trackIT-Systems` org repos |
| `filebrowser` / `envsense` | Run as root, no sandboxing | `DynamicUser`, `ProtectSystem=strict`, scoped `ReadWritePaths` |
| SSH host keys | Committed to the public repo, identical on every device | Unchanged for now — known weakness |
| `/data` | World-accessible via `filebrowser` (noauth) | Unchanged — explicitly out of scope |
| WireGuard config | Root-owned config, `pi` incidental access | `pi` may read the key; writes go through `write-config`, which rejects `PreUp`/`PostUp`-style hooks |

## Migration

This design ships with the **next release** and applies to newly built images only — it is not
retrofitted onto already-deployed devices in place. Existing devices keep today's model (shared
root/`pi` keys, passwordless root sudo, `pi`-owned source trees) until they're replaced or
re-flashed under the new release; there's no in-place migration script. CI now skips delta
update generation until `DELTA_BASELINE` in `.github/workflows/build.yml` is set to this
release's actual tag — until then, no delta is published for any release, rather than risking
one being published across this boundary by mistake.

## Open items

- **Admin key lifecycle.** Who approves changes to `root/.ssh/authorized_keys` in this repo —
  write access to the repo is effectively the power to grant root (branch protection /
  CODEOWNERS)? Only one admin key is in there today; more need to be added before a real
  release. Revocation needs a rebuild and reflash, so a departed admin keeps access on every
  device built before; an SSH CA with short-lived certificates (`TrustedUserCAKeys`) would
  avoid that.
- **Operator authentication (later release):** an operator password for `pi`, and
  authentication for network access, `tsconfig`, and BLE pairing — the "`pi` access is network
  access" known weakness above.
- **Root SSH restricted to the WireGuard interface**, so manufacturer access requires being on
  the VPN.
- **Per-device SSH host keys** (generated at first boot, removed from the repo) to fix the MITM
  known weakness.
- **Fixes for already-released images.** The world-writable `tsconfig.yml` service-allowlist
  bug and the guest-writable Samba share both predate this design and could be patched on
  their own timeline rather than waiting for a full reflash - worth a decision on whether
  that's worth doing given devices need a reflash for the rest of this anyway.
