using System.Text.Json;
using System.Text.RegularExpressions;
using System.IO;

namespace CDGlass.Windows;

public sealed class Album
{
    public string Id { get; set; } = "";
    public string SourcePath { get; set; } = "";
    public string? LibraryPath { get; set; }
    public string Title { get; set; } = "";
    public string Artist { get; set; } = "";
    public string SeriesKey { get; set; } = "";
    public string SeriesTitle { get; set; } = "";
    public string? CoverPath { get; set; }
    public int TrackCount { get; set; }
    public string PlayablePath => Directory.Exists(LibraryPath) ? LibraryPath! : SourcePath;
}

public sealed class MusicLibrary
{
    static readonly HashSet<string> Audio = new(StringComparer.OrdinalIgnoreCase) { ".wav", ".aiff", ".aif", ".mp3", ".m4a", ".flac", ".ogg", ".opus" };
    readonly string db = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Library.json");
    readonly Dictionary<string, (string title, string poster)> aliases = new(StringComparer.OrdinalIgnoreCase);
    public List<Album> Albums { get; private set; } = [];
    public MusicLibrary()
    {
        try { Albums = JsonSerializer.Deserialize<List<Album>>(File.ReadAllText(db)) ?? []; } catch { }
        LoadAnimeIndex();
    }
    void LoadAnimeIndex()
    {
        try
        {
            using var stream = typeof(MusicLibrary).Assembly.GetManifestResourceStream("AnimeTitles.json")!;
            using var doc = JsonDocument.Parse(stream);
            foreach (var subject in doc.RootElement.GetProperty("subjects").EnumerateArray())
            {
                var title = subject.TryGetProperty("zh", out var zh) && zh.GetString() is { Length: > 0 } z ? z : subject.GetProperty("title").GetString() ?? "";
                var poster = subject.TryGetProperty("poster", out var p) ? p.GetString() ?? "" : "";
                foreach (var name in subject.GetProperty("names").EnumerateArray())
                {
                    var key = Fold(name.GetString() ?? "");
                    if (key.Length >= 3 && !aliases.ContainsKey(key)) aliases[key] = (title, poster);
                }
            }
        }
        catch { }
    }
    static string Fold(string s) => Regex.Replace(s.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormKC), @"[\s\p{P}\p{S}]+", "");
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(db)!);
        File.WriteAllText(db, JsonSerializer.Serialize(Albums, new JsonSerializerOptions { WriteIndented = true }));
    }
    public Task<int> ScanAsync(string root, IProgress<int>? progress = null) => Task.Run(() =>
    {
        var existing = Albums.ToDictionary(a => a.SourcePath, StringComparer.OrdinalIgnoreCase);
        int added = 0;
        foreach (var folder in Walk(root))
        {
            try
            {
                var files = Directory.EnumerateFiles(folder).ToArray();
                var tracks = files.Where(f => Audio.Contains(Path.GetExtension(f))).ToArray();
                if (tracks.Length == 0 && !files.Any(f => Path.GetExtension(f).Equals(".cue", StringComparison.OrdinalIgnoreCase))) continue;
                var album = Inspect(folder, root, tracks, files);
                if (existing.TryGetValue(folder, out var old))
                {
                    album.LibraryPath = old.LibraryPath;
                    var manualCovers = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Covers") + Path.DirectorySeparatorChar;
                    if (old.CoverPath is { } cover && File.Exists(cover) && Path.GetFullPath(cover).StartsWith(manualCovers, StringComparison.OrdinalIgnoreCase))
                        album.CoverPath = cover;
                }
                else added++;
                existing[folder] = album;
                progress?.Report(added);
            }
            catch (UnauthorizedAccessException) { }
            catch (IOException) { }
        }
        Albums = existing.Values.OrderBy(a => a.SeriesTitle).ThenBy(a => a.Title).ToList();
        Save();
        return added;
    });
    static IEnumerable<string> Walk(string root)
    {
        var pending = new Stack<string>(); pending.Push(Path.GetFullPath(root));
        while (pending.Count != 0)
        {
            var dir = pending.Pop(); yield return dir;
            string[] children;
            try { children = Directory.GetDirectories(dir); } catch { continue; }
            foreach (var child in children) pending.Push(child);
        }
    }
    Album Inspect(string folder, string root, string[] tracks, string[] files)
    {
        string title = Path.GetFileName(folder), artist = "";
        var cuePath = files.FirstOrDefault(f => Path.GetExtension(f).Equals(".cue", StringComparison.OrdinalIgnoreCase));
        var cue = cuePath == null ? null : CueReader.Read(cuePath, tracks);
        if (!string.IsNullOrWhiteSpace(cue?.Title)) title = cue.Title;
        if (!string.IsNullOrWhiteSpace(cue?.Artist)) artist = cue.Artist;
        var meta = Path.Combine(folder, "album.json");
        if (File.Exists(meta)) try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(meta));
            if (doc.RootElement.TryGetProperty("title", out var v)) title = v.GetString() ?? title;
            if (doc.RootElement.TryGetProperty("artist", out v)) artist = v.GetString() ?? artist;
        } catch { }
        var names = new[] { Path.GetFileName(Path.GetDirectoryName(folder) ?? ""), title, Path.GetFileName(root) };
        string series = Path.GetFullPath(folder).Equals(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase) || names[0] == Path.GetFileName(root) ? title : names[0];
        foreach (var name in names)
        {
            var key = Fold(name);
            if (aliases.TryGetValue(key, out var hit)) { series = hit.title; break; }
            var nearest = aliases.FirstOrDefault(kv => key.Length > 5 && (key.Contains(kv.Key) || kv.Key.Contains(key)) && kv.Key.Length >= 5);
            if (!nearest.Equals(default(KeyValuePair<string, (string, string)>))) { series = nearest.Value.title; break; }
        }
        var cover = Artwork.Find(folder, files, cue?.CoverName);
        return new Album { Id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(folder)))[..12],
            SourcePath = folder, Title = title, Artist = artist, SeriesTitle = series, SeriesKey = Fold(series), CoverPath = cover, TrackCount = cue is { Tracks.Count: > 0 } ? cue.Tracks.Count : tracks.Length };
    }
    public static List<string> FilesFor(string folder) => Directory.EnumerateFiles(folder)
        .Where(f => Audio.Contains(Path.GetExtension(f))).OrderBy(f => Path.GetFileName(f), StringComparer.OrdinalIgnoreCase).ToList();
    public async Task<int> ArchiveAsync(IEnumerable<Album> selection, string root, IProgress<(int done, int total)>? progress = null)
    {
        var albums = selection.ToArray(); int done = 0;
        foreach (var album in albums)
        {
            var destination = Path.Combine(root, Safe(album.SeriesTitle), Safe(album.Title) + " · " + album.Id);
            var source = Path.GetFullPath(album.PlayablePath).TrimEnd(Path.DirectorySeparatorChar);
            var target = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar);
            if (target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("归档目标不能位于要复制的 CD 文件夹里面。");
            if (!target.Equals(source, StringComparison.OrdinalIgnoreCase))
            {
                await Task.Run(() => CopyTree(source, target));
                if (album.CoverPath is { } art && Path.GetFullPath(art).StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    album.CoverPath = Path.Combine(target, Path.GetRelativePath(source, art));
                album.LibraryPath = destination;
            }
            done++;
            progress?.Report((done, albums.Length));
        }
        Save(); return done;
    }
    static string Safe(string text) => string.Concat(text.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim().TrimEnd('.');
    static void CopyTree(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.EnumerateFiles(src)) File.Copy(file, Path.Combine(dst, Path.GetFileName(file)), true);
        foreach (var dir in Directory.EnumerateDirectories(src)) CopyTree(dir, Path.Combine(dst, Path.GetFileName(dir)));
    }
}
