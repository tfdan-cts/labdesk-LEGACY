#!/bin/sh
# LabDesk installer for Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/tfdan-cts/LabDesk/master/install.sh | sudo sh
#
# Downloads the newest LabDesk release from GitHub, picks the package format
# that matches this distribution, and installs it. Re-running the script
# upgrades an existing installation in place.
#
# To point the client at a server as part of the install, set any of these:
#
#   LABDESK_HOST    ID / rendezvous server
#   LABDESK_RELAY   relay server
#   LABDESK_API     API server
#   LABDESK_KEY     server public key
#
# They must be set for the shell that sudo runs, so put them after sudo:
#
#   curl -fsSL .../install.sh | sudo LABDESK_HOST=id.example.com LABDESK_KEY=abc sh
#
# Setting them before curl instead does not work, because sudo does not pass
# the surrounding environment through by default. Any setting you leave out is
# left untouched.
#
# Trust model: the packages are downloaded over TLS from github.com and are not
# signed or checksummed by this project. A working TLS connection to GitHub is
# the whole of the trust chain. Read the script before piping it to root, as you
# should with any installer that works this way.
#
# Arch note: Arch ships LocalFileSigLevel = Optional, which accepts an unsigned
# local package, so pacman -U installs these. A host hardened to
# LocalFileSigLevel = Required will refuse; the script says so if that happens.

set -eu

REPO=tfdan-cts/LabDesk
API_LATEST="https://api.github.com/repos/$REPO/releases/latest"
API_LIST="https://api.github.com/repos/$REPO/releases?per_page=100"

die() { echo "labdesk: $*" >&2; exit 1; }
info() { echo "labdesk: $*"; }
warn() { echo "labdesk: warning: $*" >&2; }

[ "$(id -u)" = "0" ] || die "must run as root. Pipe to 'sudo sh' instead of 'sh'."
command -v curl >/dev/null 2>&1 || die "curl is required but not installed."

case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "unsupported architecture '$(uname -m)'. LabDesk ships x86_64 and aarch64 packages." ;;
esac

if command -v apt-get >/dev/null 2>&1; then
    manager=apt
    pattern="labdesk-[0-9][^/]*-${arch}\.deb"
elif command -v zypper >/dev/null 2>&1; then
    manager=zypper
    pattern="labdesk-[0-9][^/]*\.${arch}-suse\.rpm"
elif command -v dnf >/dev/null 2>&1; then
    manager=dnf
    pattern="labdesk-[0-9][^/]*\.${arch}\.rpm"
elif command -v yum >/dev/null 2>&1; then
    manager=yum
    pattern="labdesk-[0-9][^/]*\.${arch}\.rpm"
elif command -v pacman >/dev/null 2>&1; then
    [ "$arch" = "x86_64" ] || die "LabDesk ships an Arch package for x86_64 only, not $arch."
    manager=pacman
    pattern="labdesk-[0-9][^/]*-${arch}\.pkg\.tar\.zst"
else
    die "no supported package manager found (looked for apt-get, zypper, dnf, yum, pacman).
Install one of the .AppImage or .flatpak builds by hand instead:
  https://github.com/$REPO/releases/latest"
fi

info "installing for $arch using $manager"

tmp=$(mktemp -d)
# EXIT does the cleanup. INT and TERM only exit, which then fires EXIT: a
# handler that merely cleans up would delete the directory and let the script
# carry on with the package manager still reading from it.
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Fetch the release metadata to a file so that a transport or HTTP failure is
# reported as itself. Folding this into the pipeline below would turn a rate
# limit into "no package for your architecture", which sends people looking for
# a problem they do not have.
fetch_json() {
    _url=$1
    _out=$2
    _code=$(curl -sSL -w '%{http_code}' -o "$_out" "$_url" 2>"$tmp/curl.err") || {
        die "could not reach the GitHub API: $(cat "$tmp/curl.err")"
    }
    case "$_code" in
        200) ;;
        403 | 429)
            die "GitHub rate-limited this address (HTTP $_code). The API allows 60 unauthenticated
requests an hour per IP, so imaging several machines behind one address can hit it.
Wait and retry, or download the package by hand:
  https://github.com/$REPO/releases" ;;
        *) die "the GitHub API returned HTTP $_code. See https://github.com/$REPO/releases" ;;
    esac
}

