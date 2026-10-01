use std::ptr::{null, null_mut};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use windows_sys::Win32::{
    Foundation::{GetLastError, SetLastError, HWND, LPARAM, POINT, RECT},
    Graphics::Gdi::MapWindowPoints,
    UI::WindowsAndMessaging::{
        EnumWindows, FindWindowExW, FindWindowW, GetAncestor, GetClassNameW, GetForegroundWindow,
        GetParent, GetWindowLongPtrW, GetWindowRect, IsWindow, SendMessageTimeoutW,
        SetLayeredWindowAttributes, SetParent, SetWindowLongPtrW, SetWindowPos, GA_ROOT,
        GWL_EXSTYLE, GWL_STYLE, HWND_BOTTOM, LWA_ALPHA, SMTO_NORMAL, SWP_FRAMECHANGED,
        SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, WS_CAPTION, WS_CHILD, WS_EX_APPWINDOW,
        WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_NOREDIRECTIONBITMAP, WS_EX_TOOLWINDOW,
        WS_EX_TRANSPARENT, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
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

#[derive(Clone, Copy)]
pub struct DesktopHost {
    parent: isize,
    worker: isize,
    defview: isize,
    raised: bool,
}

pub fn desktop_host() -> Result<DesktopHost, String> {
    unsafe {
        let progman = FindWindowW(wide("Progman").as_ptr(), null());
        if progman.is_null() {
            return Err("Explorer desktop was not found".into());
        }
        let mut result = 0usize;
        if SendMessageTimeoutW(progman, 0x052c, 0xD, 1, SMTO_NORMAL, 1000, &mut result) == 0 {
            return Err(format!(
                "Explorer desktop initialization failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let raised =
            GetWindowLongPtrW(progman, GWL_EXSTYLE) as u32 & WS_EX_NOREDIRECTIONBITMAP != 0;
        if raised {
            let worker = FindWindowExW(progman, null_mut(), wide("WorkerW").as_ptr(), null());
            let defview = FindWindowExW(
                progman,
                null_mut(),
                wide("SHELLDLL_DefView").as_ptr(),
                null(),
            );
            if worker.is_null() || defview.is_null() {
                return Err("Explorer did not expose its raised desktop layers".into());
            }
            return Ok(DesktopHost {
                parent: progman as isize,
                worker: worker as isize,
                defview: defview as isize,
                raised,
            });
        }
        let mut worker: HWND = null_mut();
        EnumWindows(Some(find_desktop), &mut worker as *mut HWND as LPARAM);
        if worker.is_null() {
            Err("Explorer did not expose a background WorkerW".into())
        } else {
            Ok(DesktopHost {
                parent: worker as isize,
                worker: worker as isize,
                defview: 0,
                raised: false,
            })
        }
    }
}

impl DesktopHost {
    pub fn attributes(
        self,
        attrs: winit::window::WindowAttributes,
    ) -> winit::window::WindowAttributes {
        let handle = winit::raw_window_handle::Win32WindowHandle::new(
            std::num::NonZeroIsize::new(self.parent).unwrap(),
        );
        // The discovered Explorer HWND is live. Winit must know this is a child,
        // otherwise its visibility/style updates silently undo external parenting.
        unsafe { attrs.with_parent_window(Some(RawWindowHandle::Win32(handle))) }
    }
}

pub fn attach(
    window: &Window,
    host: DesktopHost,
    position: PhysicalPosition<i32>,
    size: PhysicalSize<u32>,
) -> Result<DesktopHost, String> {
    let parent = host.parent as HWND;
    let hwnd = hwnd(window)?;
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        SetWindowLongPtrW(
            hwnd,
            GWL_STYLE,
            ((style
                & !(WS_POPUP
                    | WS_CAPTION
                    | WS_THICKFRAME
                    | WS_MINIMIZEBOX
                    | WS_MAXIMIZEBOX
                    | WS_SYSMENU))
                | WS_CHILD) as isize,
        );
        let exstyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            ((exstyle & !WS_EX_APPWINDOW)
                | WS_EX_NOACTIVATE
                | WS_EX_TOOLWINDOW
                | WS_EX_TRANSPARENT
                | if host.raised { WS_EX_LAYERED } else { 0 }) as isize,
        );
        if host.raised && SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA) == 0 {
            return Err(format!(
                "Cannot configure desktop layer: {}",
                std::io::Error::last_os_error()
            ));
        }
        SetParent(hwnd, parent);
        if GetParent(hwnd) != parent {
            return Err("Explorer rejected RainGlass desktop placement".into());
        }
        // Convert screen pixels into the parent's client coordinates, including negative monitors.
        let mut origin = POINT {
            x: position.x,
            y: position.y,
        };
        SetLastError(0);
        if MapWindowPoints(null_mut(), parent, &mut origin, 1) == 0 && GetLastError() != 0 {
            return Err(format!(
                "Cannot map desktop coordinates: {}",
                std::io::Error::last_os_error()
            ));
        }
        if host.raised {
            if SetWindowPos(
                host.worker as HWND,
                HWND_BOTTOM,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            ) == 0
            {
                return Err("Cannot order Explorer background layer".into());
            }
        }
        if SetWindowPos(
            hwnd,
            if host.raised {
                host.defview as HWND
            } else {
                HWND_BOTTOM
            },
            origin.x,
            origin.y,
            size.width as i32,
            size.height as i32,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ) == 0
        {
            return Err("Cannot size RainGlass desktop surface".into());
        }
    }
    eprintln!(
        "RainGlass desktop: {} parent={:#x}, {}x{} at {},{}",
        if host.raised { "raised" } else { "WorkerW" },
        host.parent,
        size.width,
        size.height,
        position.x,
        position.y
    );
    Ok(host)
}

pub fn attached(window: &Window, host: DesktopHost) -> bool {
    let Ok(window) = hwnd(window) else {
        return false;
    };
    unsafe {
        let valid = IsWindow(window) != 0
            && IsWindow(host.parent as HWND) != 0
            && GetParent(window) == host.parent as HWND
            && (!host.raised || IsWindow(host.defview as HWND) != 0);
        if !valid {
            eprintln!("RainGlass desktop attachment lost: HWND={:#x}, alive={}, actual_parent={:#x}, expected_parent={:#x}, parent_alive={}, defview_alive={}",
                window as isize, IsWindow(window), GetParent(window) as isize, host.parent, IsWindow(host.parent as HWND), IsWindow(host.defview as HWND));
        }
        valid
    }
}
pub fn covered(position: PhysicalPosition<i32>, size: PhysicalSize<u32>) -> bool {
    unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return false;
        }
        // Explorer's foreground desktop covers a monitor but must never pause its wallpaper.
        let root = GetAncestor(foreground, GA_ROOT);
        let mut class = [0u16; 64];
        let len = GetClassNameW(root, class.as_mut_ptr(), class.len() as i32);
        if matches!(
            String::from_utf16_lossy(&class[..len.max(0) as usize]).as_str(),
            "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd"
        ) {
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
pub struct TrayControls {
    icon: TrayIcon,
}
impl TrayControls {
    pub fn new() -> Result<Self, String> {
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
            .with_menu_on_left_click(false)
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { icon })
    }
    pub fn set_status(&self, message: &str) {
        let _ = self.icon.set_tooltip(Some(message));
    }
    pub fn anchor(&self) -> Option<(i32, i32)> {
        self.icon.rect().map(|rect| {
            (
                rect.position.x as i32 + rect.size.width as i32 / 2,
                rect.position.y as i32,
            )
        })
    }
    pub fn poll(&self) -> Option<(i32, i32)> {
        let mut anchor = None;
        while let Ok(event) = TrayIconEvent::receiver().try_recv() {
            if let TrayIconEvent::Click {
                button: MouseButton::Left | MouseButton::Right,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                anchor = Some((
                    rect.position.x as i32 + rect.size.width as i32 / 2,
                    rect.position.y as i32,
                ));
            }
        }
        anchor
    }
}

pub struct DiagnosticsOverlay {
    hwnd: HWND,
    text: String,
}
impl DiagnosticsOverlay {
    pub fn new(window: &Window) -> Self {
        let parent = match window.window_handle().unwrap().as_raw() {
            RawWindowHandle::Win32(handle) => handle.hwnd.get() as HWND,
            _ => unreachable!(),
        };
        let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
        let hwnd = unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::CreateWindowExW(
                WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                class.as_ptr(),
                null(),
                WS_CHILD,
                12,
                12,
                360,
                66,
                parent,
                null_mut(),
                null_mut(),
                null(),
            )
        };
        Self {
            hwnd,
            text: String::new(),
        }
    }
    pub fn update(&mut self, enabled: bool, text: String) {
        use windows_sys::Win32::UI::WindowsAndMessaging::{
            SetWindowTextW, ShowWindow, SW_HIDE, SW_SHOWNOACTIVATE,
        };
        unsafe {
            ShowWindow(self.hwnd, if enabled { SW_SHOWNOACTIVATE } else { SW_HIDE });
            if enabled && self.text != text {
                let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
                SetWindowTextW(self.hwnd, wide.as_ptr());
                self.text = text;
            }
        }
    }
}
impl Drop for DiagnosticsOverlay {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::DestroyWindow(self.hwnd);
        }
    }
}
