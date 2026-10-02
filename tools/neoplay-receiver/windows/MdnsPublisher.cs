using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
namespace NeoPlayReceiver;
// A deliberately narrow DNS-SD publisher: only this app's four local records.
internal sealed class MdnsPublisher : IDisposable
{
    private readonly ReceiverServer server;
    private readonly CancellationTokenSource stop = new();
    private readonly List<(UdpClient Socket, IPAddress Address)> outputs = [];
    private UdpClient? input;
    private Task? receiveTask, announceTask;
    private readonly string host, instance;
    internal bool Available { get; private set; }
    private const string Service = "_neoplay._tcp.local";
    internal MdnsPublisher(ReceiverServer server) { this.server = server; host = "neoplay-" + server.Id[..12] + ".local"; instance = "NeoPlay " + new string(Environment.MachineName.Where(char.IsAsciiLetterOrDigit).Take(20).ToArray()) + " " + server.Id[..6] + "." + Service; }
    internal void Start() {
        try {
            input = new UdpClient(AddressFamily.InterNetwork); input.ExclusiveAddressUse = false;
            input.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            input.Client.Bind(new IPEndPoint(IPAddress.Any, 5353)); input.MulticastLoopback = true;
            var addresses = NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.SupportsMulticast && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel).SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address).Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)).Distinct();
            foreach (var address in addresses) {
                try { input.JoinMulticastGroup(IPAddress.Parse("224.0.0.251"), address); var sender = new UdpClient(new IPEndPoint(address, 5353)); outputs.Add((sender, address)); }
                catch (SocketException) { AddOutput(address); }
            }
            Available = outputs.Count > 0; if (!Available) { input.Dispose(); input = null; return; }
            foreach (var output in outputs) { output.Socket.MulticastLoopback = true; output.Socket.Ttl = 255; output.Socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, output.Address.GetAddressBytes()); }
            receiveTask = Receive(); announceTask = Announce();
        } catch (SocketException error) { AppLog.Write("mdns", error.SocketErrorCode.ToString()); Available = false; }
    }
    private void AddOutput(IPAddress address) {
        UdpClient? socket = null;
        try { socket = new UdpClient(AddressFamily.InterNetwork); socket.ExclusiveAddressUse = false; socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true); socket.Client.Bind(new IPEndPoint(address, 5353)); outputs.Add((socket, address)); }
        catch (SocketException) { socket?.Dispose(); }
    }
    private async Task Announce() {
        try { await Task.Delay(300, stop.Token); await Send(120); await Task.Delay(1000, stop.Token); await Send(120); while (!stop.IsCancellationRequested) { await Task.Delay(30000, stop.Token); await Send(120); } }
        catch (OperationCanceledException) { }
    }
    private async Task Receive() {
        long last = 0;
        while (!stop.IsCancellationRequested) {
            try {
                var packet = await input!.ReceiveAsync(stop.Token); var bytes = packet.Buffer;
                if (bytes.Length < 12 || bytes.Length > 9000 || (bytes[2] & 0x80) != 0) continue;
                int count = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(4)), offset = 12; if (count > 32) continue;
                bool matches = false;
                for (int i = 0; i < count; i++) { var name = ReadName(bytes, ref offset); if (offset + 4 > bytes.Length) throw new InvalidDataException(); offset += 4; matches |= name.Equals(Service, StringComparison.OrdinalIgnoreCase) || name.Equals(instance, StringComparison.OrdinalIgnoreCase) || name.Equals(host, StringComparison.OrdinalIgnoreCase) || name == "_services._dns-sd._udp.local"; }
                if (!matches || Environment.TickCount64 - last < 150) continue; last = Environment.TickCount64;
                await Send(120, packet.RemoteEndPoint.Port == 5353 ? null : packet.RemoteEndPoint, BinaryPrimitives.ReadUInt16BigEndian(bytes));
            } catch (OperationCanceledException) { break; } catch (ObjectDisposedException) { break; }
            catch (Exception error) when (error is SocketException or InvalidDataException or ArgumentException or IndexOutOfRangeException) { }
        }
    }
    private async Task Send(uint ttl, IPEndPoint? destination = null, ushort id = 0) {
        foreach (var output in outputs) {
            try { var bytes = Response(output.Address, ttl, destination is null ? (ushort)0 : id); await output.Socket.SendAsync(bytes, destination ?? new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353)); }
            catch (SocketException error) { AppLog.Write("mdns_send", error.SocketErrorCode.ToString()); } catch (ObjectDisposedException) { }
        }
    }
    private byte[] Response(IPAddress address, uint ttl, ushort id) {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        U16(writer, id); U16(writer, 0x8400); U16(writer, 0); U16(writer, 5); U16(writer, 0); U16(writer, 0);
        Record(writer, Service, 12, false, ttl, w => Name(w, instance));
        Record(writer, "_services._dns-sd._udp.local", 12, false, ttl, w => Name(w, Service));
        Record(writer, instance, 33, true, ttl, w => { U16(w, 0); U16(w, 0); U16(w, (ushort)server.Port); Name(w, host); });
        Record(writer, instance, 16, true, ttl, w => { foreach (var value in new[] { "v=1", "kind=windows", "id=" + server.Id }) { var b = Encoding.UTF8.GetBytes(value); w.Write((byte)b.Length); w.Write(b); } });
        Record(writer, host, 1, true, ttl, w => w.Write(address.GetAddressBytes()));
        return stream.ToArray();
    }
    private static void Record(BinaryWriter writer, string name, ushort type, bool unique, uint ttl, Action<BinaryWriter> payload) {
        Name(writer, name); U16(writer, type); U16(writer, unique ? (ushort)0x8001 : (ushort)1);
        Span<byte> bytes = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(bytes, ttl); writer.Write(bytes);
        using var data = new MemoryStream(); using var temporary = new BinaryWriter(data); payload(temporary);
        U16(writer, (ushort)data.Length); writer.Write(data.ToArray());
    }
    private static void U16(BinaryWriter writer, ushort value) { writer.Write((byte)(value >> 8)); writer.Write((byte)value); }
    private static void Name(BinaryWriter writer, string name) { foreach (var label in name.Split('.')) { var b = Encoding.UTF8.GetBytes(label); if (b.Length > 63) throw new InvalidDataException(); writer.Write((byte)b.Length); writer.Write(b); } writer.Write((byte)0); }
    private static string ReadName(byte[] bytes, ref int offset) {
        var labels = new List<string>(); int p = offset, steps = 0; bool jumped = false;
        while (true) {
            if (p >= bytes.Length || ++steps > 64) throw new InvalidDataException();
            int length = bytes[p++];
            if (length == 0) { if (!jumped) offset = p; break; }
            if ((length & 0xc0) == 0xc0) { if (p >= bytes.Length) throw new InvalidDataException(); int target = ((length & 0x3f) << 8) | bytes[p++]; if (!jumped) offset = p; p = target; jumped = true; continue; }
            if (length > 63 || p + length > bytes.Length) throw new InvalidDataException();
            labels.Add(Encoding.UTF8.GetString(bytes, p, length)); p += length;
        }
        return string.Join('.', labels);
    }
    public void Dispose() {
        stop.Cancel(); try { Send(0).GetAwaiter().GetResult(); } catch { }
        input?.Dispose(); foreach (var output in outputs) output.Socket.Dispose();
        Available = false;
    }
}
