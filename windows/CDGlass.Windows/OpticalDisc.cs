using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CDGlass.Windows;

public sealed record AudioDisc(string Letter, IReadOnlyList<int> Tracks, string Signature, string? DiscId);

public static class OpticalDisc
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
    public static List<AudioDisc> AudioDrives()
    {
        var result = new List<AudioDisc>();
        foreach (var drive in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.CDRom))
        {
            try
            {
                var letter = drive.Name[..1];
                using var handle = CreateFile($@"\\.\{letter}:", 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (handle.IsInvalid) continue;
                var buffer = new byte[804];
                var request = new byte[4]; request[0] = 0x80; // TOC format, MSF addresses.
                if (!DeviceIoControl(handle, 0x00024054, request, 4, buffer, (uint)buffer.Length, out var count, IntPtr.Zero) &&
                    !DeviceIoControl(handle, 0x00024000, IntPtr.Zero, 0, buffer, (uint)buffer.Length, out count, IntPtr.Zero)) continue;
                if (count < 20) continue;
                int first = buffer[2], last = buffer[3];
                if (first < 1 || last > 99 || last < first || count < 4 + (last - first + 2) * 8) continue;
                var audio = new List<int>(); var offsets = new Dictionary<int, int>(); bool allAudio = true;
                for (int n = first; n <= last; n++)
                {
                    int at = 4 + (n - first) * 8;
                    if (buffer[at + 2] != n) { audio.Clear(); break; }
                    var control = buffer[at + 1] & 0x0F;
                    if ((control & 4) == 0) audio.Add(n);
                    else allAudio = false;
                    offsets[n] = Offset(buffer, at);
                }
                if (audio.Count == 0) continue;
                int leadAt = 4 + (last - first + 1) * 8;
                int leadOut = buffer[leadAt + 2] == 0xAA ? Offset(buffer, leadAt) : 0;
                var signature = Convert.ToHexString(SHA256.HashData(buffer.AsSpan(0, (int)count)))[..20];
                string? discId = allAudio && leadOut > offsets[last] ? DiscId(first, last, leadOut, offsets) : null;
                result.Add(new AudioDisc(letter, audio, signature, discId));
            }
            catch { }
        }
        return result;
    }
    static int Offset(byte[] buffer, int at)
    {
        int minute = buffer[at + 5], second = buffer[at + 6], frame = buffer[at + 7];
        return second < 60 && frame < 75 ? (minute * 60 + second) * 75 + frame : 0;
    }
    public static string DiscId(int first, int last, int leadOut, IReadOnlyDictionary<int, int> offsets)
    {
        if (first < 1 || last > 99 || last < first || leadOut <= 0) throw new ArgumentOutOfRangeException(nameof(leadOut));
        var text = new StringBuilder(804);
        text.Append(first.ToString("X2")).Append(last.ToString("X2")).Append(leadOut.ToString("X8"));
        for (int n = 1; n <= 99; n++) text.Append((offsets.TryGetValue(n, out var value) ? value : 0).ToString("X8"));
        return Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(text.ToString())))
            .Replace('+', '.').Replace('/', '_').Replace('=', '-');
    }
}
