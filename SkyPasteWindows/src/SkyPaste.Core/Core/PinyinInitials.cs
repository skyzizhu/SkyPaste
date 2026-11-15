using System.Buffers;
using System.Collections.Concurrent;
using System.Text;

namespace SkyPaste.Core.Core;

/// <summary>
/// Pinyin first-letter search support: maps common CJK characters (GB2312
/// coverage) to their pinyin initial via the classic boundary table. Pure C#,
/// no data files. Latin text passes through unchanged.
/// </summary>
public static class PinyinInitials
{
    /// <summary>Sorted (GBK code, initial) block start boundaries.</summary>
    private static readonly (int Code, char Initial)[] Boundaries =
    {
        (0xB0A1, 'A'), (0xB0C5, 'B'), (0xB2C1, 'C'), (0xB4EE, 'D'), (0xB6EA, 'E'),
        (0xB7A2, 'F'), (0xB8C1, 'G'), (0xB9FE, 'H'), (0xBBF7, 'J'), (0xBFA6, 'K'),
        (0xC0AC, 'L'), (0xC2E8, 'M'), (0xC4C3, 'N'), (0xC5B6, 'O'), (0xC5BE, 'P'),
        (0xC6DA, 'Q'), (0xC8BB, 'R'), (0xC8F6, 'S'), (0xCBFA, 'T'), (0xCDDA, 'W'),
        (0xCEF4, 'X'), (0xD1B9, 'Y'), (0xD4D1, 'Z'),
    };

    private static readonly ConcurrentDictionary<char, char> Cache = new();
    private static readonly Encoding Gbk = CreateGbkEncoding();

    private static Encoding CreateGbkEncoding()
    {
        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        }
        catch (InvalidOperationException)
        {
            // Provider already registered.
        }
        return Encoding.GetEncoding("GB18030");
    }

    /// <summary>Pinyin initial for a BMP char; '\0' when unmapped. ASCII letters map to themselves.</summary>
    public static char InitialOf(char c)
    {
        if (c < 0x80)
        {
            return char.IsAsciiLetter(c) ? char.ToUpperInvariant(c) : '\0';
        }
        return Cache.GetOrAdd(c, ComputeInitial);
    }

    private static char ComputeInitial(char c)
    {
        Span<byte> bytes = stackalloc byte[4];
        int written;
        try
        {
            written = Gbk.GetBytes(c.ToString(), bytes);
        }
        catch (Exception)
        {
            return '\0';
        }
        if (written != 2)
        {
            return '\0';
        }
        var gb = (bytes[0] << 8) | bytes[1];
        if (gb < Boundaries[0].Code || gb > 0xD7F9)
        {
            return '\0';
        }
        char initial = '\0';
        foreach (var (code, letter) in Boundaries)
        {
            if (gb >= code)
            {
                initial = letter;
            }
            else
            {
                break;
            }
        }
        return initial;
    }

    /// <summary>
    /// Concatenated pinyin initials of CJK chars; ASCII letters/digits kept so
    /// mixed strings stay readable: "截图 jietu" -> "JTJETU".
    /// </summary>
    public static string ToInitials(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (c < 0x80)
            {
                if (char.IsAsciiLetterOrDigit(c))
                {
                    sb.Append(char.ToUpperInvariant(c));
                }
                continue;
            }
            var initial = InitialOf(c);
            if (initial != '\0')
            {
                sb.Append(initial);
            }
        }
        return sb.ToString();
    }
}
