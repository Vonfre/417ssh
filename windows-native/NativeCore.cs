using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Windows;
using Renci.SshNet;
using Renci.SshNet.Common;
using Renci.SshNet.Sftp;

namespace FourOneSevenSsh;

public static class AppPaths
{
    public static string ConfigDirectory
    {
        get
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(root, "417ssh");
        }
    }

    public static string ProfilesFile => Path.Combine(ConfigDirectory, "profiles.json");

    public static string UpdatesDirectory
    {
        get
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(root, "417ssh", "updates");
        }
    }

    public static string BaseDirectory => AppContext.BaseDirectory;
}

public static class AppVersion
{
    public static string Current
    {
        get
        {
            var versionFile = Path.Combine(AppPaths.BaseDirectory, "VERSION");
            if (File.Exists(versionFile))
            {
                var text = File.ReadAllText(versionFile).Trim();
                if (!string.IsNullOrWhiteSpace(text))
                {
                    return text;
                }
            }

            return "0.6.0";
        }
    }
}

public static class WorkspaceKinds
{
    public const string Jupyter = "jupyter";
    public const string RStudio = "rstudio";
    public const string Terminal = "terminal";
    public const string Sftp = "sftp";

    public static readonly string[] All = [Jupyter, RStudio, Terminal, Sftp];

    public static string Title(string kind) => kind switch
    {
        RStudio => "RStudio",
        Terminal => "终端",
        Sftp => "SFTP",
        _ => "Jupyter"
    };

    public static string SidebarTitle(string kind) => kind switch
    {
        RStudio => "RStudio 工作区",
        Terminal => "终端工作区",
        Sftp => "SFTP 工作区",
        _ => "Jupyter 工作区"
    };

    public static string EmptyText(string kind) => kind switch
    {
        RStudio => "还没有 RStudio 配置",
        Terminal => "还没有终端配置",
        Sftp => "还没有 SFTP 配置",
        _ => "还没有 Jupyter 配置"
    };

    public static bool IsWeb(string kind) => kind is Jupyter or RStudio;

    public static string DefaultName(string kind, int number)
    {
        var suffix = number <= 1 ? "" : $" {number}";
        return kind switch
        {
            Terminal => number <= 1 ? "新终端" : $"新终端{suffix}",
            Sftp => number <= 1 ? "SFTP" : $"SFTP{suffix}",
            RStudio => number <= 1 ? "新 RStudio" : $"新 RStudio{suffix}",
            _ => number <= 1 ? "新 Jupyter" : $"新 Jupyter{suffix}"
        };
    }

    public static int DefaultLocalPort(string kind, int number) =>
        kind == RStudio ? 8008 + Math.Max(0, number - 1) : 8000 + Math.Max(0, number - 1);

    public static string DefaultRemoteHost(string kind) => kind == RStudio ? "localhost" : "127.0.0.1";

    public static int DefaultRemotePort(string kind) => kind == RStudio ? 8787 : 8888;

    public static string DefaultHttpPath(string kind) => kind == RStudio ? "/" : "/lab/tree/work";
}

public sealed class SshProfile : IEquatable<SshProfile>
{
    public string id { get; set; } = Guid.NewGuid().ToString();
    public string workspaceKind { get; set; } = WorkspaceKinds.Jupyter;
    public string name { get; set; } = "新 Jupyter";
    public int localPort { get; set; } = 8000;
    public string remoteHost { get; set; } = "127.0.0.1";
    public int remotePort { get; set; } = 8888;
    public string jumpUser { get; set; } = "";
    public string jumpHost { get; set; } = "";
    public int jumpPort { get; set; } = 22;
    public string targetUser { get; set; } = "";
    public string targetHost { get; set; } = "";
    public int targetPort { get; set; } = 22;
    public string jupyterPath { get; set; } = "/lab/tree/work";
    public string sshPassword { get; set; } = "";
    public string identityFile { get; set; } = "";
    public bool compressionEnabled { get; set; } = true;
    public bool verboseLogging { get; set; }
    public bool allowRemoteLocalPortAccess { get; set; }
    public bool keepAliveEnabled { get; set; } = true;
    public int keepAliveInterval { get; set; } = 30;
    public int keepAliveCountMax { get; set; } = 120;
    public bool useSSHConfig { get; set; }

    [JsonIgnore] public string WorkspaceTitle => WorkspaceKinds.Title(workspaceKind);
    [JsonIgnore] public bool IsWebWorkspace => WorkspaceKinds.IsWeb(workspaceKind);
    [JsonIgnore] public bool HasJumpHost => !string.IsNullOrWhiteSpace(jumpHost);

    [JsonIgnore]
    public string TargetUserOrDefault =>
        string.IsNullOrWhiteSpace(targetUser) ? Environment.UserName : targetUser.Trim();

    [JsonIgnore]
    public string TargetAddress
    {
        get
        {
            var user = targetUser.Trim();
            var host = targetHost.Trim();
            return string.IsNullOrWhiteSpace(user) ? host : $"{user}@{host}";
        }
    }

    [JsonIgnore]
    public string JumpAddress
    {
        get
        {
            var user = jumpUser.Trim();
            var host = jumpHost.Trim();
            var hostPart = string.IsNullOrWhiteSpace(user) ? host : $"{user}@{host}";
            return $"{hostPart}:{jumpPort}";
        }
    }

