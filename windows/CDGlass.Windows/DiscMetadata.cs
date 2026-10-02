using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CDGlass.Windows;

public sealed class DiscDetails
{
    public string Title { get; set; } = "音频 CD";
    public string Artist { get; set; } = "";
    public List<string> Tracks { get; set; } = [];
    public string? CoverPath { get; set; }
    [JsonIgnore] public string? ReleaseId { get; set; }
    [JsonIgnore] public string? GroupId { get; set; }
}

/// <summary>Matches a physical disc with MusicBrainz and saves its metadata for later insertions.</summary>
public static class DiscMetadata
{
    static readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(15) };
    static readonly string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Discs");
    static DiscMetadata() => client.DefaultRequestHeaders.UserAgent.ParseAdd("CDGlass/0.9 (personal Windows CD player)");

    public static DiscDetails? Cached(string? discId)
    {
        if (discId == null) return null;
        try { return JsonSerializer.Deserialize<DiscDetails>(File.ReadAllText(Path.Combine(cache, discId + ".json"))); }
        catch { return null; }
    }

    public static async Task<DiscDetails?> FetchAsync(string? discId, int trackCount)
    {
        if (discId == null) return null;
        using var response = await client.GetAsync($"https://musicbrainz.org/ws/2/discid/{Uri.EscapeDataString(discId)}?inc=recordings+artist-credits&fmt=json");
        if (!response.IsSuccessStatusCode) return null;
        var details = Parse(await response.Content.ReadAsStringAsync(), discId, trackCount);
        if (details == null) return null;
        Directory.CreateDirectory(cache);
        foreach (var url in new[] { details.ReleaseId == null ? null : $"https://coverartarchive.org/release/{details.ReleaseId}/front-500",
                                   details.GroupId == null ? null : $"https://coverartarchive.org/release-group/{details.GroupId}/front-500" })
        {
            if (url == null) continue;
            try
            {
                using var cover = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
                if (!cover.IsSuccessStatusCode || cover.Content.Headers.ContentLength > 12 * 1024 * 1024) continue;
                await using var source = await cover.Content.ReadAsStreamAsync();
                using var bytes = new MemoryStream();
                var buffer = new byte[81920]; int read; bool tooLarge = false;
                while ((read = await source.ReadAsync(buffer)) != 0)
                { if (bytes.Length + read > 12 * 1024 * 1024) { tooLarge = true; break; } bytes.Write(buffer, 0, read); }
                if (tooLarge || bytes.Length < 256) continue;
                var path = Path.Combine(cache, discId + ".jpg");
                await File.WriteAllBytesAsync(path, bytes.ToArray());
                details.CoverPath = path; break;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
        }
        await File.WriteAllTextAsync(Path.Combine(cache, discId + ".json"), JsonSerializer.Serialize(details));
        return details;
    }
    public static DiscDetails? Parse(string json, string discId, int trackCount)
    {
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("releases", out var releases) || releases.ValueKind != JsonValueKind.Array || releases.GetArrayLength() == 0) return null;
        JsonElement chosen = default, chosenMedium = default;
        int best = -1;
        foreach (var release in releases.EnumerateArray())
        {
            if (!release.TryGetProperty("media", out var media) || media.ValueKind != JsonValueKind.Array) continue;
            foreach (var medium in media.EnumerateArray())
            {
                bool countMatches = medium.TryGetProperty("tracks", out var tracks) && tracks.ValueKind == JsonValueKind.Array && tracks.GetArrayLength() == trackCount;
                bool idMatches = medium.TryGetProperty("discs", out var discs) && discs.ValueKind == JsonValueKind.Array &&
                    discs.EnumerateArray().Any(d => String(d, "id") == discId);
                bool hasCover = release.TryGetProperty("cover-art-archive", out var archive) && archive.TryGetProperty("front", out var front) && front.ValueKind == JsonValueKind.True;
                int score = (idMatches ? 4 : 0) + (countMatches ? 2 : 0) + (hasCover ? 1 : 0);
                if (score <= best) continue;
                chosen = release; chosenMedium = medium; best = score;
            }
        }
        if (best < 0) chosen = releases[0];
        var details = new DiscDetails { Title = String(chosen, "title") ?? "音频 CD", ReleaseId = String(chosen, "id") };
        details.GroupId = chosen.TryGetProperty("release-group", out var group) ? String(group, "id") : null;
        if (chosen.TryGetProperty("artist-credit", out var credits) && credits.ValueKind == JsonValueKind.Array)
            details.Artist = string.Join(", ", credits.EnumerateArray().Select(c => String(c, "name") ??
                (c.ValueKind == JsonValueKind.Object && c.TryGetProperty("artist", out var artist) ? String(artist, "name") : null)).Where(s => !string.IsNullOrWhiteSpace(s)));
        if (chosenMedium.ValueKind == JsonValueKind.Object && chosenMedium.TryGetProperty("tracks", out var selectedTracks) &&
            selectedTracks.ValueKind == JsonValueKind.Array && selectedTracks.GetArrayLength() == trackCount)
            details.Tracks = selectedTracks.EnumerateArray().Select((track, i) => String(track, "title") ?? $"Track {i + 1:00}").ToList();
        return details;
    }
    static string? String(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
