Name:       labdesk
Version:    1.4.0
Release:    0
Summary:    LabDesk remote administration client
License:    GPL-3.0
URL:        https://lab-desk.net
Vendor:     LabDesk
Requires:   gtk3 libxcb1 libXfixes3 alsa-utils libXtst6 libva2 pam gstreamer-plugins-base gstreamer-plugin-pipewire
Recommends: libayatana-appindicator3-1 xdotool

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
Remote administration client for the machines you look after.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

%global __python %{__python3}

%install
mkdir -p %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/share/labdesk/
mkdir -p %{buildroot}/usr/share/labdesk/files/
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps/
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps/
install -m 755 $HBB/target/release/labdesk %{buildroot}/usr/bin/labdesk
install $HBB/libsciter-gtk.so %{buildroot}/usr/share/labdesk/libsciter-gtk.so
install $HBB/res/labdesk.service %{buildroot}/usr/share/labdesk/files/
install $HBB/res/128x128@2x.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/labdesk.png
install $HBB/res/scalable.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/labdesk.svg
install $HBB/res/labdesk.desktop %{buildroot}/usr/share/labdesk/files/
install $HBB/res/labdesk-link.desktop %{buildroot}/usr/share/labdesk/files/

install -Dm 755 $HBB/res/labdesk-helper "%{buildroot}/usr/share/labdesk/labdesk-helper"
install -Dm 644 $HBB/res/release-signing-public-key "%{buildroot}/usr/share/labdesk/release-signing-public-key"
install -Dm 644 $HBB/res/polkit/net.lab-desk.LabDesk.policy "%{buildroot}/usr/share/polkit-1/actions/net.lab-desk.LabDesk.policy"

%files
/usr/share/labdesk/labdesk-helper
/usr/share/labdesk/release-signing-public-key
/usr/share/polkit-1/actions/net.lab-desk.LabDesk.policy
/usr/bin/labdesk
/usr/share/labdesk/libsciter-gtk.so
/usr/share/labdesk/files/labdesk.service
/usr/share/icons/hicolor/256x256/apps/labdesk.png
/usr/share/icons/hicolor/scalable/apps/labdesk.svg
/usr/share/labdesk/files/labdesk.desktop
/usr/share/labdesk/files/labdesk-link.desktop

%changelog
# let's skip this for now

%pre
legacy_rpm_package() {
    unit=/usr/share/rustdesk/files/rustdesk.service
    [ -f "$unit" ] && [ ! -L "$unit" ] || return 0
    [ "$(rpm -qf --qf '%%{NAME}' "$unit" 2>/dev/null || true)" = rustdesk ] || return 0
    [ "$(rpm -q --qf '%%{SUMMARY}' rustdesk 2>/dev/null || true)" = 'LabDesk remote administration client' ] || return 0
    grep -qx 'Description=LabDesk' "$unit" || return 0
    printf '%s\n' rustdesk
}
if [ -n "$(legacy_rpm_package)" ]; then
    echo "LabDesk: use the LabDesk Linux installer to migrate the previous package safely." >&2
    exit 1
fi
# can do something for centos7
case "$1" in
  1)
    # for install
  ;;
  2)
    # for upgrade
    systemctl stop labdesk || true
  ;;
esac

%post
cp /usr/share/labdesk/files/labdesk.service /etc/systemd/system/labdesk.service
cp /usr/share/labdesk/files/labdesk.desktop /usr/share/applications/
cp /usr/share/labdesk/files/labdesk-link.desktop /usr/share/applications/
systemctl daemon-reload
systemctl enable labdesk
systemctl start labdesk
update-desktop-database

%preun
case "$1" in
  0)
    # for uninstall
    systemctl stop labdesk || true
    systemctl disable labdesk || true
    rm /etc/systemd/system/labdesk.service || true
  ;;
  1)
    # for upgrade
  ;;
esac

%postun
case "$1" in
  0)
    # for uninstall
    rm /usr/share/applications/labdesk.desktop || true
    rm /usr/share/applications/labdesk-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
  ;;
esac
