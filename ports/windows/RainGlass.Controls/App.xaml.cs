using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;

namespace RainGlass.Controls;
public partial class App : Application
{
    public App()
    {
        if (Environment.GetCommandLineArgs().Contains("--self-test")) SelfTests.Log("Application constructed");
    }
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--self-test")) { SelfTests.Log("Startup"); Shutdown(SelfTests.Run()); return; }
        string Argument(string key) { int i = Array.IndexOf(e.Args, key); return i >= 0 && i + 1 < e.Args.Length ? e.Args[i + 1] : ""; }
        string pipe = Argument("--pipe");
        if (string.IsNullOrWhiteSpace(pipe)) { Shutdown(2); return; }
        var connection = new EngineConnection(pipe);
        var popup = new PopupWindow(connection);
        MainWindow = popup;
        _ = connection.RunAsync();
        if (Environment.GetEnvironmentVariable("RAINGLASS_UI_INTEGRATION_LOG") is string testLog && !System.IO.File.Exists(testLog))
            _ = IntegrationTests.Run(connection, testLog);
        if (int.TryParse(Argument("--engine"), out int pid))
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            timer.Tick += (_, _) => { try { if (Process.GetProcessById(pid).HasExited) Shutdown(); } catch (ArgumentException) { Shutdown(); } };
            timer.Start();
        }
        Exit += (_, _) => connection.Dispose();
    }
}
