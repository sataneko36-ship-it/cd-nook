using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace CDGlass.Windows;

/// <summary>Finds local CD artwork and extracts FLAC PICTURE metadata when needed.</summary>
public static class Artwork
{
    static readonly HashSet<string> extensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".webp", ".bmp" };
    static readonly string[] preferred = ["cover", "front", "folder", "album", "artwork"];

    public static string? Find(string folder, IReadOnlyList<string>? files = null, string? cueName = null)
    {
        files ??= Directory.GetFiles(folder);
        string? best = null; int bestScore = -1;
        void Consider(string file, bool nested)
        {
            if (!extensions.Contains(Path.GetExtension(file))) return;
            var stem = Path.GetFileNameWithoutExtension(file);
            int preference = Array.FindIndex(preferred, n => n.Equals(stem, StringComparison.OrdinalIgnoreCase));
            int score = cueName != null && Path.GetFileName(file).Equals(cueName, StringComparison.OrdinalIgnoreCase)
                ? 120 : preference >= 0 ? 90 - preference * 5 - (nested ? 10 : 0) : nested ? 0 : 25;
            if (score > bestScore) { best = file; bestScore = score; }
        }
        foreach (var file in files) Consider(file, false);
        if (bestScore < 80)
            foreach (var child in Directory.EnumerateDirectories(folder))
                try { foreach (var file in Directory.EnumerateFiles(child)) Consider(file, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
        if (bestScore >= 80) return best;
        foreach (var file in files.Where(f => Path.GetExtension(f).Equals(".flac", StringComparison.OrdinalIgnoreCase)))
            try { if (ExtractFlac(file) is { } image) return image; }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        return best;
    }

    public static string? ExtractFlac(string file)
    {
        using var stream = File.OpenRead(file);
        Span<byte> magic = stackalloc byte[4];
        if (stream.Read(magic) != 4 || !magic.SequenceEqual("fLaC"u8)) return null;
        Span<byte> header = stackalloc byte[4];
        for (int block = 0; block < 32; block++)
        {
            if (stream.Read(header) != 4) return null;
            bool last = (header[0] & 128) != 0;
            int length = header[1] << 16 | header[2] << 8 | header[3];
            if (length > 24 * 1024 * 1024 || length > stream.Length - stream.Position) return null;
            if ((header[0] & 127) == 6 && length >= 32)
            {
                var data = new byte[length];
                stream.ReadExactly(data);
                var picture = Picture(data);
                if (picture != null)
                {
                    var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(file) + "|" + stream.Length + "|" + File.GetLastWriteTimeUtc(file).Ticks)))[..20];
                    var extension = picture.Value.extension;
                    var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Embedded");
                    Directory.CreateDirectory(directory);
                    var output = Path.Combine(directory, key + extension);
                    if (!File.Exists(output)) File.WriteAllBytes(output, picture.Value.bytes);
                    return output;
                }
            }
            else stream.Position += length;
            if (last) break;
        }
        return null;
    }

    static (byte[] bytes, string extension)? Picture(ReadOnlySpan<byte> data)
    {
        int at = 4; // picture type
        if (!ReadPart(data, ref at, out var mime) || !ReadPart(data, ref at, out _)) return null;
        if (at + 20 > data.Length) return null;
        at += 16; // width, height, depth, palette size
        int imageLength = (int)BinaryPrimitives.ReadUInt32BigEndian(data.Slice(at, 4)); at += 4;
        if (imageLength <= 0 || imageLength > 22 * 1024 * 1024 || imageLength > data.Length - at) return null;
        var image = data.Slice(at, imageLength);
        string extension = Encoding.ASCII.GetString(mime).ToLowerInvariant() switch
        {
            "image/png" => ".png", "image/webp" => ".webp", "image/jpeg" or "image/jpg" => ".jpg", _ => ""
        };
        if (extension == "" || (extension == ".png" && !(image.Length >= 4 && image[0] == 137 && image[1] == 80 && image[2] == 78 && image[3] == 71)) ||
            (extension == ".jpg" && !(image.Length >= 2 && image[0] == 255 && image[1] == 216)) ||
            (extension == ".webp" && !(image.Length >= 12 && image[..4].SequenceEqual("RIFF"u8) && image.Slice(8, 4).SequenceEqual("WEBP"u8)))) return null;
        return (image.ToArray(), extension);
    }
    static bool ReadPart(ReadOnlySpan<byte> data, ref int at, out ReadOnlySpan<byte> part)
    {
        part = [];
        if (at + 4 > data.Length) return false;
        uint length = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(at, 4)); at += 4;
        if (length > data.Length - at) return false;
        part = data.Slice(at, (int)length); at += (int)length;
        return true;
    }
}
