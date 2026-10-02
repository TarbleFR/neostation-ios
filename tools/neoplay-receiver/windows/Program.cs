using System.Diagnostics;
using System.Text.Json;
namespace NeoPlayReceiver;
internal static class AppLog
{
    internal static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NeoPlay Receiver");
    private static readonly object Gate = new();
    internal static void Write(string kind, string detail = "") { try { lock (Gate) { Directory.CreateDirectory(Folder); var file = Path.Combine(Folder, "receiver.log"); if (File.Exists(file) && new FileInfo(file).Length > 524288) File.Move(file, file + ".previous", true); File.AppendAllText(file, $"{DateTime.UtcNow:O} {kind} {detail}\n"); } } catch { } }
}
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        bool selfTest = args.Length == 3 && args[0] == "--self-test";
        bool serverTest = args.Length == 2 && (args[0] == "--test-server" || args[0] == "--test-mdns");
        using var mutex = new Mutex(true, "Local\\NeoPlayReceiver." + Environment.UserName, out bool first);
        if (!first && !selfTest && !serverTest) { MessageBox.Show("NeoPlay Receiver est déjà ouvert. Retrouvez sa fenêtre dans la barre des tâches.", "NeoPlay Receiver", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        try {
            if (serverTest) { TestServer(args[1], args[0] == "--test-mdns").GetAwaiter().GetResult(); return; }
            using var window = new ReceiverWindow(selfTest ? args[1] : null, selfTest ? args[2] : null);
            Application.Run(window); Environment.ExitCode = window.ExitCode;
        } catch (Exception error) { AppLog.Write("fatal", error.ToString()); if (!selfTest) MessageBox.Show("NeoPlay n’a pas pu démarrer.\n" + error.Message + "\n\nJournal : " + AppLog.Folder, "NeoPlay Receiver", MessageBoxButtons.OK, MessageBoxIcon.Error); Environment.ExitCode = 1; }
    }
    private static async Task TestServer(string output, bool advertise) { await using var receiver = new ReceiverServer(); await receiver.StartAsync(!advertise); using var mdns = advertise ? new MdnsPublisher(receiver) : null; mdns?.Start(); await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { receiver.Port, receiver.ViewerToken, receiver.Pin, receiver.Id, MdnsAvailable = mdns?.Available ?? false })); await Task.Delay(TimeSpan.FromMinutes(3)); }
}
