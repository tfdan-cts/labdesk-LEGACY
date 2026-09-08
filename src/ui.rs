use std::{
    collections::HashMap,
    iter::FromIterator,
    sync::{Arc, Mutex},
};

use sciter::Value;

use hbb_common::{
    allow_err,
    config::{LocalConfig, PeerConfig},
    log,
};

#[cfg(not(feature = "flutter"))]
use crate::ui_session_interface::Session;
use crate::{common::get_app_name, ipc, ui_interface::*};

mod cm;
#[cfg(feature = "inline")]
pub mod inline;
pub mod remote;

#[allow(dead_code)]
type Status = (i32, bool, i64, String);

lazy_static::lazy_static! {
    // stupid workaround for https://sciter.com/forums/topic/crash-on-latest-tis-mac-sdk-sometimes/
    static ref STUPID_VALUES: Mutex<Vec<Arc<Vec<Value>>>> = Default::default();
}

#[cfg(not(feature = "flutter"))]
lazy_static::lazy_static! {
    pub static ref CUR_SESSION: Arc<Mutex<Option<Session<remote::SciterHandler>>>> = Default::default();
}

struct UIHostHandler;

pub fn start(args: &mut [String]) {
    #[cfg(target_os = "macos")]
    crate::platform::delegate::show_dock();
    #[cfg(all(target_os = "linux", feature = "inline"))]
    {
        let app_dir = std::env::var("APPDIR").unwrap_or("".to_string());
        let mut so_path = "/usr/share/labdesk/libsciter-gtk.so".to_owned();
        for (prefix, dir) in [
            ("", "/usr"),
            ("", "/app"),
            (&app_dir, "/usr"),
            (&app_dir, "/app"),
        ]
        .iter()
        {
            let path = format!("{prefix}{dir}/share/labdesk/libsciter-gtk.so");
            if std::path::Path::new(&path).exists() {
                so_path = path;
                break;
            }
        }
        sciter::set_library(&so_path).ok();
    }
    #[cfg(windows)]
    // Check if there is a sciter.dll nearby.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let sciter_dll_path = parent.join("sciter.dll");
            if sciter_dll_path.exists() {
                // Try to set the sciter dll.
                let p = sciter_dll_path.to_string_lossy().to_string();
                log::debug!("Found dll:{}, \n {:?}", p, sciter::set_library(&p));
            }
        }
    }
    // https://github.com/c-smile/sciter-sdk/blob/master/include/sciter-x-types.h
    // https://github.com/rustdesk/rustdesk/issues/132#issuecomment-886069737
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::GfxLayer(
        sciter::GFX_LAYER::WARP
    )));
    use sciter::SCRIPT_RUNTIME_FEATURES::*;
    allow_err!(sciter::set_options(sciter::RuntimeOptions::ScriptFeatures(
        ALLOW_FILE_IO as u8 | ALLOW_SOCKET_IO as u8 | ALLOW_EVAL as u8 | ALLOW_SYSINFO as u8
    )));
    let mut frame = sciter::WindowBuilder::main_window().create();
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::UxTheming(true)));
    frame.set_title(&crate::get_app_name());
    #[cfg(target_os = "macos")]
    crate::platform::delegate::make_menubar(frame.get_host(), args.is_empty());
    #[cfg(windows)]
    crate::platform::try_set_window_foreground(frame.get_hwnd() as _);
    let page;
    if args.len() > 1 && args[0] == "--play" {
        args[0] = "--connect".to_owned();
        let path: std::path::PathBuf = (&args[1]).into();
        let id = path
            .file_stem()
            .map(|p| p.to_str().unwrap_or(""))
            .unwrap_or("")
            .to_owned();
        args[1] = id;
    }
    if args.is_empty() {
        std::thread::spawn(move || check_zombie());
        crate::common::check_software_update();
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        page = "index.html";
        // Start pulse audio local server.
        #[cfg(target_os = "linux")]
        std::thread::spawn(crate::ipc::start_pa);
    } else if args[0] == "--install" {
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        page = "install.html";
    } else if args[0] == "--cm" {
        frame.register_behavior("connection-manager", move || {
            Box::new(cm::SciterConnectionManager::new())
        });
        page = "cm.html";
        *cm::HIDE_CM.lock().unwrap() = crate::ipc::get_config("hide_cm")
            .ok()
            .flatten()
            .unwrap_or_default()
            == "true";
    } else if (args[0] == "--connect"
        || args[0] == "--file-transfer"
        || args[0] == "--port-forward"
        || args[0] == "--rdp")
        && args.len() > 1
    {
        #[cfg(windows)]
        {
            let hw = frame.get_host().get_hwnd();
            crate::platform::windows::enable_lowlevel_keyboard(hw as _);
        }
        let mut iter = args.iter();
        let Some(cmd) = iter.next() else {
            log::error!("Failed to get cmd arg");
            return;
        };
        let cmd = cmd.to_owned();
        let Some(id) = iter.next() else {
            log::error!("Failed to get id arg");
            return;
        };
        let id = id.to_owned();
        let pass = iter.next().unwrap_or(&"".to_owned()).clone();
        let args: Vec<String> = iter.map(|x| x.clone()).collect();
        frame.set_title(&id);
        frame.register_behavior("native-remote", move || {
            let handler =
                remote::SciterSession::new(cmd.clone(), id.clone(), pass.clone(), args.clone());
            #[cfg(not(feature = "flutter"))]
            {
                *CUR_SESSION.lock().unwrap() = Some(handler.inner());
            }
            Box::new(handler)
        });
        page = "remote.html";
    } else {
        log::error!("Wrong command: {:?}", args);
        return;
    }
    #[cfg(feature = "inline")]
    {
        let html = if page == "index.html" {
            inline::get_index()
        } else if page == "cm.html" {
            inline::get_cm()
        } else if page == "install.html" {
            inline::get_install()
        } else {
            inline::get_remote()
        };
        frame.load_html(html.as_bytes(), Some(page));
    }
    #[cfg(not(feature = "inline"))]
    frame.load_file(&format!(
        "file://{}/src/ui/{}",
        std::env::current_dir()
            .map(|c| c.display().to_string())
            .unwrap_or("".to_owned()),
        page
    ));
    let hide_cm = *cm::HIDE_CM.lock().unwrap();
    if !args.is_empty() && args[0] == "--cm" && hide_cm {
        // run_app calls expand(show) + run_loop, we use collapse(hide) + run_loop instead to create a hidden window
        frame.collapse(true);
        frame.run_loop();
        return;
    }
    frame.run_app();
}