# The asset names carry the application version rather than the release
# tag, so the download URL has to come from the metadata. Parsed with grep and
# sed because jq is not present on a stock image.
asset_url() {
    grep -o '"browser_download_url": *"[^"]*"' "$1" \
        | sed 's/.*"\(https[^"]*\)"/\1/' \
        | grep -E "/${pattern}$" \
        | head -n 1
}

# Prefer the full release, then fall back to the newest release that actually
# carries a package for this system. Taking /releases/latest and stopping there
# is what broke the Windows installer: the newest full release had no installer
# in it, and every later build was published as a pre-release, which that
# endpoint does not return.
fetch_json "$API_LATEST" "$tmp/release.json"
url=$(asset_url "$tmp/release.json") || true

if [ -z "${url:-}" ]; then
    info "the latest release has no $manager package for $arch, looking further back"
    fetch_json "$API_LIST" "$tmp/releases.json"
    # GitHub returns the list newest first, so the first match is the newest
    # release carrying this package.
    url=$(asset_url "$tmp/releases.json") || true
    [ -n "${url:-}" ] || die "no release carries a $manager package for $arch.
See https://github.com/$REPO/releases"
    warn "installing from a pre-release, because no full release has a $manager package for $arch."
fi

# The URL comes out of an API response, so check it points where it should
# before handing it to curl and the package manager as root. Release assets are
# always served from these two hosts.
case "$url" in
    "https://github.com/$REPO/releases/download/"*) ;;
    "https://objects.githubusercontent.com/"*) ;;
    *) die "refusing to install from an unexpected location:
  $url
Release assets should come from github.com/$REPO." ;;
esac

pkg="$tmp/${url##*/}"
info "downloading ${url##*/}"
curl -fsSL --retry 3 -o "$pkg" "$url" || die "download failed: $url"

# The previous package used a shared name. Its owned unit and package summary
# must both identify LabDesk before the installer can request its removal.
legacy_rpm_package() {
    unit=/usr/share/rustdesk/files/rustdesk.service
    [ -f "$unit" ] && [ ! -L "$unit" ] || return 0
    [ "$(rpm -qf --qf '%{NAME}' "$unit" 2>/dev/null || true)" = rustdesk ] || return 0
    [ "$(rpm -q --qf '%{SUMMARY}' rustdesk 2>/dev/null || true)" = 'LabDesk remote administration client' ] || return 0
    grep -qx 'Description=LabDesk' "$unit" || return 0
    printf '%s\n' rustdesk
}

legacy_arch_package() {
    unit=/usr/share/rustdesk/files/rustdesk.service
    [ -f "$unit" ] && [ ! -L "$unit" ] || return 0
    [ "$(LC_ALL=C pacman --query --owns --quiet "$unit" 2>/dev/null || true)" = rustdesk ] || return 0
    LC_ALL=C pacman --query --info rustdesk 2>/dev/null |
        grep -Eq '^Description[[:space:]]*:[[:space:]]*LabDesk remote administration client$' || return 0
    grep -qx 'Description=LabDesk' "$unit" || return 0
    printf '%s\n' rustdesk
}

info "installing $(basename "$pkg")"
legacy_args=""
if [ "$manager" = apt ]; then
    package_name=$(dpkg-deb -f "$pkg" Package) || die "download is not a Debian package"
    case "$package_name" in
        labdesk) ;;
        *) die "unexpected package identity: $package_name" ;;
    esac
    dpkg-deb --control "$pkg" "$tmp/control"
    [ -f "$tmp/control/preinst" ] || die "package is missing the migration preflight"
    legacy_packages=$(/bin/sh "$tmp/control/preinst" --legacy-package)
    for legacy in $legacy_packages; do
        case "$legacy" in
            rustdesk|rustdesk-unattended-wayland) legacy_args="$legacy_args $legacy-" ;;
            *) die "unexpected legacy package identity: $legacy" ;;
        esac
    done
elif [ "$manager" = pacman ]; then
    [ "$(LC_ALL=C pacman --query --file --quiet "$pkg")" = labdesk ] || die "unexpected Arch package identity"
    legacy=$(legacy_arch_package)
    [ -z "$legacy" ] || pacman --remove --noconfirm "$legacy"
else
    [ "$(rpm -qp --qf '%{NAME}' "$pkg")" = labdesk ] || die "unexpected RPM package identity"
    legacy=$(legacy_rpm_package)
    [ -z "$legacy" ] || rpm --erase "$legacy"
