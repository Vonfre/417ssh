using System.Windows;

namespace FourOneSevenSsh;

public partial class App : Application
{
    private void OnStartup(object sender, StartupEventArgs e)
    {
        var window = new MainWindow();
        window.Show();
    }
}
