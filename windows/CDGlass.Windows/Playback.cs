using LibVLCSharp.Shared;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CDGlass.Windows;

public sealed class Track
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public long StartMs { get; set; }
    public long EndMs { get; set; }
    public int CdNumber { get; set; }
}

public sealed class AudioPlayer : IDisposable
{
    readonly LibVLC vlc;
    readonly MediaPlayer player;
    long playbackVersion;
    public List<Track> Tracks { get; private set; } = [];
    public CueSheet? CueInfo { get; private set; }
    public int Index { get; private set; } = -1;
    public bool IsPlaying => player.IsPlaying;
    public long Time => Current == null ? 0 : Math.Max(0, player.Time - Current.StartMs);
    public long Length => Current == null ? 0 : Current.EndMs > Current.StartMs ? Current.EndMs - Current.StartMs : Math.Max(0, player.Length - Current.StartMs);
    public Track? Current => Index >= 0 && Index < Tracks.Count ? Tracks[Index] : null;
    public event Action? Changed;
    public event Action? Finished;
    public AudioPlayer()
    {
        Core.Initialize();
        vlc = new LibVLC("--no-video", "--no-snapshot-preview", "--no-media-library", "--quiet");
        player = new MediaPlayer(vlc);
        player.EndReached += (_, _) => Finished?.Invoke();
        player.EncounteredError += (_, _) => Changed?.Invoke();
    }
    public void LoadFolder(string folder)
    {
        var files = MusicLibrary.FilesFor(folder);
        var cue = Directory.EnumerateFiles(folder).FirstOrDefault(f => Path.GetExtension(f).Equals(".cue", StringComparison.OrdinalIgnoreCase));
        CueInfo = cue == null ? null : CueReader.Read(cue, files);
        Tracks = CueInfo is { Tracks.Count: > 0 } ? CueInfo.Tracks : files.Select(f => new Track { Name = Regex.Replace(Path.GetFileNameWithoutExtension(f), @"^\s*\d{1,3}\s*[-._ ]\s*", ""), Path = f }).ToList();
        try
        {
            using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "album.json")));
            if (json.RootElement.TryGetProperty("tracks", out var names) && names.ValueKind == JsonValueKind.Array && names.GetArrayLength() == Tracks.Count)
                for (int i = 0; i < Tracks.Count; i++) if (names[i].ValueKind == JsonValueKind.String && names[i].GetString() is { Length: > 0 } name) Tracks[i].Name = name;
        }
        catch (IOException) { }
        catch (JsonException) { }
        Index = -1;
        if (Tracks.Count != 0) Play(0);
        else Changed?.Invoke();
    }
    public void LoadCd(string letter, IReadOnlyList<int> numbers)
    {
        CueInfo = null;
        Tracks = numbers.Select(n => new Track { Name = $"Track {n:00}", Path = $"cdda:///{letter}:/", CdNumber = n }).ToList();
        Index = -1;
        if (Tracks.Count != 0) Play(0);
    }
    public void ApplyTrackNames(IReadOnlyList<string> names)
    {
        if (names.Count != Tracks.Count) return;
        for (int i = 0; i < Tracks.Count; i++) if (!string.IsNullOrWhiteSpace(names[i])) Tracks[i].Name = names[i];
        Changed?.Invoke();
    }
    public void Play(int index)
    {
        if (index < 0 || index >= Tracks.Count) return;
        var version = Interlocked.Increment(ref playbackVersion);
        Index = index;
        var track = Tracks[index];
        player.Stop();
        using var media = track.CdNumber > 0 ? new Media(vlc, track.Path, FromType.FromLocation) : new Media(vlc, track.Path, FromType.FromPath);
        if (track.CdNumber > 0) media.AddOption($":cdda-track={track.CdNumber}");
        player.Media = media;
        player.Play();
        if (track.StartMs > 0) _ = Task.Run(async () => {
            await Task.Delay(500);
            if (Interlocked.Read(ref playbackVersion) == version && ReferenceEquals(Current, track)) player.Time = track.StartMs;
        });
        Changed?.Invoke();
    }
    public void Next() { if (Index + 1 < Tracks.Count) Play(Index + 1); else { player.Stop(); Changed?.Invoke(); } }
    public void EndSession() { Interlocked.Increment(ref playbackVersion); player.Stop(); Tracks = []; CueInfo = null; Index = -1; Changed?.Invoke(); }
    public void Previous() { if (Time > 3000) Seek(0); else Play(Math.Max(0, Index - 1)); }
    public void Toggle() { if (Index < 0 && Tracks.Count > 0) Play(0); else if (player.IsPlaying) player.Pause(); else player.Play(); Changed?.Invoke(); }
    public void Seek(double fraction)
    {
        if (Current == null || Length <= 0) return;
        player.Time = Current.StartMs + (long)(Math.Clamp(fraction, 0, 1) * Length);
    }
    public void SeekBy(long milliseconds)
    {
        if (Current == null || Length <= 0) return;
        player.Time = Current.StartMs + Math.Clamp(Time + milliseconds, 0, Length);
    }
    public int Volume { get => player.Volume; set => player.Volume = Math.Clamp(value, 0, 100); }
    public void Dispose() { Interlocked.Increment(ref playbackVersion); player.Dispose(); vlc.Dispose(); }
}

