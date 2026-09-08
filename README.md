<p align="center">
  <img src="res/logo-header.svg" alt="LabDesk"><br>
</p>

# LabDesk

LabDesk is a remote administration client for people who look after fleets of machines across
separate networks. It is its own application: LabDesk Connect is the remote-access feature, Fleet
is the management console, and Labnet is the encrypted machine-to-machine network that carries
both, brokered by [lab-desk.net](https://lab-desk.net).

## What LabDesk does

LabDesk opens on a **console**. It is the whole interface rather than a screen beside one: a
single sidebar carrying Connect, Fleet, Health, Terminal, Actions, This machine and Settings.

- **Connect** is where you work: pick a machine from your fleet, recent sessions or favourites,
  and open a desktop, file-transfer or terminal session. Every session is authorised by the
  broker and carried over Labnet, and a revoked grant ends the session.
- **Fleet** shows reachability across the session. Every machine's recent checks are drawn as a
  strip rather than a single dot, so a machine that keeps dropping looks different from one that
  is simply down, and a machine nobody has asked about yet reads as unknown rather than offline.
- **Health** shows what LabDesk can honestly read from a machine, and says plainly when it can
  read nothing rather than showing zeroes.
- **Terminal** and **Actions** act on the machine selected in Fleet. Actions that need an open
  session are disabled with their reason shown, never hidden and never inert.
- **This machine** is this computer's own identity, its enrollment, and whether the background
  service and the Labnet tunnel are running.
- **Settings** nests its pages in the same sidebar, so there is one place to navigate.

Underneath that:

- **Labnet**: each enrolled machine joins an owned WireGuard overlay. A remote session is a
  temporary, one-way rule between two machines; a labnet is a persistent group a machine joins
  only after approval on the machine itself.
- **Machine groups** and **machine icons**: organise machines into local groups with themed
  icons.
- **Live reachability**: green, red, and a real unknown state, with a manual refresh for an
  immediate re-check.
- **Purple theme and branding** throughout, including the installer.

## Installing

### Windows

From an elevated PowerShell prompt:

```powershell
irm https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.ps1 | iex
```

This finds the newest release that publishes a
`LabDesk-<version>-<arch>-install.exe`, installs it unattended, and verifies the
installation registered before reporting success. Re-running it upgrades in
place.

That setup binary is the only build that installs the LabDesk layout, so the
script installs nothing else. If no release publishes one for this machine's
architecture, it says so and stops without changing anything. A full release is
preferred; when only a pre-release carries the installer, the script says which
pre-release it is about to install before it does.

To pass settings during the install, download the script first, because piping
to `iex` leaves no way to pass parameters. Windows refuses to run downloaded
scripts under its default execution policy, so bypass it for this one run:

```powershell
irm https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Server id.example.com -Relay relay.example.com -Api https://api.example.com -Key YOURKEY
```

Every parameter is optional, and any setting you leave out is left untouched.
Each setting is read back after it is written, so the script reports a failure
rather than claiming success on a setting that did not apply.

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.sh | sudo sh
```

The script detects the architecture and the package manager, then installs the
matching `.deb`, `.rpm`, or `.pkg.tar.zst` from the newest full release. Unlike
the Windows script it does not consider pre-releases, because every full release
carries the Linux packages. It supports apt, dnf, yum, zypper, and pacman on
x86_64 and aarch64, and it installs the `labdesk` systemd service along with the
desktop entries. Re-running it upgrades in place, and an installation from a
release before the package rename is migrated in place.

Settings are passed as environment variables:

```sh
curl -fsSL https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.sh   | sudo LABDESK_HOST=id.example.com LABDESK_KEY=YOURKEY sh
```

`LABDESK_HOST`, `LABDESK_RELAY`, `LABDESK_API`, and `LABDESK_KEY` are all
optional, and any setting you leave out is left untouched. They have to be set
for the shell that `sudo` runs, which is why they go after `sudo` and not before
`curl`.

On a Wayland session the script warns that screen capture and unattended access
need X11, and prints the change required to switch. LabDesk also publishes a
separate `labdesk-unattended-wayland` package that captures through DRM/KMS
without switching to X11. It is a distinct package because it bypasses the
desktop's consent prompt, so install it deliberately rather than as routine.

### Offline or hand-delivered installs

`LabDesk-<version>-x86_64-install.exe` and `LabDesk-<version>-aarch64-install.exe`
are ordinary Windows installers. Copy one to a flash drive, double-click it on
the target machine, and it installs without needing a network connection or a
terminal. They are the standard build renamed: the client treats any executable
whose filename ends in `install.exe` as a setup program.

Take them from the [full list of releases](https://github.com/tfdan-cts/LabDesk/releases),
not from the `releases/latest` link. That link resolves to the newest release
that is not marked pre-release, and these files are so far published only on
pre-releases, so it will not show them.

Add `--silent-install` to run one without any interface:

```powershell
.\LabDesk-1.2.0-x86_64-install.exe --silent-install
```

### Uninstalling

On Windows, use *Settings > Apps > Installed apps*, or run this from an elevated
prompt:

```powershell
& "$env:ProgramFiles\LabDesk\LabDesk.exe" --uninstall
```

On Linux, remove the package with the same tool that installed it:

```sh
sudo apt remove labdesk       # Debian, Ubuntu
sudo dnf remove labdesk       # Fedora, RHEL
sudo zypper remove labdesk    # openSUSE
sudo pacman -R labdesk        # Arch
```

Neither removes your settings. Machine groups and icons live in the
configuration directory (`%APPDATA%\LabDesk` on Windows, `~/.config/labdesk`
on Linux, lower case) and survive an uninstall, so reinstalling restores them.
Delete that directory if you want a clean slate.

On Windows the service keeps a second copy of the configuration under its own
account's profile, holding the enrollment and the peer history. Uninstalling
with the `.exe` installer removes it. Uninstalling an `.msi` installation does not,
because Windows Installer only removes what it installed and that directory is
written at runtime. Clear it explicitly before handing a machine on:

```powershell
& "$env:ProgramFiles\LabDesk\LabDesk.exe" --remove-service-config
```

Run that before uninstalling, while the program is still present.

## Downloads

Packaged builds for **Windows, macOS, Linux (deb/rpm/AppImage/flatpak), and Android** are on the [Releases page](https://github.com/tfdan-cts/LabDesk/releases).

Binaries are unsigned; on Windows, SmartScreen will warn on first run. Binary filenames are `labdesk-<version>-<arch>.<kind>` on every platform.

LabDesk uses its own configuration directory and generates its own machine identity, so it can be installed alongside other remote-desktop tools without conflicts.

## Building

`build.py` is the build entry point on every platform and `.github/workflows/flutter-build.yml`
records the pinned toolchains and the exact steps CI runs. `docs/WORKFLOW.md` is the binding
branch and release workflow.

## License

LabDesk is licensed under [AGPL-3.0](LICENCE).

The remote-access engine inside LabDesk Connect is derived from an AGPL-3.0 upstream project.
Based on RustDesk (rustdesk/rustdesk at commit `1d09760ef`, release line 1.4.9), modified from
2026-08-11 onward by the LabDesk maintainers; AGPL-3.0 section 5(a) asks a modified work to say so
and to carry the date. The copyright notices of the upstream authors are kept in the source, and
every included third-party component is listed in [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md). The
commit history in this repository is the full record of what changed.

Please report LabDesk problems here, not to the upstream project. Bugs in a
modified build are not theirs to answer for.

> [!Caution]
> **Misuse Disclaimer:** The developers do not condone or support any unethical or illegal use of this software. Misuse, such as unauthorized access, control, or invasion of privacy, is strictly against our guidelines.