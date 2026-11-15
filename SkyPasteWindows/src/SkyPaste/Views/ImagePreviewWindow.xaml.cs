using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Image preview (mac SkyImagePreviewView): 0.4-5x zoom &amp; pan, double-click
/// toggles 3x, pen annotation with 5 colors / 2-12 width / undo / clear, and
/// PNG export that re-renders the strokes at original resolution.
/// </summary>
public partial class ImagePreviewWindow : Window
{
    private readonly App _app;
    private readonly ClipboardItem _item;
    private BitmapSource _source = null!;
    private bool _annotating;
    private readonly List<AnnotationStroke> _strokes = new();
    private AnnotationStroke? _activeStroke;
    private double _zoom = 1.0;
    private AnnotationColor _color = AnnotationColor.Red;
    private double _penWidth = 4;

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

    public ImagePreviewWindow(App app, ClipboardItem item)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        Title = L10n.T("preview.title");
        Width = 1000;
        Height = 700;
        MinWidth = 760;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Window.Background");

        PreviewTitle.Text = L10n.T("preview.title");
        CopyButtonLabel.Text = L10n.T("menu.copy");
        SaveAsButtonLabel.Text = L10n.T("menu.save_as");
        AnnotateButtonLabel.Text = L10n.T("preview.annotate");
        FavoriteButtonLabel.Text = _item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
        UndoLabel.Text = L10n.T("preview.annotation_undo");
        ClearLabel.Text = L10n.T("preview.annotation_clear");
        DragHint.Text = L10n.T("preview.drag_hint");

        Loaded += (_, _) => LoadImage();
        Loaded += (_, _) => WindowEffectsService.EnableRoundedCorners(this);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
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
        ZoomText.Text = L10n.T("preview.fit");

        var sourceApp = _item.SourceApp?.Name ?? _item.DeviceName ?? L10n.T("preview.source_local");
        PreviewSubtitle.Text = $"{_item.Content.ImageName ?? ""} · {Math.Max(1, (_item.Content.OriginalByteCount) / 1024)} KB · {sourceApp}";
    }

    // ---- zoom & pan ------------------------------------------------------------------

    private void ApplyZoom(double newZoom)
    {
        _zoom = Math.Clamp(newZoom, 0.4, 5.0);
        var transform = (ScaleTransform)PreviewImage.LayoutTransform;
        transform.ScaleX = _zoom;
        transform.ScaleY = _zoom;
        ZoomText.Text = Math.Abs(_zoom - 1.0) < 0.01 ? L10n.T("preview.fit") : $"{(int)Math.Round(_zoom * 100)}%";
    }

    private void OnZoomOut(object sender, RoutedEventArgs e) => ApplyZoom(_zoom - 0.2);
    private void OnZoomIn(object sender, RoutedEventArgs e) => ApplyZoom(_zoom + 0.2);
    private void OnZoomReset(object sender, RoutedEventArgs e) => ApplyZoom(1.0);

    private void OnPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            ApplyZoom(_zoom + (e.Delta > 0 ? 0.12 : -0.12));
            e.Handled = true;
        }
    }

    private void OnPreviewMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_annotating)
        {
            return;
        }
        ApplyZoom(_zoom > 1.01 ? 1.0 : 3.0);
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
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            var scroll = (ScrollViewer)sender;
            var position = e.GetPosition(scroll);
            if (scroll.GetValue(LastDragPointProperty) is Point last
                && (Math.Abs(position.X - last.X) > 1 || Math.Abs(position.Y - last.Y) > 1))
            {
                scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - (position.X - last.X));
                scroll.ScrollToVerticalOffset(scroll.VerticalOffset - (position.Y - last.Y));
                scroll.SetValue(LastDragPointProperty, position);
            }
        }
    }

    private static readonly DependencyProperty LastDragPointProperty =
        DependencyProperty.RegisterAttached("LastDragPoint", typeof(Point), typeof(ImagePreviewWindow), new PropertyMetadata(new Point(double.NaN, double.NaN)));

    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_annotating)
        {
            if (e.LeftButton == MouseButtonState.Pressed)
            {
                _activeStroke = new AnnotationStroke(_color, _penWidth, new List<Point>());
                _strokes.Add(_activeStroke);
                AddStrokePoint(e.GetPosition(AnnotationHost));
            }
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            var scroll = (ScrollViewer)sender;
            scroll.SetValue(LastDragPointProperty, e.GetPosition(scroll));
        }
    }

    private void OnPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        _activeStroke = null;
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
                StrokeThickness = Math.Max(1, Math.Min(AnnotationHost.ActualWidth, AnnotationHost.ActualHeight) * stroke.WidthFraction),
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
        DragHint.Text = _annotating ? L10n.T("preview.annotation_drag_hint") : L10n.T("preview.drag_hint");
        if (!_annotating)
        {
            RedrawStrokes();
        }
    }

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

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        var exportBytes = RenderAnnotatedPng() ?? _item.Content.ImageData;
        if (exportBytes is not null)
        {
            var exportItem = new ClipboardItem(
                Guid.NewGuid(), DateTime.UtcNow,
                ClipboardContent.FromImage(exportBytes, _item.Content.ImageName, exportBytes.LongLength, previewOnly: false),
                _item.Fingerprint, ClipboardSource.Local, null);
            _app.Coordinator.CopyOnly(exportItem);
        }
    }

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        var exportBytes = RenderAnnotatedPng() ?? _item.Content.ImageData;
        if (exportBytes is null)
        {
            return;
        }
        var exportItem = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromImage(exportBytes, _item.Content.ImageName, exportBytes.LongLength, previewOnly: false),
            _item.Fingerprint, ClipboardSource.Local, null);
        SaveAsService.SaveImage(this, exportItem);
    }

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        _app.Store.SetFavorite(_item, !_item.IsFavorite);
        FavoriteButtonLabel.Text = _item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
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
                    var geometry = new StreamGeometry();
                    using (var g = geometry.Open())
                    {
                        g.BeginFigure(new Point(stroke.Points[0].X * width, stroke.Points[0].Y * height), false, stroke.Points.Count == 1);
                        if (stroke.Points.Count > 1)
                        {
                            g.PolyLineTo(
                                stroke.Points.Skip(1).Select(p => new Point(p.X * width, p.Y * height)).ToList(),
                                true, true);
                        }
                    }
                    geometry.Freeze();
                    context.DrawGeometry(null, new Pen(new SolidColorBrush(StrokeColor(stroke.Color)), Math.Max(1, minDimension * stroke.WidthFraction))
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