struct UI {}

impl UI {
    fn recent_sessions_updated(&self) -> bool {
        recent_sessions_updated()
    }

    fn get_id(&self) -> String {
        ipc::get_id()
    }

    fn temporary_password(&mut self) -> String {
        temporary_password()
    }

    fn update_temporary_password(&self) {
        update_temporary_password()
    }

    fn set_permanent_password(&self, password: String) {
        let _ = set_permanent_password_with_result(password);
    }

    fn is_local_permanent_password_set(&self) -> bool {
        is_local_permanent_password_set()
    }

    fn is_permanent_password_set(&self) -> bool {
        is_permanent_password_set()
    }

    fn get_remote_id(&mut self) -> String {
        LocalConfig::get_remote_id()
    }

    fn set_remote_id(&mut self, id: String) {
        LocalConfig::set_remote_id(&id);
    }

    fn goto_install(&mut self) {
        goto_install();
    }

    fn install_me(&mut self, _options: String, _path: String) {
        install_me(_options, _path, false, false);
    }

    fn update_me(&self, _path: String) {
        update_me(_path);
    }

    fn run_without_install(&self) {
        run_without_install();
    }

    fn show_run_without_install(&self) -> bool {
        show_run_without_install()
    }

    fn get_license(&self) -> String {
        get_license()
    }

    fn get_option(&self, key: String) -> String {
        get_option(key)
    }

    fn get_local_option(&self, key: String) -> String {
        get_local_option(key)
    }

