using System.Text.RegularExpressions;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Core;

/// <summary>
/// Port of macOS SensitiveClipboardContentFilter: when enabled, password-manager
/// output, verification codes, bank card numbers (Luhn), and token-like secrets
/// are never recorded into history.
/// </summary>
public static partial class SensitiveContentFilter
{
    private static readonly string[] PasswordManagerFragments =
    {
        "1password", "agilebits", "bitwarden", "lastpass", "dashlane",
        "keeper", "enpass", "strongbox", "keychain access", "keepass",
    };

    private static readonly string[] TokenPrefixes =
    {
        "sk-", "rk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "ya29.", "akia", "aiza", "bearer ",
    };

    private static readonly string[] VerificationCodePhrases =
    {
        "验证码", "驗證碼", "verification code", "security code", "otp", "one-time password", "one time password",
    };

    [GeneratedRegex(@"^\d{4,8}$")]
    private static partial Regex DigitsOnly4To8();

    [GeneratedRegex(@"^[A-Z0-9]{4,8}$")]
    private static partial Regex UpperAlphaNum4To8();

    [GeneratedRegex(@"^[0-9A-Za-z]{4,8}$")]
    private static partial Regex CodeToken4To8();

    [GeneratedRegex(@"^[A-Za-z0-9_\-/+=]{32,}$")]
    private static partial Regex LongRandomToken();

    [GeneratedRegex(@"^-----BEGIN [A-Z ]*PRIVATE KEY-----")]
    private static partial Regex PemPrivateKey();

    [GeneratedRegex(@"^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$")]
    private static partial Regex JwtLike();

    [GeneratedRegex(@"(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|secret[_ -]?key|client[_ -]?secret|private[_ -]?key|token)[:= ]+\S{12,}", RegexOptions.IgnoreCase)]
    private static partial Regex KeyEqualsToken();

    /// <summary>True when the text should be excluded from history entirely.</summary>
    public static bool ShouldExclude(string? text, ClipboardSourceApp? sourceApp, bool enabled)
    {
        if (!enabled || string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        if (MatchesPasswordManager(sourceApp))
        {
            return true;
        }

        return IsVerificationCode(text)
               || IsBankCard(text)
               || IsSensitiveToken(text);
    }

    public static bool MatchesPasswordManager(ClipboardSourceApp? sourceApp)
    {
        if (sourceApp is null)
        {
            return false;
        }
        var procId = Fold(sourceApp.ProcessId);
        var name = Fold(sourceApp.Name);
        return PasswordManagerFragments.Any(fragment =>
            procId.Contains(fragment) || name.Contains(fragment));
    }

    public static bool IsVerificationCode(string text)
    {
        var trimmed = text.Trim();
        if (DigitsOnly4To8().IsMatch(trimmed) || UpperAlphaNum4To8().IsMatch(trimmed))
        {
            return true;
        }

        // Phrase followed (within ~16 chars of separators/words) by a 4-8 char code,
        // e.g. "Your verification code is 552211".
        var lower = trimmed.ToLowerInvariant();
        foreach (var phrase in VerificationCodePhrases)
        {
            var index = lower.IndexOf(phrase, StringComparison.Ordinal);
            if (index < 0)
            {
                continue;
            }
            var window = trimmed.Substring(
                Math.Min(index + phrase.Length, trimmed.Length),
                Math.Min(16, Math.Max(0, trimmed.Length - index - phrase.Length)));
            foreach (Match match in Regex.Matches(window, @"[0-9A-Za-z]{2,}"))
            {
                if (CodeToken4To8().IsMatch(match.Value))
                {
                    return true;
                }
            }
        }
        return false;
    }

    public static bool IsBankCard(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Any(c => !char.IsDigit(c) && c != ' ' && c != '-'))
        {
            return false;
        }
        var digits = new string(trimmed.Where(char.IsDigit).ToArray());
        if (digits.Length is < 13 or > 19)
        {
            return false;
        }
        return LuhnCheck(digits);
    }

    public static bool LuhnCheck(string digits)
    {
        var sum = 0;
        var doubleDigit = false;
        for (var i = digits.Length - 1; i >= 0; i--)
        {
            if (!char.IsDigit(digits[i]))
            {
                return false;
            }
            var d = digits[i] - '0';
            if (doubleDigit)
            {
                d *= 2;
                if (d > 9)
                {
                    d -= 9;
                }
            }
            sum += d;
            doubleDigit = !doubleDigit;
        }
        return sum % 10 == 0;
    }

    public static bool IsSensitiveToken(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return false;
        }

        var lower = trimmed.ToLowerInvariant();
        if (TokenPrefixes.Any(prefix => lower.StartsWith(prefix)))
        {
            return true;
        }
        if (PemPrivateKey().IsMatch(trimmed))
        {
            return true;
        }
        if (JwtLike().IsMatch(trimmed) && LooksBase64Url(trimmed))
        {
            return true;
        }
        if (KeyEqualsToken().IsMatch(trimmed))
        {
            return true;
        }
        if (LongRandomToken().IsMatch(trimmed))
        {
            return true;
        }
        return false;
    }

    private static bool LooksBase64Url(string text)
    {
        // JWT-like: three base64url segments separated by dots, no whitespace.
        return !text.Any(char.IsWhiteSpace) && text.Count(c => c == '.') == 2;
    }

    private static string Fold(string value) =>
        value.Trim().ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormD);
}
