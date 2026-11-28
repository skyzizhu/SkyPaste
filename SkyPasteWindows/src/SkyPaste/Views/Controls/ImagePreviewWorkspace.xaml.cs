using System.Windows;
using System.Windows.Controls;
using System.Windows.Ink;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkyPaste.Core.Core;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste.Views.Controls;

/// <summary>
/// Image preview (mac SkyImagePreviewView): 0.4-5x zoom &amp; pan, double-click
/// toggles 3x, pen annotation with 5 colors / 2-12 width / undo / clear, and
/// PNG export that re-renders the strokes at original resolution.
/// </summary>
public partial class ImagePreviewWorkspace : UserControl
{
    private readonly App _app;
    private readonly ClipboardItem _item;
    private readonly ClipboardItem _favoriteTarget;
    private BitmapSource? _source;
    private bool _annotating;
    private double _fitScale = 1.0;
    private double _zoom = 1.0;
    private AnnotationColor _color = AnnotationColor.Red;
    private double _penWidth = 4;
    private Point? _dragStart;
    private Point? _panPoint;
    private bool _dragImageOut;
    private byte[]? _annotatedPng;

    private enum AnnotationColor { Black, Red, Yellow, Blue, Green }

    private static Color StrokeColor(AnnotationColor color) => color switch
    {
        AnnotationColor.Red => Color.FromRgb(0xE0, 0x45, 0x3A),
        AnnotationColor.Yellow => Color.FromRgb(0xF5, 0xB8, 0x25),
        AnnotationColor.Blue => Color.FromRgb(0x14, 0x6B, 0xF0),
        AnnotationColor.Green => Color.FromRgb(0x1F, 0x9E, 0x8C),
        _ => Color.FromRgb(0x11, 0x11, 0x11),
    };

    public ImagePreviewWorkspace(App app, ClipboardItem item, ClipboardItem? fileItem = null, BitmapSource? bitmap = null)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        _favoriteTarget = fileItem ?? item;
        WorkspaceHeading.Visibility = fileItem is null ? Visibility.Visible : Visibility.Collapsed;
        if (fileItem is not null)
        {
            foreach (var button in ImageActions.Children.OfType<Button>())
            {
                if (button != AnnotateButton)
                {
                    button.Visibility = Visibility.Collapsed;
                }
            }
            AnnotateButton.Margin = new Thickness(0);
        }
        PreviewTitle.Text = L10n.T("preview.title");
        if (fileItem is null)
        {
            PreviewSubtitle.Text = $"{Math.Max(1, _item.Content.OriginalByteCount / 1024)} KB ·";
            PreviewSource.Content = SourceIcon.CreatePreviewLabel(_item);
        }
        CopyButtonLabel.Text = L10n.T("menu.copy");
        ShareLabel.Text = L10n.T("menu.share");
        OpenImageLabel.Text = L10n.T("preview.open_image");
        SaveAsButtonLabel.Text = L10n.T("menu.save_as");
        AnnotateButtonLabel.Text = L10n.T("preview.annotate");
        FavoriteButtonLabel.Text = _favoriteTarget.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
        UndoLabel.Text = L10n.T("preview.annotation_undo");
        ClearLabel.Text = L10n.T("preview.annotation_clear");
        DragHint.Text = L10n.T("preview.drag_hint");

