using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using System.Windows;

namespace RainGlass.Controls;
public sealed class EngineConnection(string pipeName) : IDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly Channel<JsonObject> outgoing = Channel.CreateUnbounded<JsonObject>();
    public event Action<JsonObject>? Message;
    public void Send(string command, JsonNode? data = null) => outgoing.Writer.TryWrite(new JsonObject { ["version"] = 1, ["command"] = command, ["data"] = data });
    public async Task RunAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(cancellation.Token);
                using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
                using var session = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
                var writing = Task.Run(async () => {
                    await foreach (var message in outgoing.Reader.ReadAllAsync(session.Token))
                        await writer.WriteLineAsync(message.ToJsonString().AsMemory(), session.Token);
                }, session.Token);
                Send("snapshot");
                try
                {
                    while (await reader.ReadLineAsync(cancellation.Token) is { } line)
                    {
                        if (line.Length > 1_048_576) throw new IOException("Oversized engine message");
                        var message = JsonNode.Parse(line)?.AsObject();
                        if (message?["version"]?.GetValue<int>() == 1)
                            await Application.Current.Dispatcher.InvokeAsync(() => Message?.Invoke(message));
                    }
                }
                finally { session.Cancel(); try { await writing; } catch (OperationCanceledException) { } }
            }
            catch (Exception e)
            {
                if (Environment.GetEnvironmentVariable("RAINGLASS_UI_LOG") is string log) File.AppendAllText(log, e + Environment.NewLine);
                if (!cancellation.IsCancellationRequested)
                    await Application.Current.Dispatcher.InvokeAsync(() => Message?.Invoke(new JsonObject { ["error"] = "Controls reconnecting: " + e.Message }));
            }
        }
    }
    public void Dispose() => cancellation.Cancel();
}