    [JsonIgnore]
    public string LocalUrl
    {
        get
        {
            var path = string.IsNullOrWhiteSpace(jupyterPath) ? "/" : jupyterPath.Trim();
            if (!path.StartsWith('/'))
            {
                path = "/" + path;
            }
            return $"http://127.0.0.1:{localPort}{path}";
        }
    }

    public static SshProfile Blank(int number, string kind)
    {
        return new SshProfile
        {
            id = Guid.NewGuid().ToString(),
            workspaceKind = kind,
            name = WorkspaceKinds.DefaultName(kind, number),
            localPort = WorkspaceKinds.DefaultLocalPort(kind, number),
            remoteHost = WorkspaceKinds.DefaultRemoteHost(kind),
            remotePort = WorkspaceKinds.DefaultRemotePort(kind),
            jupyterPath = WorkspaceKinds.DefaultHttpPath(kind),
            jumpPort = 22,
            targetPort = 22,
            keepAliveEnabled = true,
            keepAliveInterval = 30,
            keepAliveCountMax = 120,
            compressionEnabled = true
        };
    }

    public SshProfile Clone()
    {
        var json = JsonSerializer.Serialize(this, JsonOptions.Default);
        return JsonSerializer.Deserialize<SshProfile>(json, JsonOptions.Default) ?? new SshProfile();
    }

    public void Normalize()
    {
        id = string.IsNullOrWhiteSpace(id) ? Guid.NewGuid().ToString() : id;
        workspaceKind = WorkspaceKinds.All.Contains(workspaceKind) ? workspaceKind : WorkspaceKinds.Jupyter;
        name = string.IsNullOrWhiteSpace(name) ? WorkspaceKinds.DefaultName(workspaceKind, 1) : name.Trim();
        remoteHost ??= WorkspaceKinds.DefaultRemoteHost(workspaceKind);
        jumpUser ??= "";
        jumpHost ??= "";
        targetUser ??= "";
        targetHost ??= "";
        jupyterPath = string.IsNullOrWhiteSpace(jupyterPath) ? WorkspaceKinds.DefaultHttpPath(workspaceKind) : jupyterPath.Trim();
        sshPassword ??= "";
        identityFile ??= "";
        localPort = Clamp(localPort, 1, 65535);
        remotePort = Clamp(remotePort, 1, 65535);
        jumpPort = Clamp(jumpPort, 1, 65535);
        targetPort = Clamp(targetPort, 1, 65535);
        keepAliveInterval = Clamp(keepAliveInterval, 10, 600);
        keepAliveCountMax = Clamp(keepAliveCountMax, 3, 720);
    }

    public bool Equals(SshProfile? other) => other?.id == id;

    private static int Clamp(int value, int low, int high) => Math.Max(low, Math.Min(high, value));
}

public static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        WriteIndented = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip
    };
}

public sealed class ProfileStore
{
    public ObservableCollection<SshProfile> Profiles { get; } = [];
    public string? SelectedProfileId { get; set; }

    public void Load()
    {
        Directory.CreateDirectory(AppPaths.ConfigDirectory);
        Profiles.Clear();

        if (File.Exists(AppPaths.ProfilesFile))
        {
            try
            {
                var json = File.ReadAllText(AppPaths.ProfilesFile);
                var profiles = JsonSerializer.Deserialize<List<SshProfile>>(json, JsonOptions.Default) ?? [];
                foreach (var profile in profiles)
                {
                    profile.Normalize();
                    Profiles.Add(profile);
                }
            }
            catch
            {
                // A broken config should not keep the app from opening.
            }
        }

        if (Profiles.Count == 0)
        {
            Profiles.Add(SshProfile.Blank(1, WorkspaceKinds.Jupyter));
        }

        NormalizeBuiltInSftpWorkspace();
        SelectedProfileId = Profiles.FirstOrDefault()?.id;
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.ConfigDirectory);
        var json = JsonSerializer.Serialize(Profiles.ToList(), JsonOptions.Default);
        File.WriteAllText(AppPaths.ProfilesFile, json, new UTF8Encoding(false));
    }

    public IEnumerable<SshProfile> ProfilesFor(string kind)
    {
        var profiles = Profiles.Where(profile => profile.workspaceKind == kind);
        return kind == WorkspaceKinds.Sftp ? profiles.Take(1) : profiles;
    }

    public SshProfile? SelectedProfile =>
        Profiles.FirstOrDefault(profile => profile.id == SelectedProfileId) ?? Profiles.FirstOrDefault();

    public SshProfile AddProfile(string kind)
    {
        if (kind == WorkspaceKinds.Sftp)
        {
            var existing = Profiles.FirstOrDefault(profile => profile.workspaceKind == WorkspaceKinds.Sftp);
            if (existing is not null)
            {
                SelectedProfileId = existing.id;
                return existing;
            }
        }

        var count = Profiles.Count(profile => profile.workspaceKind == kind);
        var profile = SshProfile.Blank(count + 1, kind);
        profile.name = NextProfileName(profile.name);
        Profiles.Add(profile);
        SelectedProfileId = profile.id;
        Save();
        return profile;
    }

    public SshProfile AddCustomSftpProfile()
    {
        var count = Profiles.Count(profile => profile.workspaceKind == WorkspaceKinds.Sftp);
        var profile = SshProfile.Blank(count + 1, WorkspaceKinds.Sftp);
        profile.name = NextProfileName("自定义 SFTP");
        Profiles.Add(profile);
        Save();
        return profile;
    }

    public void DeleteProfile(string id)
    {
        var profile = Profiles.FirstOrDefault(item => item.id == id);
        if (profile is null)
        {
            return;
        }

        Profiles.Remove(profile);
        if (Profiles.Count == 0)
        {
            Profiles.Add(SshProfile.Blank(1, WorkspaceKinds.Jupyter));
        }

        SelectedProfileId = Profiles.FirstOrDefault()?.id;
        Save();
    }

    public void Update(SshProfile updated)
    {
        updated.Normalize();
        var index = Profiles.ToList().FindIndex(profile => profile.id == updated.id);
        if (index >= 0)
        {
            Profiles[index] = updated;
            Save();
        }
    }

    private void NormalizeBuiltInSftpWorkspace()
    {
        var sftp = Profiles.FirstOrDefault(profile => profile.workspaceKind == WorkspaceKinds.Sftp);
        if (sftp is null)
        {
            return;
        }

        if (sftp.name == "新 SFTP" || sftp.name.StartsWith("新 SFTP ", StringComparison.Ordinal))
        {
            sftp.name = NextProfileName("SFTP");
        }
    }

    private string NextProfileName(string baseName)
    {
        var existing = Profiles.Select(profile => profile.name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var candidate = baseName;
        var suffix = 2;
        while (existing.Contains(candidate))
        {
            candidate = $"{baseName} {suffix++}";
        }

        return candidate;
    }
}