    fn set_local_option(&self, key: String, value: String) {
        set_local_option(key, value);
    }

    fn peer_has_password(&self, id: String) -> bool {
        peer_has_password(id)
    }

    fn forget_password(&self, id: String) {
        forget_password(id)
    }

    fn get_peer_option(&self, id: String, name: String) -> String {
        get_peer_option(id, name)
    }

    fn set_peer_option(&self, id: String, name: String, value: String) {
        set_peer_option(id, name, value)
    }

    fn using_public_server(&self) -> bool {
        crate::using_public_server()
    }

    fn is_incoming_only(&self) -> bool {
        hbb_common::config::is_incoming_only()
    }

    pub fn is_outgoing_only(&self) -> bool {
        hbb_common::config::is_outgoing_only()
    }

    pub fn is_custom_client(&self) -> bool {
        crate::common::is_custom_client()
    }

    pub fn is_disable_settings(&self) -> bool {
        hbb_common::config::is_disable_settings()
    }

    pub fn is_disable_account(&self) -> bool {
        hbb_common::config::is_disable_account()
    }

    pub fn is_disable_installation(&self) -> bool {
        hbb_common::config::is_disable_installation()
    }

    pub fn is_disable_ab(&self) -> bool {
        hbb_common::config::is_disable_ab()
    }

    fn get_options(&self) -> Value {
        let hashmap: HashMap<String, String> =
            serde_json::from_str(&get_options()).unwrap_or_default();
        let mut m = Value::map();
        for (k, v) in hashmap {
            m.set_item(k, v);
        }
        m
    }

    fn test_if_valid_server(&self, host: String, test_with_proxy: bool) -> String {
        test_if_valid_server(host, test_with_proxy)
    }

    fn get_sound_inputs(&self) -> Value {
        Value::from_iter(get_sound_inputs())
    }

    fn set_options(&self, v: Value) {
        let mut m = HashMap::new();
        for (k, v) in v.items() {
            if let Some(k) = k.as_string() {
                if let Some(v) = v.as_string() {
                    if !v.is_empty() {
                        m.insert(k, v);
                    }
                }
            }
        }
        set_options(m);
    }

    fn set_option(&self, key: String, value: String) {
        set_option(key, value);
    }

    fn install_path(&mut self) -> String {
        install_path()
    }

    fn install_options(&self) -> String {
        install_options()
    }

    fn get_socks(&self) -> Value {
        Value::from_iter(get_socks())
    }

    fn set_socks(&self, proxy: String, username: String, password: String) {
        set_socks(proxy, username, password)
    }

    fn is_installed(&self) -> bool {
        is_installed()
    }

    fn get_supported_privacy_mode_impls(&self) -> String {
        serde_json::to_string(&crate::privacy_mode::get_supported_privacy_mode_impl())
            .unwrap_or_default()
    }

    fn is_root(&self) -> bool {
        is_root()
    }

    fn is_release(&self) -> bool {
        #[cfg(not(debug_assertions))]
        return true;
        #[cfg(debug_assertions)]
        return false;
    }

    fn is_share_rdp(&self) -> bool {
        is_share_rdp()
    }

    fn set_share_rdp(&self, _enable: bool) {
        set_share_rdp(_enable);
    }

    fn is_installed_lower_version(&self) -> bool {
        is_installed_lower_version()
    }

    fn closing(&mut self, x: i32, y: i32, w: i32, h: i32) {
        crate::server::input_service::fix_key_down_timeout_at_exit();
        LocalConfig::set_size(x, y, w, h);
    }

    fn get_size(&mut self) -> Value {
        let s = LocalConfig::get_size();
        let mut v = Vec::new();
        v.push(s.0);
        v.push(s.1);
        v.push(s.2);
        v.push(s.3);
        Value::from_iter(v)
    }

    fn get_mouse_time(&self) -> f64 {
        get_mouse_time()
    }

    fn check_mouse_time(&self) {
        check_mouse_time()
    }

