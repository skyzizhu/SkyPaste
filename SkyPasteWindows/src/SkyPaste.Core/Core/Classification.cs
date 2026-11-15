using System.Text.RegularExpressions;

namespace SkyPaste.Core.Core;

/// <summary>
/// Port of macOS ClipboardItem classification: URL / email / code detection.
/// </summary>
public static partial class Classification
{
    private static readonly Regex EmailRegex =
        new(@"^[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\.)+[A-Z]{2,63}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex HostShapeRegex = new(@"^[a-z0-9\.\-]+$", RegexOptions.Compiled);
    private static readonly Regex Ipv4Regex = new(@"^\d{1,3}(\.\d{1,3}){3}$", RegexOptions.Compiled);
    private static readonly Regex LabelRegex = new(@"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$", RegexOptions.Compiled);

    public static string? NormalizedEmailAddress(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0 || trimmed.Any(char.IsWhiteSpace))
        {
            return null;
        }
        return EmailRegex.IsMatch(trimmed) ? trimmed : null;
    }

    public static bool LooksLikeUrl(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0 || trimmed.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var candidate = trimmed;
        if (!candidate.Contains("://", StringComparison.OrdinalIgnoreCase))
        {
            candidate = "https://" + candidate;
        }
        if (Uri.TryCreate(candidate, UriKind.Absolute, out var withScheme)
            && (withScheme.Scheme == Uri.UriSchemeHttp || withScheme.Scheme == Uri.UriSchemeHttps)
            && IsLikelyWebHost(withScheme.Host))
        {
            return true;
        }

        // Fallback: an explicit http(s) URL accepted by Uri even when the custom
        // host validator rejects it (IDN hosts, unusual ports, etc.).
        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var direct)
            && (direct.Scheme == Uri.UriSchemeHttp || direct.Scheme == Uri.UriSchemeHttps)
            && !string.IsNullOrEmpty(direct.Host)
            && direct.Host.Contains('.'))
        {
            return true;
        }
        return false;
    }

    public static bool IsLikelyWebHost(string host)
    {
        var normalized = host.Trim().TrimEnd('.').ToLowerInvariant();
        if (normalized.Length == 0)
        {
            return false;
        }
        if (normalized == "localhost")
        {
            return true;
        }
        if (!HostShapeRegex.IsMatch(normalized))
        {
            return false;
        }
        if (Ipv4Regex.IsMatch(normalized))
        {
            foreach (var segment in normalized.Split('.'))
            {
                if (!int.TryParse(segment, out var value) || value < 0 || value > 255)
                {
                    return false;
                }
            }
            return true;
        }

        var labels = normalized.Split('.');
        if (labels.Length < 2)
        {
            return false;
        }
        var tld = labels[^1];
        if (tld.Length < 2 || tld.Any(c => c < 'a' || c > 'z'))
        {
            return false;
        }
        foreach (var label in labels)
        {
            if (label.Length == 0 || label.Length > 63 || !LabelRegex.IsMatch(label))
            {
                return false;
            }
        }
        return true;
    }

    // ---- code detection -------------------------------------------------

    [GeneratedRegex(@"\b(func|class|struct|enum|protocol|extension|namespace|interface|typedef|def)\b")]
    private static partial Regex DeclRegex();

    [GeneratedRegex(@"\b(const|let|var)\b\s+[\w$]+\s*=")]
    private static partial Regex ConstAssignRegex();

    [GeneratedRegex(@"\b(import|export)\b")]
    private static partial Regex ImportExportRegex();

    [GeneratedRegex(@"\b(public|private|protected|internal|static|final|abstract|override|readonly|sealed|virtual)\b\s+\w")]
    private static partial Regex ModifierRegex();

    [GeneratedRegex(@"\b(if|else\s+if|for|while|switch|guard|catch)\b\s*[\({]")]
    private static partial Regex ControlFlowRegex();

    [GeneratedRegex(@"\b(case|try|await|return)\b[^;\n{}]*[;{}]")]
    private static partial Regex KeywordStatementRegex();

    [GeneratedRegex(@"<\/?[a-zA-Z][a-zA-Z0-9\-_]*(\s[^>]*)?\/?>")]
    private static partial Regex HtmlTagRegex();

    private static readonly string[] SqlKeywords =
    {
        "select", "insert", "update", "delete", "create", "alter", "drop",
        "from", "where", "join", "set", "values", "into", "group by", "order by",
    };

    private static readonly string[] PenaltyWords =
    {
        "你好", "谢谢", "请", "the ", "and ", "that ", "this ", "with ", "你", "我们",
    };

    public static bool LooksLikeCode(string text, bool knownUrl)
    {
        if (knownUrl || string.IsNullOrEmpty(text) || text.Trim().Length < 8)
        {
            return false;
        }

        var strongCount = 0;
        var controlFlowCount = 0;
        var weakCount = 0;
        var lower = text.ToLowerInvariant();

        if (text.Contains("```"))
        {
            strongCount += 1;
        }
        if (DeclRegex().IsMatch(text))
        {
            strongCount += 1;
        }
        if (ConstAssignRegex().IsMatch(text))
        {
            strongCount += 1;
        }
        if (ImportExportRegex().IsMatch(text))
        {
            strongCount += 1;
        }
        if (ModifierRegex().IsMatch(text))
        {
            strongCount += 1;
        }
        if (ControlFlowRegex().IsMatch(text))
        {
            controlFlowCount += 1;
            strongCount += 1;
        }
        if (KeywordStatementRegex().IsMatch(text))
        {
            strongCount += 1;
        }
        if (HtmlTagRegex().IsMatch(text))
        {
            strongCount += 1;
        }

        var trimmedStart = text.TrimStart();
        if (trimmedStart.StartsWith('{') || trimmedStart.StartsWith('['))
        {
            strongCount += 1;
        }

        var sqlKeywordCount = 0;
        foreach (var kw in SqlKeywords)
        {
            sqlKeywordCount += CountOccurrences(lower, kw);
        }
        var startsWithSql = SqlKeywords.Take(7).Any(kw => lower.StartsWith(kw));
        if (startsWithSql && (sqlKeywordCount >= 2 || text.TrimEnd().EndsWith(';')))
        {
            strongCount += 1;
        }

        if (text.Contains("->"))
        {
            weakCount += 1;
        }
        if (text.Contains("=>"))
        {
            weakCount += 1;
        }
        if (text.Contains("::"))
        {
            weakCount += 1;
        }
        if (Regex.IsMatch(text, @"\)\s*\{"))
        {
            weakCount += 1;
        }
        if (Regex.IsMatch(text, @"\)\s*;"))
        {
            weakCount += 1;
        }
        if (text.Contains('[') && text.Contains(']'))
        {
            weakCount += 1;
        }
        if (text.Contains('{') && text.Contains('}'))
        {
            weakCount += 1;
        }

        var additions = 0;
        var newlineCount = text.Count(c => c == '\n');
        if (newlineCount >= 2)
        {
            additions += 1;
        }
        var hasIndentedLine = text.Split('\n').Any(l => l.StartsWith(' ') || l.StartsWith('\t'));
        if (hasIndentedLine)
        {
            additions += 1;
        }
        const string symbolChars = "{}[]();<>=$#`";
        var symbolCount = text.Count(c => symbolChars.Contains(c));
        if (symbolCount >= 6)
        {
            additions += 1;
        }
        if (text.Contains(";\n") || text.Contains("{\n") || text.Contains("\n}"))
        {
            additions += 1;
        }

        var penalty = 0;
        foreach (var word in PenaltyWords)
        {
            penalty += CountOccurrences(lower, word.ToLowerInvariant());
        }
        penalty = Math.Min(penalty, 2);

        var score = 3 * strongCount + weakCount + additions - penalty;

        var isMultiLine = newlineCount > 0;
        if (!isMultiLine)
        {
            return strongCount > 0
                || (controlFlowCount >= 1 && weakCount >= 1)
                || (weakCount >= 2 && symbolCount >= 4);
        }

        if (strongCount > 0)
        {
            return true;
        }
        if (controlFlowCount >= 1 && (weakCount >= 1 || hasIndentedLine))
        {
            return true;
        }
        return score >= 4;
    }

    private static int CountOccurrences(string haystack, string needle)
    {
        if (needle.Length == 0)
        {
            return 0;
        }
        var count = 0;
        var index = 0;
        while ((index = haystack.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count += 1;
            index += needle.Length;
        }
        return count;
    }
}