public static class SshCommandParser
{
    public static void ApplyToProfile(string command, SshProfile profile)
    {
        var tokens = Split(command);
        if (tokens.Count == 0)
        {
            return;
        }

        if (tokens[0].Equals("ssh", StringComparison.OrdinalIgnoreCase))
        {
            tokens.RemoveAt(0);
        }

        var positional = new List<string>();
        for (var i = 0; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (token == "--")
            {
                positional.AddRange(tokens.Skip(i + 1));
                break;
            }

            if (token is "-L" or "-J" or "-p" or "-P" or "-i")
            {
                if (i + 1 >= tokens.Count)
                {
                    continue;
                }
                ApplyOption(token, tokens[++i], profile);
                continue;
            }

            if (token.StartsWith("-L", StringComparison.Ordinal) && token.Length > 2)
            {
                ApplyOption("-L", token[2..], profile);
                continue;
            }

            if (token.StartsWith("-J", StringComparison.Ordinal) && token.Length > 2)
            {
                ApplyOption("-J", token[2..], profile);
                continue;
            }

            if (token.StartsWith("-p", StringComparison.Ordinal) && token.Length > 2 && int.TryParse(token[2..], out _))
            {
                ApplyOption("-p", token[2..], profile);
                continue;
            }

            if (token.StartsWith("-i", StringComparison.Ordinal) && token.Length > 2)
            {
                ApplyOption("-i", token[2..], profile);
                continue;
            }

            if (token.StartsWith("-", StringComparison.Ordinal) && token.Length > 1)
            {
                foreach (var flag in token.Skip(1))
                {
                    switch (flag)
                    {
                        case 'C':
                            profile.compressionEnabled = true;
                            break;
                        case 'v':
                            profile.verboseLogging = true;
                            break;
                        case 'g':
                            profile.allowRemoteLocalPortAccess = true;
                            break;
                    }
                }
                continue;
            }

            positional.Add(token);
        }

        var target = positional.LastOrDefault(item => item.Contains('@') || LooksLikeHost(item));
        if (!string.IsNullOrWhiteSpace(target))
        {
            ApplyTarget(target, profile);
        }

        if (string.IsNullOrWhiteSpace(profile.name) || profile.name.StartsWith("新 ", StringComparison.Ordinal))
        {
            profile.name = string.IsNullOrWhiteSpace(profile.targetHost) ? profile.WorkspaceTitle : profile.targetHost;
        }
    }

    private static void ApplyOption(string option, string value, SshProfile profile)
    {
        switch (option)
        {
            case "-L":
                var forward = value.Split(':', 3);
                if (forward.Length == 3)
                {
                    if (int.TryParse(forward[0], out var localPort)) profile.localPort = localPort;
                    profile.remoteHost = forward[1];
                    if (int.TryParse(forward[2], out var remotePort)) profile.remotePort = remotePort;
                }
                break;
            case "-J":
                ApplyJump(value, profile);
                break;
            case "-p":
            case "-P":
                if (int.TryParse(value, out var port)) profile.targetPort = port;
                break;
            case "-i":
                profile.identityFile = value;
                break;
        }
    }

    private static void ApplyJump(string value, SshProfile profile)
    {
        var hostPart = value;
        var port = 22;
        var colon = value.LastIndexOf(':');
        if (colon > -1 && colon < value.Length - 1 && int.TryParse(value[(colon + 1)..], out var parsedPort))
        {
            hostPart = value[..colon];
            port = parsedPort;
        }

        var at = hostPart.IndexOf('@');
        if (at > -1)
        {
            profile.jumpUser = hostPart[..at];
            profile.jumpHost = hostPart[(at + 1)..];
        }
        else
        {
            profile.jumpHost = hostPart;
        }
        profile.jumpPort = port;
    }

    private static void ApplyTarget(string value, SshProfile profile)
    {
        var hostPart = value;
        var port = profile.targetPort;
        var colon = value.LastIndexOf(':');
        if (colon > -1 && colon < value.Length - 1 && int.TryParse(value[(colon + 1)..], out var parsedPort))
        {
            hostPart = value[..colon];
            port = parsedPort;
        }

        var at = hostPart.IndexOf('@');
        if (at > -1)
        {
            profile.targetUser = hostPart[..at];
            profile.targetHost = hostPart[(at + 1)..];
        }
        else
        {
            profile.targetHost = hostPart;
        }
        profile.targetPort = port;
    }