fi
case "$manager" in
    # Word splitting is intentional: every extra word was checked above and is
    # an apt removal request for a package proven to belong to this product.
    apt) apt-get install -y "$pkg" $legacy_args ;;
    dnf) dnf install -y "$pkg" ;;
    yum) yum install -y "$pkg" ;;
    zypper) zypper --non-interactive install --allow-unsigned-rpm "$pkg" ;;
    pacman)
        pacman -U --noconfirm "$pkg" || die "pacman refused the package.
LabDesk does not sign its packages. Stock Arch accepts that, because it ships
LocalFileSigLevel = Optional, so this host is likely set to Required. Either
install it deliberately with a config that relaxes LocalFileSigLevel, or fetch
the package and check it yourself first:
  $url"
        ;;
esac

command -v labdesk >/dev/null 2>&1 || die "install finished but the labdesk binary is not on PATH."

# Apply every setting that was supplied and report the ones that did not take,
# rather than dying part-way and leaving a half-pointed client with no record
# of which settings landed.
applied=""
failed=""
# `labdesk --option` exits 0 whatever happens: in the shipped source every
# branch, including "Installation and administrative privileges required!",
# returns None. Reading the value back is the only way to know whether the write
# landed. This also catches the case below, where there is no session to write
# to. The value is printed on its own line; take the last non-empty one.
set_option() {
    [ -n "${2:-}" ] || return 0
    labdesk --option "$1" "$2" >/dev/null 2>&1 || true
    actual=$(labdesk --option "$1" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 1 || true)
    if [ "$actual" = "$2" ]; then
        applied="$applied $1"
    else
        failed="$failed $1"
    fi
}

if [ -n "${LABDESK_HOST:-}${LABDESK_RELAY:-}${LABDESK_API:-}${LABDESK_KEY:-}" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet labdesk || systemctl start labdesk || true
    fi
    set_option custom-rendezvous-server "${LABDESK_HOST:-}"
    set_option relay-server "${LABDESK_RELAY:-}"
    set_option api-server "${LABDESK_API:-}"
    set_option key "${LABDESK_KEY:-}"
    if [ -n "$applied" ]; then info "applied:$applied"; fi
    if [ -n "$failed" ]; then
        warn "could not apply:$failed
The client is installed but is not pointed at your server. Settings are written
through the LabDesk instance running in a logged-in user's session, not through
the root service, so on a machine nobody has logged into yet there is nothing to
write to. Log in on this machine once, then set them:
  sudo labdesk --option custom-rendezvous-server <host>
Or set them in the GUI under Settings > Network."
    fi
else
    info "no server settings given, so none were changed"
fi

# Wayland has had experimental support since 1.2.0, so a Wayland desktop works.
# What does not work is reaching the *login screen* after a reboot or logout,
# which still needs X11. Say so rather than let someone discover it the first
# time a machine reboots with nobody sitting at it.
session="${XDG_SESSION_TYPE:-}"
if [ -z "$session" ] && [ -n "$(find /run/user -maxdepth 2 -name 'wayland-*' -print -quit 2>/dev/null)" ]; then
    session=wayland
fi
if [ "$session" = "wayland" ]; then
    gdm_conf=""
    for f in /etc/gdm/custom.conf /etc/gdm3/custom.conf; do
        [ -f "$f" ] && gdm_conf="$f" && break
    done
    if [ -n "$gdm_conf" ]; then
        warn "this machine is running a Wayland session.
Wayland support is experimental, and connecting to the login screen after a
reboot or logout is not supported on it. To reach this machine when nobody is
logged in, switch the login screen to X11 and reboot:
  sudo sed -i 's/^#*WaylandEnable=.*/WaylandEnable=false/' $gdm_conf"
    else
        warn "this machine is running a Wayland session.
Wayland support is experimental, and connecting to the login screen after a
reboot or logout is not supported on it. Screen capture goes through the
desktop's portal, so xdg-desktop-portal and the backend for this compositor
need to be installed and running.
No GDM configuration was found here, so the X11 switch documented upstream does
not apply. On a compositor with no X11 session at all, such as Hyprland or
Sway, there is no login-screen workaround."
    fi
    if [ "$manager" = "apt" ] && [ "$arch" = "x86_64" ]; then
        warn "LabDesk also publishes a separate 'labdesk-unattended-wayland' deb that
captures through DRM/KMS with no X11 switch. It is a distinct package on purpose
because it bypasses the desktop's consent prompt and injects input as root, so
install it deliberately rather than as part of a routine setup:
  https://github.com/$REPO/releases/latest"
    fi
fi

info "done. Launch LabDesk from your applications menu or run 'labdesk'."
