using System.IO;
using System.IO.Pipes;
using System.Text.Json.Nodes;

namespace RainGlass.Controls;
internal static class SelfTests
{
    internal static void Log(string text) => File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "self-test.log"), text + Environment.NewLine);
    public static int Run()
    {
        try
        {
            var settings = new JsonObject(); PopupWindow.Set(settings, "rain.blur", JsonValue.Create(64.0));
            PopupWindow.Set(settings, "audio.muted", JsonValue.Create(true));
            if (settings["rain"]!["blur"]!.GetValue<double>() != 64 || !settings["audio"]!["muted"]!.GetValue<bool>()) throw new Exception("Patch paths");
            var position = PopupWindow.ClampPlacement(-10, 1070, 630, 1000, new Native.Rect { Left = -1920, Top = 0, Right = 0, Bottom = 1080 });
            if (position.X < -1920 || position.X+630 > 0 || position.Y < 0 || position.Y+1000 > 1080) throw new Exception("Negative monitor placement");
            Log("State and placement passed");
            Task.Run(TestPipe).GetAwaiter().GetResult();
            Log("Pipe passed");
            var popup = new PopupWindow(new EngineConnection("unused-self-test"));
            var handle = new System.Windows.Interop.WindowInteropHelper(popup).EnsureHandle();
            long style = Native.GetWindowLongPtr(handle, -20).ToInt64();
            if (popup.ShowInTaskbar || (style & 0x80) == 0 || (style & 0x40000) != 0 || (Native.GetWindowLongPtr(handle, -16).ToInt64() & 0x20000) != 0)
                throw new Exception("Popup must be a tool window without a taskbar entry or minimize button");
            var fixture = Environment.GetEnvironmentVariable("RAINGLASS_UI_FIXTURE");
            if (fixture is not null)
            {
                popup.OnMessage(new JsonObject { ["version"] = 1, ["settings"] = JsonNode.Parse(File.ReadAllText(fixture)), ["status"] = "RainGlass running", ["fps_status"] = "2560×1440: 60.0 FPS / 165.0 Hz" });
                foreach (string theme in new[] { "light", "dark" }) for (int tab = 0; tab < 4; tab++) popup.CaptureForTest(tab, theme, Path.Combine(AppContext.BaseDirectory, $"self-test-{theme}-{tab}.png"));
            }
            popup.Close();
            if (!Native.IsWindow(handle)) throw new Exception("Closing the popup must hide its reusable window");
            return 0;
        }
        catch (Exception e) { File.WriteAllText(Path.Combine(Path.GetTempPath(), "RainGlass-controls-test-error.txt"), e.ToString()); return 1; }
    }
    private static async Task TestPipe()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        string name = "RainGlass-test-" + Guid.NewGuid();
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        Log("Connecting pipe");
        var accepting = server.WaitForConnectionAsync(timeout.Token); await client.ConnectAsync(timeout.Token); await accepting;
        Log("Pipe connected");
        byte[] buffer = new byte[256];
        var reading = server.ReadAsync(buffer, timeout.Token).AsTask();
        await client.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"version\":1,\"command\":\"snapshot\"}\n"), timeout.Token);
        int length = await reading;
        if (JsonNode.Parse(System.Text.Encoding.UTF8.GetString(buffer, 0, length))!["command"]!.GetValue<string>() != "snapshot") throw new Exception("Pipe framing");
    }
}