    private static bool LooksLikeHost(string value) =>
        value.Contains('.') || value.Equals("localhost", StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(value, @"^[A-Za-z0-9_-]+$");

    private static List<string> Split(string command)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        var quote = '\0';
        var escaping = false;

        foreach (var c in command)
        {
            if (escaping)
            {
                current.Append(c);
                escaping = false;
                continue;
            }

            if (c == '\\')
            {
                escaping = true;
                continue;
            }

            if (quote != '\0')
            {
                if (c == quote)
                {
                    quote = '\0';
                }
                else
                {
                    current.Append(c);
                }
                continue;
            }

            if (c is '\'' or '"')
            {
                quote = c;
                continue;
            }

            if (char.IsWhiteSpace(c))
            {
                if (current.Length > 0)
                {
                    result.Add(current.ToString());
                    current.Clear();
                }
                continue;
            }

            current.Append(c);
        }

        if (current.Length > 0)
        {
            result.Add(current.ToString());
        }

        return result;
    }
}

public sealed class SshConnectionContext : IDisposable
{
    public SshConnectionContext(ConnectionInfo connectionInfo, SshClient? jumpClient = null, ForwardedPortLocal? jumpForward = null)
    {
        ConnectionInfo = connectionInfo;
        JumpClient = jumpClient;
        JumpForward = jumpForward;
    }

    public ConnectionInfo ConnectionInfo { get; }
    public SshClient? JumpClient { get; }
    public ForwardedPortLocal? JumpForward { get; }

    public void Dispose()
    {
        try { JumpForward?.Stop(); } catch { }
        try { JumpForward?.Dispose(); } catch { }
        try
        {
            if (JumpClient?.IsConnected == true) JumpClient.Disconnect();
        }
        catch { }
        try { JumpClient?.Dispose(); } catch { }
    }
}

public static class SshConnectionFactory
{
    public static SshConnectionContext CreateContext(SshProfile profile)
    {
        profile.Normalize();
        if (string.IsNullOrWhiteSpace(profile.targetHost))
        {
            throw new InvalidOperationException("目标主机为空");
        }

        if (!profile.HasJumpHost)
        {
            return new SshConnectionContext(BuildConnectionInfo(profile.targetHost, profile.targetPort, profile.TargetUserOrDefault, profile));
        }

        var jumpUser = string.IsNullOrWhiteSpace(profile.jumpUser) ? profile.TargetUserOrDefault : profile.jumpUser.Trim();
        var jumpInfo = BuildConnectionInfo(profile.jumpHost, profile.jumpPort, jumpUser, profile);
        var jumpClient = new SshClient(jumpInfo);
        jumpClient.Connect();

        var localPort = GetFreeTcpPort();
        var forward = new ForwardedPortLocal("127.0.0.1", (uint)localPort, profile.targetHost, (uint)profile.targetPort);
        jumpClient.AddForwardedPort(forward);
        forward.Start();

        var targetInfo = BuildConnectionInfo("127.0.0.1", localPort, profile.TargetUserOrDefault, profile);
        return new SshConnectionContext(targetInfo, jumpClient, forward);
    }

    public static SshClient CreateConnectedSshClient(SshProfile profile, out SshConnectionContext context)
    {
        context = CreateContext(profile);
        var client = new SshClient(context.ConnectionInfo);
        client.Connect();
        return client;
    }

    public static SftpClient CreateConnectedSftpClient(SshProfile profile, out SshConnectionContext context)
    {
        context = CreateContext(profile);
        var client = new SftpClient(context.ConnectionInfo);
        client.Connect();
        return client;
    }

    private static ConnectionInfo BuildConnectionInfo(string host, int port, string user, SshProfile profile)
    {
        var methods = new List<AuthenticationMethod>();
        var identityFile = Environment.ExpandEnvironmentVariables(profile.identityFile.Trim());
        if (identityFile.StartsWith("~", StringComparison.Ordinal))
        {
            identityFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), identityFile[1..].TrimStart('\\', '/'));
        }

        if (!string.IsNullOrWhiteSpace(identityFile) && File.Exists(identityFile))
        {
            try
            {
                methods.Add(new PrivateKeyAuthenticationMethod(user, new PrivateKeyFile(identityFile)));
            }
            catch
            {
                // Fall back to password if the key cannot be loaded.
            }
        }

        if (!string.IsNullOrEmpty(profile.sshPassword))
        {
            methods.Add(new PasswordAuthenticationMethod(user, profile.sshPassword));
        }

        if (methods.Count == 0)
        {
            methods.Add(new PasswordAuthenticationMethod(user, ""));
        }

        return new ConnectionInfo(host.Trim(), port, user, methods.ToArray())
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
    }

    private static int GetFreeTcpPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}

public sealed class TunnelSession : IDisposable
{
    private SshConnectionContext? _context;
    private SshClient? _client;
    private ForwardedPortLocal? _forward;

    public bool IsConnected => _client?.IsConnected == true && _forward?.IsStarted == true;

