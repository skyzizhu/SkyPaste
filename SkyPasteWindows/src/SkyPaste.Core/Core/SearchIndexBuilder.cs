using SkyPaste.Core.Models;

namespace SkyPaste.Core.Core;

/// <summary>
/// Port of macOS makeSearchIndex: lowercase, newline-joined index containing the
/// content itself plus type/source keyword aliases and source-app names.
/// </summary>
public static class SearchIndexBuilder
{
    public static string Build(ClipboardItem item)
    {
        var parts = new List<string>();

        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Text:
                parts.Add((item.Content.Text ?? string.Empty).Trim());
                break;
            case ClipboardContentKind.Image:
                if (!string.IsNullOrWhiteSpace(item.Content.ImageName))
                {
                    parts.Add(item.Content.ImageName!.Trim());
                }
                parts.Add("image img 图片");
                break;
            case ClipboardContentKind.FileRefs:
            {
                var paths = item.Content.FilePaths ?? Array.Empty<string>();
                foreach (var path in paths)
                {
                    parts.Add(Path.GetFileName(path).Trim());
                    parts.Add(path);
                }
                parts.Add("file files folder folders directory directories 文件 文件夹 目录");
                if (paths.Any(ClipboardItem.IsImagePath))
                {
                    parts.Add("image file photo file image img 图片 图片文件");
                }
                break;
            }
        }

        if (item.Classification.IsPlainText)
        {
            parts.Add("text plain text 文本");
        }
        if (item.Classification.IsUrl)
        {
            parts.Add("url link 链接");
        }
        if (item.Classification.IsEmail)
        {
            parts.Add("email mail e-mail 邮箱 邮件");
        }
        if (item.Classification.IsCode)
        {
            parts.Add("code snippet 代码");
        }

        parts.Add(string.Join(" ", item.Source.SearchKeywords()));

        if (item.SourceApp is { } app)
        {
            parts.Add(app.Name);
            parts.Add(app.ProcessId);
        }
        else if (item.DeviceName is { } device)
        {
            parts.Add(device);
        }

        var joined = string.Join("\n", parts.Where(p => !string.IsNullOrWhiteSpace(p)));
        return joined.ToLowerInvariant();
    }
}
