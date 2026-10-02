using System.Net;
using System.Net.WebSockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
namespace NeoPlayReceiver;

internal sealed class ReceiverServer : IAsyncDisposable
{
    internal const int MaxPacket = 4 * 1024 * 1024;
    private readonly object sync = new();
    private WebApplication? app;
    private Peer? viewer, sender;
    private bool viewerReserved, senderReserved, ready;
    private int width = 1280, height = 720;
    private string pin = NewPin();
    private long pinExpires = Now + 300000;
    private (string Token, IPAddress Address, long Until)? grant;
    private readonly Dictionary<string, (int Count, long Until)> attempts = new();
    internal string ViewerToken { get; } = Token();
    internal string Id { get; } = Token();
    internal string Name { get; } = "NeoPlay — " + Environment.MachineName;
    internal int Port { get; private set; }
    internal bool PlaybackAcknowledged { get; private set; }
    internal bool IsReady { get { lock (sync) return ready; } }
    internal string Pin { get { lock (sync) return pin; } }
    internal string LocalUrl => $"http://127.0.0.1:{Port}";
    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private static string Token() => Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
    private static string NewPin() => RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
    private static bool Equal(string? a, string b) => a is not null && a.Length <= 256 && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));
    private static int Dimension(JsonElement value, string key, int fallback, int max) => value.TryGetProperty(key, out var p) && p.TryGetInt32(out var n) && n >= 2 ? Math.Min(max, n / 2 * 2) : fallback;
    private object State() => new { type = "state", pin, expires = pinExpires, connected = sender is not null, name = Name };
    private void RotatePin() { pin = NewPin(); pinExpires = Now + 300000; grant = null; }
    internal async Task StartAsync(bool loopbackOnly = false)
    {
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [], ContentRootPath = AppContext.BaseDirectory });
        builder.Logging.ClearProviders(); // Never log pairing capabilities or request URLs.
        builder.WebHost.ConfigureKestrel(options => { options.AddServerHeader = false; options.Limits.MaxRequestBodySize = 1024; options.Limits.MaxConcurrentConnections = 32; options.Limits.MaxConcurrentUpgradedConnections = 4; options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(8); options.Listen(loopbackOnly ? IPAddress.Loopback : IPAddress.Any, 0); });
        app = builder.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(10), KeepAliveTimeout = TimeSpan.FromSeconds(10) });
        app.Run(Handle);
        await app.StartAsync();
        Port = new Uri(app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single()).Port;
    }
    internal void Disconnect() { lock (sync) sender?.Close("receiver_stop"); }
    internal void RenewCode() { lock (sync) { if (sender is null) { RotatePin(); viewer?.Json(State()); } } }
    private static bool PrivateAddress(IPAddress? address)
    {
        if (address is null) return false; if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return true; var b = address.GetAddressBytes();
        return b.Length == 4 && (b[0] == 10 || b[0] == 192 && b[1] == 168 || b[0] == 172 && b[1] >= 16 && b[1] <= 31 || b[0] == 169 && b[1] == 254);
    }
    private async Task Handle(HttpContext context)
    {
        var request = context.Request;
        context.Response.Headers.CacheControl = "no-store";
        try {
            if (!PrivateAddress(context.Connection.RemoteIpAddress)) { context.Response.StatusCode = 403; return; }
            if (request.Path == "/v1/info" && request.Method == "GET") {
                object info; lock (sync) info = new { v = 1, id = Id, name = Name, kind = "windows", available = ready && sender is null && !senderReserved, width, height, maxWidth = 1920, maxHeight = 1080, fps = 60 };
                await context.Response.WriteAsJsonAsync(info); return;
            }
            if (request.Path == "/v1/pair" && request.Method == "POST") { await Pair(context); return; }
            if (context.WebSockets.IsWebSocketRequest) { await Upgrade(context); return; }
            var loopback = IPAddress.IsLoopback(context.Connection.RemoteIpAddress!);
            if (!loopback || request.Host.Port != Port || request.Host.Host != "127.0.0.1") { context.Response.StatusCode = 403; return; }
            var asset = request.Path.Value switch { "/" => "index.html", "/desktop.mjs" => "desktop.mjs", "/protocol.mjs" => "protocol.mjs", "/LICENSE.txt" => "LICENSE.txt", _ => null };
            if (request.Method != "GET" || asset is null) { context.Response.StatusCode = 404; return; }
            if (asset == "index.html" && !Equal(request.Query["token"], ViewerToken)) { context.Response.StatusCode = 403; return; }
            using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NeoPlayReceiver.Assets." + asset);
            if (resource is null) { context.Response.StatusCode = 404; return; }
            using var reader = new StreamReader(resource); var body = (await reader.ReadToEndAsync()).Replace("__VIEWER_TOKEN__", ViewerToken);
            context.Response.ContentType = asset.EndsWith("html") ? "text/html; charset=utf-8" : asset.EndsWith("mjs") ? "text/javascript; charset=utf-8" : "text/plain; charset=utf-8";
            context.Response.Headers["X-Content-Type-Options"] = "nosniff";
            context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:*; media-src blob:; img-src 'self' data:; frame-ancestors 'none'";
            await context.Response.WriteAsync(body);
        } catch (OperationCanceledException) { context.Abort(); }
        catch (Exception error) { AppLog.Write("request", error.GetType().Name); if (!context.Response.HasStarted) context.Response.StatusCode = 500; else context.Abort(); }
    }
    private async Task Pair(HttpContext context)
    {
        if (context.Request.Headers.ContainsKey("Origin")) { context.Response.StatusCode = 403; return; }
        var address = context.Connection.RemoteIpAddress!; var key = address.ToString();
        lock (sync) {
            foreach (var old in attempts.Where(p => p.Value.Until < Now).Select(p => p.Key).ToArray()) attempts.Remove(old);
            if (attempts.Count >= 128 && !attempts.ContainsKey(key)) { context.Response.StatusCode = 429; return; }
            (int Count, long Until) item = attempts.GetValueOrDefault(key, (0, Now + 60000)); item.Count++; attempts[key] = item;
            if (item.Count > 5) { context.Response.StatusCode = 429; return; }
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted); timeout.CancelAfter(TimeSpan.FromSeconds(8));
        using var body = new MemoryStream(); var buffer = new byte[1025];
        while (true) { int count = await context.Request.Body.ReadAsync(buffer, timeout.Token); if (count == 0) break; if (body.Length + count > 1024) { context.Response.StatusCode = 413; return; } body.Write(buffer, 0, count); }
        JsonDocument document;
        try { document = JsonDocument.Parse(body.ToArray()); } catch (JsonException) { context.Response.StatusCode = 400; return; }
        using (document) {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("v", out var v) || !v.TryGetInt32(out var version) || version != 1 || !root.TryGetProperty("pin", out var p) || p.ValueKind != JsonValueKind.String) { context.Response.StatusCode = 400; return; }
            object reply;
            lock (sync) {
                if (Now > pinExpires || !Equal(p.GetString(), pin)) { context.Response.StatusCode = 403; return; }
                if (!ready || sender is not null || senderReserved) { context.Response.StatusCode = 409; return; }
                var token = Token(); grant = (token, address, Now + 30000);
                reply = new { v = 1, token, width, height, maxWidth = 1920, maxHeight = 1080, fps = 60 };
            }
            await context.Response.WriteAsJsonAsync(reply);
        }
    }
    private async Task Upgrade(HttpContext context)
    {
        bool isViewer; var request = context.Request;
        lock (sync) {
            isViewer = request.Path == "/v1/view" && IPAddress.IsLoopback(context.Connection.RemoteIpAddress!) && Equal(request.Query["token"], ViewerToken) && !viewerReserved && viewer is null && request.Headers.Origin == LocalUrl;
            bool isSender = request.Path == "/v1/sender" && !request.Headers.ContainsKey("Origin") && ready && sender is null && !senderReserved && grant is { } g && g.Until > Now && g.Address.Equals(context.Connection.RemoteIpAddress) && Equal(request.Headers.Authorization, "Bearer " + g.Token);
            if (!isViewer && !isSender) { context.Response.StatusCode = 403; return; }
            if (isViewer) viewerReserved = true; else { senderReserved = true; grant = null; }
        }
        Peer? peer = null;
        try {
            var socket = await context.WebSockets.AcceptWebSocketAsync(); peer = new Peer(socket, context.RequestAborted);
            lock (sync) {
                if (isViewer) { viewer = peer; viewerReserved = false; peer.Json(State()); }
                else { sender = peer; senderReserved = false; PlaybackAcknowledged = false; peer.Json(new { type = "ready", v = 1, width, height, maxWidth = 1920, maxHeight = 1080, fps = 60 }); viewer?.Json(State()); AppLog.Write("connected"); }
            }
            bool initialized = false; var packet = new byte[isViewer ? 2048 : MaxPacket];
            while (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseSent) {
                var message = await peer.Read(packet, isViewer ? 600 : 30);
                if (message is null) break;
                var (count, binary) = message.Value;
                if (isViewer) { if (binary) break; HandleViewer(peer, packet.AsSpan(0, count)); }
                else {
                    if (!binary || count < 9 || (packet[0] != 1 && packet[0] != 2)) break;
                    if (packet[0] == 1) initialized = true;
                    lock (sync) { if (!initialized || viewer is null || !viewer.Bytes(packet.AsSpan(0, count).ToArray())) { peer.Close("backpressure"); break; } }
                }
            }
        } catch (Exception error) when (error is WebSocketException or OperationCanceledException or InvalidDataException or JsonException) { AppLog.Write("stream_closed", error.GetType().Name); }
        finally {
            lock (sync) {
                if (isViewer) { viewerReserved = false; if (viewer == peer) { viewer = null; ready = false; sender?.Close("viewer_closed"); } }
                else { senderReserved = false; if (sender == peer) { sender = null; RotatePin(); viewer?.Json(new { type = "ended" }); viewer?.Json(State()); } }
            }
            if (peer is not null) await peer.DisposeAsync();
        }
    }
    private void HandleViewer(Peer peer, ReadOnlySpan<byte> bytes)
    {
        using var document = JsonDocument.Parse(bytes.ToArray()); var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var kind)) throw new InvalidDataException();
        lock (sync) {
            switch (kind.GetString()) {
                case "display":
                    int w = Dimension(root, "width", 1280, 7680), h = Dimension(root, "height", 720, 4320);
                    bool changed = w != width || h != height; width = w; height = h;
                    ready = root.TryGetProperty("supported", out var supported) && supported.ValueKind == JsonValueKind.True;
                    if (changed) sender?.Json(new { type = "display", width, height });
                    break;
                case "new_pin": if (sender is null) { RotatePin(); peer.Json(State()); } break;
                case "stop": sender?.Close("receiver_stop"); break;
                case "playback": PlaybackAcknowledged = root.TryGetProperty("playing", out var playing) && playing.ValueKind == JsonValueKind.True; sender?.Json(new { type = "playback", playing = PlaybackAcknowledged }); break;
            }
        }
    }
    public async ValueTask DisposeAsync() { lock (sync) { sender?.Abort(); viewer?.Abort(); } if (app is not null) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await app.StopAsync(timeout.Token); await app.DisposeAsync(); } }
}
