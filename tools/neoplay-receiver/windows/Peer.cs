using System.Net.WebSockets;
using System.Text.Json;
using System.Threading.Channels;
namespace NeoPlayReceiver;
internal sealed class Peer : IAsyncDisposable
{
    private readonly WebSocket socket;
    private readonly CancellationTokenSource lifetime;
    private readonly Channel<(byte[] Data, WebSocketMessageType Type)> queue = Channel.CreateBounded<(byte[], WebSocketMessageType)>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly Task writer;
    private int queuedBytes;
    private string? closeReason;
    internal Peer(WebSocket socket, CancellationToken cancellation) { this.socket = socket; lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellation); writer = WriteLoop(); }
    internal bool Bytes(byte[] bytes) => Enqueue(bytes, WebSocketMessageType.Binary);
    internal void Json(object value) { if (!Enqueue(JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text)) Close("backpressure"); }
    private bool Enqueue(byte[] data, WebSocketMessageType type) {
        if (closeReason is not null) return false;
        if (Interlocked.Add(ref queuedBytes, data.Length) > 8 * 1024 * 1024) { Interlocked.Add(ref queuedBytes, -data.Length); return false; }
        if (queue.Writer.TryWrite((data, type))) return true;
        Interlocked.Add(ref queuedBytes, -data.Length); return false;
    }
    private async Task WriteLoop() {
        try {
            await foreach (var item in queue.Reader.ReadAllAsync(lifetime.Token)) {
                if (closeReason is not null) break;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(TimeSpan.FromSeconds(8));
                await socket.SendAsync(item.Data.AsMemory(), item.Type, true, timeout.Token); Interlocked.Add(ref queuedBytes, -item.Data.Length);
            }
            if (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseReceived) {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, closeReason ?? "closed", timeout.Token);
            }
        } catch (Exception error) when (error is WebSocketException or OperationCanceledException or ObjectDisposedException) { Abort(); }
    }
    internal async Task<(int Count, bool Binary)?> Read(byte[] buffer, int seconds) {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
        int count = 0; WebSocketMessageType? kind = null;
        while (true) {
            if (count == buffer.Length) throw new InvalidDataException("Packet too large");
            var result = await socket.ReceiveAsync(buffer.AsMemory(count), timeout.Token);
            if (result.MessageType == WebSocketMessageType.Close) return null;
            if (kind is not null && kind != result.MessageType) throw new InvalidDataException("Mixed message types");
            kind = result.MessageType; count += result.Count;
            if (result.EndOfMessage) return (count, kind == WebSocketMessageType.Binary);
        }
    }
    internal void Close(string reason) {
        if (Interlocked.CompareExchange(ref closeReason, reason, null) is not null) return;
        queue.Writer.TryComplete();
        _ = Task.Run(async () => { await Task.Delay(2500); Abort(); });
    }
    internal void Abort() { try { lifetime.Cancel(); socket.Abort(); } catch (ObjectDisposedException) { } }
    public async ValueTask DisposeAsync() { Close("closed"); try { await writer.WaitAsync(TimeSpan.FromSeconds(3)); } catch { Abort(); } socket.Dispose(); lifetime.Dispose(); }
}
