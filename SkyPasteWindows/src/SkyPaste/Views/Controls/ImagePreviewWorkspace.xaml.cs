using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    private BitmapSource _source = null!;
    private bool _annotating;
    private readonly List<AnnotationStroke> _strokes = new();
    private AnnotationStroke? _activeStroke;
    private double _zoom = 1.0;
    private AnnotationColor _color = AnnotationColor.Red;
    private double _penWidth = 4;
    private Point? _dragStart;
    private Point? _panPoint;
    private bool _dragImageOut;

    private sealed record AnnotationStroke(AnnotationColor Color, double WidthFraction, IReadOnlyList<Point> Points);
    private enum AnnotationColor { Black, Red, Yellow, Blue, Green }

    private static Color StrokeColor(AnnotationColor color) => color switch
    {
        AnnotationColor.Red => Color.FromRgb(0xE0, 0x45, 0x3A),
        AnnotationColor.Yellow => Color.FromRgb(0xF5, 0xB8, 0x25),
        AnnotationColor.Blue => Color.FromRgb(0x14, 0x6B, 0xF0),
        AnnotationColor.Green => Color.FromRgb(0x1F, 0x9E, 0x8C),
        _ => Color.FromRgb(0x11, 0x11, 0x11),
    };

    public ImagePreviewWorkspace(App app, ClipboardItem item, ClipboardItem? fileItem = null)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        _favoriteTarget = fileItem ?? item;
        WorkspaceHeading.Visibility = fileItem is null ? Visibility.Visible : Visibility.Collapsed;
        PreviewTitle.Text = L10n.T("preview.title");
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
        LoadImage();
        PreviewScroll.ScrollChanged += (_, args) =>
        {
            if (args.ViewportWidthChange != 0 || args.ViewportHeightChange != 0)
            {
                FitImageToViewport();
            }
        };
        AnnotationHost.SizeChanged += (_, _) => RedrawStrokes();
    }

    private void LoadImage()
    {
        var bitmap = ClipboardWriter.DecodeBitmap(_item.Content.ImageData ?? Array.Empty<byte>());
        if (bitmap is null)
        {
            PreviewText.Text = L10n.T("preview.unavailable");
            PreviewText.Visibility = Visibility.Visible;
            return;
        }
        _source = bitmap;
        PreviewImage.Source = _source;
        FitImageToViewport();
        ZoomText.Text = L10n.T("preview.fit");

        var sourceApp = _item.SourceApp?.Name ?? _item.DeviceName ?? L10n.T("preview.source_local");
        PreviewSubtitle.Text = $"{Math.Max(1, _item.Content.OriginalByteCount / 1024)} KB · {L10n.T("preview.source_label")} {sourceApp}";
    }

    // ---- zoom & pan ------------------------------------------------------------------

    private void FitImageToViewport()
    {
        if (_source is null || PreviewScroll.ViewportWidth <= 0 || PreviewScroll.ViewportHeight <= 0)
        {
            return;
        }
        var scale = Math.Min(PreviewScroll.ViewportWidth / _source.Width, PreviewScroll.ViewportHeight / _source.Height);
        PreviewImage.Width = _source.Width * Math.Min(scale, 1);
        PreviewImage.Height = _source.Height * Math.Min(scale, 1);
    }

    private void ApplyZoom(double newZoom, Point? anchor = null)
    {
        var before = anchor is Point point && AnnotationHost.ActualWidth > 0 && AnnotationHost.ActualHeight > 0
            ? PreviewScroll.TranslatePoint(point, AnnotationHost)
            : (Point?)null;
        var oldWidth = AnnotationHost.ActualWidth;
        var oldHeight = AnnotationHost.ActualHeight;
        _zoom = Math.Clamp(newZoom, 0.4, 5.0);
        var transform = (ScaleTransform)PreviewImage.LayoutTransform;
        transform.ScaleX = _zoom;
        transform.ScaleY = _zoom;
        ZoomText.Text = Math.Abs(_zoom - 1.0) < 0.01 ? L10n.T("preview.fit") : $"{(int)Math.Round(_zoom * 100)}%";
        UpdateDragHint();
        if (before is Point imagePoint && anchor is Point target)
        {
            PreviewScroll.UpdateLayout();
            var newImagePoint = new Point(imagePoint.X / oldWidth * AnnotationHost.ActualWidth,
                imagePoint.Y / oldHeight * AnnotationHost.ActualHeight);
            var current = AnnotationHost.TranslatePoint(newImagePoint, PreviewScroll);
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
            if (e.LeftButton == MouseButtonState.Pressed && _activeStroke is not null)
            {
                AddStrokePoint(e.GetPosition(AnnotationHost));
            }
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
                if (ImageForExport() is { } item && DragOutService.BuildDataObject(item) is { } data)
                {
                    DragPreviewService.AttachPreview(item, data);
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
            if (e.ChangedButton == MouseButton.Left && PreviewImage.IsMouseOver)
            {
                var minDimension = Math.Min(AnnotationHost.ActualWidth, AnnotationHost.ActualHeight);
                if (minDimension <= 0)
                {
                    return;
                }
                _activeStroke = new AnnotationStroke(_color, _penWidth / minDimension, new List<Point>());
                _strokes.Add(_activeStroke);
                AddStrokePoint(e.GetPosition(AnnotationHost));
                PreviewScroll.CaptureMouse();
                e.Handled = true;
            }
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
        _activeStroke = null;
        if (PreviewScroll.IsMouseCaptured)
        {
            PreviewScroll.ReleaseMouseCapture();
        }
        _dragStart = null;
        _panPoint = null;
    }

    // ---- annotation ---------------------------------------------------------------------

    private void AddStrokePoint(Point normalizedPoint)
    {
        if (AnnotationHost.ActualWidth is <= 0 or double.NaN || AnnotationHost.ActualHeight is <= 0 or double.NaN)
        {
            return;
        }
        var normalized = new Point(
            Math.Clamp(normalizedPoint.X / AnnotationHost.ActualWidth, 0, 1),
            Math.Clamp(normalizedPoint.Y / AnnotationHost.ActualHeight, 0, 1));
        var points = (List<Point>)_strokes[^1].Points;
        if (points.Count > 0)
        {
            var last = points[^1];
            if (Math.Abs(last.X - normalized.X) < 0.001 && Math.Abs(last.Y - normalized.Y) < 0.001)
            {
                return;
            }
        }
        points.Add(normalized);
        RedrawStrokes();
    }

    private void RedrawStrokes()
    {
        AnnotationCanvas.Children.Clear();
        if (AnnotationHost.ActualWidth <= 0)
        {
            return;
        }
        foreach (var stroke in _strokes)
        {
            if (stroke.Points.Count == 0)
            {
                continue;
            }
            var geometry = new StreamGeometry();
            var thickness = Math.Max(1, Math.Min(AnnotationHost.ActualWidth, AnnotationHost.ActualHeight) * stroke.WidthFraction);
            if (stroke.Points.Count == 1)
            {
                AnnotationCanvas.Children.Add(new System.Windows.Shapes.Path
                {
                    Data = new EllipseGeometry(ToPixel(stroke.Points[0]), thickness / 2, thickness / 2),
                    Fill = new SolidColorBrush(StrokeColor(stroke.Color)),
                });
                continue;
            }
            using (var context = geometry.Open())
            {
                var first = ToPixel(stroke.Points[0]);
                context.BeginFigure(first, false, stroke.Points.Count == 1);
                if (stroke.Points.Count > 1)
                {
                    context.PolyLineTo(stroke.Points.Skip(1).Select(ToPixel).ToList(), true, true);
                }
            }
            geometry.Freeze();
            AnnotationCanvas.Children.Add(new System.Windows.Shapes.Path
            {
                Data = geometry,
                Stroke = new SolidColorBrush(StrokeColor(stroke.Color)),
                StrokeThickness = thickness,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
                IsHitTestVisible = false,
            });
        }
    }

    private Point ToPixel(Point normalized) => new(normalized.X * AnnotationHost.ActualWidth, normalized.Y * AnnotationHost.ActualHeight);

    private void OnToggleAnnotate(object sender, RoutedEventArgs e)
    {
        _annotating = !_annotating;
        AnnotationToolbar.Visibility = _annotating ? Visibility.Visible : Visibility.Collapsed;
        AnnotateButtonLabel.Text = _annotating ? L10n.T("preview.annotation_done") : L10n.T("preview.annotate");
        UpdateDragHint();
        if (!_annotating)
        {
            RedrawStrokes();
        }
    }

    private void UpdateDragHint() => DragHint.Text = L10n.T(_annotating
        ? "preview.annotation_drag_hint"
        : _zoom > 1.01 ? "preview.drag_zoomed_hint" : "preview.drag_hint");

    private void OnPickColor(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Border { Tag: string raw } && Enum.TryParse(raw, out AnnotationColor color))
        {
            _color = color;
            foreach (var child in ColorHost.Children.OfType<System.Windows.Controls.Border>())
            {
                child.Opacity = child.Tag as string == raw ? 1.0 : 0.45;
            }
        }
    }

    private void OnPenWidthChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        _penWidth = e.NewValue;
    }

    private void OnUndoStroke(object sender, RoutedEventArgs e)
    {
        if (_strokes.Count > 0)
        {
            _strokes.RemoveAt(_strokes.Count - 1);
            RedrawStrokes();
        }
    }

    private void OnClearStrokes(object sender, RoutedEventArgs e)
    {
        _strokes.Clear();
        RedrawStrokes();
    }

    // ---- actions ---------------------------------------------------------------------------

    private ClipboardItem? ImageForExport()
    {
        var exportBytes = RenderAnnotatedPng();
        if (exportBytes is null)
        {
            return null;
        }
        return new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromImage(exportBytes, _item.Content.ImageName, exportBytes.LongLength, previewOnly: false),
            _item.Fingerprint, ClipboardSource.Local, null);
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
        _app.Store.SetFavorite(_favoriteTarget, !_favoriteTarget.IsFavorite);
        FavoriteButtonLabel.Text = _favoriteTarget.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
    }

    /// <summary>
    /// Port of ImageAnnotationRenderer.pngData: re-render the original image plus
    /// normalized strokes at full resolution (no layer screenshots).
    /// </summary>
    private byte[]? RenderAnnotatedPng()
    {
        if (_strokes.Count == 0 || _source is null)
        {
            return _item.Content.ImageData;
        }
        try
        {
            var width = _source.PixelWidth;
            var height = _source.PixelHeight;
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                context.DrawImage(_source, new Rect(0, 0, width, height));
                var minDimension = Math.Min(width, height);
                foreach (var stroke in _strokes)
                {
                    if (stroke.Points.Count == 0)
                    {
                        continue;
                    }
                    var brush = new SolidColorBrush(StrokeColor(stroke.Color));
                    var thickness = Math.Max(1, minDimension * stroke.WidthFraction);
                    var first = new Point(stroke.Points[0].X * width, stroke.Points[0].Y * height);
                    if (stroke.Points.Count == 1)
                    {
                        context.DrawEllipse(brush, null, first, thickness / 2, thickness / 2);
                        continue;
                    }
                    var geometry = new StreamGeometry();
                    using (var g = geometry.Open())
                    {
                        g.BeginFigure(first, false, false);
                        if (stroke.Points.Count > 1)
                        {
                            g.PolyLineTo(
                                stroke.Points.Skip(1).Select(p => new Point(p.X * width, p.Y * height)).ToList(),
                                true, true);
                        }
                    }
                    geometry.Freeze();
                    context.DrawGeometry(null, new Pen(brush, thickness)
                    {
                        StartLineCap = PenLineCap.Round,
                        EndLineCap = PenLineCap.Round,
                        LineJoin = PenLineJoin.Round,
                    }, geometry);
                }
            }
            var renderer = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            renderer.Render(visual);
            return ClipboardDecoder.EncodePng(renderer);
        }
        catch (Exception)
        {
            MessageBox.Show(L10n.T("preview.annotation_export_error_message"),
                L10n.T("preview.annotation_export_error_title"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
    }
}