    fn get_connect_status(&mut self) -> Value {
        let mut v = Value::array(0);
        let x = get_connect_status();
        v.push(x.status_num);
        v.push(x.key_confirmed);
        v.push(x.id);
        v
    }

    #[inline]
    fn get_peer_value(id: String, p: PeerConfig) -> Value {
        let values = vec![
            id,
            p.info.username.clone(),
            p.info.hostname.clone(),
            p.info.platform.clone(),
            p.options.get("alias").unwrap_or(&"".to_owned()).to_owned(),
        ];
        Value::from_iter(values)
    }

    fn get_peer(&self, id: String) -> Value {
        let c = get_peer(id.clone());
        Self::get_peer_value(id, c)
    }

    fn get_fav(&self) -> Value {
        Value::from_iter(get_fav())
    }

    fn store_fav(&self, fav: Value) {
        let mut tmp = vec![];
        fav.values().for_each(|v| {
            if let Some(v) = v.as_string() {
                if !v.is_empty() {
                    tmp.push(v);
                }
            }
        });
        store_fav(tmp);
    }

    fn get_recent_sessions(&mut self) -> Value {
        // to-do: limit number of recent sessions, and remove old peer file
        let peers: Vec<Value> = PeerConfig::peers(None)
            .drain(..)
            .map(|p| Self::get_peer_value(p.0, p.2))
            .collect();
        Value::from_iter(peers)
    }

    fn get_icon(&mut self) -> String {
        get_icon()
    }

    fn remove_peer(&mut self, id: String) {
        PeerConfig::remove(&id);
    }

    fn remove_discovered(&mut self, id: String) {
        remove_discovered(id);
    }

    fn send_wol(&mut self, id: String) {
        crate::lan::send_wol(id)
    }

    fn new_remote(&mut self, id: String, remote_type: String, force_relay: bool) {
        new_remote(id, remote_type, force_relay)
    }

    fn is_process_trusted(&mut self, _prompt: bool) -> bool {
        is_process_trusted(_prompt)
    }

    fn is_can_screen_recording(&mut self, _prompt: bool) -> bool {
        is_can_screen_recording(_prompt)
    }

    fn is_installed_daemon(&mut self, _prompt: bool) -> bool {
        is_installed_daemon(_prompt)
    }

    fn get_error(&mut self) -> String {
        get_error()
    }

    fn is_login_wayland(&mut self) -> bool {
        is_login_wayland()
    }

    fn current_is_wayland(&mut self) -> bool {
        current_is_wayland()
    }

    fn get_software_update_url(&self) -> String {
        crate::SOFTWARE_UPDATE_URL.lock().unwrap().clone()
    }

    fn get_new_version(&self) -> String {
        get_new_version()
    }

    fn get_version(&self) -> String {
        get_version()
    }

    fn get_fingerprint(&self) -> String {
        get_fingerprint()
    }

    fn get_app_name(&self) -> String {
        get_app_name()
    }

    fn get_software_ext(&self) -> String {
        #[cfg(windows)]
        let p = "exe";
        #[cfg(target_os = "macos")]
        let p = "dmg";
        #[cfg(target_os = "linux")]
        let p = "deb";
        p.to_owned()
    }

    fn get_software_store_path(&self) -> String {
        let mut p = std::env::temp_dir();
        let name = crate::SOFTWARE_UPDATE_URL
            .lock()
            .unwrap()
            .split("/")
            .last()
            .map(|x| x.to_owned())
            .unwrap_or(crate::get_app_name());
        p.push(name);
        format!("{}.{}", p.to_string_lossy(), self.get_software_ext())
    }

    fn create_shortcut(&self, _id: String) {
        #[cfg(windows)]
        create_shortcut(_id)
    }

    fn discover(&self) {
        std::thread::spawn(move || {
            allow_err!(crate::lan::discover());
        });
    }