        AnnotationHintLabel.Text = L10n.T("preview.annotation_hint");
        PenWidthLabel.Text = L10n.T("preview.annotation_width");
        AnnotationCanvas.DefaultDrawingAttributes.IgnorePressure = true;
        AnnotationCanvas.Strokes.StrokesChanged += (_, _) =>
        {
            _annotatedPng = null;
            var hasStrokes = AnnotationCanvas.Strokes.Count > 0;
            UndoButton.IsEnabled = hasStrokes;
            ClearButton.IsEnabled = hasStrokes;
        };
        LoadImage(bitmap ?? ClipboardWriter.DecodeBitmap(_item.Content.ImageData ?? Array.Empty<byte>()));
        PreviewScroll.ScrollChanged += (_, args) =>
        {
            if (args.ViewportWidthChange != 0 || args.ViewportHeightChange != 0)
            {
                FitImageToViewport();
            }
        };
    }

    private void LoadImage(BitmapSource? bitmap)
    {
        if (bitmap is null)
        {
            PreviewText.Text = L10n.T("preview.unavailable");
            PreviewText.Visibility = Visibility.Visible;
            AnnotateButton.IsEnabled = false;
            return;
        }
        _source = bitmap;
        PreviewImage.Source = _source;
        // InkCanvas uses source pixels as its coordinates. The preview and ink
        // scale together, so strokes do not move when the viewport changes.
        AnnotationHost.Width = bitmap.PixelWidth;
        AnnotationHost.Height = bitmap.PixelHeight;
        FitImageToViewport();
        ZoomText.Text = L10n.T("preview.fit");

    }

    // ---- zoom & pan ------------------------------------------------------------------

    private void FitImageToViewport()
    {
        if (_source is null || PreviewScroll.ViewportWidth <= 0 || PreviewScroll.ViewportHeight <= 0)
        {
            return;
        }
        _fitScale = Math.Min(1, Math.Min(PreviewScroll.ViewportWidth / _source.PixelWidth,
            PreviewScroll.ViewportHeight / _source.PixelHeight));
        UpdateImageScale();
    }

    private void UpdateImageScale()
    {
        ImageScale.ScaleX = ImageScale.ScaleY = _fitScale * _zoom;
        UpdatePen();
    }

    private void ApplyZoom(double newZoom, Point? anchor = null)
    {
        var before = anchor is Point point && AnnotationHost.ActualWidth > 0 && AnnotationHost.ActualHeight > 0
            ? PreviewScroll.TranslatePoint(point, AnnotationHost)
            : (Point?)null;
        _zoom = Math.Clamp(newZoom, 0.4, 5.0);
        UpdateImageScale();
        ZoomText.Text = Math.Abs(_zoom - 1.0) < 0.01 ? L10n.T("preview.fit") : $"{(int)Math.Round(_zoom * 100)}%";
        UpdateDragHint();
        if (before is Point imagePoint && anchor is Point target)
        {
            PreviewScroll.UpdateLayout();
            var current = AnnotationHost.TranslatePoint(imagePoint, PreviewScroll);
            PreviewScroll.ScrollToHorizontalOffset(PreviewScroll.HorizontalOffset + current.X - target.X);
            PreviewScroll.ScrollToVerticalOffset(PreviewScroll.VerticalOffset + current.Y - target.Y);
        }
    }

    private void OnZoomOut(object sender, RoutedEventArgs e) => ApplyZoom(_zoom - 0.2);
    private void OnZoomIn(object sender, RoutedEventArgs e) => ApplyZoom(_zoom + 0.2);
    private void OnZoomReset(object sender, RoutedEventArgs e) => ApplyZoom(1.0);

    private void OnPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            ApplyZoom(_zoom + (e.Delta > 0 ? 0.12 : -0.12), e.GetPosition(PreviewScroll));
            e.Handled = true;
        }
    }

    private void OnPreviewMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_annotating || e.ChangedButton != MouseButton.Left)
        {
            return;
        }
        _dragStart = null;
        _panPoint = null;
        ApplyZoom(_zoom > 1.01 ? 1.0 : 3.0, e.GetPosition(PreviewScroll));
        e.Handled = true;
    }

    private void OnPreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (_annotating)
        {
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed && _dragStart is Point start)
        {
            var scroll = (ScrollViewer)sender;
            var position = e.GetPosition(scroll);
            if (_dragImageOut)
            {
                if (Math.Abs(position.X - start.X) < SystemParameters.MinimumHorizontalDragDistance
                    && Math.Abs(position.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance)
                {
                    return;
                }
                _dragStart = null;
                var dragItem = _favoriteTarget.IsFileCollection && AnnotationCanvas.Strokes.Count == 0
                    ? _favoriteTarget : ImageForExport();
                if (dragItem is not null && DragOutService.BuildDataObject(dragItem) is { } data)
                {
                    DragPreviewService.AttachPreview(dragItem, data);
                    DragOutService.StartDrag(PreviewImage, data);
                }
                return;
            }
            if (_panPoint is Point last)
            {
                scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - (position.X - last.X));
                scroll.ScrollToVerticalOffset(scroll.VerticalOffset - (position.Y - last.Y));
                _panPoint = position;
            }
        }
    }

    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_annotating)
        {
            return;
        }
        if (e.ChangedButton == MouseButton.Left && e.ClickCount == 1 && PreviewImage.IsMouseOver)
        {
            var scroll = (ScrollViewer)sender;
            _dragStart = _panPoint = e.GetPosition(scroll);
            _dragImageOut = _zoom <= 1.01 || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);
        }
    }

    private void OnPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        _dragStart = null;
        _panPoint = null;
    }

    // ---- annotation ---------------------------------------------------------------------

    private void UpdatePen()
    {
        var width = Math.Clamp(_penWidth / (_fitScale * _zoom), DrawingAttributes.MinWidth, DrawingAttributes.MaxWidth);
        var pen = AnnotationCanvas.DefaultDrawingAttributes;
        pen.Color = StrokeColor(_color);
        pen.Width = width;
        pen.Height = width;
    }

    private void OnToggleAnnotate(object sender, RoutedEventArgs e)
    {
        if (_source is null)
        {
            return;
        }
        _annotating = !_annotating;
        _dragStart = null;
        _panPoint = null;
        AnnotationCanvas.IsHitTestVisible = _annotating;
        AnnotationCanvas.EditingMode = _annotating ? InkCanvasEditingMode.Ink : InkCanvasEditingMode.None;
        AnnotationToolbar.Visibility = _annotating ? Visibility.Visible : Visibility.Collapsed;
        AnnotateButtonLabel.Text = _annotating ? L10n.T("preview.annotation_done") : L10n.T("preview.annotate");
        UpdateDragHint();
    }

    private void UpdateDragHint() => DragHint.Text = L10n.T(_annotating
        ? "preview.annotation_drag_hint"
        : _zoom > 1.01 ? "preview.drag_zoomed_hint" : "preview.drag_hint");

    private void OnPickColor(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Border { Tag: string raw } && Enum.TryParse(raw, out AnnotationColor color))
        {
            _color = color;
            UpdatePen();
            foreach (var child in ColorHost.Children.OfType<System.Windows.Controls.Border>())
            {
                child.Opacity = child.Tag as string == raw ? 1.0 : 0.45;
            }
        }
    }

    private void OnPenWidthChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        _penWidth = e.NewValue;
        UpdatePen();
    }

    private void OnUndoStroke(object sender, RoutedEventArgs e)
    {
        var strokes = AnnotationCanvas.Strokes;
        if (strokes.Count > 0)
        {
            strokes.RemoveAt(strokes.Count - 1);
        }
    }

    private void OnClearStrokes(object sender, RoutedEventArgs e)
    {
        AnnotationCanvas.Strokes.Clear();
    }

    // ---- actions ---------------------------------------------------------------------------

    private ClipboardItem? ImageForExport()
    {
        if (AnnotationCanvas.Strokes.Count == 0)
        {
            return _source is null ? null : _item;
        }
        var exportBytes = RenderAnnotatedPng();
        if (exportBytes is null)
        {
            return null;
        }
        return new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromImage(exportBytes, _item.Content.ImageName, exportBytes.LongLength, previewOnly: false),
            Fingerprint.ForImage(exportBytes), ClipboardSource.Local, null);
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (ImageForExport() is { } item)
        {
            _app.Coordinator.CopyOnly(item);
        }
    }

    private void OnShare(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } owner && ImageForExport() is { } item)
        {
            _app.Coordinator.Share(owner, item);
        }
    }

    private void OnOpenImage(object sender, RoutedEventArgs e)
    {
        if (ImageForExport() is not { } item)
        {
            return;
        }
        if (DragOutService.MaterializeImage(item) is { } path)
        {
            _app.Coordinator.OpenPaths(new[] { path });
        }
        else
        {
            _app.Toast.Show(L10n.T("preview.unavailable_message"));
        }
    }

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        if (ImageForExport() is { } item)
        {
            SaveAsService.SaveImage(Window.GetWindow(this), item);
        }
    }

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        _app.Store.SetFavorite(_favoriteTarget, !_app.Store.IsFavorite(_favoriteTarget));
        FavoriteButtonLabel.Text = _app.Store.IsFavorite(_favoriteTarget) ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
    }

    /// <summary>
    /// Port of ImageAnnotationRenderer.pngData: re-render the original image plus
    /// original-pixel strokes at full resolution.
    /// </summary>
    private byte[]? RenderAnnotatedPng()
    {
        var strokes = AnnotationCanvas.Strokes;
        if (strokes.Count == 0 || _source is null)
        {
            return _item.Content.ImageData;
        }
        if (_annotatedPng is not null)
        {
            return _annotatedPng;
        }
        try
        {
            var width = _source.PixelWidth;
            var height = _source.PixelHeight;
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                context.DrawImage(_source, new Rect(0, 0, width, height));
                strokes.Draw(context);
            }
            var renderer = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            renderer.Render(visual);
            return _annotatedPng = ClipboardDecoder.EncodePng(renderer);
        }
        catch (Exception)
        {
            MessageBox.Show(L10n.T("preview.annotation_export_error_message"),
                L10n.T("preview.annotation_export_error_title"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
    }
}
