use std::{
    collections::HashMap,
    ptr::{null, null_mut},
};
use tray_icon::{
    menu::{Menu, MenuEvent, MenuItem},
    Icon, TrayIcon, TrayIconBuilder,
};
use windows_sys::Win32::{
    Foundation::{HWND, LPARAM, RECT},
    UI::WindowsAndMessaging::{
        EnumWindows, FindWindowExW, FindWindowW, GetForegroundWindow, GetParent, GetWindowLongPtrW,
        GetWindowRect, IsWindow, SendMessageTimeoutW, SetParent, SetWindowLongPtrW, SetWindowPos,
        GWL_EXSTYLE, GWL_STYLE, HWND_BOTTOM, SMTO_NORMAL, SWP_FRAMECHANGED, SWP_NOACTIVATE,
        SWP_SHOWWINDOW, WS_CHILD, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT, WS_POPUP,
    },
};
use winit::{
    dpi::{PhysicalPosition, PhysicalSize},
    raw_window_handle::{HasWindowHandle, RawWindowHandle},
    window::Window,
};

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
fn hwnd(window: &Window) -> Result<HWND, String> {
    let handle = window.window_handle().map_err(|e| e.to_string())?;
    match handle.as_raw() {
        RawWindowHandle::Win32(h) => Ok(h.hwnd.get() as HWND),
        _ => Err("Expected a Win32 window".into()),
    }
}

unsafe extern "system" fn find_desktop(window: HWND, param: LPARAM) -> i32 {
    let defview = FindWindowExW(
        window,
        null_mut(),
        wide("SHELLDLL_DefView").as_ptr(),
        null(),
    );
    if !defview.is_null() {
        let worker = FindWindowExW(null_mut(), window, wide("WorkerW").as_ptr(), null());
        if !worker.is_null() {
            *(param as *mut HWND) = worker;
            return 0;
        }
    }
    1
}

fn workerw() -> Result<HWND, String> {
    unsafe {
        let progman = FindWindowW(wide("Progman").as_ptr(), null());
        if progman.is_null() {
            return Err("Explorer desktop was not found".into());
        }
        let mut result = 0usize;
        SendMessageTimeoutW(progman, 0x052c, 0, 0, SMTO_NORMAL, 1000, &mut result);
        let mut worker: HWND = null_mut();
        EnumWindows(Some(find_desktop), &mut worker as *mut HWND as LPARAM);
        if worker.is_null() {
            Err("Explorer did not expose a background WorkerW".into())
        } else {
            Ok(worker)
        }
    }
}

pub fn attach(
    window: &Window,
    position: PhysicalPosition<i32>,
    size: PhysicalSize<u32>,
) -> Result<isize, String> {
    let worker = workerw()?;
    let hwnd = hwnd(window)?;
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        SetWindowLongPtrW(hwnd, GWL_STYLE, ((style & !WS_POPUP) | WS_CHILD) as isize);
        let exstyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            (exstyle | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT) as isize,
        );
        SetParent(hwnd, worker);
        if GetParent(hwnd) != worker {
            return Err("Explorer rejected RainGlass desktop placement".into());
        }
        let mut bounds: RECT = std::mem::zeroed();
        if GetWindowRect(worker, &mut bounds) == 0 {
            return Err("Cannot read Explorer desktop bounds".into());
        }
        if SetWindowPos(
            hwnd,
            HWND_BOTTOM,
            position.x - bounds.left,
            position.y - bounds.top,
            size.width as i32,
            size.height as i32,
            SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED,
        ) == 0
        {
            return Err("Cannot size RainGlass desktop surface".into());
        }
    }
    Ok(worker as isize)
}

pub fn parent_alive(parent: isize) -> bool {
    parent != 0 && unsafe { IsWindow(parent as HWND) != 0 }
}
pub fn covered(position: PhysicalPosition<i32>, size: PhysicalSize<u32>) -> bool {
    unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return false;
        }
        let mut rect: RECT = std::mem::zeroed();
        if GetWindowRect(foreground, &mut rect) == 0 {
            return false;
        }
        rect.left <= position.x
            && rect.top <= position.y
            && rect.right >= position.x + size.width as i32
            && rect.bottom >= position.y + size.height as i32
    }
}
pub fn reattach(
    window: &Window,
    position: PhysicalPosition<i32>,
    size: PhysicalSize<u32>,
) -> Result<isize, String> {
    attach(window, position, size)
}

pub struct TrayControls {
    _icon: TrayIcon,
    status: MenuItem,
    commands: HashMap<String, Vec<String>>,
}
impl TrayControls {
    pub fn new() -> Result<Self, String> {
        let items: [(&str, Vec<&str>); 17] = [
            ("Retry Desktop", vec!["--retry"]),
            ("Settings…", vec!["--settings"]),
            ("Choose Wallpaper…", vec!["--choose-wallpaper"]),
            ("Pause / Resume", vec!["--toggle-pause"]),
            ("Mute / Unmute", vec!["--toggle-mute"]),
            ("Cozy Window", vec!["--preset", "cozy"]),
            ("Light Drizzle", vec!["--preset", "drizzle"]),
            ("Autumn Storm", vec!["--preset", "storm"]),
            ("Night Rain", vec!["--preset", "night"]),
            ("Sleep", vec!["--preset", "sleep"]),
            ("Blur 2", vec!["--blur", "2"]),
            ("Blur 16", vec!["--blur", "16"]),
            ("Blur 32", vec!["--blur", "32"]),
            ("Zoom 1×", vec!["--zoom", "1"]),
            ("Zoom 1.5×", vec!["--zoom", "1.5"]),
            ("Volume 35%", vec!["--volume", "0.35"]),
            ("Quit RainGlass", vec!["--quit"]),
        ];
        let menu = Menu::new();
        let mut commands = HashMap::new();
        let status = MenuItem::new("RainGlass running", false, None);
        menu.append(&status).map_err(|e| e.to_string())?;
        for (index, (title, args)) in items.into_iter().enumerate() {
            let id = format!("rain-{index}");
            let item = MenuItem::with_id(id.clone(), title, true, None);
            menu.append(&item).map_err(|e| e.to_string())?;
            commands.insert(id, args.into_iter().map(str::to_owned).collect());
        }
        let mut pixels = vec![0u8; 32 * 32 * 4];
        for y in 0..32 {
            for x in 0..32 {
                let i = (y * 32 + x) * 4;
                let drop =
                    (x as f32 - 16.0).powi(2) / 64.0 + (y as f32 - 17.0).powi(2) / 121.0 < 1.0;
                pixels[i] = if drop { 158 } else { 25 };
                pixels[i + 1] = if drop { 210 } else { 36 };
                pixels[i + 2] = if drop { 242 } else { 55 };
                pixels[i + 3] = 255;
            }
        }
        let icon = Icon::from_rgba(pixels, 32, 32).map_err(|e| e.to_string())?;
        let icon = TrayIconBuilder::new()
            .with_tooltip("RainGlass")
            .with_icon(icon)
            .with_menu(Box::new(menu))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            _icon: icon,
            status,
            commands,
        })
    }
    pub fn set_status(&self, message: &str) {
        self.status.set_text(message);
    }
    pub fn poll(&self) -> Vec<Vec<String>> {
        let mut result = Vec::new();
        while let Ok(event) = MenuEvent::receiver().try_recv() {
            if let Some(command) = self.commands.get(&event.id.0) {
                result.push(command.clone());
            }
        }
        result
    }
}
