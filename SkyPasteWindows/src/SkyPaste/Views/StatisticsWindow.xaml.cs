using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using SkyPaste.Core.Data;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Services;

using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Clipboard Insights (mac ClipboardStatisticsView/Charts): 5 time ranges,
/// hand-drawn trend bars, category donut with legend, source-app ranking.
/// </summary>
public partial class StatisticsWindow : Window
{
    private readonly App _app;
    private StatisticsPeriod _period = StatisticsPeriod.Week;

    private enum StatisticsPeriod { Today, Week, Month, HalfYear, Year }

    private sealed record Snapshot(long Total, Dictionary<StatisticsCategory, long> Categories,
        IReadOnlyList<(DateTime Bucket, long Count)> Trend,
        IReadOnlyList<StatisticsAppEntry> Apps, StatisticsCategory? LeadingCategory);

    private static readonly IReadOnlyDictionary<StatisticsCategory, Color> CategoryColors =
        new Dictionary<StatisticsCategory, Color>
        {
            [StatisticsCategory.Text] = Color.FromRgb(0x1A, 0x6B, 0xE8),
            [StatisticsCategory.Image] = Color.FromRgb(0xF2, 0x7A, 0x42),
            [StatisticsCategory.File] = Color.FromRgb(0x1F, 0x9E, 0x8C),
            [StatisticsCategory.Folder] = Color.FromRgb(0xE0, 0xA3, 0x29),
            [StatisticsCategory.Code] = Color.FromRgb(0x87, 0x63, 0xC9),
            [StatisticsCategory.Url] = Color.FromRgb(0x1F, 0xA3, 0xD1),
            [StatisticsCategory.Email] = Color.FromRgb(0xCC, 0x57, 0x73),
        };

    public StatisticsWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = L10n.T("stats.title");
        Width = 820;
        Height = 640;
        MinWidth = 700;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Background = (Brush)FindResource("Window.Background");

        ApplyLocalization();

        Loaded += (_, _) => WindowEffectsService.EnableRoundedCorners(this);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        TrendCanvas.SizeChanged += (_, _) =>
        {
            if (_lastSnapshot is not null)
            {
                DrawTrend(_lastSnapshot);
            }
        };

