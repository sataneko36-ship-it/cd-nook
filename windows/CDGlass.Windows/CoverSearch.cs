using System.Net.Http;
using System.Text.Json;

namespace CDGlass.Windows;

public sealed record CoverCandidate(string Title, string Artist, string ReleaseId, byte[] Image);

public static class CoverSearch
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(12) };
    static CoverSearch() => http.DefaultRequestHeaders.UserAgent.ParseAdd("CDGlass-Windows/0.1 (cover selection; https://musicbrainz.org)");
    public static async Task<List<CoverCandidate>> SearchAsync(string query, CancellationToken token = default)
    {
        var results = new List<CoverCandidate>();
        var url = "https://musicbrainz.org/ws/2/release/?fmt=json&limit=12&query=" + Uri.EscapeDataString(query);
        using var response = await http.GetAsync(url, token);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(token));
        if (!doc.RootElement.TryGetProperty("releases", out var releases)) return results;
        foreach (var release in releases.EnumerateArray())
        {
            if (results.Count >= 8) break;
            var id = release.GetProperty("id").GetString() ?? "";
            if (id.Length != 36) continue;
            var artUrl = "https://coverartarchive.org/release/" + id + "/front-250";
            try
            {
                using var imageResponse = await http.GetAsync(artUrl, token);
                if (!imageResponse.IsSuccessStatusCode || imageResponse.Content.Headers.ContentLength > 3_000_000) continue;
                var image = await imageResponse.Content.ReadAsByteArrayAsync(token);
                if (image.Length < 100 || image.Length > 3_000_000) continue;
                string artist = "";
                if (release.TryGetProperty("artist-credit", out var credits))
                    artist = string.Join("", credits.EnumerateArray().Select(c => c.ValueKind == JsonValueKind.String ? c.GetString() : c.TryGetProperty("name", out var n) ? n.GetString() : ""));
                results.Add(new CoverCandidate(release.GetProperty("title").GetString() ?? "", artist, id, image));
            }
            catch (OperationCanceledException) { throw; }
            catch (HttpRequestException) { }
        }
        return results;
    }
}