    fn get_lan_peers(&self) -> String {
        // let peers = get_lan_peers()
        //     .into_iter()
        //     .map(|mut peer| {
        //         (
        //             peer.remove("id").unwrap_or_default(),
        //             peer.remove("username").unwrap_or_default(),
        //             peer.remove("hostname").unwrap_or_default(),
        //             peer.remove("platform").unwrap_or_default(),
        //         )
        //     })
        //     .collect::<Vec<(String, String, String, String)>>();
        serde_json::to_string(&get_lan_peers()).unwrap_or_default()
    }

    fn get_uuid(&self) -> String {
        get_uuid()
    }

    fn open_url(&self, url: String) {
        #[cfg(windows)]
        let p = "explorer";
        #[cfg(target_os = "macos")]
        let p = "open";
        #[cfg(target_os = "linux")]
        let p = if std::path::Path::new("/usr/bin/firefox").exists() {
            "firefox"
        } else {
            "xdg-open"
        };
        allow_err!(std::process::Command::new(p).arg(url).spawn());
    }

    fn change_id(&self, id: String) {
        reset_async_job_status();
        let old_id = self.get_id();
        change_id_shared(id, old_id);
    }

    fn http_request(&self, url: String, method: String, body: Option<String>, header: String) {
        http_request(url, method, body, header)
    }

    fn post_request(&self, url: String, body: String, header: String) {
        post_request(url, body, header)
    }

    fn is_ok_change_id(&self) -> bool {
        hbb_common::machine_uid::get().is_ok()
    }

    fn get_async_job_status(&self) -> String {
        get_async_job_status()
    }

    fn get_http_status(&self, url: String) -> Option<String> {
        get_async_http_status(url)
    }

    fn t(&self, name: String) -> String {
        crate::client::translate(name)
    }

    fn is_xfce(&self) -> bool {
        crate::platform::is_xfce()
    }

    fn get_api_server(&self) -> String {
        get_api_server()
    }

    fn has_hwcodec(&self) -> bool {
        has_hwcodec()
    }

    fn has_vram(&self) -> bool {
        has_vram()
    }

    fn get_langs(&self) -> String {
        get_langs()
    }

    fn video_save_directory(&self, root: bool) -> String {
        video_save_directory(root)
    }

    fn handle_relay_id(&self, id: String) -> String {
        handle_relay_id(&id).to_owned()
    }

    fn get_login_device_info(&self) -> String {
        get_login_device_info_json()
    }

    fn support_remove_wallpaper(&self) -> bool {
        support_remove_wallpaper()
    }

    fn has_valid_2fa(&self) -> bool {
        has_valid_2fa()
    }

    fn generate2fa(&self) -> String {
        generate2fa()
    }

    pub fn verify2fa(&self, code: String) -> bool {
        verify2fa(code)
    }

    fn verify_login(&self, raw: String, id: String) -> bool {
        crate::verify_login(&raw, &id)
    }

