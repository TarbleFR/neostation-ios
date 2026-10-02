using System.Diagnostics;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
namespace NeoPlayReceiver;
internal sealed class ReceiverWindow : Form
{
    private readonly WebView2 web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(8, 13, 23) };
    private readonly ReceiverServer receiver = new();
    private MdnsPublisher? mdns;
    private readonly string? fixture, testOutput;
    private bool fullScreen, closing;
    private Rectangle savedBounds;
    private FormBorderStyle savedBorder;
    private FormWindowState savedState;
    private readonly System.Windows.Forms.Timer pinTimer = new() { Interval = 300000 };
    internal int ExitCode { get; private set; }
    internal ReceiverWindow(string? fixture, string? testOutput) {
        this.fixture = fixture; this.testOutput = testOutput;
        Text = "NeoPlay Receiver"; Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); ClientSize = new Size(1160, 760); MinimumSize = new Size(760, 520); StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(8, 13, 23); Controls.Add(web); KeyPreview = true;
        Shown += async (_, _) => await Initialize();
        FormClosing += async (_, e) => { if (closing) return; e.Cancel = true; closing = true; pinTimer.Stop(); mdns?.Dispose(); await receiver.DisposeAsync(); web.Dispose(); Close(); };
        pinTimer.Tick += (_, _) => receiver.RenewCode();
    }
    private async Task Initialize() {
        try {
            Directory.CreateDirectory(AppLog.Folder);
            var options = new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required");
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppLog.Folder, fixture is null ? "WebView2" : "WebView2-Test"), options);
            await web.EnsureCoreWebView2Async(environment);
            var core = web.CoreWebView2; core.Settings.AreDevToolsEnabled = false; core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false; core.Settings.AreBrowserAcceleratorKeysEnabled = false; core.Settings.IsZoomControlEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false; core.Settings.IsGeneralAutofillEnabled = false;
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.NewWindowRequested += (_, e) => e.Handled = true; core.DownloadStarting += (_, e) => e.Cancel = true;
            core.ProcessFailed += (_, _) => { receiver.Disconnect(); AppLog.Write("webview_failed"); };
            core.WebMessageReceived += (_, e) => { if (!e.Source.StartsWith(receiver.LocalUrl + "/", StringComparison.Ordinal)) return; var message = e.TryGetWebMessageAsString(); if (message == "licenses") OpenLicenses(); if (message == "copy") Clipboard.SetText(receiver.Pin); if (message == "fullscreen") ToggleFullScreen(); if (message == "exitfullscreen" && fullScreen) ToggleFullScreen(); if (message == "logs") Process.Start(new ProcessStartInfo("explorer.exe", AppLog.Folder) { UseShellExecute = true }); };
            await receiver.StartAsync(fixture is not null);
            core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith(receiver.LocalUrl + "/", StringComparison.Ordinal)) e.Cancel = true; };
            web.Source = new Uri(receiver.LocalUrl + "/?token=" + receiver.ViewerToken + (fixture is null ? "" : "&test=1"));
            if (fixture is null) { mdns = new MdnsPublisher(receiver); mdns.Start(); AppLog.Write("started", "port=" + receiver.Port + " mdns=" + mdns.Available); pinTimer.Start(); }
            else await RunSelfTest();
        } catch (WebView2RuntimeNotFoundException) {
            ExitCode = 1;
            if (fixture is null && MessageBox.Show("Le composant Microsoft Edge WebView2 est nécessaire.\n\nOuvrir sa page officielle d’installation ?", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes) Process.Start(new ProcessStartInfo("https://developer.microsoft.com/microsoft-edge/webview2/consumer/") { UseShellExecute = true });
            Close();
        } catch (Exception error) { ExitCode = 1; AppLog.Write("initialization", error.ToString()); if (testOutput is not null) { Directory.CreateDirectory(testOutput); await File.WriteAllTextAsync(Path.Combine(testOutput, "error.txt"), error.ToString()); } else MessageBox.Show("Impossible de démarrer NeoPlay.\n" + error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); Close(); }
    }
    private void OpenLicenses() {
        var folder = Path.Combine(AppLog.Folder, "Licences"); Directory.CreateDirectory(folder); var assembly = System.Reflection.Assembly.GetExecutingAssembly();
        foreach (var name in assembly.GetManifestResourceNames().Where(n => n.EndsWith(".txt"))) { using var source = assembly.GetManifestResourceStream(name)!; using var output = File.Create(Path.Combine(folder, name.Replace("NeoPlayReceiver.Assets.", ""))); source.CopyTo(output); }
        Process.Start(new ProcessStartInfo("explorer.exe", folder) { UseShellExecute = true });
    }
    private void ToggleFullScreen() {
        if (!fullScreen) { savedBounds = Bounds; savedState = WindowState; savedBorder = FormBorderStyle; WindowState = FormWindowState.Normal; FormBorderStyle = FormBorderStyle.None; Bounds = Screen.FromControl(this).Bounds; }
        else { FormBorderStyle = savedBorder; Bounds = savedBounds; WindowState = savedState; }
        fullScreen = !fullScreen; if (web.CoreWebView2 is not null) _ = web.CoreWebView2.ExecuteScriptAsync("document.body.classList.toggle('immersive', " + (fullScreen ? "true" : "false") + ")");
    }
    private async Task RunSelfTest() {
        Directory.CreateDirectory(testOutput!);
        for (int i = 0; i < 150 && !receiver.IsReady; i++) await Task.Delay(100);
        if (!receiver.IsReady) throw new InvalidOperationException("WebView2 receiver did not become ready");
        using (var image = File.Create(Path.Combine(testOutput!, "waiting.png"))) await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image);
        using var http = new HttpClient();
        var response = await http.PostAsJsonAsync(receiver.LocalUrl + "/v1/pair", new { v = 1, pin = receiver.Pin }); response.EnsureSuccessStatusCode();
        using var grant = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        using var socket = new ClientWebSocket(); socket.Options.SetRequestHeader("Authorization", "Bearer " + grant.RootElement.GetProperty("token").GetString());
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        await socket.ConnectAsync(new Uri(receiver.LocalUrl.Replace("http://", "ws://") + "/v1/sender"), deadline.Token);
        using var parts = JsonDocument.Parse(await File.ReadAllTextAsync(fixture!));
        foreach (var part in parts.RootElement.EnumerateArray()) {
            bool initial = part.GetProperty("initial").GetBoolean(); var bytes = Convert.FromBase64String(part.GetProperty("data").GetString()!);
            var packet = new byte[bytes.Length + 1]; packet[0] = initial ? (byte)1 : (byte)2; bytes.CopyTo(packet, 1);
            await socket.SendAsync(packet.AsMemory(), WebSocketMessageType.Binary, true, deadline.Token);
            if (!initial) await Task.Delay(TimeSpan.FromSeconds(part.GetProperty("duration").GetDouble()), deadline.Token);
        }
        await Task.Delay(250);
        var result = await web.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window.neoPlayMetrics())");
        var json = JsonSerializer.Deserialize<string>(result)!; using var report = JsonDocument.Parse(json); var r = report.RootElement;
        if (r.GetProperty("width").GetInt32() != 640 || r.GetProperty("height").GetInt32() != 480 || r.GetProperty("frames").GetInt32() < 60 || r.GetProperty("audioRms").GetDouble() < 0.01 || !receiver.PlaybackAcknowledged || r.GetProperty("error").ValueKind != JsonValueKind.Null) throw new InvalidOperationException("Decode verification failed: " + json);
        using (var image = File.Create(Path.Combine(testOutput!, "playback.png"))) await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image);
        ToggleFullScreen(); await Task.Delay(300); if (FormBorderStyle != FormBorderStyle.None) throw new InvalidOperationException("Fullscreen failed"); ToggleFullScreen();
        receiver.Disconnect(); await Task.Delay(400);
        await File.WriteAllTextAsync(Path.Combine(testOutput!, "report.json"), json);
        await File.WriteAllTextAsync(Path.Combine(testOutput!, "host.json"), JsonSerializer.Serialize(new { nativeWindow = true, webView2 = web.CoreWebView2.Environment.BrowserVersionString, fullScreenTested = true, protocol = 1, physicalIPhone = false }));
        Close();
    }
}
