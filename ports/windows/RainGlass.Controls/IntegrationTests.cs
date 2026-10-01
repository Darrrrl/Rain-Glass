using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace RainGlass.Controls;
// Opt-in end-to-end checks against an engine using RAINGLASS_CONFIG_DIR.
internal static class IntegrationTests
{
    public static async Task Run(EngineConnection engine, string log)
    {
        var snapshots = Channel.CreateUnbounded<JsonObject>();
        void Receive(JsonObject value) => snapshots.Writer.TryWrite((JsonObject)value.DeepClone());
        engine.Message += Receive;
        void Record(string message) => File.AppendAllText(log, message + Environment.NewLine);
        async Task<JsonObject> Wait(Func<JsonObject, bool> predicate, int seconds = 15)
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            while (true) { var snapshot = await snapshots.Reader.ReadAsync(deadline.Token); if (predicate(snapshot)) return snapshot; }
        }
        async Task<JsonObject> Patch(JsonObject values, Func<JsonObject, bool> predicate)
        {
            engine.Send("patch", values); return await Wait(s => s["settings"] is JsonObject settings && predicate(settings));
        }
        try
        {
            var initial = await Wait(s => s["settings"] is JsonObject);
            var original = (JsonObject)initial["settings"]!.DeepClone();
            await Patch(new JsonObject { ["rain.blur"] = 64, ["audio.master"] = .77, ["audio.muted"] = true, ["rain.lightningEnabled"] = true, ["rain.thunderProbability"] = 1, ["rain.lightningIntensity"] = .4, ["frame_rate"] = new JsonObject { ["fixed"] = 0 }, ["theme"] = "dark" },
                s => s["rain"]!["blur"]!.GetValue<double>() == 64 && s["audio"]!["master"]!.GetValue<double>() == .77 && s["frame_rate"]?["fixed"]?.GetValue<int>() == 0);
            Record("PASS blur 100%, volume, mute, thunder parameters and FPS 0");
            foreach (uint fps in new uint[] { 30, 60, 165, 240 })
            {
                await Patch(new JsonObject { ["frame_rate"] = new JsonObject { ["fixed"] = fps }, ["audio.muted"] = false, ["rain.blur"] = 0 }, s => s["frame_rate"] is JsonObject rate && rate["fixed"]!.GetValue<uint>() == fps);
                Record($"PASS fixed FPS {fps}");
            }
            await Patch(new JsonObject { ["frame_rate"] = "monitor" }, s => s["frame_rate"] is JsonValue value && value.GetValue<string>() == "monitor"); Record("PASS monitor FPS");
            await Patch(new JsonObject { ["frame_rate"] = new JsonObject { ["fixed"] = 0 }, ["theme"] = "light" }, s => s["theme"]!.GetValue<string>() == "light" && !s["audio"]!["muted"]!.GetValue<bool>()); Record("PASS FPS 0 preserves saved unmute and light theme");
            for (int i = 1; i <= 20; i++) engine.Send("patch", new JsonObject { ["rain.intensity"] = i / 20.0 });
            await Wait(s => s["settings"]?["rain"]?["intensity"]?.GetValue<double>() == 1); Record("PASS rapid settings changes converge");
            string name = "Test " + Guid.NewGuid().ToString("N")[..8];
            bool Contains(JsonObject s) => s["settings"]?["saved_presets"]?.AsArray().Any(p => p!["name"]!.GetValue<string>() == name) == true;
            engine.Send("save_preset", JsonValue.Create(name)); await Wait(Contains);
            string presetPath = Path.Combine(Path.GetDirectoryName(log)!, "integration-preset.json");
            engine.Send("export_preset", new JsonObject { ["name"] = name, ["path"] = presetPath });
            await Wait(_ => File.Exists(presetPath));
            engine.Send("delete_preset", JsonValue.Create(name)); await Wait(s => s["settings"] is not null && !Contains(s));
            engine.Send("import_preset", JsonValue.Create(presetPath)); await Wait(Contains);
            engine.Send("preset", JsonValue.Create(name)); await Wait(s => s["preset"]?.GetValue<string>() == name);
            engine.Send("delete_preset", JsonValue.Create(name)); await Wait(s => s["settings"] is not null && !Contains(s)); Record("PASS preset save/export/delete/import/apply");
            engine.Send("search_weather", JsonValue.Create("Vienna"));
            var result = await Wait(s => s["weather_results"] is JsonArray cities && cities.Count > 0, 25);
            await Patch(new JsonObject { ["weather.city"] = result["weather_results"]![0]!.DeepClone(), ["weather.enabled"] = true }, s => s["weather"]!["enabled"]!.GetValue<bool>());
            await Wait(s => s["settings"]?["weather"]?["cached"] is JsonObject, 25); Record("PASS live Open-Meteo city search and current conditions");
            var restore = new JsonObject();
            foreach (var group in new[] { "rain", "audio", "atmosphere", "frame" })
                foreach (var field in original[group]!.AsObject())
                    if (field.Key != "stormFrequency") restore[group + "." + field.Key] = field.Value?.DeepClone();
            foreach (string key in new[] { "fit", "zoom", "quality", "frame_rate", "seed", "paused", "theme", "diagnostics_overlay" }) restore[key] = original[key]?.DeepClone();
            restore["weather.enabled"] = original["weather"]?["enabled"]?.DeepClone() ?? JsonValue.Create(false);
            restore["weather.city"] = original["weather"]?["city"]?.DeepClone();
            await Patch(restore, s => s["rain"]!["blur"]!.GetValue<double>() == original["rain"]!["blur"]!.GetValue<double>() && s["weather"]!["enabled"]!.GetValue<bool>() == original["weather"]!["enabled"]!.GetValue<bool>());
            Record("PASS restore manual settings"); Record("COMPLETE");
        }
        catch (Exception e) { Record("FAIL " + e); }
        finally { engine.Message -= Receive; }
    }
}
