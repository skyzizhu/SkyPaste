using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Storage;
using Windows.Storage.Streams;
using WinRT;

namespace SkyPaste.Services;

internal static class WindowsShareService
{
    private static Action? _cancelPendingRequest;

    public static void Show(Window owner, ClipboardItem item)
    {
        _cancelPendingRequest?.Invoke();
        var handle = new WindowInteropHelper(owner).Handle;
        var interop = DataTransferManager.As<IDataTransferManagerInterop>();
        var interfaceId = new Guid("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
        var pointer = interop.GetForWindow(handle, ref interfaceId);
        DataTransferManager manager;
        try
        {
            manager = MarshalInterface<DataTransferManager>.FromAbi(pointer);
        }
        finally
        {
            Marshal.Release(pointer);
        }

        var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        TypedEventHandler<DataTransferManager, DataRequestedEventArgs> handler = async (_, args) =>
        {
            _cancelPendingRequest?.Invoke();
            var request = args.Request;
            var deferral = request.GetDeferral();
            try
            {
                await SetDataAsync(request.Data, item);
            }
            catch (Exception error)
            {
                App.UiLog($"Windows share data failed: {error.GetType().Name}");
                request.FailWithDisplayText(L10n.T("menu.share_failed"));
            }
            finally
            {
                deferral.Complete();
            }
        };
        void Cancel()
        {
            timeout.Stop();
            owner.Closed -= OnOwnerClosed;
            manager.DataRequested -= handler;
            _cancelPendingRequest = null;
        }
        void OnOwnerClosed(object? sender, EventArgs e) => Cancel();
        timeout.Tick += (_, _) => Cancel();
        owner.Closed += OnOwnerClosed;
        manager.DataRequested += handler;
        _cancelPendingRequest = Cancel;
        timeout.Start();
        try
        {
            interop.ShowShareUIForWindow(handle);
        }
        catch
        {
            Cancel();
            throw;
        }
    }

    private static async Task SetDataAsync(DataPackage data, ClipboardItem item)
    {
        data.Properties.Title = "SkyPaste";
        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Text:
                if (item.BrowserUrl is { } link)
                {
                    data.SetWebLink(link);
                }
                data.SetText(item.TextValue ?? string.Empty);
                break;
            case ClipboardContentKind.Image:
                var stream = new InMemoryRandomAccessStream();
                using (var writer = new DataWriter(stream))
                {
                    writer.WriteBytes(item.Content.ImageData ?? throw new InvalidOperationException());
                    await writer.StoreAsync();
                    writer.DetachStream();
                }
                stream.Seek(0);
                data.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
                break;
            case ClipboardContentKind.FileRefs:
                var files = new List<IStorageItem>();
                foreach (var path in item.Content.FilePaths ?? Array.Empty<string>())
                {
                    if (System.IO.Directory.Exists(path))
                    {
                        files.Add(await StorageFolder.GetFolderFromPathAsync(path));
                    }
                    else
                    {
                        files.Add(await StorageFile.GetFileFromPathAsync(path));
                    }
                }
                data.SetStorageItems(files);
                break;
        }
    }

    [ComImport]
    [Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(IntPtr window, ref Guid interfaceId);
        void ShowShareUIForWindow(IntPtr window);
    }
}