    public void Connect(SshProfile profile)
    {
        Disconnect();
        _client = SshConnectionFactory.CreateConnectedSshClient(profile, out _context);
        var boundHost = profile.allowRemoteLocalPortAccess ? "0.0.0.0" : "127.0.0.1";
        _forward = new ForwardedPortLocal(boundHost, (uint)profile.localPort, profile.remoteHost, (uint)profile.remotePort);
        _client.AddForwardedPort(_forward);
        _forward.Start();
    }

    public void Disconnect()
    {
        try { _forward?.Stop(); } catch { }
        try { _forward?.Dispose(); } catch { }
        _forward = null;
        try
        {
            if (_client?.IsConnected == true) _client.Disconnect();
        }
        catch { }
        try { _client?.Dispose(); } catch { }
        _client = null;
        try { _context?.Dispose(); } catch { }
        _context = null;
    }

    public void Dispose() => Disconnect();
}

public sealed class TunnelManager : IDisposable
{
    private readonly Dictionary<string, TunnelSession> _sessions = [];

    public bool IsConnected(string profileId) =>
        _sessions.TryGetValue(profileId, out var session) && session.IsConnected;

    public void Connect(SshProfile profile)
    {
        if (!_sessions.TryGetValue(profile.id, out var session))
        {
            session = new TunnelSession();
            _sessions[profile.id] = session;
        }
        session.Connect(profile);
    }

    public void Disconnect(string profileId)
    {
        if (_sessions.Remove(profileId, out var session))
        {
            session.Dispose();
        }
    }

    public void Dispose()
    {
        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
        _sessions.Clear();
    }
}

public sealed class TerminalSession : IDisposable
{
    private SshConnectionContext? _context;
    private SshClient? _client;
    private ShellStream? _stream;
    private CancellationTokenSource? _cts;
    private readonly StringBuilder _inputLine = new();
    private string _currentDirectory = "";

    public event Action<string>? OutputReceived;
    public event Action<string>? DirectoryChanged;
    public event Action<string>? StateChanged;

    public bool IsConnected => _client?.IsConnected == true && _stream is not null;
    public string CurrentDirectory => _currentDirectory;

    public async Task ConnectAsync(SshProfile profile, int columns = 100, int rows = 30)
    {
        Disconnect();
        StateChanged?.Invoke("连接中");
        await Task.Run(() =>
        {
            _client = SshConnectionFactory.CreateConnectedSshClient(profile, out _context);
            _stream = _client.CreateShellStream("xterm-256color", (uint)columns, (uint)rows, 0, 0, 4096);
            _cts = new CancellationTokenSource();
            _ = Task.Run(() => ReadLoop(_cts.Token));
            TryProbeInitialDirectory(profile);
        });
        StateChanged?.Invoke("已连接");
    }

    public void Send(string text)
    {
        if (_stream is null)
        {
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(text);
        _stream.Write(bytes, 0, bytes.Length);
        _stream.Flush();
        TrackInput(text);
    }

    public void Resize(int columns, int rows)
    {
        // SSH.NET terminal resize support varies by package version; xterm still resizes locally.
    }

    public void Disconnect()
    {
        try { _cts?.Cancel(); } catch { }
        try { _stream?.Dispose(); } catch { }
        _stream = null;
        try
        {
            if (_client?.IsConnected == true) _client.Disconnect();
        }
        catch { }
        try { _client?.Dispose(); } catch { }
        _client = null;
        try { _context?.Dispose(); } catch { }
        _context = null;
        _cts = null;
        StateChanged?.Invoke("未连接");
    }

    public void Dispose() => Disconnect();

    private void ReadLoop(CancellationToken token)
    {
        var buffer = new byte[8192];
        while (!token.IsCancellationRequested && _stream is not null)
        {
            try
            {
                var count = _stream.Read(buffer, 0, buffer.Length);
                if (count <= 0)
                {
                    Thread.Sleep(20);
                    continue;
                }

                var text = Encoding.UTF8.GetString(buffer, 0, count);
                ParseOsc7(text);
                OutputReceived?.Invoke(text);
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                StateChanged?.Invoke($"连接断开：{ex.Message}");
                break;
            }
        }
    }

    private void TrackInput(string text)
    {
        foreach (var c in text)
        {
            if (c is '\r' or '\n')
            {
                var line = _inputLine.ToString();
                _inputLine.Clear();
                TrackCommand(line);
                continue;
            }

            if (c == '\b' || c == '\u007f')
            {
                if (_inputLine.Length > 0) _inputLine.Length--;
                continue;
            }

            if (!char.IsControl(c))
            {
                _inputLine.Append(c);
            }
        }
    }

    private void TrackCommand(string line)
    {
        var match = Regex.Match(line.Trim(), @"^cd(?:\s+(?<path>.+))?$");
        if (!match.Success)
        {
            return;
        }

        var rawPath = match.Groups["path"].Success ? match.Groups["path"].Value.Trim() : "~";
        if (string.IsNullOrWhiteSpace(rawPath))
        {
            rawPath = "~";
        }

        var cleaned = ShellEscaper.Unquote(rawPath);
        if (cleaned == "-")
        {
            return;
        }

        var next = cleaned.StartsWith("/", StringComparison.Ordinal)
            ? cleaned
            : PosixPath.Join(string.IsNullOrWhiteSpace(_currentDirectory) ? "~" : _currentDirectory, cleaned);
        next = PosixPath.Normalize(next);
        if (!string.IsNullOrWhiteSpace(next))
        {
            SetDirectory(next);
        }
    }

    private void ParseOsc7(string text)
    {
        foreach (Match match in Regex.Matches(text, @"\x1b\]7;file://[^\x07]*(?<path>/[^\x07]*)\x07"))
        {
            var value = Uri.UnescapeDataString(match.Groups["path"].Value);
            SetDirectory(value);
        }
    }

    private void TryProbeInitialDirectory(SshProfile profile)
    {
        try
        {
            using var context = SshConnectionFactory.CreateContext(profile);
            using var client = new SshClient(context.ConnectionInfo);
            client.Connect();
            var command = client.RunCommand("printf '%s' \"$PWD\"");
            if (!string.IsNullOrWhiteSpace(command.Result))
            {
                SetDirectory(command.Result.Trim());
            }
        }
        catch
        {
            // Directory sync still works through typed cd commands and OSC 7.
        }
    }

    private void SetDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        _currentDirectory = path.Trim();
        DirectoryChanged?.Invoke(_currentDirectory);
    }
}