    fn generate_2fa_img_src(&self, data: String) -> String {
        let v = qrcode_generator::to_png_to_vec(data, qrcode_generator::QrCodeEcc::Low, 128)
            .unwrap_or_default();
        let s = hbb_common::sodiumoxide::base64::encode(
            v,
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        format!("data:image/png;base64,{s}")
    }

    pub fn check_hwcodec(&self) {
        check_hwcodec()
    }

    fn is_option_fixed(&self, key: String) -> bool {
        crate::ui_interface::is_option_fixed(&key)
    }

    fn get_builtin_option(&self, key: String) -> String {
        crate::ui_interface::get_builtin_option(&key)
    }

    fn is_remote_modify_enabled_by_control_permissions(&self) -> String {
        match crate::ui_interface::is_remote_modify_enabled_by_control_permissions() {
            Some(true) => "true",
            Some(false) => "false",
            None => "",
        }
        .to_string()
    }
}

impl sciter::EventHandler for UI {
    sciter::dispatch_script_call! {
        fn t(String);
        fn get_api_server();
        fn is_xfce();
        fn using_public_server();
        fn is_custom_client();
        fn is_outgoing_only();
        fn is_incoming_only();
        fn is_disable_settings();
        fn is_disable_account();
        fn is_disable_installation();
        fn is_disable_ab();
        fn get_id();
        fn temporary_password();
        fn update_temporary_password();
        fn set_permanent_password(String);
        fn is_local_permanent_password_set();
        fn is_permanent_password_set();
        fn get_remote_id();
        fn set_remote_id(String);
        fn closing(i32, i32, i32, i32);
        fn get_size();
        fn new_remote(String, String, bool);
        fn send_wol(String);
        fn remove_peer(String);
        fn remove_discovered(String);
        fn get_connect_status();
        fn get_mouse_time();
        fn check_mouse_time();
        fn get_recent_sessions();
        fn get_peer(String);
        fn get_fav();
        fn store_fav(Value);
        fn recent_sessions_updated();
        fn get_icon();
        fn install_me(String, String);
        fn is_installed();
        fn get_supported_privacy_mode_impls();
        fn is_root();
        fn is_release();
        fn set_socks(String, String, String);
        fn get_socks();
        fn is_share_rdp();
        fn set_share_rdp(bool);
        fn is_installed_lower_version();
        fn install_path();
        fn install_options();
        fn goto_install();
        fn is_process_trusted(bool);
        fn is_can_screen_recording(bool);
        fn is_installed_daemon(bool);
        fn get_error();
        fn is_login_wayland();
        fn current_is_wayland();
        fn get_options();
        fn get_option(String);
        fn get_local_option(String);
        fn set_local_option(String, String);
        fn get_peer_option(String, String);
        fn peer_has_password(String);
        fn forget_password(String);
        fn set_peer_option(String, String, String);
        fn get_license();
        fn test_if_valid_server(String, bool);
        fn get_sound_inputs();
        fn set_options(Value);
        fn set_option(String, String);
        fn get_software_update_url();
        fn get_new_version();
        fn get_version();
        fn get_fingerprint();
        fn update_me(String);
        fn show_run_without_install();
        fn run_without_install();
        fn get_app_name();
        fn get_software_store_path();
        fn get_software_ext();
        fn open_url(String);
        fn change_id(String);
        fn get_async_job_status();
        fn post_request(String, String, String);
        fn is_ok_change_id();
        fn create_shortcut(String);
        fn discover();
        fn get_lan_peers();
        fn get_uuid();
        fn has_hwcodec();
        fn has_vram();
        fn get_langs();
        fn video_save_directory(bool);
        fn handle_relay_id(String);
        fn get_login_device_info();
        fn support_remove_wallpaper();
        fn has_valid_2fa();
        fn generate2fa();
        fn generate_2fa_img_src(String);
        fn verify2fa(String);
        fn check_hwcodec();
        fn verify_login(String, String);
        fn is_option_fixed(String);
        fn get_builtin_option(String);
        fn is_remote_modify_enabled_by_control_permissions();
    }
}

impl sciter::host::HostHandler for UIHostHandler {
    fn on_graphics_critical_failure(&mut self) {
        log::error!("Critical rendering error: e.g. DirectX gfx driver error. Most probably bad gfx drivers.");
    }
}

#[cfg(not(target_os = "linux"))]
fn get_sound_inputs() -> Vec<String> {
    let mut out = Vec::new();
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    if let Ok(devices) = host.devices() {
        for device in devices {
            if device.default_input_config().is_err() {
                continue;
            }
            if let Ok(name) = device.name() {
                out.push(name);
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn get_sound_inputs() -> Vec<String> {
    crate::platform::linux::get_pa_sources()
        .drain(..)
        .map(|x| x.1)
        .collect()
}

// sacrifice some memory
pub fn value_crash_workaround(values: &[Value]) -> Arc<Vec<Value>> {
    let persist = Arc::new(values.to_vec());
    STUPID_VALUES.lock().unwrap().push(persist.clone());
    persist
}

pub fn get_icon() -> String {
    // 128x128
    #[cfg(target_os = "macos")]
    // 128x128 on 160x160 canvas, then shrink to 128, mac looks better with padding
    {
        "data:image/png;base64,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".into()
    }
    #[cfg(not(target_os = "macos"))] // 128x128 no padding
    {
        "data:image/png;base64,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".into()
    }
}
