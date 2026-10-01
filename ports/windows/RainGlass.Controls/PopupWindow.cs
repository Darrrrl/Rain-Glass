using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RainGlass.Controls;
public sealed class PopupWindow : Window
{
    private readonly EngineConnection engine;
    private readonly Dictionary<string, Action<JsonNode?>> setters = [];
    private readonly Dictionary<string, JsonNode?> pending = [];
    private JsonObject settings = [];
    private bool updating, dialogOpen;
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11 };
    private readonly TextBlock weatherStatus = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11 };
    private readonly TextBlock weatherNotice = new() { Text = "Live weather controls rain, wind, blur and storms. Manual values are retained.", TextWrapping = TextWrapping.Wrap, FontSize = 11, Visibility = Visibility.Collapsed };
    private readonly Button pause, mute;
    private readonly ComboBox presets = new();
    private readonly ComboBox cities = new();
    private readonly Slider fpsSlider;
    private readonly TextBox customFps = new() { Width = 78 };
    private readonly CheckBox monitorFps = new() { Content = "Follow each monitor’s refresh rate" };
    private readonly TextBlock fpsInfo = new() { FontSize = 11, TextWrapping = TextWrapping.Wrap };
    private readonly List<Button> tabs = [];
    private readonly List<ScrollViewer> pages = [];
    private JsonArray? searchResults;
    private JsonArray? monitors;
    private readonly DispatcherTimer sendTimer;
    private int activeTab;
    private DateTime lastDismissed;
    private bool wasActive;
    private bool? appliedDarkTheme;

    public PopupWindow(EngineConnection engine)
    {
        this.engine = engine;
        Title = "RainGlass"; Width = 420; Height = 720;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; Topmost = true;
        var shell = new Border { CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1), Padding = new Thickness(18, 16, 18, 12) };
        shell.SetResourceReference(Border.BackgroundProperty, "Surface"); shell.SetResourceReference(Border.BorderBrushProperty, "Line");
        Content = shell;
        var root = new DockPanel(); shell.Child = root;
        var header = new StackPanel(); DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var heading = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var actions = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(actions, Dock.Right); heading.Children.Add(actions);
        pause = Button("", () => Patch("paused", !(Read("paused")?.GetValue<bool>() ?? false))); pause.ToolTip = "Pause / resume visuals";
        mute = Button("", () => Patch("audio.muted", !(Read("audio.muted")?.GetValue<bool>() ?? false))); mute.ToolTip = "Mute / unmute";
        pause.Content = MakeIcon(PauseIcon); mute.Content = MakeIcon(SoundIcon);
        actions.Children.Add(pause); actions.Children.Add(mute);
        var title = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var drop = MakeIcon("M8,1 C6,4 2,8 2,11 C2,19 14,19 14,11 C14,8 10,4 8,1 Z"); drop.Width = 18; drop.Height = 24; drop.Margin = new Thickness(0, 0, 9, 0); drop.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Accent"); drop.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "Accent");
        title.Children.Add(drop); title.Children.Add(new TextBlock { Text = "RainGlass", FontSize = 23, FontWeight = FontWeights.SemiBold }); heading.Children.Add(title);
        header.Children.Add(heading);
        var presetRow = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var image = Button("Choose image", ChooseImage); DockPanel.SetDock(image, Dock.Right); presetRow.Children.Add(image); presetRow.Children.Add(presets); header.Children.Add(presetRow);
        presets.SelectionChanged += (_, _) => { if (!updating && presets.SelectedItem is string name && name != "Custom") engine.Send("preset", JsonValue.Create(name)); };
        SliderRow(header, "Volume", "audio.master", 0, 100, 100, "%");
        SliderRow(header, "Blur", "rain.blur", 0, 100, 100.0 / 64.0, "%");
        var nav = new UniformGrid { Columns = 4, Margin = new Thickness(0, 14, 0, 10) }; header.Children.Add(nav);
        var footer = new DockPanel { Margin = new Thickness(0, 10, 0, 0) }; DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var quit = Button("Quit", () => { Flush(); engine.Send("quit"); }); DockPanel.SetDock(quit, Dock.Right); footer.Children.Add(quit);
        status.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); footer.Children.Add(status);
        var content = new Grid(); root.Children.Add(content);
        var names = new[] { "Scene", "Image", "Sound", "App" };
        var panels = new List<StackPanel>();
        for (int i = 0; i < names.Length; i++)
        {
            int index = i; var tab = Button(names[i], () => SelectTab(index)); tabs.Add(tab); nav.Children.Add(tab);
            var panel = new StackPanel { Margin = new Thickness(0, 0, 6, 0) }; panels.Add(panel);
            var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Visibility = i == 0 ? Visibility.Visible : Visibility.Collapsed };
            pages.Add(scroll); content.Children.Add(scroll);
        }
        header.Children.Insert(4, weatherNotice);
        BuildScene(panels[0]); BuildImage(panels[1]); BuildSound(panels[2]);
        fpsSlider = BuildApp(panels[3]);
        SelectTab(0);
        sendTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        sendTimer.Tick += (_, _) => Flush(); sendTimer.Start();
        engine.Message += OnMessage;
        Closing += (_, e) => { e.Cancel = true; Flush(); Hide(); };
        Activated += (_, _) => wasActive = true;
        Deactivated += (_, _) => { if (wasActive && !dialogOpen) { Flush(); lastDismissed = DateTime.UtcNow; Hide(); } };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && !dialogOpen) { Flush(); Hide(); e.Handled = true; } };
        SourceInitialized += (_, _) => {
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetWindowLongPtr(hwnd, -20, (Native.GetWindowLongPtr(hwnd, -20).ToInt64() | 0x80) & ~0x40000L);
        };
        ApplyTheme("system");
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.InvokeAsync(() => ApplyTheme(Read("theme")?.GetValue<string>() ?? "system"));
    }
    private static Button Button(string text, Action action) { var b = new Button { Content = text }; AutomationProperties.SetName(b, text); b.Click += (_, _) => action(); return b; }
    private const string PauseIcon = "M4,2 L4,14 M10,2 L10,14", PlayIcon = "M3,1 L14,8 L3,15 Z";
    private const string SoundIcon = "M1,6 L4,6 L8,2 L8,14 L4,10 L1,10 Z M11,4 C15,6 15,10 11,12", MutedIcon = "M1,6 L4,6 L8,2 L8,14 L4,10 L1,10 Z M11,5 L15,11 M15,5 L11,11";
    private static System.Windows.Shapes.Path MakeIcon(string data)
    {
        var icon = new System.Windows.Shapes.Path { Data = Geometry.Parse(data), Width = 14, Height = 14, Stretch = Stretch.Uniform, StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        icon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "Text"); return icon;
    }
    private static void Heading(Panel panel, string title)
    {
        var text = new TextBlock { Text = title.ToUpperInvariant(), FontSize = 10, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 17, 0, 8) };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); panel.Children.Add(text);
    }
    private void SelectTab(int index)
    {
        activeTab = index;
        for (int i = 0; i < tabs.Count; i++) { pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed; tabs[i].SetResourceReference(Control.BorderBrushProperty, i == index ? "Accent" : "Line"); }
    }
    private Slider SliderRow(Panel panel, string label, string path, double min, double max, double scale = 1, string suffix = "", bool integer = false)
    {
        var box = new StackPanel { Margin = new Thickness(0, 3, 0, 5) };
        var row = new DockPanel(); var value = new TextBlock { FontSize = 11, FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(value, Dock.Right); row.Children.Add(value); row.Children.Add(new TextBlock { Text = label, FontSize = 12 }); box.Children.Add(row);
        var slider = new Slider { Minimum = min, Maximum = max, TickFrequency = integer ? 1 : Math.Max((max-min)/100.0, .01), IsSnapToTickEnabled = integer, SmallChange = integer ? 1 : (max-min)/100.0 };
        string format = integer || (suffix == "%" && path != "rain.thunderProbability") ? "0" : "0.##";
        AutomationProperties.SetName(slider, label); box.Children.Add(slider); panel.Children.Add(box);
        slider.ValueChanged += (_, _) => { value.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture) + suffix; if (!updating) Patch(path, slider.Value / scale); };
        setters[path] = node => { slider.Value = (node?.GetValue<double>() ?? min) * scale; value.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture) + suffix; };
        return slider;
    }
    private void Toggle(Panel panel, string label, string path)
    {
        var toggle = new CheckBox { Content = label }; panel.Children.Add(toggle); AutomationProperties.SetName(toggle, label);
        toggle.Checked += (_, _) => { if (!updating) Patch(path, true); }; toggle.Unchecked += (_, _) => { if (!updating) Patch(path, false); };
        setters[path] = node => toggle.IsChecked = node?.GetValue<bool>() ?? false;
    }
    private void Choice(Panel panel, string label, string path, params string[] options)
    {
        panel.Children.Add(new TextBlock { Text = label, FontSize = 12, Margin = new Thickness(0, 6, 0, 4) });
        var combo = new ComboBox { ItemsSource = options }; panel.Children.Add(combo); AutomationProperties.SetName(combo, label);
        combo.SelectionChanged += (_, _) => { if (!updating && combo.SelectedItem is string selected) Patch(path, selected); };
        setters[path] = node => combo.SelectedItem = node?.GetValue<string>();
    }
    private void BuildScene(Panel p)
    {
        weatherNotice.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        Heading(p, "Rain");
        SliderRow(p, "Amount of rain", "rain.intensity", 0, 100, 100, "%"); SliderRow(p, "Drop size", "rain.dropletSize", .5, 2);
        var details = new StackPanel { Margin = new Thickness(0, 7, 0, 0) }; p.Children.Add(new Expander { Header = "Rain details", Content = details });
        SliderRow(details, "Drop count", "rain.dropCount", 0, 6000, integer: true); SliderRow(details, "Gravity", "rain.gravity", 0, 2);
        SliderRow(details, "Wind", "rain.wind", -1, 1); SliderRow(details, "Refraction", "rain.refraction", 0, 100, 100, "%"); SliderRow(details, "Trail persistence", "rain.trailPersistence", .5, 15, suffix: " s");
        Heading(p, "Thunder & lightning"); Toggle(p, "Enable thunder and lightning", "rain.lightningEnabled");
        SliderRow(p, "Chance each second", "rain.thunderProbability", 0, 100, 100, "%");
        SliderRow(p, "Lightning intensity", "rain.lightningIntensity", 0, 100, 100, "%");
        p.Children.Add(Button("Test lightning", () => engine.Send("test_lightning")));
        Heading(p, "Atmosphere"); SliderRow(p, "Condensation", "atmosphere.condensation", 0, 100, 100, "%");
        SliderRow(p, "Fog softness", "atmosphere.fogSoftness", 0, 100, 100, "%"); SliderRow(p, "Fog return", "atmosphere.fogReturnTime", 8, 35, suffix: " s");
        SliderRow(p, "Haze", "atmosphere.haze", 0, 100, 100, "%"); SliderRow(p, "Imperfections", "atmosphere.imperfections", 0, 100, 100, "%");
        Heading(p, "Window frame"); Choice(p, "Layout", "frame.layout", "off", "two", "four", "six"); SliderRow(p, "Thickness", "frame.thickness", 6, 24);
        Heading(p, "Presets"); var name = new TextBox { MaxLength = 40, ToolTip = "New preset name", Margin = new Thickness(0, 0, 0, 8) }; AutomationProperties.SetName(name, "New preset name"); p.Children.Add(name);
        var buttons = new WrapPanel(); p.Children.Add(buttons);
        buttons.Children.Add(Button("Save", () => { Flush(); engine.Send("save_preset", JsonValue.Create(name.Text)); }));
        buttons.Children.Add(Button("Import", () => FileDialog(false, "JSON presets|*.json", path => engine.Send("import_preset", JsonValue.Create(path)))));
        buttons.Children.Add(Button("Export", () => FileDialog(true, "JSON presets|*.json", path => engine.Send("export_preset", new JsonObject { ["name"] = presets.SelectedItem?.ToString(), ["path"] = path }))));
        buttons.Children.Add(Button("Delete", () => engine.Send("delete_preset", JsonValue.Create(presets.SelectedItem?.ToString()))));
        Heading(p, "Live weather"); Toggle(p, "Use live weather", "weather.enabled");
        var search = new DockPanel(); var query = new TextBox { ToolTip = "City or postal code" }; AutomationProperties.SetName(query, "City or postal code");
        var searchButton = Button("Search", () => engine.Send("search_weather", JsonValue.Create(query.Text))); DockPanel.SetDock(searchButton, Dock.Right); search.Children.Add(searchButton); search.Children.Add(query); p.Children.Add(search);
        query.KeyDown += (_, e) => { if (e.Key == Key.Enter) engine.Send("search_weather", JsonValue.Create(query.Text)); };
        cities.Margin = new Thickness(0, 8, 0, 8); p.Children.Add(cities);
        cities.SelectionChanged += (_, _) => { if (!updating && cities.SelectedIndex >= 0 && searchResults is not null) Patch("weather.city", searchResults[cities.SelectedIndex]?.DeepClone()); };
        p.Children.Add(weatherStatus); p.Children.Add(Button("Refresh weather", () => engine.Send("refresh_weather")));
        p.Children.Add(new TextBlock { Text = "Weather data: Open-Meteo", FontSize = 10, Margin = new Thickness(0, 8, 0, 4) });
    }
    private void BuildImage(Panel p)
    {
        Heading(p, "Wallpaper"); var filename = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 }; p.Children.Add(filename);
        setters["wallpaper"] = n => filename.Text = n?.GetValue<string>() ?? "No wallpaper selected";
        p.Children.Add(Button("Choose image…", ChooseImage)); Choice(p, "Image fit", "fit", "fill", "fit", "stretch"); SliderRow(p, "Zoom", "zoom", 1, 3, suffix: "×");
        p.Children.Add(new TextBlock { Text = "The background always renders at the display’s native resolution. Blur is optional.", TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 16, 0, 0) });
    }
    private void BuildSound(Panel p)
    {
        Heading(p, "Ambient mix");
        foreach (var (label, key) in new[] { ("Window rain", "window"), ("Distant rain", "distant"), ("Wind", "wind"), ("Room", "room"), ("Thunder", "thunder"), ("Glass taps", "glassTaps") }) SliderRow(p, label, "audio." + key, 0, 100, 100, "%");
        p.Children.Add(Button("Retry audio", () => engine.Send("retry_audio")));
    }
    private Slider BuildApp(Panel p)
    {
        Heading(p, "Frame rate");
        var fps = SliderRow(p, "FPS", "ui.fps", 0, 60, integer: true);
        setters.Remove("ui.fps");
        fps.ValueChanged += (_, _) => { if (!updating) { Patch("frame_rate", new JsonObject { ["fixed"] = (uint)Math.Round(fps.Value) }); updating = true; monitorFps.IsChecked = false; customFps.Text = Math.Round(fps.Value).ToString(); updating = false; } };
        monitorFps.Checked += (_, _) => { if (!updating) Patch("frame_rate", "monitor"); }; monitorFps.Unchecked += (_, _) => { if (!updating) Patch("frame_rate", new JsonObject { ["fixed"] = (uint)Math.Round(fps.Value) }); };
        p.Children.Add(monitorFps);
        var custom = new StackPanel { Orientation = Orientation.Horizontal }; custom.Children.Add(new TextBlock { Text = "Custom FPS  ", VerticalAlignment = VerticalAlignment.Center }); custom.Children.Add(customFps);
        custom.Children.Add(Button("Apply", () => {
            if (uint.TryParse(customFps.Text, out uint number)) { Patch("frame_rate", new JsonObject { ["fixed"] = number }); updating = true; monitorFps.IsChecked = false; updating = false; }
            else status.Text = "Enter a non-negative whole FPS value.";
        })); p.Children.Add(custom); p.Children.Add(fpsInfo);
        setters["frame_rate"] = n => {
            string? mode = n is JsonValue ? n.GetValue<string>() : null;
            monitorFps.IsChecked = mode == "monitor";
            double number = mode == "monitor" ? fps.Maximum : n is JsonObject ? double.Parse(n["fixed"]!.ToJsonString(), CultureInfo.InvariantCulture) : double.TryParse(mode, out var parsed) ? parsed : 60;
            fps.Value = Math.Min(fps.Maximum, number); customFps.Text = mode == "monitor" ? "" : number.ToString(CultureInfo.InvariantCulture);
        };
        p.Children.Add(new TextBlock { Text = "0 FPS stops visuals and sound. Custom targets may exceed refresh rate; actual presentation depends on the display and GPU.", TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 8, 0, 0) });
        Heading(p, "Appearance"); Choice(p, "Theme", "theme", "system", "light", "dark"); Choice(p, "Effect quality", "quality", "eco", "balanced", "ultra");
        Toggle(p, "Start RainGlass when I sign in", "start_at_login");
        Heading(p, "Diagnostics"); Toggle(p, "Show diagnostics overlay", "diagnostics_overlay");
        var seed = new TextBox { ToolTip = "Unsigned 64-bit rain seed" }; AutomationProperties.SetName(seed, "Rain seed"); p.Children.Add(seed);
        setters["seed"] = n => { if (!seed.IsKeyboardFocusWithin) seed.Text = n?.GetValue<ulong>().ToString() ?? "0"; };
        p.Children.Add(Button("Apply rain seed", () => { if (ulong.TryParse(seed.Text, out ulong value)) Patch("seed", JsonValue.Create(value)); else status.Text = "Enter an unsigned 64-bit seed."; }));
        p.Children.Add(Button("Reconnect desktop", () => engine.Send("retry_desktop")));
        return fps;
    }
    private void ChooseImage() => FileDialog(false, "Images|*.jpg;*.jpeg;*.png;*.webp;*.gif;*.bmp;*.tif;*.tiff", path => engine.Send("wallpaper", JsonValue.Create(path)));
    private void FileDialog(bool save, string filter, Action<string> selected)
    {
        Flush(); dialogOpen = true;
        try { Microsoft.Win32.FileDialog dialog = save ? new SaveFileDialog { Filter = filter, DefaultExt = ".json" } : new OpenFileDialog { Filter = filter }; if (dialog.ShowDialog(this) == true) selected(dialog.FileName); }
        finally { dialogOpen = false; Activate(); }
    }
    private JsonNode? Read(string path)
    {
        JsonNode? node = settings; foreach (string part in path.Split('.')) node = node?[part];
        if (path == "rain.thunderProbability" && node is null) return JsonValue.Create((settings["rain"]?["stormFrequency"]?.GetValue<double>() ?? 0) / 3600.0);
        return node;
    }
    private void Patch(string path, double value) => Patch(path, JsonValue.Create(value));
    private void Patch(string path, bool value) => Patch(path, JsonValue.Create(value));
    private void Patch(string path, string value) => Patch(path, JsonValue.Create(value));
    private void Patch(string path, JsonNode? value)
    {
        if (path == "ui.fps") return;
        pending[path] = value?.DeepClone(); Set(settings, path, value?.DeepClone());
        if (path == "theme") ApplyTheme(value?.GetValue<string>() ?? "system");
        if (path.StartsWith("rain.") || path.StartsWith("audio.") || path.StartsWith("atmosphere.") || path.StartsWith("frame.")) { updating = true; presets.SelectedItem = "Custom"; updating = false; }
    }
    internal static void Set(JsonObject root, string path, JsonNode? value)
    {
        string[] parts = path.Split('.'); JsonObject node = root;
        foreach (string part in parts[..^1]) { if (node[part] is not JsonObject nested) { nested = []; node[part] = nested; } node = nested; }
        node[parts[^1]] = value;
    }
    private void Flush()
    {
        if (pending.Count == 0) return;
        var patch = new JsonObject(); foreach (var (path, value) in pending) patch[path] = value?.DeepClone(); pending.Clear(); engine.Send("patch", patch);
    }
    internal void OnMessage(JsonObject message)
    {
        if (message["settings"] is JsonObject snapshot)
        {
            settings = (JsonObject)snapshot.DeepClone(); foreach (var (path, value) in pending) Set(settings, path, value?.DeepClone());
            updating = true;
            foreach (var (path, set) in setters) { if (pending.ContainsKey(path)) continue; set(Read(path)); }
            pause.Content = MakeIcon(Read("paused")?.GetValue<bool>() == true ? PlayIcon : PauseIcon); mute.Content = MakeIcon(Read("audio.muted")?.GetValue<bool>() == true ? MutedIcon : SoundIcon);
            AutomationProperties.SetName(pause, Read("paused")?.GetValue<bool>() == true ? "Resume visuals" : "Pause visuals"); AutomationProperties.SetName(mute, Read("audio.muted")?.GetValue<bool>() == true ? "Unmute" : "Mute");
            var selected = presets.SelectedItem?.ToString() ?? "Custom";
            var names = new[] { "Custom", "Cozy Window", "Light Drizzle", "Autumn Storm", "Night Rain", "Sleep" }.Concat(settings["saved_presets"]?.AsArray().Select(n => n!["name"]!.GetValue<string>()) ?? []).ToList();
            if (presets.ItemsSource is not IEnumerable<string> currentNames || !currentNames.SequenceEqual(names)) presets.ItemsSource = names;
            var requested = message["preset"]?.GetValue<string>() ?? selected;
            if (!Equals(presets.SelectedItem, requested)) presets.SelectedItem = requested;
            weatherNotice.Visibility = Read("weather.enabled")?.GetValue<bool>() == true ? Visibility.Visible : Visibility.Collapsed;
            updating = false; ApplyTheme(Read("theme")?.GetValue<string>() ?? "system");
        }
        if (message["monitors"] is JsonArray displays) monitors = displays;
        if (message["weather_results"] is JsonArray results)
        {
            searchResults = results; updating = true;
            var titles = results.Select(n => $"{n!["name"]}, {n["country"]}").ToList();
            if (cities.ItemsSource is not IEnumerable<string> currentCities || !currentCities.SequenceEqual(titles)) cities.ItemsSource = titles;
            updating = false;
        }
        weatherStatus.Text = message["weather_status"]?.GetValue<string>() ?? weatherStatus.Text;
        status.Text = message["error"]?.GetValue<string>() ?? message["status"]?.GetValue<string>() ?? status.Text;
        fpsInfo.Text = message["fps_status"]?.GetValue<string>() ?? fpsInfo.Text;
        if (message["toggle"] is JsonObject anchor)
        {
            if (Environment.GetEnvironmentVariable("RAINGLASS_UI_LOG") is string log) System.IO.File.AppendAllText(log, $"Toggle received, visible={IsVisible}, anchor={anchor}\n");
            if (IsVisible) { Flush(); Hide(); }
            else if ((DateTime.UtcNow - lastDismissed).TotalMilliseconds > 250) { WindowState = WindowState.Normal; Position(anchor); Show(); Activate(); }
        }
    }
    private void ApplyTheme(string mode)
    {
        bool dark = mode == "dark";
        if (mode == "system") { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"); dark = key?.GetValue("AppsUseLightTheme") is int value && value == 0; }
        if (appliedDarkTheme == dark) return; appliedDarkTheme = dark;
        var colors = dark ? new[] { "#171D28", "#222B39", "#EEF3FC", "#A5B2C7", "#344052" } : new[] { "#F7F9FC", "#FFFFFF", "#142033", "#637084", "#DFE6EF" };
        var names = new[] { "Surface", "Panel", "Text", "Muted", "Line" };
        for (int i = 0; i < names.Length; i++) Application.Current.Resources[names[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
    }
    private void Position(JsonObject anchor)
    {
        int x = anchor["x"]!.GetValue<int>(), y = anchor["y"]!.GetValue<int>();
        var monitor = Native.MonitorFromPoint(new Native.Point(x, y), 2);
        var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() }; Native.GetMonitorInfo(monitor, ref info);
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        Native.SetWindowPos(hwnd, 0, info.Work.Left, info.Work.Top, 0, 0, 0x15);
        double scale = Native.GetDpiForWindow(hwnd) / 96.0; if (scale <= 0) scale = 1;
        Width = Math.Min(420, (info.Work.Right-info.Work.Left) / scale - 16);
        Height = Math.Min(720, (info.Work.Bottom-info.Work.Top) / scale - 16);
        int width = (int)Math.Ceiling(Width*scale), height = (int)Math.Ceiling(Height*scale);
        var placement = ClampPlacement(x, y, width, height, info.Work);
        Native.SetWindowPos(hwnd, -1, placement.X, placement.Y, width, height, 0x10);
        if (monitors is not null)
        {
            var display = monitors.FirstOrDefault(n => x >= n!["x"]!.GetValue<int>() && x < n["x"]!.GetValue<int>() + n["width"]!.GetValue<int>() && y >= n["y"]!.GetValue<int>() && y <= n["y"]!.GetValue<int>() + n["height"]!.GetValue<int>());
            updating = true; fpsSlider.Maximum = display?["hz"]?.GetValue<double>() ?? 60;
            setters["frame_rate"](Read("frame_rate")); updating = false;
        }
    }
    internal static Native.Point ClampPlacement(int x, int y, int width, int height, Native.Rect work) => new(
        Math.Max(work.Left+8, Math.Min(x-width/2, work.Right-width-8)), Math.Max(work.Top+8, Math.Min(y-height-10, work.Bottom-height-8)));

    internal void CaptureForTest(int tab, string theme, string path)
    {
        SelectTab(tab); ApplyTheme(theme);
        var visual = (FrameworkElement)Content;
        visual.Measure(new Size(Width, Height)); visual.Arrange(new Rect(0, 0, Width, Height)); visual.UpdateLayout();
        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Width, (int)Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder(); encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
        using var file = System.IO.File.Create(path); encoder.Save(file);
    }
}
internal static class Native
{
    [StructLayout(LayoutKind.Sequential)] internal struct Point(int x, int y) { public int X = x, Y = y; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] internal static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] internal static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtrNative(nint hwnd, int index, nint value);
    internal static void SetWindowLongPtr(nint hwnd, int index, long value) => SetWindowLongPtrNative(hwnd, index, (nint)value);
}
