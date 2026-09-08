Name:       labdesk
Version:    1.4.0
Release:    0
Summary:    LabDesk remote administration client
License:    GPL-3.0
URL:        https://lab-desk.net
Vendor:     LabDesk
Requires:   gtk3 libxcb libXfixes alsa-lib libva pam gstreamer1-plugins-base
Recommends: libayatana-appindicator-gtk3 libxdo
Provides:   libdesktop_drop_plugin.so()(64bit), libdesktop_multi_window_plugin.so()(64bit), libfile_selector_linux_plugin.so()(64bit), libflutter_custom_cursor_plugin.so()(64bit), libflutter_linux_gtk.so()(64bit), libscreen_retriever_plugin.so()(64bit), libtray_manager_plugin.so()(64bit), liburl_launcher_linux_plugin.so()(64bit), libwindow_manager_plugin.so()(64bit), libwindow_size_plugin.so()(64bit), libtexture_rgba_renderer_plugin.so()(64bit)

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
Remote administration client for the machines you look after.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

# %global __python %{__python3}

%install

mkdir -p "%{buildroot}/usr/share/labdesk" && cp -r ${HBB}/flutter/build/linux/x64/release/bundle/* -t "%{buildroot}/usr/share/labdesk"
# labnet: the NetBird client fetched by third_party/netbird/fetch.py, when present.
if [ -d "${HBB}/netbird-dist" ]; then mkdir -p "%{buildroot}/usr/share/labdesk/netbird" && cp -r ${HBB}/netbird-dist/* -t "%{buildroot}/usr/share/labdesk/netbird"; fi
mkdir -p "%{buildroot}/usr/bin"
install -Dm 644 $HBB/res/labdesk.service -t "%{buildroot}/usr/share/labdesk/files"
install -Dm 644 $HBB/res/labdesk.desktop -t "%{buildroot}/usr/share/labdesk/files"
install -Dm 644 $HBB/res/labdesk-link.desktop -t "%{buildroot}/usr/share/labdesk/files"
install -Dm 644 $HBB/res/128x128@2x.png "%{buildroot}/usr/share/icons/hicolor/256x256/apps/labdesk.png"
install -Dm 644 $HBB/res/scalable.svg "%{buildroot}/usr/share/icons/hicolor/scalable/apps/labdesk.svg"
# The update helper and the polkit action that names it. src/updater.rs's Linux arm calls the
# helper by this absolute path, so an rpm built without these two lines can never install an update.
install -Dm 755 $HBB/res/labdesk-helper "%{buildroot}/usr/share/labdesk/labdesk-helper"
install -Dm 644 $HBB/res/release-signing-public-key "%{buildroot}/usr/share/labdesk/release-signing-public-key"
install -Dm 644 $HBB/res/polkit/net.lab-desk.LabDesk.policy "%{buildroot}/usr/share/polkit-1/actions/net.lab-desk.LabDesk.policy"

%files
/usr/share/labdesk/*
/usr/share/labdesk/files/labdesk.service
/usr/share/icons/hicolor/256x256/apps/labdesk.png
/usr/share/icons/hicolor/scalable/apps/labdesk.svg
/usr/share/polkit-1/actions/net.lab-desk.LabDesk.policy
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
ln -sf /usr/share/labdesk/labdesk /usr/bin/labdesk
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
    rm /usr/bin/labdesk || true
    rmdir /usr/lib/labdesk || true
    rmdir /usr/local/labdesk || true
    rmdir /usr/share/labdesk || true
    rm /usr/share/applications/labdesk.desktop || true
    rm /usr/share/applications/labdesk-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
    rmdir /usr/lib/labdesk || true
    rmdir /usr/local/labdesk || true
  ;;
esac
