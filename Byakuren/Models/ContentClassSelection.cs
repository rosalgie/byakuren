namespace Byakuren.Models;

public static class ContentClassSelection
{
    public const string Auto = "auto";
    public const string Off = "off";
    public const string General = "general";
    public const string Screen = "screen";
    public const string Gameplay = "gameplay";
    public const string Anime = "anime";
    public const string NoisyCamera = "noisy_camera";
    public const string TalkingHead = "talking_head";

    public static IReadOnlyList<string> Values { get; } =
    [
        Auto,
        General,
        Screen,
        Gameplay,
        Anime,
        NoisyCamera,
        TalkingHead,
        Off
    ];

    public static bool IsExplicit(string value)
    {
        string normalized = Normalize(value);
        return normalized is not (Auto or Off);
    }

    public static string Normalize(string? value)
    {
        string normalized = (value ?? Auto)
            .Trim()
            .ToLowerInvariant()
            .Replace('-', '_');

        if (!Values.Contains(normalized, StringComparer.Ordinal))
        {
            throw new ArgumentException(
                $"Content class must be one of: {string.Join(", ", Values)}.",
                nameof(value));
        }

        return normalized;
    }
}
