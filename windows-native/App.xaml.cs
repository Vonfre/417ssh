using System.Windows;
using System.Windows.Threading;

namespace FourOneSevenSsh;

public partial class App : Application
{
    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception exception)
            {
                AppLog.Error("Unhandled app-domain exception", exception);
            }
        };

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            AppLog.Error("Unobserved task exception", e.Exception);
            e.SetObserved();
        };
    }

    private void OnStartup(object sender, StartupEventArgs e)
    {
        try
        {
            AppLog.Info("Starting 417ssh native Windows " + AppVersion.Current);
            var window = new MainWindow();
            window.Show();
        }
        catch (Exception exception)
        {
            AppLog.Error("Startup failed", exception);
            MessageBox.Show(
                "417ssh 启动失败，错误已经写入日志：\n" + AppPaths.NativeLogFile + "\n\n" + exception.Message,
                "417ssh 启动失败",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        AppLog.Error("UI exception", e.Exception);
        MessageBox.Show(
            "417ssh 遇到错误，日志位置：\n" + AppPaths.NativeLogFile + "\n\n" + e.Exception.Message,
            "417ssh",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }
}