public sealed class SftpEntry
{
    public string Name { get; init; } = "";
    public string Path { get; init; } = "";
    public bool IsDirectory { get; init; }
    public bool IsLink { get; init; }
    public long SizeBytes { get; init; }
    public DateTime Modified { get; init; }
    public string Type => IsDirectory ? "文件夹" : IsLink ? "链接" : "文件";
    public string SizeText => IsDirectory ? "--" : FormatBytes(SizeBytes);
    public string Icon => IsDirectory ? "\uE8B7" : "\uE8A5";

    public static SftpEntry FromLocal(FileSystemInfo info)
    {
        var directory = info is DirectoryInfo;
        var length = info is FileInfo file ? file.Length : 0;
        return new SftpEntry
        {
            Name = info.Name,
            Path = info.FullName,
            IsDirectory = directory,
            SizeBytes = length,
            Modified = info.LastWriteTime
        };
    }

    public static SftpEntry FromRemote(SftpFile file)
    {
        return new SftpEntry
        {
            Name = file.Name,
            Path = file.FullName,
            IsDirectory = file.IsDirectory,
            IsLink = file.IsSymbolicLink,
            SizeBytes = file.Length,
            Modified = file.LastWriteTime
        };
    }

    private static string FormatBytes(long bytes)
    {
        double size = bytes;
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        foreach (var unit in units)
        {
            if (size < 1024 || unit == "TB")
            {
                return unit == "B" ? $"{size:0} {unit}" : $"{size:0.0} {unit}";
            }
            size /= 1024;
        }
        return $"{bytes} B";
    }
}

public sealed class SftpSession : IDisposable
{
    private readonly SshProfile _profile;
    private readonly SshConnectionContext _context;
    private readonly SftpClient _client;

    public SftpSession(SshProfile profile)
    {
        _profile = profile.Clone();
        _client = SshConnectionFactory.CreateConnectedSftpClient(profile, out _context);
    }

    public bool IsConnected => _client.IsConnected;

    public IReadOnlyList<SftpEntry> List(string path)
    {
        var normalized = PosixPath.Normalize(string.IsNullOrWhiteSpace(path) ? "." : path);
        return _client.ListDirectory(normalized)
            .Where(file => file.Name is not "." and not "..")
            .Select(file => SftpEntry.FromRemote(file))
            .OrderByDescending(entry => entry.IsDirectory)
            .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    public void CreateDirectory(string path)
    {
        if (!_client.Exists(path))
        {
            _client.CreateDirectory(path);
        }
    }

    public void Rename(string oldPath, string newPath) => _client.RenameFile(oldPath, newPath);

    public void Delete(string path, bool directory)
    {
        if (directory)
        {
            DeleteDirectoryRecursive(path);
        }
        else
        {
            _client.DeleteFile(path);
        }
    }

    public void Download(string remotePath, string localDirectory, bool directory)
    {
        Directory.CreateDirectory(localDirectory);
        if (directory)
        {
            DownloadDirectory(remotePath, Path.Combine(localDirectory, PosixPath.BaseName(remotePath)));
            return;
        }

        using var stream = File.Create(Path.Combine(localDirectory, PosixPath.BaseName(remotePath)));
        _client.DownloadFile(remotePath, stream);
    }

    public void Upload(string localPath, string remoteDirectory)
    {
        if (Directory.Exists(localPath))
        {
            UploadDirectory(localPath, PosixPath.Join(remoteDirectory, Path.GetFileName(localPath)));
            return;
        }

        using var stream = File.OpenRead(localPath);
        _client.UploadFile(stream, PosixPath.Join(remoteDirectory, Path.GetFileName(localPath)), true);
    }

    public string DownloadToTemporary(string remotePath, bool directory)
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "417ssh-transfer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        Download(remotePath, tempRoot, directory);
        return Path.Combine(tempRoot, PosixPath.BaseName(remotePath));
    }