public sealed class CueSheet
{
    public string? Title { get; set; }
    public string? Artist { get; set; }
    public string? CoverName { get; set; }
    public List<Track> Tracks { get; } = [];
}

public static class CueReader
{
    public static CueSheet Read(string cue, IReadOnlyList<string> audioFiles)
    {
        var result = new CueSheet(); string? file = null; Track? current = null;
        var indexed = new HashSet<Track>();
        foreach (var raw in Decode(cue).Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (Regex.Match(line, @"^REM\s+(?:COVER|COVERFILE)\s+(.+)$", RegexOptions.IgnoreCase) is { Success: true } cover)
                result.CoverName = Path.GetFileName(Value(cover.Groups[1].Value).Replace('\\', '/'));
            else if (Regex.Match(line, @"^FILE\s+(.+?)(?:\s+(?:WAVE|MP3|FLAC|AIFF|BINARY))?$", RegexOptions.IgnoreCase) is { Success: true } source)
            {
                var wanted = Path.GetFileName(Value(source.Groups[1].Value).Replace('\\', '/'));
                file = audioFiles.FirstOrDefault(f => Path.GetFileName(f).Equals(wanted, StringComparison.OrdinalIgnoreCase));
                current = null;
            }
            else if (Regex.Match(line, @"^TRACK\s+(\d+)\s+(\w+)", RegexOptions.IgnoreCase) is { Success: true } number)
            {
                current = file != null && number.Groups[2].Value.Equals("AUDIO", StringComparison.OrdinalIgnoreCase)
                    ? new Track { Name = $"Track {number.Groups[1].Value}", Path = file } : null;
                if (current != null) result.Tracks.Add(current);
            }
            else if (Regex.Match(line, @"^TITLE\s+(.+)$", RegexOptions.IgnoreCase) is { Success: true } title)
            {
                if (current != null) current.Name = Value(title.Groups[1].Value);
                else if (result.Tracks.Count == 0) result.Title = Value(title.Groups[1].Value);
            }
            else if (Regex.Match(line, @"^PERFORMER\s+(.+)$", RegexOptions.IgnoreCase) is { Success: true } artist && current == null && result.Tracks.Count == 0)
                result.Artist = Value(artist.Groups[1].Value);
            else if (Regex.Match(line, @"^INDEX\s+01\s+(\d+):(\d+):(\d+)", RegexOptions.IgnoreCase) is { Success: true } index && current != null)
            {
                var seconds = int.Parse(index.Groups[2].Value); var frames = int.Parse(index.Groups[3].Value);
                if (seconds < 60 && frames < 75)
                {
                    current.StartMs = (int.Parse(index.Groups[1].Value) * 60L + seconds) * 1000 + frames * 1000 / 75;
                    indexed.Add(current);
                }
            }
        }
        result.Tracks.RemoveAll(t => !indexed.Contains(t));
        for (int i = 0; i < result.Tracks.Count - 1; i++) if (result.Tracks[i].Path.Equals(result.Tracks[i + 1].Path, StringComparison.OrdinalIgnoreCase)) result.Tracks[i].EndMs = result.Tracks[i + 1].StartMs;
        return result;
    }
    static string Value(string raw) => raw.Trim().Trim('"').Trim();
    static string Decode(string path)
    {
        var bytes = File.ReadAllBytes(path);
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(932).GetString(bytes);
        }
    }
}