        _app.Store.StatisticsChanged += OnStatisticsChanged;
        L10n.LanguageChanged += ApplyLocalizationAndReload;
        Loaded += (_, _) => Reload();
        Closed += (_, _) =>
        {
            _app.Store.StatisticsChanged -= OnStatisticsChanged;
            L10n.LanguageChanged -= ApplyLocalizationAndReload;
        };
    }

    private void ApplyLocalizationAndReload()
    {
        ApplyLocalization();
        Reload();
    }

    private void ApplyLocalization()
    {
        Title = L10n.T("stats.title");
        TitleLabel.Text = L10n.T("stats.title");
        SubtitleLabel.Text = L10n.T("stats.subtitle");
        TrendHeader.Text = L10n.T("stats.trend");
        BreakdownHeader.Text = L10n.T("stats.breakdown");
        AppsHeader.Text = L10n.T("stats.apps.title");
        NoteText.Text = L10n.T("stats.note");
        TotalHeader.Text = L10n.T("stats.total");
        TopCategoryHeader.Text = L10n.T("stats.top_category");
    }

    private void OnStatisticsChanged()
    {
        Dispatcher.BeginInvoke(Reload);
    }

    private void OnPeriodClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string raw } && Enum.TryParse(raw, out StatisticsPeriod period))
        {
            _period = period;
            Reload();
        }
    }

    private Snapshot? _lastSnapshot;

    private void Reload()
    {
        try
        {
            var snapshot = LoadSnapshot(_period);
            _lastSnapshot = snapshot;
            TotalValue.Text = snapshot.Total.ToString("N0", CultureInfo.CurrentCulture);
            TopCategory.Text = snapshot.LeadingCategory is { } leading
                ? L10n.T(leading.LabelKey())
                : L10n.T("stats.no_data");
            DrawPeriodButtons();
            DrawTrend(snapshot);
            DrawDonut(snapshot);
            DrawApps(snapshot);
        }
        catch (Exception)
        {
        }
    }

    private Snapshot LoadSnapshot(StatisticsPeriod period)
    {
        var nowLocal = DateTime.Now;
        var (startLocal, bucketMode) = period switch
        {
            StatisticsPeriod.Today => (nowLocal.Date, "hour"),
            StatisticsPeriod.Week => (nowLocal.Date.AddDays(-6), "day"),
            StatisticsPeriod.Month => (nowLocal.Date.AddDays(-29), "day"),
            StatisticsPeriod.HalfYear => (nowLocal.Date.AddMonths(-6), "week"),
            _ => (nowLocal.Date.AddYears(-1), "month"),
        };
        var endLocal = nowLocal.Date.AddDays(1);

        var fromBucket = StatisticsDatabase.DayBucket(startLocal);
        var toBucket = StatisticsDatabase.DayBucket(endLocal);
        var hourlyFrom = StatisticsDatabase.HourBucket(startLocal);
        var hourlyTo = StatisticsDatabase.HourBucket(endLocal);

        var daily = _app.Statistics.DailyEntries(fromBucket, toBucket);
        var hourly = _app.Statistics.HourlyEntries(hourlyFrom, hourlyTo);

        var categories = new Dictionary<StatisticsCategory, long>();
        foreach (var entry in daily)
        {
            var category = (StatisticsCategory)entry.Category;
            categories[category] = categories.GetValueOrDefault(category) + entry.Count;
        }

        var trend = bucketMode switch
        {
            "hour" => hourly.GroupBy(e => e.Bucket).Select(g => (BucketToDateTime(g.Key, "hour"), g.Sum(e => e.Count))).ToList(),
            "day" => daily.GroupBy(e => e.Bucket).Select(g => (BucketToDateTime(g.Key, "day"), g.Sum(e => e.Count))).ToList(),
            "week" => daily.GroupBy(e => e.Bucket).Select(g => (BucketToDateTime(g.Key, "week"), g.Sum(e => e.Count)))
                .GroupBy(x => x.Item1).Select(g => (g.Key, g.Sum(x => x.Item2))).ToList(),
            _ => daily.GroupBy(e => e.Bucket).Select(g => (BucketToDateTime(g.Key, "month"), g.Sum(e => e.Count)))
                .GroupBy(x => x.Item1).Select(g => (g.Key, g.Sum(x => x.Item2))).ToList(),
        };
        trend = trend.OrderBy(t => t.Item1).ToList();
        if (trend.Count > 60)
        {
            trend = trend.Skip(trend.Count - 60).ToList();
        }

        var apps = _app.Statistics.AppEntries(fromBucket, toBucket);
        var total = categories.Values.Sum();
        var leading = categories.OrderByDescending(kv => kv.Value).FirstOrDefault();
        return new Snapshot(total, categories, trend, apps,
            total > 0 ? leading.Key : null);
    }

    private static DateTime BucketToDateTime(long bucket, string mode)
    {
        var dateTime = DateTimeOffset.FromUnixTimeSeconds(bucket).LocalDateTime;
        return mode switch
        {
            "week" => dateTime.AddDays(-(int)dateTime.DayOfWeek),
            _ => dateTime,
        };
    }

    // ---- charts ---------------------------------------------------------------------------

    private void DrawTrend(Snapshot snapshot)
    {
        TrendCanvas.Children.Clear();
        const double plotHeight = 130;
        var width = Math.Max(TrendCanvas.ActualWidth, 600);
        TrendCanvas.Width = width;
        TrendCanvas.Height = plotHeight;

        var max = snapshot.Trend.Count > 0 ? snapshot.Trend.Max(t => t.Item2) : 0;
        var axisMaximum = AxisMaximum(max);
        if (snapshot.Trend.Count == 0 || axisMaximum == 0)
        {
            TrendCanvas.Children.Add(new TextBlock
            {
                Text = L10n.T("stats.no_data"),
                Foreground = (Brush)FindResource("Text.Secondary"),
                FontSize = 12,
            });
            return;
        }

        var barSlot = width / snapshot.Trend.Count;
        var barWidth = Math.Clamp(barSlot * (snapshot.Trend.Count > 35 ? 0.5 : 0.68), 2, 26);

        for (var i = 0; i < snapshot.Trend.Count; i++)
        {
            var (bucket, count) = snapshot.Trend[i];
            var barHeight = Math.Max(3, plotHeight * count / (double)axisMaximum);
            var x = i * barSlot + (barSlot - barWidth) / 2;
            var bar = new Rectangle
            {
                Width = barWidth,
                Height = barHeight,
                RadiusX = Math.Min(3, barWidth / 2),
                RadiusY = Math.Min(3, barWidth / 2),
                Fill = new SolidColorBrush(count == 0
                    ? Color.FromArgb(31, 0x14, 0x6B, 0xF0)
                    : Color.FromRgb(0x14, 0x6B, 0xF0)),
                ToolTip = $"{bucket:yyyy-MM-dd HH:mm} · {count}",
            };
            Canvas.SetLeft(bar, x);
            Canvas.SetTop(bar, plotHeight - barHeight);
            TrendCanvas.Children.Add(bar);
        }

        var firstLabel = new TextBlock
        {
            Text = snapshot.Trend[0].Item1.ToString("MM-dd", CultureInfo.CurrentCulture),
            FontSize = 9,
            Foreground = (Brush)FindResource("Text.Secondary"),
        };
        Canvas.SetLeft(firstLabel, 0);
        Canvas.SetTop(firstLabel, plotHeight + 2);
        TrendCanvas.Children.Add(firstLabel);

        var lastLabel = new TextBlock
        {
            Text = snapshot.Trend[^1].Item1.ToString("MM-dd", CultureInfo.CurrentCulture),
            FontSize = 9,
            Foreground = (Brush)FindResource("Text.Secondary"),
        };
        Canvas.SetLeft(lastLabel, width - 34);
        Canvas.SetTop(lastLabel, plotHeight + 2);
        TrendCanvas.Children.Add(lastLabel);
        TrendCanvas.Height = plotHeight + 18;
    }

    private static long AxisMaximum(long max)
    {
        if (max <= 0)
        {
            return 0;
        }
        var power = (long)Math.Pow(10, Math.Floor(Math.Log10(max)));
        foreach (var factor in new[] { 2L, 4L, 10L })
        {
            var candidate = factor * power;
            if (candidate >= max)
            {
                return candidate;
            }
        }
        return 10 * power;
    }

    private void DrawDonut(Snapshot snapshot)
    {
        DonutCanvas.Children.Clear();
        if (snapshot.Total == 0)
        {
            return;
        }

        const double size = 130;
        const double thickness = 20;
        var center = new Point(size / 2, size / 2);
        var radius = size / 2 - thickness / 2;
        double startAngle = -90;
        var ordered = snapshot.Categories.OrderByDescending(kv => kv.Value).ToList();

        foreach (var (category, count) in ordered)
        {
            var fraction = count / (double)snapshot.Total;
            var angle = 360.0 * fraction;
            var arc = CreateArc(center, radius, startAngle, Math.Max(angle, 0.5), thickness);
            arc.Stroke = new SolidColorBrush(CategoryColors[category]);
            arc.ToolTip = $"{L10n.T(category.LabelKey())} · {count} ({fraction:P1})";
            DonutCanvas.Children.Add(arc);
            startAngle += angle;
        }

        DonutCanvas.Children.Add(new TextBlock
        {
            Text = snapshot.Total.ToString("N0", CultureInfo.CurrentCulture),
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("Text.Primary"),
        });
        Canvas.SetLeft(DonutCanvas.Children[^1], size / 2 - 18);
        Canvas.SetTop(DonutCanvas.Children[^1], size / 2 - 18);

        var legendHost = (StackPanel)DonutLegendHost;
        legendHost.Children.Clear();
        foreach (var (category, count) in ordered)
        {
            var fraction = count / (double)snapshot.Total;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 3) };
            row.Children.Add(new System.Windows.Shapes.Ellipse
            {
                Width = 9,
                Height = 9,
                Fill = new SolidColorBrush(CategoryColors[category]),
                VerticalAlignment = VerticalAlignment.Center,
            });
            row.Children.Add(new TextBlock
            {
                Text = $" {L10n.T(category.LabelKey())}  {fraction * 100:0.0}%",
                FontSize = 11,
                Foreground = (Brush)FindResource("Text.Primary"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            legendHost.Children.Add(row);
        }
    }

    private static System.Windows.Shapes.Path CreateArc(Point center, double radius, double startAngle, double sweep, double thickness)
    {
        var startRadians = startAngle * Math.PI / 180;
        var endRadians = (startAngle + sweep) * Math.PI / 180;
        var startPoint = new Point(center.X + radius * Math.Cos(startRadians), center.Y + radius * Math.Sin(startRadians));
        var endPoint = new Point(center.X + radius * Math.Cos(endRadians), center.Y + radius * Math.Sin(endRadians));
        var isLarge = sweep > 180 ? 1 : 0;

        var geometry = new PathGeometry(new[]
        {
            new PathFigure(startPoint, new[]
            {
                new ArcSegment(endPoint, new Size(radius, radius), 0, isLarge == 1, SweepDirection.Clockwise, true),
            }, false),
        });
        return new System.Windows.Shapes.Path
        {
            Data = geometry,
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Flat,
            StrokeEndLineCap = PenLineCap.Flat,
        };
    }

    private void DrawApps(Snapshot snapshot)
    {
        AppsHost.Children.Clear();
        if (snapshot.Apps.Count == 0)
        {
            AppsHost.Children.Add(new TextBlock
            {
                Text = L10n.T("stats.apps.empty"),
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Secondary"),
            });
            return;
        }
        var totalAppCopies = snapshot.Apps.Sum(a => a.Count);
        foreach (var app in snapshot.Apps.Take(10))
        {
            var fraction = totalAppCopies > 0 ? app.Count / (double)totalAppCopies : 0;
            var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new TextBlock
            {
                Text = app.Name,
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Primary"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            grid.Children.Add(new TextBlock
            {
                Text = $"{app.Count} · {fraction * 100:0.0}%",
                FontSize = 11,
                Foreground = (Brush)FindResource("Text.Secondary"),
            });
            Grid.SetColumn(grid.Children[1], 1);
            AppsHost.Children.Add(grid);
        }
    }

    private void DrawPeriodButtons()
    {
        foreach (var child in PeriodHost.Children.OfType<Button>())
        {
            var selected = (StatisticsPeriod)int.Parse((string)child.Tag, CultureInfo.InvariantCulture);
            if (child.Content is TextBlock textBlock)
            {
                textBlock.Text = PeriodLabel(selected);
            }
            else
            {
                child.Content = PeriodLabel(selected);
            }
            child.Background = selected == _period
                ? (Brush)FindResource("Chip.Selected.Background")
                : (Brush)FindResource("Chip.Unselected.Background");
            child.Foreground = selected == _period
                ? (Brush)FindResource("Chip.Selected.Foreground")
                : (Brush)FindResource("Text.Primary");
        }
    }

    private string PeriodLabel(StatisticsPeriod period) => period switch
    {
        StatisticsPeriod.Today => L10n.T("stats.period.today"),
        StatisticsPeriod.Week => L10n.T("stats.period.week"),
        StatisticsPeriod.Month => L10n.T("stats.period.month"),
        StatisticsPeriod.HalfYear => L10n.T("stats.period.halfYear"),
        _ => L10n.T("stats.period.year"),
    };
}
