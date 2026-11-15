using System.Collections.Concurrent;
using System.Globalization;
using System.Resources;
using System.Text;

namespace SkyPaste.Core.Localization;

/// <summary>
/// Localization helper backed by Strings.resx satellite assemblies.
/// Languages: system, en, zh-Hans, zh-Hant, ja, ko, fr (mirrors the macOS app).
/// Resource values keep macOS printf placeholders (%@, %d, %1$@) which are
/// converted to .NET positional placeholders on the fly.
/// </summary>
public static class L10n
{
    private static readonly ResourceManager Manager =
        new("SkyPaste.Core.Localization.Strings", typeof(L10n).Assembly);

    private static readonly ConcurrentDictionary<string, string> FormatCache = new();

    private static CultureInfo _culture = CultureInfo.CurrentUICulture;

    /// <summary>Raised after the active language changed; windows rebuild their content.</summary>
    public static event Action? LanguageChanged;

    public static string CurrentLanguageCode { get; private set; } = "system";

    public static void SetLanguage(string code)
    {
        CurrentLanguageCode = code;
        _culture = ResolveCulture(code);
        LanguageChanged?.Invoke();
    }

    public static CultureInfo ResolveCulture(string code)
    {
        if (string.IsNullOrWhiteSpace(code) || code == "system")
        {
            return CultureInfo.CurrentUICulture;
        }
        try
        {
            return CultureInfo.GetCultureInfo(code);
        }
        catch (CultureNotFoundException)
        {
            return CultureInfo.CurrentUICulture;
        }
    }

    /// <summary>Translate a key; returns the key itself when missing (same as L10n.tr on macOS).</summary>
    public static string T(string key)
    {
        var value = Manager.GetString(key, _culture);
        return string.IsNullOrEmpty(value) ? key : value;
    }

    public static string Format(string key, params object[] args)
    {
        var dotNetFormat = FormatCache.GetOrAdd(T(key), ConvertPrintfFormat);
        try
        {
            return string.Format(_culture, dotNetFormat, args);
        }
        catch (FormatException)
        {
            return dotNetFormat;
        }
    }

    /// <summary>
    /// Convert printf-style placeholders (%@, %d, %u, %1$@, %2$d...) into
    /// .NET placeholders ({0}, {1}, ...) left-to-right like C's printf.
    /// </summary>
    public static string ConvertPrintfFormat(string format)
    {
        if (string.IsNullOrEmpty(format) || !format.Contains('%'))
        {
            return format;
        }
        var sb = new StringBuilder(format.Length + 8);
        var nextArg = 0;
        for (var i = 0; i < format.Length; i++)
        {
            if (format[i] != '%')
            {
                sb.Append(format[i]);
                continue;
            }
            if (i + 1 < format.Length && format[i + 1] == '%')
            {
                sb.Append('%');
                i += 1;
                continue;
            }

            var j = i + 1;
            var positional = -1;
            var digitsStart = j;
            while (j < format.Length && char.IsDigit(format[j]))
            {
                j++;
            }
            if (j > digitsStart && j < format.Length && format[j] == '$')
            {
                positional = int.Parse(format[digitsStart..j]) - 1;
                j++;
            }
            while (j < format.Length && "-+ 0123456789.#lh".Contains(format[j]))
            {
                j++;
            }
            if (j < format.Length && "@dioxXufgeEsc".Contains(format[j]))
            {
                var index = positional >= 0 ? positional : nextArg++;
                sb.Append('{').Append(index).Append('}');
                i = j;
                continue;
            }
            sb.Append('%');
        }
        return sb.ToString();
    }

    /// <summary>Day section title: Today / Yesterday / yyyy-MM-dd (mac uses yyyyMMdd; we keep ISO-style for Windows).</summary>
    public static string SectionTitle(DateTime dayLocal)
    {
        var today = DateTime.Today;
        if (dayLocal.Date == today)
        {
            return T("section.today");
        }
        if (dayLocal.Date == today.AddDays(-1))
        {
            return T("section.yesterday");
        }
        return dayLocal.Date.ToString("yyyy-MM-dd", _culture);
    }

    public static string TimeText(DateTime utc)
    {
        return utc.ToLocalTime().ToString("HH:mm", _culture);
    }

    public static string DateTimeText(DateTime utc)
    {
        return utc.ToLocalTime().ToString("yyyy-MM-dd HH:mm", _culture);
    }
}