    public void CopyRemote(string sourcePath, string targetDirectory)
    {
        using var context = SshConnectionFactory.CreateContext(_profile);
        using var client = new SshClient(context.ConnectionInfo);
        client.Connect();
        var script = $"cp -a -- {ShellEscaper.Quote(sourcePath)} {ShellEscaper.Quote(targetDirectory.TrimEnd('/') + "/")}";
        var result = client.RunCommand(script);
        if (result.ExitStatus != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(result.Error) ? "远程复制失败" : result.Error.Trim());
        }
    }

    public void Chmod(string path, string mode)
    {
        using var context = SshConnectionFactory.CreateContext(_profile);
        using var client = new SshClient(context.ConnectionInfo);
        client.Connect();
        var script = $"chmod {ShellEscaper.Quote(mode)} -- {ShellEscaper.Quote(path)}";
        var result = client.RunCommand(script);
        if (result.ExitStatus != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(result.Error) ? "权限修改失败" : result.Error.Trim());
        }
    }

    public void Dispose()
    {
        try
        {
            if (_client.IsConnected) _client.Disconnect();
        }
        catch { }
        try { _client.Dispose(); } catch { }
        try { _context.Dispose(); } catch { }
    }

    private void UploadDirectory(string localDirectory, string remoteDirectory)
    {
        CreateDirectory(remoteDirectory);
        foreach (var file in Directory.GetFiles(localDirectory))
        {
            Upload(file, remoteDirectory);
        }
        foreach (var directory in Directory.GetDirectories(localDirectory))
        {
            UploadDirectory(directory, PosixPath.Join(remoteDirectory, Path.GetFileName(directory)));
        }
    }

    private void DownloadDirectory(string remoteDirectory, string localDirectory)
    {
        Directory.CreateDirectory(localDirectory);
        foreach (var entry in List(remoteDirectory))
        {
            if (entry.IsDirectory)
            {
                DownloadDirectory(entry.Path, Path.Combine(localDirectory, entry.Name));
            }
            else
            {
                using var stream = File.Create(Path.Combine(localDirectory, entry.Name));
                _client.DownloadFile(entry.Path, stream);
            }
        }
    }

    private void DeleteDirectoryRecursive(string path)
    {
        foreach (var entry in List(path))
        {
            if (entry.IsDirectory)
            {
                DeleteDirectoryRecursive(entry.Path);
            }
            else
            {
                _client.DeleteFile(entry.Path);
            }
        }
        _client.DeleteDirectory(path);
    }
}

public sealed class SftpSessionCache : IDisposable
{
    private readonly Dictionary<string, SftpSession> _sessions = [];

    public SftpSession Get(SshProfile profile)
    {
        if (_sessions.TryGetValue(profile.id, out var session) && session.IsConnected)
        {
            return session;
        }

        session?.Dispose();
        session = new SftpSession(profile);
        _sessions[profile.id] = session;
        return session;
    }

    public void Disconnect(string profileId)
    {
        if (_sessions.Remove(profileId, out var session))
        {
            session.Dispose();
        }
    }

    public void Dispose()
    {
        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
        _sessions.Clear();
    }
}

public static class LocalFileService
{
    public static IReadOnlyList<SftpEntry> List(string path)
    {
        var normalized = string.IsNullOrWhiteSpace(path)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : Environment.ExpandEnvironmentVariables(path);
        var directory = new DirectoryInfo(normalized);
        if (!directory.Exists)
        {
            throw new DirectoryNotFoundException(normalized);
        }

        return directory.EnumerateFileSystemInfos()
            .Where(info => (info.Attributes & FileAttributes.Hidden) == 0)
            .Select(SftpEntry.FromLocal)
            .OrderByDescending(entry => entry.IsDirectory)
            .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }
}

public static class PosixPath
{
    public static string Normalize(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return ".";
        }

        path = path.Replace('\\', '/');
        var absolute = path.StartsWith("/", StringComparison.Ordinal);
        var tilde = path.StartsWith("~", StringComparison.Ordinal);
        var parts = new List<string>();
        foreach (var part in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".")
            {
                continue;
            }
            if (part == "..")
            {
                if (parts.Count > 0 && parts[^1] != "~")
                {
                    parts.RemoveAt(parts.Count - 1);
                }
                continue;
            }
            parts.Add(part);
        }

        var prefix = absolute ? "/" : tilde ? "" : "";
        var joined = string.Join("/", parts);
        if (absolute)
        {
            return "/" + joined;
        }
        return string.IsNullOrWhiteSpace(joined) ? (absolute ? "/" : ".") : prefix + joined;
    }

    public static string Join(string parent, string child)
    {
        if (string.IsNullOrWhiteSpace(child))
        {
            return Normalize(parent);
        }
        if (child.StartsWith("/", StringComparison.Ordinal) || child.StartsWith("~", StringComparison.Ordinal))
        {
            return Normalize(child);
        }
        if (string.IsNullOrWhiteSpace(parent) || parent == ".")
        {
            return Normalize(child);
        }
        return Normalize(parent.TrimEnd('/') + "/" + child);
    }

    public static string Parent(string path)
    {
        path = Normalize(path);
        if (path == "/" || path == "." || path == "~")
        {
            return path;
        }
        var index = path.TrimEnd('/').LastIndexOf('/');
        if (index <= 0)
        {
            return path.StartsWith("/", StringComparison.Ordinal) ? "/" : ".";
        }
        return path[..index];
    }

    public static string BaseName(string path)
    {
        path = Normalize(path).TrimEnd('/');
        var index = path.LastIndexOf('/');
        return index >= 0 ? path[(index + 1)..] : path;
    }
}

public static class ShellEscaper
{
    public static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "''";
        }

        if (Regex.IsMatch(value, @"^[A-Za-z0-9_@%+=:,./~-]+$"))
        {
            return value;
        }

        return "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    }

    public static string Unquote(string value)
    {
        value = value.Trim();
        if ((value.StartsWith("'", StringComparison.Ordinal) && value.EndsWith("'", StringComparison.Ordinal)) ||
            (value.StartsWith("\"", StringComparison.Ordinal) && value.EndsWith("\"", StringComparison.Ordinal)))
        {
            return value[1..^1];
        }
        return value.Replace("\\ ", " ", StringComparison.Ordinal);
    }
}

