using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace FourOneSevenSsh;

public sealed class MainWindow : Window
{
    private readonly ProfileStore _store = new();
    private readonly TunnelManager _tunnels = new();
    private readonly SftpSessionCache _sftpSessions = new();
    private readonly Dictionary<string, TerminalSession> _terminalSessions = [];
    private readonly Dictionary<string, WebView2> _webViews = [];
    private readonly StackPanel _sectionsPanel = new();
    private readonly Grid _content = new();

    public MainWindow()
    {
        Title = $"417ssh {AppVersion.Current}";
        Width = 1220;
        Height = 780;
        MinWidth = 980;
        MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        Background = Brush("#F5F7FB");

        _store.Load();
        Content = BuildShell();
        RefreshSidebar();
        ShowSelectedProfile();
        Closing += (_, _) =>
        {
            _tunnels.Dispose();
            _sftpSessions.Dispose();
            foreach (var session in _terminalSessions.Values)
            {
                session.Dispose();
            }
        };
    }

    private UIElement BuildShell()
    {
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(270) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var sidebar = new DockPanel
        {
            LastChildFill = true,
            Background = Brush("#EDF2F7")
        };
        Grid.SetColumn(sidebar, 0);

        var header = new Border
        {
            Margin = new Thickness(10, 10, 10, 8),
            Padding = new Thickness(10),
            Background = Brushes.White,
            BorderBrush = Brush("#D9E2EC"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = "417ssh", FontWeight = FontWeights.SemiBold, FontSize = 18, Foreground = Brush("#172033") },
                    new TextBlock { Text = "连接 / 终端 / 文件", FontSize = 12, Foreground = Brush("#65758B"), Margin = new Thickness(0, 2, 0, 0) }
                }
            }
        };
        DockPanel.SetDock(header, Dock.Top);
        sidebar.Children.Add(header);

        var footer = new UniformGrid
        {
            Columns = 3,
            Margin = new Thickness(10, 8, 10, 10)
        };
        DockPanel.SetDock(footer, Dock.Bottom);
        footer.Children.Add(SidebarButton("增加", "\uE710", (_, _) => OpenAddMenu()));
        footer.Children.Add(SidebarButton("删除", "\uE74D", (_, _) => DeleteSelected()));
        footer.Children.Add(SidebarButton("设置", "\uE713", (_, _) => new SettingsWindow().ShowDialog()));
        sidebar.Children.Add(footer);

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _sectionsPanel
        };
        sidebar.Children.Add(scroll);

        _content.Background = Brushes.White;
        Grid.SetColumn(_content, 1);

        root.Children.Add(sidebar);
        root.Children.Add(_content);
        return root;
    }

    private Button SidebarButton(string text, string icon, RoutedEventHandler handler)
    {
        var button = new Button
        {
            Margin = new Thickness(3, 0, 3, 0),
            Padding = new Thickness(8, 6, 8, 6),
            BorderThickness = new Thickness(1),
            Background = Brushes.White,
            BorderBrush = Brush("#CBD5E1"),
            Cursor = Cursors.Hand
        };
        button.Click += handler;
        button.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 12, Margin = new Thickness(0, 0, 5, 0) },
                new TextBlock { Text = text, FontSize = 12 }
            }
        };
        return button;
    }

    private void RefreshSidebar()
    {
        _sectionsPanel.Children.Clear();
        foreach (var kind in WorkspaceKinds.All)
        {
            var profiles = _store.ProfilesFor(kind).ToList();
            var section = new StackPanel { Margin = new Thickness(10, 6, 10, 8) };
            section.Children.Add(new TextBlock
            {
                Text = $"{WorkspaceKinds.SidebarTitle(kind)}  {profiles.Count}",
                Foreground = Brush("#64748B"),
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(2, 0, 0, 6)
            });

            if (profiles.Count == 0)
            {
                section.Children.Add(new TextBlock
                {
                    Text = WorkspaceKinds.EmptyText(kind),
                    Foreground = Brush("#94A3B8"),
                    Margin = new Thickness(8, 6, 0, 4),
                    FontSize = 12
                });
            }
            else
            {
                foreach (var profile in profiles)
                {
                    section.Children.Add(ProfileRow(profile));
                }
            }

            _sectionsPanel.Children.Add(section);
        }
    }

    private Border ProfileRow(SshProfile profile)
    {
        var selected = profile.id == _store.SelectedProfileId;
        var row = new Border
        {
            CornerRadius = new CornerRadius(7),
            Background = selected ? Brush("#DBEAFE") : Brushes.Transparent,
            BorderBrush = selected ? Brush("#93C5FD") : Brushes.Transparent,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 7, 8, 7),
            Margin = new Thickness(0, 0, 0, 4),
            Cursor = Cursors.Hand
        };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new TextBlock
        {
            Text = KindIcon(profile.workspaceKind),
            FontFamily = new FontFamily("Segoe MDL2 Assets"),
            Foreground = selected ? Brush("#1D4ED8") : Brush("#475569"),
            FontSize = 16,
            VerticalAlignment = VerticalAlignment.Center
        });

        var text = new StackPanel { Margin = new Thickness(2, 0, 0, 0) };
        text.Children.Add(new TextBlock
        {
            Text = profile.name,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            Foreground = Brush("#172033"),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        text.Children.Add(new TextBlock
        {
            Text = ProfileSubtitle(profile),
            FontSize = 11,
            Foreground = Brush("#64748B"),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var edit = IconButton("\uE70F", "编辑", 24, (_, _) => EditProfile(profile, false));
        Grid.SetColumn(edit, 2);
        grid.Children.Add(edit);

        row.Child = grid;
        row.MouseLeftButtonUp += (_, _) =>
        {
            _store.SelectedProfileId = profile.id;
            RefreshSidebar();
            ShowSelectedProfile();
        };
        return row;
    }

    private static string KindIcon(string kind) => kind switch
    {
        WorkspaceKinds.RStudio => "\uE770",
        WorkspaceKinds.Terminal => "\uE756",
        WorkspaceKinds.Sftp => "\uE8B7",
        _ => "\uE8F1"
    };

    private static string ProfileSubtitle(SshProfile profile)
    {
        if (profile.workspaceKind == WorkspaceKinds.Sftp)
        {
            return "双栏文件传输";
        }
        if (profile.workspaceKind == WorkspaceKinds.Terminal)
        {
            return string.IsNullOrWhiteSpace(profile.TargetAddress) ? "SSH 终端" : profile.TargetAddress;
        }
        return $"{profile.localPort} -> {profile.remoteHost}:{profile.remotePort}";
    }

    private void ShowSelectedProfile()
    {
        _content.Children.Clear();
        var profile = _store.SelectedProfile;
        if (profile is null)
        {
            _content.Children.Add(EmptyState("未选择配置", "请在左侧选择或新建一个连接配置"));
            return;
        }

        if (profile.workspaceKind == WorkspaceKinds.Terminal)
        {
            try
            {
                _content.Children.Add(new TerminalWorkspaceView(profile, _terminalSessions, _sftpSessions, EditCurrentProfile));
            }
            catch (Exception exception)
            {
                AppLog.Error("Terminal workspace failed", exception);
                _content.Children.Add(FeatureErrorState("终端初始化失败", "内置终端依赖 WebView2。请先使用系统 SSH 或安装 WebView2 Runtime。", exception));
            }
        }
        else if (profile.workspaceKind == WorkspaceKinds.Sftp)
        {
            _content.Children.Add(new SftpWorkspaceView(_store, _sftpSessions, RefreshSidebar));
        }
        else
        {
            _content.Children.Add(BuildWebWorkspace(profile));
        }
    }

    private UIElement BuildWebWorkspace(SshProfile profile)
    {
        var root = new DockPanel { Margin = new Thickness(18) };
        var toolbar = new Border
        {
            Background = Brush("#F8FAFC"),
            BorderBrush = Brush("#E2E8F0"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10),
            Margin = new Thickness(0, 0, 0, 12)
        };
        DockPanel.SetDock(toolbar, Dock.Top);

        var tools = new DockPanel();
        var title = new StackPanel();
        title.Children.Add(new TextBlock { Text = profile.name, FontWeight = FontWeights.SemiBold, FontSize = 17, Foreground = Brush("#172033") });
        title.Children.Add(new TextBlock { Text = profile.LocalUrl, FontSize = 12, Foreground = Brush("#64748B") });
        DockPanel.SetDock(title, Dock.Left);
        tools.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(PrimaryButton(_tunnels.IsConnected(profile.id) ? "重新连接" : "连接", "\uE768", async (_, _) => await RunUiAsync(() =>
        {
            _tunnels.Connect(profile);
            Dispatcher.Invoke(ShowSelectedProfile);
        })));
        actions.Children.Add(SecondaryButton("断开", "\uE711", (_, _) =>
        {
            _tunnels.Disconnect(profile.id);
            ShowSelectedProfile();
        }));
        actions.Children.Add(SecondaryButton("浏览器", "\uE774", (_, _) => Process.Start(new ProcessStartInfo(profile.LocalUrl) { UseShellExecute = true })));
        actions.Children.Add(SecondaryButton("编辑", "\uE70F", (_, _) => EditCurrentProfile()));
        DockPanel.SetDock(actions, Dock.Right);
        tools.Children.Add(actions);
        toolbar.Child = tools;
        root.Children.Add(toolbar);

        if (_tunnels.IsConnected(profile.id))
        {
            try
            {
                var web = GetWebView(profile.id);
                web.Margin = new Thickness(0);
                root.Children.Add(web);
                _ = NavigateWeb(profile);
            }
            catch (Exception exception)
            {
                AppLog.Error("WebView2 creation failed", exception);
                root.Children.Add(WebFallbackState(profile, exception));
            }
        }
        else
        {
            root.Children.Add(EmptyState($"{profile.WorkspaceTitle} 未连接", "点击上方连接后会在这里打开本地网页；如果 WebView2 不可用，会自动使用系统浏览器。"));
        }
        return root;
    }

    private WebView2 GetWebView(string id)
    {
        if (_webViews.TryGetValue(id, out var web))
        {
            return web;
        }
        web = new WebView2();
        _webViews[id] = web;
        return web;
    }

    private async Task NavigateWeb(SshProfile profile)
    {
        try
        {
            var web = GetWebView(profile.id);
            await web.EnsureCoreWebView2Async();
            web.CoreWebView2.Navigate(profile.LocalUrl);
        }
        catch (Exception exception)
        {
            AppLog.Error("WebView2 navigation failed", exception);
            try
            {
                Process.Start(new ProcessStartInfo(profile.LocalUrl) { UseShellExecute = true });
            }
            catch (Exception browserException)
            {
                AppLog.Error("Browser fallback failed", browserException);
            }

            MessageBox.Show(
                "内置网页组件 WebView2 初始化失败，已尝试用系统浏览器打开。\n\n日志位置：\n" + AppPaths.NativeLogFile,
                "WebView2 不可用",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void OpenAddMenu()
    {
        var menu = new ContextMenu { Placement = PlacementMode.MousePoint };
        AddMenuItem(menu, "Jupyter 工作区", WorkspaceKinds.Jupyter);
        AddMenuItem(menu, "RStudio 工作区", WorkspaceKinds.RStudio);
        AddMenuItem(menu, "终端工作区", WorkspaceKinds.Terminal);
        AddMenuItem(menu, "SFTP 工作区", WorkspaceKinds.Sftp);
        menu.IsOpen = true;
    }

    private void AddMenuItem(ContextMenu menu, string title, string kind)
    {
        var item = new MenuItem { Header = title };
        item.Click += (_, _) =>
        {
            var profile = _store.AddProfile(kind);
            EditProfile(profile, true);
        };
        menu.Items.Add(item);
    }

    private void EditCurrentProfile()
    {
        if (_store.SelectedProfile is { } profile)
        {
            EditProfile(profile, false);
        }
    }

    private void EditProfile(SshProfile profile, bool isNew)
    {
        var editor = new ProfileEditorWindow(profile.Clone(), isNew) { Owner = this };
        if (editor.ShowDialog() == true && editor.Profile is not null)
        {
            _store.Update(editor.Profile);
        }
        else if (isNew)
        {
            _store.DeleteProfile(profile.id);
        }
        RefreshSidebar();
        ShowSelectedProfile();
    }

    private void DeleteSelected()
    {
        if (_store.SelectedProfile is not { } profile)
        {
            return;
        }
        if (MessageBox.Show(this, $"删除“{profile.name}”？", "删除配置", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }

        _tunnels.Disconnect(profile.id);
        _sftpSessions.Disconnect(profile.id);
        if (_terminalSessions.Remove(profile.id, out var session))
        {
            session.Dispose();
        }
        _store.DeleteProfile(profile.id);
        RefreshSidebar();
        ShowSelectedProfile();
    }

    private static Border EmptyState(string title, string subtitle)
    {
        return new Border
        {
            Margin = new Thickness(28),
            Background = Brush("#F8FAFC"),
            BorderBrush = Brush("#E2E8F0"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = Brush("#172033"), HorizontalAlignment = HorizontalAlignment.Center },
                    new TextBlock { Text = subtitle, FontSize = 13, Foreground = Brush("#64748B"), Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Center }
                }
            }
        };
    }

    private static Border FeatureErrorState(string title, string subtitle, Exception exception)
    {
        return EmptyState(title, subtitle + "\n\n日志：" + AppPaths.NativeLogFile + "\n错误：" + exception.Message);
    }

    private static Border WebFallbackState(SshProfile profile, Exception exception)
    {
        var panel = EmptyState(
            "内置网页不可用",
            "WebView2 初始化失败。可以点击上方“浏览器”用系统浏览器打开：" + profile.LocalUrl + "\n\n日志：" + AppPaths.NativeLogFile + "\n错误：" + exception.Message);
        return panel;
    }

    private static string SimpleHtml(string title, string subtitle)
    {
        return $"""
<!doctype html><meta charset="utf-8">
<body style="font-family:Segoe UI,Microsoft YaHei UI,sans-serif;background:#f8fafc;color:#172033;margin:0;display:grid;place-items:center;height:100vh">
<div style="text-align:center"><h2>{System.Net.WebUtility.HtmlEncode(title)}</h2><p style="color:#64748b">{System.Net.WebUtility.HtmlEncode(subtitle)}</p></div>
</body>
""";
    }

    public static Button PrimaryButton(string text, string icon, RoutedEventHandler handler) =>
        ActionButton(text, icon, handler, Brush("#2563EB"), Brushes.White, Brush("#2563EB"));

    public static Button SecondaryButton(string text, string icon, RoutedEventHandler handler) =>
        ActionButton(text, icon, handler, Brushes.White, Brush("#172033"), Brush("#CBD5E1"));

    public static Button IconButton(string icon, string tooltip, double size, RoutedEventHandler handler)
    {
        var button = new Button
        {
            Width = size,
            Height = size,
            Padding = new Thickness(0),
            Margin = new Thickness(3, 0, 0, 0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            ToolTip = tooltip,
            Cursor = Cursors.Hand,
            Content = new TextBlock
            {
                Text = icon,
                FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize = Math.Max(12, size * 0.48),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        button.Click += handler;
        return button;
    }

    public static Button ActionButton(string text, string icon, RoutedEventHandler handler, Brush background, Brush foreground, Brush border)
    {
        var button = new Button
        {
            Margin = new Thickness(6, 0, 0, 0),
            Padding = new Thickness(12, 7, 12, 7),
            Background = background,
            Foreground = foreground,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children =
                {
                    new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 12, Margin = new Thickness(0, 0, 6, 0) },
                    new TextBlock { Text = text, FontSize = 12 }
                }
            }
        };
        button.Click += handler;
        return button;
    }

    private static async Task RunUiAsync(Action action)
    {
        try
        {
            await Task.Run(action);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "操作失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    public static SolidColorBrush Brush(string color) =>
        new((Color)ColorConverter.ConvertFromString(color));
}

public sealed class TerminalWorkspaceView : DockPanel
{
    private readonly SshProfile _profile;
    private readonly Dictionary<string, TerminalSession> _sessions;
    private readonly TerminalSession _session;
    private readonly SftpBrowserControl _sftpBrowser;
    private readonly Grid _body = new();
    private readonly ColumnDefinition _fileColumn = new() { Width = new GridLength(360) };
    private readonly TerminalControl _terminal;
    private readonly TextBlock _status = new();
    private readonly Button _autoSyncButton;
    private readonly Button _fileButton;
    private readonly Action<string> _stateHandler;
    private readonly Action<string> _directoryHandler;
    private bool _autoSync;
    private bool _filePaneVisible = true;

    public TerminalWorkspaceView(
        SshProfile profile,
        Dictionary<string, TerminalSession> sessions,
        SftpSessionCache sftpSessions,
        Action onEdit)
    {
        _profile = profile;
        _sessions = sessions;
        LastChildFill = true;
        Margin = new Thickness(18);
        _session = GetOrCreateSession();
        _sftpBrowser = new SftpBrowserControl(
            () => [new SftpSource("terminal", profile.id, profile.name, false, profile)],
            sftpSessions,
            fixedSourceId: profile.id,
            paneTitle: "文件");
        _stateHandler = state => Dispatcher.Invoke(() => _status.Text = "终端" + state);
        _directoryHandler = path =>
        {
            if (_autoSync)
            {
                Dispatcher.Invoke(() => _sftpBrowser.Navigate(path));
            }
        };
        _session.StateChanged += _stateHandler;
        _session.DirectoryChanged += _directoryHandler;
        Unloaded += (_, _) =>
        {
            _session.StateChanged -= _stateHandler;
            _session.DirectoryChanged -= _directoryHandler;
        };
        _terminal = new TerminalControl(_session);

        var toolbar = new Border
        {
            Background = MainWindow.Brush("#F8FAFC"),
            BorderBrush = MainWindow.Brush("#E2E8F0"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10),
            Margin = new Thickness(0, 0, 0, 12)
        };
        DockPanel.SetDock(toolbar, Dock.Top);
        Children.Add(toolbar);

        var tools = new DockPanel();
        var title = new StackPanel();
        title.Children.Add(new TextBlock { Text = profile.name, FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = MainWindow.Brush("#172033") });
        _status.Text = _session.IsConnected ? "终端已连接" : "终端未连接";
        _status.Foreground = MainWindow.Brush("#64748B");
        _status.FontSize = 12;
        title.Children.Add(_status);
        tools.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(MainWindow.PrimaryButton(_session.IsConnected ? "重连" : "连接", "\uE768", async (_, _) => await Connect()));
        actions.Children.Add(MainWindow.SecondaryButton("断开", "\uE711", (_, _) =>
        {
            _session.Disconnect();
            _status.Text = "终端未连接";
        }));
        actions.Children.Add(MainWindow.SecondaryButton("清屏", "\uE894", (_, _) => _terminal.Clear()));
        actions.Children.Add(MainWindow.IconButton("\uE7E8", "中断 Ctrl+C", 32, (_, _) => _session.SendControlC()));
        _fileButton = MainWindow.SecondaryButton("文件", "\uE8B7", (_, _) => ToggleFilePane());
        actions.Children.Add(_fileButton);
        actions.Children.Add(MainWindow.IconButton("\uE756", "原生终端", 32, (_, _) => OpenNativeTerminal()));
        actions.Children.Add(MainWindow.IconButton("\uE8C8", "将 SFTP 目录路径复制到终端", 32, (_, _) =>
        {
            _terminal.SendText("cd " + ShellEscaper.Quote(_sftpBrowser.CurrentPath));
        }));
        actions.Children.Add(MainWindow.IconButton("\uE8AB", "同步到终端文件夹", 32, (_, _) => SyncSftpToTerminalDirectory()));
        _autoSyncButton = MainWindow.IconButton("\uE895", "自动同步终端文件夹", 32, (_, _) => ToggleAutoSync());
        actions.Children.Add(_autoSyncButton);
        actions.Children.Add(MainWindow.SecondaryButton("编辑", "\uE70F", (_, _) => onEdit()));
        DockPanel.SetDock(actions, Dock.Right);
        tools.Children.Add(actions);
        toolbar.Child = tools;

        _body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _body.ColumnDefinitions.Add(_fileColumn);
        _terminal.SetValue(Grid.ColumnProperty, 0);
        _sftpBrowser.SetValue(Grid.ColumnProperty, 1);
        _body.Children.Add(_terminal);
        _body.Children.Add(_sftpBrowser);
        Children.Add(_body);
    }

    private TerminalSession GetOrCreateSession()
    {
        if (!_sessions.TryGetValue(_profile.id, out var session))
        {
            session = new TerminalSession();
            _sessions[_profile.id] = session;
        }
        return session;
    }

    private async Task Connect()
    {
        try
        {
            await _terminal.EnsureReadyAsync();
            await _session.ConnectAsync(_profile);
            _status.Text = "终端已连接";
        }
        catch (Exception ex)
        {
            _status.Text = "终端连接失败";
            MessageBox.Show(ex.Message, "终端连接失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void SyncSftpToTerminalDirectory()
    {
        var path = _session.CurrentDirectory;
        if (!string.IsNullOrWhiteSpace(path))
        {
            _sftpBrowser.Navigate(path);
        }
    }

    private void OpenNativeTerminal()
    {
        try
        {
            NativeTerminalLauncher.Open(_profile);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "原生终端", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ToggleFilePane()
    {
        _filePaneVisible = !_filePaneVisible;
        _fileColumn.Width = _filePaneVisible ? new GridLength(360) : new GridLength(0);
        _sftpBrowser.Visibility = _filePaneVisible ? Visibility.Visible : Visibility.Collapsed;
        _fileButton.Background = _filePaneVisible ? MainWindow.Brush("#DBEAFE") : Brushes.White;
    }

    private void ToggleAutoSync()
    {
        _autoSync = !_autoSync;
        _autoSyncButton.Background = _autoSync ? MainWindow.Brush("#DBEAFE") : Brushes.Transparent;
        SyncSftpToTerminalDirectory();
    }
}

public sealed class TerminalControl : Border
{
    private readonly TerminalSession _session;
    private readonly WebView2 _web = new();
    private readonly Action<string> _outputHandler;
    private bool _ready;

    public TerminalControl(TerminalSession session)
    {
        _session = session;
        Background = MainWindow.Brush("#0B1220");
        BorderBrush = MainWindow.Brush("#111827");
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(8);
        Child = _web;
        _outputHandler = text => Dispatcher.Invoke(() => SendToTerminal("output", text));
        _session.OutputReceived += _outputHandler;
        Loaded += async (_, _) => await EnsureReadyAsync();
        Unloaded += (_, _) => _session.OutputReceived -= _outputHandler;
    }

    public async Task EnsureReadyAsync()
    {
        if (_ready)
        {
            return;
        }
        await _web.EnsureCoreWebView2Async();
        _web.CoreWebView2.WebMessageReceived += (_, e) =>
        {
            try
            {
                using var doc = JsonDocument.Parse(e.WebMessageAsJson);
                var type = doc.RootElement.GetProperty("type").GetString();
                if (type == "input")
                {
                    _session.Send(doc.RootElement.GetProperty("data").GetString() ?? "");
                }
                else if (type == "resize")
                {
                    _session.Resize(doc.RootElement.GetProperty("cols").GetInt32(), doc.RootElement.GetProperty("rows").GetInt32());
                }
            }
            catch { }
        };
        _web.NavigateToString(BuildTerminalHtml());
        _ready = true;
    }

    public void SendText(string text) => _session.Send(text);

    public void Clear() => SendToTerminal("clear", "");

    private void SendToTerminal(string type, string data)
    {
        if (_web.CoreWebView2 is null)
        {
            return;
        }
        var json = JsonSerializer.Serialize(new { type, data });
        _web.CoreWebView2.PostWebMessageAsJson(json);
    }

    private static string BuildTerminalHtml()
    {
        var css = new Uri(Path.Combine(AppPaths.BaseDirectory, "assets", "vendor", "xterm", "xterm.css")).AbsoluteUri;
        var js = new Uri(Path.Combine(AppPaths.BaseDirectory, "assets", "vendor", "xterm", "xterm.js")).AbsoluteUri;
        var fit = new Uri(Path.Combine(AppPaths.BaseDirectory, "assets", "vendor", "xterm", "xterm-addon-fit.js")).AbsoluteUri;
        return $$$"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<link rel="stylesheet" href="{{{css}}}">
<style>
html,body,#terminal{margin:0;width:100%;height:100%;background:#0b1220;overflow:hidden;}
.xterm{padding:10px;box-sizing:border-box;}
</style>
</head>
<body>
<div id="terminal"></div>
<script src="{{{js}}}"></script>
<script src="{{{fit}}}"></script>
<script>
const term = new Terminal({cursorBlink:true,fontFamily:'Cascadia Mono,Consolas,monospace',fontSize:13,theme:{background:'#0b1220',foreground:'#dbeafe',cursor:'#93c5fd'}});
const fitAddon = new FitAddon.FitAddon();
term.loadAddon(fitAddon);
term.open(document.getElementById('terminal'));
fitAddon.fit();
term.focus();
term.onData(data => chrome.webview.postMessage({type:'input',data}));
function resize(){ fitAddon.fit(); chrome.webview.postMessage({type:'resize',cols:term.cols,rows:term.rows}); }
window.addEventListener('resize', resize);
chrome.webview.addEventListener('message', event => {
  const msg = event.data;
  if (msg.type === 'output') term.write(msg.data);
  if (msg.type === 'clear') term.clear();
});
setTimeout(resize, 80);
</script>
</body>
</html>
""";
    }
}

public sealed class SftpWorkspaceView : DockPanel
{
    private readonly ProfileStore _store;
    private readonly SftpSessionCache _sessions;
    private readonly Action _refreshSidebar;
    private readonly TabControl _tabs = new();
    private int _tabCounter = 1;

    public SftpWorkspaceView(ProfileStore store, SftpSessionCache sessions, Action refreshSidebar)
    {
        _store = store;
        _sessions = sessions;
        _refreshSidebar = refreshSidebar;
        LastChildFill = true;
        Margin = new Thickness(18);

        var toolbar = new Border
        {
            Background = MainWindow.Brush("#F8FAFC"),
            BorderBrush = MainWindow.Brush("#E2E8F0"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10),
            Margin = new Thickness(0, 0, 0, 12)
        };
        DockPanel.SetDock(toolbar, Dock.Top);
        Children.Add(toolbar);

        var tools = new DockPanel();
        var title = new StackPanel();
        title.Children.Add(new TextBlock { Text = "SFTP 工作区", FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = MainWindow.Brush("#172033") });
        title.Children.Add(new TextBlock { Text = "左右 A/B 双栏组成一个标签，可多开标签并直接拖拽传输", FontSize = 12, Foreground = MainWindow.Brush("#64748B") });
        tools.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(MainWindow.PrimaryButton("新标签", "\uE710", (_, _) => AddTab()));
        actions.Children.Add(MainWindow.SecondaryButton("新增自定义", "\uE710", (_, _) => AddCustomHost()));
        actions.Children.Add(MainWindow.SecondaryButton("删除自定义", "\uE74D", (_, _) => DeleteCustomHost()));
        DockPanel.SetDock(actions, Dock.Right);
        tools.Children.Add(actions);
        toolbar.Child = tools;

        Children.Add(_tabs);
        AddTab();
    }

    private void AddTab()
    {
        var tab = new TabItem
        {
            Header = $"SFTP {_tabCounter++}",
            Content = new SftpPairView(() => Sources(), _sessions)
        };
        _tabs.Items.Add(tab);
        _tabs.SelectedItem = tab;
    }

    private List<SftpSource> Sources()
    {
        var sources = new List<SftpSource>
        {
            new("local", "local", "本地主机", true, null)
        };
        sources.AddRange(_store.Profiles
            .Where(profile => profile.workspaceKind == WorkspaceKinds.Terminal)
            .Select(profile => new SftpSource("terminal", profile.id, profile.name, false, profile)));
        sources.AddRange(_store.Profiles
            .Where(profile => profile.workspaceKind == WorkspaceKinds.Sftp)
            .Skip(1)
            .Select(profile => new SftpSource("custom", profile.id, profile.name, false, profile)));
        return sources;
    }

    private void AddCustomHost()
    {
        var profile = _store.AddCustomSftpProfile();
        var editor = new ProfileEditorWindow(profile.Clone(), true) { Owner = Window.GetWindow(this) };
        if (editor.ShowDialog() == true && editor.Profile is not null)
        {
            _store.Update(editor.Profile);
        }
        else
        {
            _store.DeleteProfile(profile.id);
        }
        _refreshSidebar();
        RefreshTabSources();
    }

    private void DeleteCustomHost()
    {
        var custom = _store.Profiles.Where(profile => profile.workspaceKind == WorkspaceKinds.Sftp).Skip(1).ToList();
        if (custom.Count == 0)
        {
            MessageBox.Show("没有自定义 SFTP Host", "删除自定义", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var picker = new HostPickerWindow(custom) { Owner = Window.GetWindow(this) };
        if (picker.ShowDialog() == true && picker.SelectedProfile is not null)
        {
            _store.DeleteProfile(picker.SelectedProfile.id);
            _refreshSidebar();
            RefreshTabSources();
        }
    }

    private void RefreshTabSources()
    {
        foreach (TabItem item in _tabs.Items)
        {
            if (item.Content is SftpPairView pair)
            {
                pair.RefreshSources();
            }
        }
    }
}

public sealed class SftpPairView : Grid
{
    private readonly SftpBrowserControl _left;
    private readonly SftpBrowserControl _right;

    public SftpPairView(Func<List<SftpSource>> sourcesFactory, SftpSessionCache sessions)
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _left = new SftpBrowserControl(sourcesFactory, sessions, paneTitle: "A") { Margin = new Thickness(0, 0, 8, 0) };
        _right = new SftpBrowserControl(sourcesFactory, sessions, paneTitle: "B") { Margin = new Thickness(8, 0, 0, 0) };
        _left.Peer = _right;
        _right.Peer = _left;
        _right.SetValue(ColumnProperty, 1);
        Children.Add(_left);
        Children.Add(_right);
    }

    public void RefreshSources()
    {
        _left.RefreshSources();
        _right.RefreshSources();
    }
}

public sealed record SftpSource(string Kind, string Id, string Name, bool IsLocal, SshProfile? Profile);

public sealed class SftpBrowserControl : DockPanel
{
    private const string RemoteDragFormat = "417ssh.remote-entry";
    private readonly Func<List<SftpSource>> _sourcesFactory;
    private readonly SftpSessionCache _sessions;
    private readonly string? _fixedSourceId;
    private readonly ComboBox _sourceBox = new();
    private readonly TextBox _pathBox = new();
    private readonly ListView _list = new();
    private readonly TextBlock _status = new();
    private List<SftpSource> _sources = [];
    private readonly Dictionary<string, List<SftpEntry>> _cache = [];
    private GridViewColumnHeader? _lastHeader;
    private ListSortDirection _lastDirection = ListSortDirection.Ascending;

    public SftpBrowserControl Peer { get; set; } = null!;
    public string CurrentPath => _pathBox.Text.Trim();
    public SftpSource? CurrentSource => _sourceBox.SelectedItem as SftpSource;

    public SftpBrowserControl(Func<List<SftpSource>> sourcesFactory, SftpSessionCache sessions, string? fixedSourceId = null, string paneTitle = "")
    {
        _sourcesFactory = sourcesFactory;
        _sessions = sessions;
        _fixedSourceId = fixedSourceId;
        LastChildFill = true;
        AllowDrop = true;
        Background = Brushes.White;

        var frame = new Border
        {
            Background = Brushes.White,
            BorderBrush = MainWindow.Brush("#E2E8F0"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10)
        };
        Children.Add(frame);

        var inner = new DockPanel();
        frame.Child = inner;

        var toolbar = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(toolbar, Dock.Top);
        inner.Children.Add(toolbar);

        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        top.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(paneTitle) ? "SFTP" : paneTitle,
            FontWeight = FontWeights.SemiBold,
            Foreground = MainWindow.Brush("#172033"),
            VerticalAlignment = VerticalAlignment.Center
        });
        _sourceBox.DisplayMemberPath = "Name";
        _sourceBox.MinWidth = 150;
        _sourceBox.Margin = new Thickness(8, 0, 0, 0);
        _sourceBox.SelectionChanged += (_, _) => ResetPathAndRefresh();
        DockPanel.SetDock(_sourceBox, Dock.Right);
        top.Children.Add(_sourceBox);
        toolbar.Children.Add(top);

        var pathRow = new DockPanel();
        _pathBox.MinHeight = 28;
        _pathBox.VerticalContentAlignment = VerticalAlignment.Center;
        _pathBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Refresh();
            }
        };
        pathRow.Children.Add(_pathBox);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(MainWindow.IconButton("\uE74A", "上级目录", 28, (_, _) => NavigateParent()));
        buttons.Children.Add(MainWindow.IconButton("\uE72C", "刷新", 28, (_, _) => Refresh()));
        buttons.Children.Add(MainWindow.IconButton("\uE8F4", "新建文件夹", 28, (_, _) => NewFolder()));
        buttons.Children.Add(MainWindow.IconButton("\uE898", "下载", 28, (_, _) => DownloadSelected()));
        DockPanel.SetDock(buttons, Dock.Right);
        pathRow.Children.Add(buttons);
        toolbar.Children.Add(pathRow);

        var gridView = new GridView();
        gridView.Columns.Add(Column("名称", "Name", 220));
        gridView.Columns.Add(Column("修改时间", "Modified", 135));
        gridView.Columns.Add(Column("大小", "SizeText", 85));
        gridView.Columns.Add(Column("类型", "Type", 70));
        _list.View = gridView;
        _list.BorderThickness = new Thickness(0);
        _list.MouseDoubleClick += (_, _) => OpenSelected();
        _list.PreviewMouseMove += StartDrag;
        _list.Drop += DropOnList;
        _list.ContextMenu = BuildContextMenu();
        _list.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(SortByHeader));
        DockPanel.SetDock(_status, Dock.Bottom);
        _status.Foreground = MainWindow.Brush("#64748B");
        _status.FontSize = 12;
        _status.Margin = new Thickness(0, 8, 0, 0);
        inner.Children.Add(_status);
        inner.Children.Add(_list);

        RefreshSources();
    }

    public void RefreshSources()
    {
        _sources = _sourcesFactory();
        _sourceBox.ItemsSource = _sources;
        var selected = _sources.FirstOrDefault(source => source.Id == _fixedSourceId) ?? _sources.FirstOrDefault();
        _sourceBox.SelectedItem = selected;
        _sourceBox.IsEnabled = _fixedSourceId is null;
        ResetPathAndRefresh();
    }

    public void Navigate(string path)
    {
        _pathBox.Text = path;
        Refresh();
    }

    private GridViewColumn Column(string header, string binding, double width)
    {
        var column = new GridViewColumn { Width = width };
        var h = new GridViewColumnHeader { Content = header, Tag = binding };
        column.Header = h;
        if (binding == "Name")
        {
            var template = new DataTemplate(typeof(SftpEntry));
            var panel = new FrameworkElementFactory(typeof(StackPanel));
            panel.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
            var icon = new FrameworkElementFactory(typeof(TextBlock));
            icon.SetValue(TextBlock.FontFamilyProperty, new FontFamily("Segoe MDL2 Assets"));
            icon.SetValue(TextBlock.MarginProperty, new Thickness(0, 0, 7, 0));
            icon.SetBinding(TextBlock.TextProperty, new Binding("Icon"));
            var text = new FrameworkElementFactory(typeof(TextBlock));
            text.SetBinding(TextBlock.TextProperty, new Binding("Name"));
            text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
            panel.AppendChild(icon);
            panel.AppendChild(text);
            template.VisualTree = panel;
            column.CellTemplate = template;
        }
        else
        {
            column.DisplayMemberBinding = new Binding(binding);
        }
        return column;
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        AddContext(menu, "打开", (_, _) => OpenSelected());
        AddContext(menu, "下载", (_, _) => DownloadSelected());
        AddContext(menu, "复制到另一侧", (_, _) => CopyToPeer());
        AddContext(menu, "重命名", (_, _) => RenameSelected());
        AddContext(menu, "删除", (_, _) => DeleteSelected());
        menu.Items.Add(new Separator());
        AddContext(menu, "刷新", (_, _) => Refresh());
        AddContext(menu, "新建文件夹", (_, _) => NewFolder());
        AddContext(menu, "修改权限", (_, _) => ChangePermissions());
        return menu;
    }

    private static void AddContext(ContextMenu menu, string text, RoutedEventHandler handler)
    {
        var item = new MenuItem { Header = text };
        item.Click += handler;
        menu.Items.Add(item);
    }

    private void ResetPathAndRefresh()
    {
        if (CurrentSource is null)
        {
            return;
        }
        _pathBox.Text = CurrentSource.IsLocal
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : ".";
        Refresh();
    }

    private async void Refresh()
    {
        var source = CurrentSource;
        if (source is null)
        {
            return;
        }
        var path = CurrentPath;
        var cacheKey = source.Id + "|" + path;
        if (_cache.TryGetValue(cacheKey, out var cached))
        {
            _list.ItemsSource = cached;
        }
        _status.Text = "正在读取...";
        try
        {
            var entries = await Task.Run(() => source.IsLocal
                ? LocalFileService.List(path)
                : _sessions.Get(source.Profile!).List(path));
            _cache[cacheKey] = entries.ToList();
            _list.ItemsSource = entries;
            _status.Text = $"{entries.Count} 项";
        }
        catch (Exception ex)
        {
            _status.Text = "读取失败";
            MessageBox.Show(ex.Message, "SFTP", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenSelected()
    {
        if (_list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        var source = CurrentSource;
        if (entry.IsDirectory)
        {
            _pathBox.Text = entry.Path;
            Refresh();
            return;
        }

        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    Process.Start(new ProcessStartInfo(entry.Path) { UseShellExecute = true });
                }
                else if (source?.Profile is { } profile)
                {
                    var local = _sessions.Get(profile).DownloadToTemporary(entry.Path, false);
                    Process.Start(new ProcessStartInfo(local) { UseShellExecute = true });
                }
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "打开文件", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void NavigateParent()
    {
        _pathBox.Text = CurrentSource?.IsLocal == true
            ? Directory.GetParent(CurrentPath)?.FullName ?? CurrentPath
            : PosixPath.Parent(CurrentPath);
        Refresh();
    }

    private void NewFolder()
    {
        var name = Prompt("新建文件夹", "名称", "新建文件夹");
        if (string.IsNullOrWhiteSpace(name))
        {
            return;
        }
        var source = CurrentSource;
        var currentPath = CurrentPath;
        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    Directory.CreateDirectory(Path.Combine(currentPath, name));
                }
                else if (source?.Profile is { } profile)
                {
                    _sessions.Get(profile).CreateDirectory(PosixPath.Join(currentPath, name));
                }
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "新建文件夹", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void DownloadSelected()
    {
        if (_list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        var source = CurrentSource;
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    var destination = Path.Combine(downloads, Path.GetFileName(entry.Path));
                    if (entry.IsDirectory)
                    {
                        CopyDirectory(entry.Path, destination);
                    }
                    else
                    {
                        File.Copy(entry.Path, destination, true);
                    }
                }
                else if (source?.Profile is { } profile)
                {
                    _sessions.Get(profile).Download(entry.Path, downloads, entry.IsDirectory);
                }
                Dispatcher.Invoke(() => _status.Text = "下载完成");
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "下载", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void CopyToPeer()
    {
        if (Peer is null || _list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        TransferTo(Peer, entry);
    }

    private void RenameSelected()
    {
        if (_list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        var name = Prompt("重命名", "新名称", entry.Name);
        if (string.IsNullOrWhiteSpace(name) || name == entry.Name)
        {
            return;
        }
        var source = CurrentSource;
        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    var target = Path.Combine(Path.GetDirectoryName(entry.Path)!, name);
                    if (entry.IsDirectory) Directory.Move(entry.Path, target);
                    else File.Move(entry.Path, target, true);
                }
                else if (source?.Profile is { } profile)
                {
                    _sessions.Get(profile).Rename(entry.Path, PosixPath.Join(PosixPath.Parent(entry.Path), name));
                }
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "重命名", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void DeleteSelected()
    {
        if (_list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        if (MessageBox.Show($"删除“{entry.Name}”？", "删除", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }
        var source = CurrentSource;
        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    if (entry.IsDirectory) Directory.Delete(entry.Path, true);
                    else File.Delete(entry.Path);
                }
                else if (source?.Profile is { } profile)
                {
                    _sessions.Get(profile).Delete(entry.Path, entry.IsDirectory);
                }
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "删除", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void ChangePermissions()
    {
        if (_list.SelectedItem is not SftpEntry entry || CurrentSource?.Profile is not { } profile)
        {
            return;
        }
        var mode = Prompt("修改权限", "权限，例如 755", "755");
        if (string.IsNullOrWhiteSpace(mode))
        {
            return;
        }
        _ = Task.Run(() =>
        {
            try
            {
                _sessions.Get(profile).Chmod(entry.Path, mode);
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "修改权限", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void StartDrag(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _list.SelectedItem is not SftpEntry entry)
        {
            return;
        }
        var data = new DataObject();
        if (CurrentSource?.IsLocal == true)
        {
            data.SetFileDropList(new System.Collections.Specialized.StringCollection { entry.Path });
        }
        else if (CurrentSource is { } source)
        {
            data.SetData(RemoteDragFormat, JsonSerializer.Serialize(new RemoteDragPayload(source.Id, entry.Path, entry.Name, entry.IsDirectory)));
        }
        DragDrop.DoDragDrop(_list, data, DragDropEffects.Copy);
    }

    private void DropOnList(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            var paths = (string[])e.Data.GetData(DataFormats.FileDrop)!;
            foreach (var path in paths)
            {
                UploadLocal(path);
            }
        }
        else if (e.Data.GetDataPresent(RemoteDragFormat))
        {
            var payload = JsonSerializer.Deserialize<RemoteDragPayload>((string)e.Data.GetData(RemoteDragFormat)!);
            if (payload is not null)
            {
                ReceiveRemote(payload);
            }
        }
    }

    private void UploadLocal(string localPath)
    {
        var source = CurrentSource;
        var currentPath = CurrentPath;
        _ = Task.Run(() =>
        {
            try
            {
                if (source?.IsLocal == true)
                {
                    var target = Path.Combine(currentPath, Path.GetFileName(localPath));
                    if (Directory.Exists(localPath)) CopyDirectory(localPath, target);
                    else File.Copy(localPath, target, true);
                }
                else if (source?.Profile is { } profile)
                {
                    _sessions.Get(profile).Upload(localPath, currentPath);
                }
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "上传", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void ReceiveRemote(RemoteDragPayload payload)
    {
        var source = _sourcesFactory().FirstOrDefault(item => item.Id == payload.SourceId);
        if (source?.Profile is null)
        {
            return;
        }
        var targetSource = CurrentSource;
        var targetPath = CurrentPath;
        _ = Task.Run(() =>
        {
            try
            {
                var sourceSession = _sessions.Get(source.Profile);
                if (targetSource?.IsLocal == true)
                {
                    sourceSession.Download(payload.Path, targetPath, payload.IsDirectory);
                }
                else if (targetSource?.Profile is { } targetProfile)
                {
                    if (targetProfile.id == source.Profile.id)
                    {
                        sourceSession.CopyRemote(payload.Path, targetPath);
                    }
                    else
                    {
                        var temp = sourceSession.DownloadToTemporary(payload.Path, payload.IsDirectory);
                        _sessions.Get(targetProfile).Upload(temp, targetPath);
                    }
                }
                Dispatcher.Invoke(Refresh);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => MessageBox.Show(ex.Message, "拖拽传输", MessageBoxButton.OK, MessageBoxImage.Error));
            }
        });
    }

    private void TransferTo(SftpBrowserControl target, SftpEntry entry)
    {
        if (CurrentSource?.IsLocal == true)
        {
            target.UploadLocal(entry.Path);
            return;
        }
        if (CurrentSource is { } source)
        {
            target.ReceiveRemote(new RemoteDragPayload(source.Id, entry.Path, entry.Name, entry.IsDirectory));
        }
    }

    private void SortByHeader(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not GridViewColumnHeader header || header.Tag is not string sortBy)
        {
            return;
        }
        var direction = header == _lastHeader && _lastDirection == ListSortDirection.Ascending
            ? ListSortDirection.Descending
            : ListSortDirection.Ascending;
        _lastHeader = header;
        _lastDirection = direction;
        var view = CollectionViewSource.GetDefaultView(_list.ItemsSource);
        view.SortDescriptions.Clear();
        view.SortDescriptions.Add(new SortDescription(sortBy, direction));
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.GetFiles(source))
        {
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), true);
        }
        foreach (var directory in Directory.GetDirectories(source))
        {
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
        }
    }

    private static string? Prompt(string title, string label, string value)
    {
        var window = new PromptWindow(title, label, value);
        return window.ShowDialog() == true ? window.Value : null;
    }
}

public sealed record RemoteDragPayload(string SourceId, string Path, string Name, bool IsDirectory);

public sealed class ProfileEditorWindow : Window
{
    private readonly SshProfile _profile;
    private readonly Dictionary<string, TextBox> _text = [];
    private readonly Dictionary<string, CheckBox> _checks = [];

    public SshProfile? Profile { get; private set; }

    public ProfileEditorWindow(SshProfile profile, bool isNew)
    {
        _profile = profile;
        Title = isNew ? "新增配置" : "编辑配置";
        Width = 640;
        Height = 720;
        MinWidth = 560;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = MainWindow.Brush("#F5F7FB");
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        Content = Build();
    }

    private UIElement Build()
    {
        var root = new DockPanel { Margin = new Thickness(18) };
        var footer = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0)
        };
        footer.Children.Add(MainWindow.SecondaryButton("取消", "\uE711", (_, _) =>
        {
            DialogResult = false;
            Close();
        }));
        footer.Children.Add(MainWindow.PrimaryButton("完成", "\uE73E", (_, _) => Save()));
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var panel = new StackPanel();
        scroll.Content = panel;
        root.Children.Add(scroll);

        panel.Children.Add(new TextBlock
        {
            Text = "快捷填写",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = MainWindow.Brush("#172033")
        });
        var quick = new TextBox
        {
            AcceptsReturn = true,
            Height = 72,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 12),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        quick.TextChanged += (_, _) =>
        {
            if (quick.Text.TrimStart().StartsWith("ssh ", StringComparison.OrdinalIgnoreCase))
            {
                SshCommandParser.ApplyToProfile(quick.Text, _profile);
                LoadProfileToFields();
            }
        };
        panel.Children.Add(quick);

        var kindBox = new ComboBox { Margin = new Thickness(0, 0, 0, 10) };
        kindBox.Items.Add(new ComboBoxItem { Content = "Jupyter", Tag = WorkspaceKinds.Jupyter });
        kindBox.Items.Add(new ComboBoxItem { Content = "RStudio", Tag = WorkspaceKinds.RStudio });
        kindBox.Items.Add(new ComboBoxItem { Content = "终端", Tag = WorkspaceKinds.Terminal });
        kindBox.Items.Add(new ComboBoxItem { Content = "SFTP", Tag = WorkspaceKinds.Sftp });
        kindBox.SelectedIndex = Array.IndexOf(WorkspaceKinds.All, _profile.workspaceKind);
        kindBox.SelectionChanged += (_, _) =>
        {
            if (kindBox.SelectedItem is ComboBoxItem item && item.Tag is string kind)
            {
                _profile.workspaceKind = kind;
            }
        };
        panel.Children.Add(Labeled("类型", kindBox));

        AddText(panel, "name", "名称", _profile.name);
        AddText(panel, "localPort", "本地端口", _profile.localPort.ToString());
        AddText(panel, "remoteHost", "远程服务主机", _profile.remoteHost);
        AddText(panel, "remotePort", "远程服务端口", _profile.remotePort.ToString());
        AddText(panel, "jupyterPath", "网页路径", _profile.jupyterPath);
        AddText(panel, "targetUser", "目标用户", _profile.targetUser);
        AddText(panel, "targetHost", "目标主机", _profile.targetHost);
        AddText(panel, "targetPort", "目标 SSH 端口", _profile.targetPort.ToString());
        AddText(panel, "jumpUser", "跳板用户", _profile.jumpUser);
        AddText(panel, "jumpHost", "跳板主机", _profile.jumpHost);
        AddText(panel, "jumpPort", "跳板端口", _profile.jumpPort.ToString());
        AddText(panel, "sshPassword", "SSH 密码", _profile.sshPassword, password: true);
        AddText(panel, "identityFile", "密钥文件", _profile.identityFile);

        AddCheck(panel, "compressionEnabled", "启用压缩", _profile.compressionEnabled);
        AddCheck(panel, "verboseLogging", "详细日志", _profile.verboseLogging);
        AddCheck(panel, "allowRemoteLocalPortAccess", "允许局域网访问本地转发端口（Windows 内置转发会回退到本机）", _profile.allowRemoteLocalPortAccess);
        AddCheck(panel, "keepAliveEnabled", "启用 keepalive", _profile.keepAliveEnabled);
        AddText(panel, "keepAliveInterval", "keepalive 间隔", _profile.keepAliveInterval.ToString());
        AddText(panel, "keepAliveCountMax", "keepalive 次数", _profile.keepAliveCountMax.ToString());
        AddCheck(panel, "useSSHConfig", "使用本机 SSH config", _profile.useSSHConfig);

        return root;
    }

    private void LoadProfileToFields()
    {
        SetText("name", _profile.name);
        SetText("localPort", _profile.localPort.ToString());
        SetText("remoteHost", _profile.remoteHost);
        SetText("remotePort", _profile.remotePort.ToString());
        SetText("jupyterPath", _profile.jupyterPath);
        SetText("targetUser", _profile.targetUser);
        SetText("targetHost", _profile.targetHost);
        SetText("targetPort", _profile.targetPort.ToString());
        SetText("jumpUser", _profile.jumpUser);
        SetText("jumpHost", _profile.jumpHost);
        SetText("jumpPort", _profile.jumpPort.ToString());
        SetText("identityFile", _profile.identityFile);
        if (_checks.TryGetValue("compressionEnabled", out var compression)) compression.IsChecked = _profile.compressionEnabled;
        if (_checks.TryGetValue("verboseLogging", out var verbose)) verbose.IsChecked = _profile.verboseLogging;
        if (_checks.TryGetValue("allowRemoteLocalPortAccess", out var allow)) allow.IsChecked = _profile.allowRemoteLocalPortAccess;
    }

    private void Save()
    {
        _profile.name = GetText("name");
        _profile.localPort = IntValue("localPort", _profile.localPort);
        _profile.remoteHost = HostNames.NormalizeForwardTarget(GetText("remoteHost"));
        _profile.remotePort = IntValue("remotePort", _profile.remotePort);
        _profile.jupyterPath = GetText("jupyterPath");
        _profile.targetUser = GetText("targetUser");
        _profile.targetHost = GetText("targetHost");
        _profile.targetPort = IntValue("targetPort", _profile.targetPort);
        _profile.jumpUser = GetText("jumpUser");
        _profile.jumpHost = GetText("jumpHost");
        _profile.jumpPort = IntValue("jumpPort", _profile.jumpPort);
        _profile.sshPassword = GetText("sshPassword");
        _profile.identityFile = GetText("identityFile");
        _profile.compressionEnabled = Checked("compressionEnabled");
        _profile.verboseLogging = Checked("verboseLogging");
        _profile.allowRemoteLocalPortAccess = Checked("allowRemoteLocalPortAccess");
        _profile.keepAliveEnabled = Checked("keepAliveEnabled");
        _profile.keepAliveInterval = IntValue("keepAliveInterval", _profile.keepAliveInterval);
        _profile.keepAliveCountMax = IntValue("keepAliveCountMax", _profile.keepAliveCountMax);
        _profile.useSSHConfig = Checked("useSSHConfig");
        _profile.Normalize();
        Profile = _profile;
        DialogResult = true;
        Close();
    }

    private void AddText(Panel panel, string key, string label, string value, bool password = false)
    {
        var box = new TextBox
        {
            Text = value,
            Height = 30,
            VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 4, 0, 8)
        };
        _text[key] = box;
        panel.Children.Add(Labeled(label, box));
    }

    private void AddCheck(Panel panel, string key, string label, bool value)
    {
        var check = new CheckBox
        {
            Content = label,
            IsChecked = value,
            Margin = new Thickness(0, 4, 0, 8),
            Foreground = MainWindow.Brush("#172033")
        };
        _checks[key] = check;
        panel.Children.Add(check);
    }

    private static FrameworkElement Labeled(string label, UIElement child)
    {
        return new StackPanel
        {
            Margin = new Thickness(0, 0, 0, 4),
            Children =
            {
                new TextBlock { Text = label, FontSize = 12, Foreground = MainWindow.Brush("#64748B") },
                child
            }
        };
    }

    private string GetText(string key) => _text.TryGetValue(key, out var box) ? box.Text.Trim() : "";
    private void SetText(string key, string value) { if (_text.TryGetValue(key, out var box)) box.Text = value; }
    private bool Checked(string key) => _checks.TryGetValue(key, out var check) && check.IsChecked == true;
    private int IntValue(string key, int fallback) => int.TryParse(GetText(key), out var value) ? value : fallback;
}

public sealed class SettingsWindow : Window
{
    private readonly UpdateService _updates = new();
    private readonly TextBlock _status = new();
    private readonly ProgressBar _progress = new() { Minimum = 0, Maximum = 1, Height = 8, Margin = new Thickness(0, 8, 0, 8) };
    private GitHubRelease? _latest;
    private string? _downloadedZip;

    public SettingsWindow()
    {
        Title = "设置";
        Width = 560;
        Height = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = MainWindow.Brush("#F5F7FB");
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        Content = Build();
    }

    private UIElement Build()
    {
        var panel = new StackPanel { Margin = new Thickness(18) };
        panel.Children.Add(new TextBlock { Text = $"当前版本：{AppVersion.Current}", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = MainWindow.Brush("#172033") });
        panel.Children.Add(new TextBlock { Text = $"安装目录：{AppPaths.InstallDirectory}", FontSize = 12, Foreground = MainWindow.Brush("#64748B"), Margin = new Thickness(0, 6, 0, 4) });
        panel.Children.Add(new TextBlock { Text = $"更新缓存：{AppPaths.PortableUpdatesDirectory}", FontSize = 12, Foreground = MainWindow.Brush("#64748B"), Margin = new Thickness(0, 0, 0, 12) });
        _status.Text = "可以检查 GitHub Releases 中的新版本。";
        _status.TextWrapping = TextWrapping.Wrap;
        _status.Foreground = MainWindow.Brush("#475569");
        panel.Children.Add(_status);
        panel.Children.Add(_progress);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(MainWindow.SecondaryButton("检查更新", "\uE895", async (_, _) => await Check()));
        actions.Children.Add(MainWindow.PrimaryButton("下载并安装", "\uE896", async (_, _) => await Download()));
        actions.Children.Add(MainWindow.SecondaryButton("安装已下载包", "\uE777", (_, _) => Install()));
        panel.Children.Add(actions);
        return panel;
    }

    private async Task Check()
    {
        try
        {
            _status.Text = "正在检查...";
            _latest = await _updates.CheckLatestAsync(CancellationToken.None);
            _status.Text = $"最新版本：{_latest.TagName}\n{_latest.HtmlUrl}";
        }
        catch (Exception ex)
        {
            _status.Text = "检查失败：" + ex.Message;
        }
    }

    private async Task Download()
    {
        try
        {
            if (_latest is null)
            {
                await Check();
            }
            if (_latest is null)
            {
                return;
            }
            _progress.Value = 0;
            var progress = new Progress<double>(value => _progress.Value = value);
            _downloadedZip = await _updates.DownloadWindowsZipAsync(_latest, progress, CancellationToken.None);
            _status.Text = $"下载完成，正在退出并安装：{_downloadedZip}";
            _updates.InstallAfterExit(_downloadedZip);
        }
        catch (Exception ex)
        {
            _status.Text = "下载失败：" + ex.Message;
        }
    }

    private void Install()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(_downloadedZip))
            {
                MessageBox.Show("请先下载更新包。", "安装更新", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            _updates.InstallAfterExit(_downloadedZip);
        }
        catch (Exception ex)
        {
            _status.Text = "安装失败：" + ex.Message;
        }
    }
}

public sealed class HostPickerWindow : Window
{
    private readonly ListBox _list = new();
    public SshProfile? SelectedProfile { get; private set; }

    public HostPickerWindow(IEnumerable<SshProfile> profiles)
    {
        Title = "选择 Host";
        Width = 360;
        Height = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        var root = new DockPanel { Margin = new Thickness(14) };
        _list.DisplayMemberPath = "name";
        _list.ItemsSource = profiles.ToList();
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(footer, Dock.Bottom);
        footer.Children.Add(MainWindow.SecondaryButton("取消", "\uE711", (_, _) => Close()));
        footer.Children.Add(MainWindow.PrimaryButton("删除", "\uE74D", (_, _) =>
        {
            SelectedProfile = _list.SelectedItem as SshProfile;
            DialogResult = SelectedProfile is not null;
            Close();
        }));
        root.Children.Add(footer);
        root.Children.Add(_list);
        Content = root;
    }
}

public sealed class PromptWindow : Window
{
    private readonly TextBox _box = new();
    public string Value => _box.Text.Trim();

    public PromptWindow(string title, string label, string value)
    {
        Title = title;
        Width = 360;
        Height = 170;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        var root = new DockPanel { Margin = new Thickness(14) };
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = label, Foreground = MainWindow.Brush("#64748B") });
        _box.Text = value;
        _box.Margin = new Thickness(0, 6, 0, 10);
        _box.Height = 30;
        _box.VerticalContentAlignment = VerticalAlignment.Center;
        panel.Children.Add(_box);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(footer, Dock.Bottom);
        footer.Children.Add(MainWindow.SecondaryButton("取消", "\uE711", (_, _) => Close()));
        footer.Children.Add(MainWindow.PrimaryButton("确定", "\uE73E", (_, _) =>
        {
            DialogResult = true;
            Close();
        }));
        root.Children.Add(footer);
        root.Children.Add(panel);
        Content = root;
    }
}
