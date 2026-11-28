using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using SkyPaste.Core.Core;

namespace SkyPaste.Services;

internal static class FileIconProvider
{
    private static readonly ConcurrentDictionary<string, BitmapSource> ApplicationIcons = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<ClipboardSourceAppOption, Lazy<Task<BitmapSource?>>> AppLookups = new();
    private static readonly Lazy<IReadOnlyList<InstalledApp>> InstalledApps = new(ReadInstalledApps);

    public static Task<BitmapSource?> GetApplicationIconAsync(ClipboardSourceAppOption app) =>
        AppLookups.GetOrAdd(app, key => new Lazy<Task<BitmapSource?>>(
            () => Task.Run(() => GetApplicationIcon(key)))).Value;

    private static BitmapSource? GetApplicationIcon(ClipboardSourceAppOption app)
    {
        // These system executables may be launchers for the installed Store app.
        var packagePrefix = app.ProcessId.ToLowerInvariant() switch
        {
            "notepad.exe" => @"shell:AppsFolder\Microsoft.WindowsNotepad_",
            "snippingtool.exe" => @"shell:AppsFolder\Microsoft.ScreenSketch_",
            _ => null,
        };
        if (packagePrefix is not null)
        {
            var package = InstalledApps.Value.FirstOrDefault(entry =>
                entry.ParsingName.StartsWith(packagePrefix, StringComparison.OrdinalIgnoreCase));
            if (package is not null && GetCachedIcon(package.ParsingName, ExtractShellIcon) is { } packageIcon)
            {
                return packageIcon;
            }
        }

        var path = File.Exists(app.ExecutablePath) ? app.ExecutablePath : FindApplicationPath(app.ProcessId);
        if (path is not null && !path.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase))
        {
            var icon = GetCachedIcon(path, Extract);
            if (icon is not null)
            {
                return icon;
            }
        }

        var name = Path.GetFileNameWithoutExtension(app.ProcessId);
        var registered = InstalledApps.Value.FirstOrDefault(entry =>
            string.Equals(entry.ExecutableName, app.ProcessId, StringComparison.OrdinalIgnoreCase))
            ?? InstalledApps.Value.FirstOrDefault(entry =>
                string.Equals(entry.Name, app.Name, StringComparison.OrdinalIgnoreCase)
                || string.Equals(entry.Name.Replace(" ", ""), name, StringComparison.OrdinalIgnoreCase));
        var shellIcon = registered is null ? null : GetCachedIcon(registered.ParsingName, ExtractShellIcon);
        if (shellIcon is null && registered?.TargetPath is { } target && File.Exists(target))
        {
            shellIcon = GetCachedIcon(target, Extract);
        }
        return shellIcon ?? (path is null ? null : GetCachedIcon(path, Extract));
    }

    private static BitmapSource? GetCachedIcon(string path, Func<string, BitmapSource?> load)
    {
        if (ApplicationIcons.TryGetValue(path, out var cached))
        {
            return cached;
        }
        var image = load(path);
        if (image is not null)
        {
            ApplicationIcons.TryAdd(path, image);
        }
        return image;
    }

    private sealed record InstalledApp(string Name, string ParsingName, string? ExecutableName, string? TargetPath);

    private static IReadOnlyList<InstalledApp> ReadInstalledApps()
    {
        var apps = new List<InstalledApp>();
        var shellType = Type.GetTypeFromProgID("Shell.Application");
        if (shellType is null)
        {
            return apps;
        }

        object? shell = null;
        object? folder = null;
        object? items = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            folder = CallShell(shell, "NameSpace", BindingFlags.InvokeMethod, "shell:AppsFolder");
            if (folder is null)
            {
                return apps;
            }
            items = CallShell(folder, "Items", BindingFlags.InvokeMethod);
            var count = Convert.ToInt32(CallShell(items, "Count", BindingFlags.GetProperty));
            for (var i = 0; i < count; i++)
            {
                var item = CallShell(items, "Item", BindingFlags.InvokeMethod, i);
                if (item is null)
                {
                    continue;
                }
                try
                {
                    var path = CallShell(item, "Path", BindingFlags.GetProperty) as string;
                    var name = CallShell(item, "Name", BindingFlags.GetProperty) as string;
                    if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(name))
                    {
                        continue;
                    }
                    var target = CallShell(item, "ExtendedProperty", BindingFlags.InvokeMethod,
                        "System.Link.TargetParsingPath") as string;
                    var executableName = Path.GetFileName(string.IsNullOrWhiteSpace(target) ? path : target);
                    var parsingName = Path.IsPathRooted(path) || path.StartsWith("::", StringComparison.Ordinal)
                        ? path : @"shell:AppsFolder\" + path;
                    apps.Add(new InstalledApp(name, parsingName, executableName, target));
                }
                catch (Exception error) when (error is COMException or TargetInvocationException)
                {
                    // A removed shortcut may still be present in the folder.
                }
                finally
                {
                    Marshal.ReleaseComObject(item);
                }
            }
        }
        catch (Exception error) when (error is COMException or TargetInvocationException or UnauthorizedAccessException)
        {
            // The desktop Shell can be unavailable, for example in a headless session.
        }
        finally
        {
            foreach (var value in new[] { items, folder, shell })
            {
                if (value is not null)
                {
                    Marshal.ReleaseComObject(value);
                }
            }
        }
        return apps;
    }

    private static object? CallShell(object? target, string member, BindingFlags action, params object[] arguments) =>
        target?.GetType().InvokeMember(member, action, null, target, arguments);

    private static BitmapSource? ExtractShellIcon(string parsingName)
    {
        var factoryId = typeof(IShellItemImageFactory).GUID;
        if (SHCreateItemFromParsingName(parsingName, IntPtr.Zero, in factoryId, out var factory) < 0 || factory is null)
        {
            return null;
        }
        try
        {
            const uint iconOnly = 0x4;
            if (factory.GetImage(new System.Drawing.Size(48, 48), iconOnly, out var bitmap) < 0 || bitmap == IntPtr.Zero)
            {
                return null;
            }
            try
            {
                var source = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty,
                    BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                return source;
            }
            finally
            {
                DeleteObject(bitmap);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(factory);
        }
    }

    [ComImport, Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(System.Drawing.Size size, uint flags, out IntPtr bitmap);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, in Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory? factory);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr handle);

    public static BitmapSource? Extract(string path)
    {
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon is null)
            {
                return null;
            }
            var source = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException
            or ExternalException or SecurityException or NotSupportedException)
        {
            return null;
        }
    }

    private static string? FindApplicationPath(string executableName)
    {
        if (!executableName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(executableName) != executableName)
        {
            return null;
        }

        var keyName = @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" + executableName;
        foreach (var root in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = root.OpenSubKey(keyName);
                if (key?.GetValue(null) is string path && File.Exists(path.Trim('"')))
                {
                    return path.Trim('"');
                }
            }
            catch (Exception error) when (error is IOException or SecurityException or UnauthorizedAccessException)
            {
            }
        }

        string? runningPath = null;
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(executableName)))
        {
            using (process)
            {
                try
                {
                    runningPath ??= process.MainModule?.FileName;
                }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException or NotSupportedException)
                {
                }
            }
        }
        var systemPath = Path.Combine(Environment.SystemDirectory, executableName);
        var windowsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), executableName);
        return runningPath ?? (File.Exists(systemPath) ? systemPath : File.Exists(windowsPath) ? windowsPath : null);
    }
}