public sealed class ReleaseAsset
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("browser_download_url")] public string Url { get; set; } = "";
}

public sealed class GitHubRelease
{
    [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
    [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
    [JsonPropertyName("assets")] public List<ReleaseAsset> Assets { get; set; } = [];
}

public sealed class UpdateService
{
    private const string LatestReleaseUrl = "https://api.github.com/repos/Vonfre/417ssh/releases/latest";

    public async Task<GitHubRelease> CheckLatestAsync(CancellationToken cancellationToken)
    {
        using var client = CreateHttpClient();
        using var stream = await client.GetStreamAsync(LatestReleaseUrl, cancellationToken);
        var release = await JsonSerializer.DeserializeAsync<GitHubRelease>(stream, cancellationToken: cancellationToken);
        if (release is null)
        {
            throw new InvalidOperationException("无法读取 GitHub Releases");
        }
        return release;
    }

    public async Task<string> DownloadWindowsZipAsync(GitHubRelease release, IProgress<double>? progress, CancellationToken cancellationToken)
    {
        var asset = release.Assets.FirstOrDefault(item => item.Name.EndsWith("-win-portable.zip", StringComparison.OrdinalIgnoreCase));
        if (asset is null)
        {
            throw new InvalidOperationException("最新 Release 中没有 Windows portable zip");
        }

        Directory.CreateDirectory(AppPaths.UpdatesDirectory);
        var destination = Path.Combine(AppPaths.UpdatesDirectory, asset.Name);
        using var client = CreateHttpClient();
        using var response = await client.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength ?? -1;
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
        await using var output = File.Create(destination);
        var buffer = new byte[1024 * 128];
        long readTotal = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                break;
            }
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            readTotal += read;
            if (total > 0)
            {
                progress?.Report(readTotal / (double)total);
            }
        }
        progress?.Report(1);
        return destination;
    }

    public void InstallAfterExit(string zipPath)
    {
        if (!File.Exists(zipPath))
        {
            throw new FileNotFoundException("更新包不存在", zipPath);
        }

        var exePath = Process.GetCurrentProcess().MainModule?.FileName;
        if (string.IsNullOrWhiteSpace(exePath))
        {
            throw new InvalidOperationException("无法定位当前程序路径");
        }

        var appDir = Path.GetDirectoryName(exePath)!;
        var scriptPath = Path.Combine(AppPaths.UpdatesDirectory, "install-417ssh-update.ps1");
        var logPath = Path.Combine(AppPaths.UpdatesDirectory, "install.log");
        var script = BuildInstallerScript();
        Directory.CreateDirectory(AppPaths.UpdatesDirectory);
        File.WriteAllText(scriptPath, script, new UTF8Encoding(false));

        var args = string.Join(" ", new[]
        {
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden",
            "-File", QuotePowerShell(scriptPath),
            "-Zip", QuotePowerShell(zipPath),
            "-InstallDir", QuotePowerShell(appDir),
            "-ExeName", QuotePowerShell(Path.GetFileName(exePath)),
            "-ParentPid", Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture),
            "-Log", QuotePowerShell(logPath)
        });

        Process.Start(new ProcessStartInfo("powershell.exe", args)
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden
        });

        Application.Current.Shutdown();
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("417ssh-native-windows");
        return client;
    }

    private static string QuotePowerShell(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private static string BuildInstallerScript()
    {
        return """
param(
  [Parameter(Mandatory=$true)][string]$Zip,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][string]$ExeName,
  [Parameter(Mandatory=$true)][int]$ParentPid,
  [Parameter(Mandatory=$true)][string]$Log
)
$ErrorActionPreference = "Stop"
function Write-Log([string]$Message) {
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -Path $Log -Value "$stamp $Message"
}
try {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) | Out-Null
  Write-Log "Waiting for parent process $ParentPid"
  try { Wait-Process -Id $ParentPid -Timeout 60 } catch {}

  $stage = Join-Path (Split-Path -Parent $Zip) ("stage-" + [guid]::NewGuid().ToString("N"))
  $backup = Join-Path (Split-Path -Parent $Zip) ("backup-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -Path $Zip -DestinationPath $stage -Force

  $source = Get-ChildItem -Path $stage -Recurse -Filter $ExeName | Select-Object -First 1
  if ($null -eq $source) { throw "Cannot find $ExeName in update package" }
  $sourceDir = Split-Path -Parent $source.FullName

  Write-Log "Backing up $InstallDir to $backup"
  Copy-Item -Path $InstallDir -Destination $backup -Recurse -Force
  Write-Log "Replacing files from $sourceDir"
  Copy-Item -Path (Join-Path $sourceDir "*") -Destination $InstallDir -Recurse -Force
  Write-Log "Starting updated app"
  Start-Process -FilePath (Join-Path $InstallDir $ExeName)
  Write-Log "Update completed"
} catch {
  Write-Log ("Update failed: " + $_.Exception.Message)
  try {
    if ((Test-Path $backup) -and (Test-Path $InstallDir)) {
      Copy-Item -Path (Join-Path $backup "*") -Destination $InstallDir -Recurse -Force
      Start-Process -FilePath (Join-Path $InstallDir $ExeName)
    }
  } catch {
    Write-Log ("Rollback failed: " + $_.Exception.Message)
  }
}
""";
    }
}
