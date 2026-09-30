import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const WINDOW_PREFIX = 'RainGlass Background ';

export default class RainGlassExtension extends Extension {
    enable() {
        this._binary = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'rainglass-desktop']);
        this._windows = new Map();
        this._spawned = null;
        this._waylandClient = null;
        this._indicator = new PanelMenu.Button(0.0, 'RainGlass');
        this._indicator.add_child(new St.Icon({icon_name: 'weather-showers-symbolic', style_class: 'system-status-icon'}));
        this._item('Choose Wallpaper…', ['--choose-wallpaper']);
        this._item('Settings…', ['--settings']);
        this._item('Pause / Resume', ['--toggle-pause']);
        this._item('Mute / Unmute', ['--toggle-mute']);
        this._indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        for (const [name, alias] of [['Cozy Window', 'cozy'], ['Light Drizzle', 'drizzle'],
                                     ['Autumn Storm', 'storm'], ['Night Rain', 'night'], ['Sleep', 'sleep']])
            this._item(name, ['--preset', alias]);
        this._indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._item('Blur 2', ['--blur', '2']);
        this._item('Blur 16', ['--blur', '16']);
        this._item('Blur 32', ['--blur', '32']);
        this._item('Zoom 1×', ['--zoom', '1']);
        this._item('Zoom 1.5×', ['--zoom', '1.5']);
        this._item('Retry Desktop', null, () => this._retry());
        Main.panel.addToStatusArea('rainglass', this._indicator);

        this._created = global.display.connect('window-created', (_display, window) => this._consider(window));
        this._monitors = Main.layoutManager.connect('monitors-changed', () => this._resizeWindows());
        this._background = Main.layoutManager._backgroundGroup;
        if (!this._background) {
            Main.notify('RainGlass', 'This GNOME Shell version has no background layer for RainGlass.');
            return;
        }
        this._childAdded = this._background.connect('child-added', (_group, child) => {
            for (const record of this._windows.values())
                if (record.actor !== child && record.actor.get_parent() === this._background)
                    this._background.set_child_above_sibling(record.actor, null);
        });
        this._launch();
    }

    _item(label, args, callback = null) {
        const item = new PopupMenu.PopupMenuItem(label);
        item.connect('activate', () => callback ? callback() : this._control(args));
        this._indicator.menu.addMenuItem(item);
    }

    _control(args) {
        try {
            Gio.Subprocess.new([this._binary, ...args], Gio.SubprocessFlags.NONE);
        } catch (error) {
            Main.notify('RainGlass', `Control failed: ${error.message}`);
        }
    }

    _launch() {
        if (this._spawned && !this._spawned.get_if_exited())
            return;
        try {
            if (Meta.is_wayland_compositor() && Meta.WaylandClient?.new_subprocess) {
                const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
                this._waylandClient = Meta.WaylandClient.new_subprocess(
                    global.context, launcher, [this._binary]);
                this._spawned = this._waylandClient.get_subprocess();
            } else {
                this._waylandClient = null;
                this._spawned = Gio.Subprocess.new([this._binary], Gio.SubprocessFlags.NONE);
            }
        } catch (error) {
            this._waylandClient = null;
            try {this._spawned = Gio.Subprocess.new([this._binary], Gio.SubprocessFlags.NONE);}
            catch (fallbackError) {
                Main.notify('RainGlass', `Could not start desktop renderer: ${fallbackError.message}`);
            }
        }
        this._spawned?.wait_async(null, (process, result) => {
            try { process.wait_finish(result); } catch (_) {}
            if (this._spawned === process) {
                this._spawned = null;
                this._waylandClient = null;
            }
        });
    }

    _retry() {
        if (!this._background) {
            Main.notify('RainGlass', 'Desktop background layer is unavailable in this GNOME Shell session.');
            return;
        }
        this._spawned?.force_exit();
        this._spawned = null;
        this._waylandClient = null;
        this._launch();
    }

    _matches(window) {
        const title = window.get_title() ?? '';
        if (!title.startsWith(WINDOW_PREFIX))
            return false;
        try {
            if (this._waylandClient?.owns_window(window))
                return true;
        } catch (_) {}
        const pid = Number.parseInt(this._spawned?.get_identifier() ?? '', 10);
        return Number.isInteger(pid) && window.get_pid() === pid;
    }

    _consider(window, attempts = 0) {
        if (!this._windows || !this._matches(window) || this._windows.has(window))
            return;
        const actor = window.get_compositor_private();
        if (!actor) {
            if (attempts < 20)
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, () => {
                    this._consider(window, attempts + 1);
                    return GLib.SOURCE_REMOVE;
                });
            return;
        }
        const originalParent = actor.get_parent();
        if (originalParent)
            originalParent.remove_child(actor);
        this._background.add_child(actor);
        this._background.set_child_above_sibling(actor, null);
        actor.reactive = false;
        const visibleSignal = actor.connect('notify::visible', () => {
            if (!actor.visible && this._windows?.has(window))
                actor.show();
        });
        const unmanagedSignal = window.connect('unmanaged', () => this._forget(window));
        const raisedSignal = window.connect('raised', () => window.lower());
        const focusSignal = window.connect('focus', () => this._restoreFocus(window));
        if (typeof window.hide_from_window_list === 'function')
            window.hide_from_window_list();
        else if (typeof this._waylandClient?.hide_from_window_list === 'function')
            this._waylandClient.hide_from_window_list(window);
        this._windows.set(window, {actor, originalParent, visibleSignal, unmanagedSignal,
            raisedSignal, focusSignal});
        window.lower();
        this._position(window);
        this._restoreFocus(window);
    }

    _position(window) {
        const index = Number.parseInt((window.get_title() ?? '').slice(WINDOW_PREFIX.length), 10);
        const monitors = Main.layoutManager.monitors;
        const monitor = monitors[Number.isInteger(index) ? index : 0];
        if (monitor)
            window.move_resize_frame(false, monitor.x, monitor.y, monitor.width, monitor.height);
    }

    _resizeWindows() {
        for (const window of this._windows.keys())
            this._position(window);
    }

    _restoreFocus(backgroundWindow) {
        const next = global.display.get_tab_list(Meta.TabList.NORMAL, null)
            .find(candidate => candidate !== backgroundWindow);
        if (next)
            next.activate(global.get_current_time());
    }

    _forget(window) {
        const record = this._windows?.get(window);
        if (!record)
            return;
        try {record.actor.disconnect(record.visibleSignal);} catch (_) {}
        try {window.disconnect(record.unmanagedSignal);} catch (_) {}
        try {window.disconnect(record.raisedSignal);} catch (_) {}
        try {window.disconnect(record.focusSignal);} catch (_) {}
        try {
            if (typeof window.show_in_window_list === 'function')
                window.show_in_window_list();
            else if (typeof this._waylandClient?.show_in_window_list === 'function')
                this._waylandClient.show_in_window_list(window);
        } catch (_) {}
        this._windows.delete(window);
    }

    disable() {
        if (this._created) global.display.disconnect(this._created);
        if (this._monitors) Main.layoutManager.disconnect(this._monitors);
        if (this._childAdded) this._background.disconnect(this._childAdded);
        for (const [window, record] of this._windows ?? []) {
            this._forget(window);
            if (record.originalParent && record.actor.get_parent() === this._background) {
                this._background.remove_child(record.actor);
                record.originalParent.add_child(record.actor);
            }
        }
        this._windows = null;
        this._spawned?.force_exit();
        this._spawned = null;
        this._waylandClient = null;
        this._indicator?.destroy();
        this._indicator = null;
    }
}
