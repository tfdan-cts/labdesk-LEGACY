# labdesk_desktop_multi_window

LabDesk's multi-window plugin for Windows, Linux and macOS. It opens the remote
desktop, file transfer and port forward windows as separate Flutter windows and
registers the plugins those windows need.

It is derived from `desktop_multi_window` by MixinNetwork (Apache-2.0, see
`LICENSE`), taken from the fork at
https://github.com/rustdesk-org/rustdesk_desktop_multi_window commit
533883bcb0ffe91a9afdb13b8bac9b14b3e054ba and renamed for LabDesk: the package,
plugin target and include directory are `labdesk_desktop_multi_window`, the
Win32 window class is `LabDeskMultiWindow`, the DLL carries LabDesk version
information and icon, and Linux sub-windows look up the `labdesk` theme icon.
Behaviour and performance are unchanged.