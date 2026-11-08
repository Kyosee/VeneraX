import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'windows_updater_strings.dart';

enum UpdateStage {
  waiting,
  preparing,
  downloading,
  extracting,
  backingUp,
  installing,
  rollingBack,
  restarting,
  complete,
  failed,
}

class WindowsUpdaterWindow {
  WindowsUpdaterWindow({
    this.restart = false,
    this.iconPath,
    this.themeColors,
    this.onError,
  });

  final bool restart;
  final String? iconPath;
  final String? themeColors;
  final void Function(String)? onError;
  Process? _process;
  Directory? _directory;
  File? _stateFile;
  Timer? _retryWrite;
  String? _pendingState;
  int _writeAttempts = 0;
  final _ready = Completer<void>();
  Completer<Map<String, dynamic>>? _capture;
  final _lastUpdate = Stopwatch()..start();
  UpdateStage? _stage;

  Future<void> show({String? locale}) async {
    try {
      _directory = await Directory.systemTemp.createTemp('venera_update_ui_');
      _stateFile = File('${_directory!.path}/state.json');
      final script = File('${_directory!.path}/window.ps1');
      // Windows PowerShell 5.1 needs a BOM for non-ASCII script text.
      await script.writeAsString(
        '\uFEFF\$translations = @\'\n${jsonEncode(windowsUpdaterStrings)}\n\'@ | ConvertFrom-Json\n'
        '\$options = @\'\n${jsonEncode({'locale': locale, 'restart': restart, 'iconPath': iconPath, 'colors': decodeUpdaterColors(themeColors), 'statePath': _stateFile!.path, 'parentPid': pid})}\n\'@ | ConvertFrom-Json\n'
        '$_windowScript',
      );
      final process = _process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]);
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'ready' && !_ready.isCompleted) _ready.complete();
            if (line.startsWith('captured:')) {
              _capture?.complete(
                jsonDecode(line.substring(9)) as Map<String, dynamic>,
              );
            }
          }, onError: (Object error) => onError?.call('$error'));
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (text) => onError?.call(text),
            onError: (Object error) => onError?.call('$error'),
          );
      await Future.any([
        _ready.future,
        process.exitCode.then((code) {
          throw StateError('Progress window exited before ready ($code).');
        }),
      ]).timeout(const Duration(seconds: 15));
    } catch (error) {
      onError?.call('Cannot show progress window: $error');
      await close();
    }
  }

  void update(UpdateStage stage, {int? completed, int? total, String? unit}) {
    if (_stage == stage &&
        _lastUpdate.elapsedMilliseconds < 100 &&
        (total == null || completed != total)) {
      return;
    }
    _stage = stage;
    _lastUpdate.reset();
    _send({
      'stage': stage.name,
      'completed': completed,
      'total': total,
      'unit': unit,
    });
  }

  Future<Map<String, dynamic>> capture(String path) async {
    if (_process == null) throw StateError('Progress window is unavailable.');
    _capture = Completer<Map<String, dynamic>>();
    _send({'capture': File(path).absolute.path});
    final result = await _capture!.future.timeout(const Duration(seconds: 10));
    _capture = null;
    return result;
  }

  Future<void> waitForClose() async => await _process?.exitCode;

  void _send(Map<String, Object?> message) {
    _retryWrite?.cancel();
    _pendingState = jsonEncode(message);
    _writeAttempts = 0;
    _writeState();
  }

  void _writeState() {
    try {
      _stateFile?.writeAsStringSync(_pendingState!);
    } catch (error) {
      if (++_writeAttempts < 5) {
        _retryWrite = Timer(const Duration(milliseconds: 100), _writeState);
      } else {
        onError?.call('Cannot update progress window: $error');
        _process?.kill();
      }
    }
  }

  Future<void> close() async {
    final process = _process;
    if (process != null) {
      _send({'close': true});
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill();
      }
      _process = null;
    }
    try {
      await _directory?.delete(recursive: true);
    } catch (_) {
      // A failed UI cleanup must not fail the update.
    }
    _directory = null;
    _stateFile = null;
    _retryWrite?.cancel();
  }
}

Map<String, String> decodeUpdaterColors(String? encoded) {
  if (encoded == null) return {};
  try {
    final values = jsonDecode(utf8.decode(base64Url.decode(encoded)));
    if (values is! Map) return {};
    return {
      for (final key in const [
        'primary',
        'onPrimary',
        'primaryContainer',
        'onPrimaryContainer',
        'surface',
        'surfaceContainerLow',
        'onSurface',
        'onSurfaceVariant',
        'outlineVariant',
        'error',
      ])
        if (values[key] is String &&
            RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(values[key]))
          key: values[key] as String,
    };
  } catch (_) {
    return {};
  }
}

const _windowScript = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName PresentationFramework
$locale = $options.locale
if (-not $locale) { $locale = [Globalization.CultureInfo]::CurrentUICulture.Name }
$locale = $locale.Replace('_', '-').ToLowerInvariant()
if ($locale -match '^zh') {
  if ($locale -match 'hant|-(tw|hk|mo)(-|$)') { $locale = 'zh-Hant' }
  else { $locale = 'zh-Hans' }
} else { $locale = $locale.Split('-')[0] }
$text = $translations.$locale
if (-not $text) { $text = $translations.en }

$palette = @{
  primary='#FF39618F'; onPrimary='#FFFFFFFF'; primaryContainer='#FFD3E3FF'; onPrimaryContainer='#FF001C39';
  surface='#FFF8F9FF'; surfaceContainerLow='#FFF1F3FA'; onSurface='#FF191C20';
  onSurfaceVariant='#FF43474E'; outlineVariant='#FFC3C6CF'; error='#FFBA1A1A'
}
foreach ($property in $options.colors.PSObject.Properties) { $palette[$property.Name] = $property.Value }

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" FontFamily="Segoe UI, Microsoft YaHei UI"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Border x:Name="Surface" Background="{surface}" BorderBrush="{outlineVariant}"
          BorderThickness="1" CornerRadius="16" Padding="30,20,30,26">
    <StackPanel>
      <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,26">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="34" Height="34" CornerRadius="10" Background="{primaryContainer}" Margin="0,0,10,0">
            <Grid>
              <TextBlock x:Name="FallbackIcon" Text="V" Foreground="{onPrimaryContainer}" FontSize="23" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Image x:Name="AppIcon" Width="30" Height="30"/>
            </Grid>
          </Border>
          <TextBlock Text="VeneraX" FontWeight="SemiBold" FontSize="16" Foreground="{onSurface}" VerticalAlignment="Center"/>
        </StackPanel>
        <Button x:Name="CloseButton" HorizontalAlignment="Right" Width="30" Height="30" IsEnabled="False"
                Background="Transparent" BorderThickness="0" Foreground="{onSurfaceVariant}" FontFamily="Segoe MDL2 Assets" FontSize="11" Content="&#xE8BB;">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="ButtonBackground" Background="Transparent" CornerRadius="6"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.25"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBackground" Property="Background" Value="{primaryContainer}"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Grid>
      <TextBlock x:Name="Title" FontSize="27" FontWeight="SemiBold" Foreground="{onSurface}" TextWrapping="Wrap"/>
      <TextBlock x:Name="Subtitle" FontSize="13" Foreground="{onSurfaceVariant}" Margin="0,8,0,26" TextWrapping="Wrap"/>
      <Border Background="{surfaceContainerLow}" BorderBrush="{outlineVariant}" BorderThickness="1" CornerRadius="12" Padding="22,20">
        <StackPanel>
          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center" Margin="0,0,14,0">
              <TextBlock x:Name="ProgressLabel" Foreground="{onSurfaceVariant}" FontSize="11" Margin="0,0,0,7"/>
              <TextBlock x:Name="Status" Foreground="{onSurface}" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
            </StackPanel>
            <TextBlock x:Name="Percent" Grid.Column="1" Text="—" Foreground="{primary}" FontSize="32" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </Grid>
          <ProgressBar x:Name="Progress" Height="7" Minimum="0" Maximum="100" Foreground="{primary}" Background="{outlineVariant}" IsIndeterminate="True" BorderThickness="0">
            <ProgressBar.Template>
              <ControlTemplate TargetType="ProgressBar">
                <Grid ClipToBounds="True">
                  <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="3.5"/>
                  <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="3.5" HorizontalAlignment="Left"/>
                </Grid>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsIndeterminate" Value="True">
                    <Setter TargetName="PART_Indicator" Property="Opacity" Value="0.4"/>
                    <Trigger.EnterActions>
                      <BeginStoryboard x:Name="WorkingAnimation"><Storyboard><DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity" From="0.25" To="0.7" Duration="0:0:0.9" AutoReverse="True" RepeatBehavior="Forever"/></Storyboard></BeginStoryboard>
                    </Trigger.EnterActions>
                    <Trigger.ExitActions><RemoveStoryboard BeginStoryboardName="WorkingAnimation"/></Trigger.ExitActions>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </ProgressBar.Template>
          </ProgressBar>
          <TextBlock x:Name="Detail" FontSize="12" Foreground="{onSurfaceVariant}" Margin="0,11,0,0"/>
        </StackPanel>
      </Border>
      <UniformGrid x:Name="Steps" Columns="4" Margin="2,24,2,24"/>
      <Border Height="1" Background="{outlineVariant}" Margin="0,0,0,17"/>
      <TextBlock x:Name="Hint" Foreground="{onSurfaceVariant}" FontSize="12" TextWrapping="Wrap" LineHeight="19"/>
    </StackPanel>
  </Border>
</Window>
'@
foreach ($key in $palette.Keys) { $xamlText = $xamlText.Replace('{' + $key + '}', $palette[$key]) }
[xml]$xaml = $xamlText
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
foreach ($name in @('Surface','Header','CloseButton','AppIcon','FallbackIcon','Title','Subtitle','ProgressLabel','Status','Percent','Progress','Detail','Steps','Hint')) {
  Set-Variable -Name $name -Value $window.FindName($name)
}
$window.Title = $text.windowTitle
$Title.Text = $text.title
$Subtitle.Text = $text.subtitle
$ProgressLabel.Text = $text.stageProgress
$Status.Text = $text.waiting
$Detail.Text = $text.working
$Hint.Text = $text.keepOpen
if ($options.restart) { $Hint.Text = $text.restartHint }
[Windows.Automation.AutomationProperties]::SetName($CloseButton, $text.close)
$CloseButton.ToolTip = $text.close
if ($options.iconPath -and (Test-Path -LiteralPath $options.iconPath)) {
  try {
    $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($options.iconPath)
    $bitmap.EndInit()
    $bitmap.Freeze()
    $AppIcon.Source = $bitmap
    $window.Icon = $bitmap
    $FallbackIcon.Visibility = 'Collapsed'
  } catch {}
}

$stepDots = @()
$stepLabels = @()
foreach ($key in @('prepareStep', 'extractStep', 'installStep', 'finishStep')) {
  $panel = [Windows.Controls.StackPanel]::new()
  $panel.Orientation = 'Horizontal'
  $dot = [Windows.Controls.TextBlock]::new()
  $dot.Text = [string]($stepDots.Count + 1)
  $dot.FontSize = 11
  $dot.FontWeight = 'SemiBold'
  $dot.HorizontalAlignment = 'Center'
  $dot.VerticalAlignment = 'Center'
  $circle = [Windows.Controls.Border]::new()
  $circle.Width = 22
  $circle.Height = 22
  $circle.CornerRadius = 11
  $circle.Child = $dot
  $label = [Windows.Controls.TextBlock]::new()
  $label.Text = $text.$key
  $label.FontSize = 12
  $label.Margin = '7,0,0,0'
  $label.VerticalAlignment = 'Center'
  $panel.Children.Add($circle) | Out-Null
  $panel.Children.Add($label) | Out-Null
  $Steps.Children.Add($panel) | Out-Null
  $stepDots += $circle
  $stepLabels += $label
}
function Set-Step([int]$active) {
  for ($i = 0; $i -lt 4; $i++) {
    $stepDots[$i].Background = $palette.surfaceContainerLow
    $stepDots[$i].Child.Foreground = $palette.onSurfaceVariant
    $stepLabels[$i].Foreground = $palette.onSurfaceVariant
    $stepDots[$i].Child.Text = [string]($i + 1)
    if ($i -le $active) {
      $stepDots[$i].Background = $palette.primaryContainer
      $stepDots[$i].Child.Foreground = $palette.onPrimaryContainer
      $stepLabels[$i].Foreground = $palette.primary
    }
    if ($i -lt $active) { $stepDots[$i].Child.Text = [char]0x2713 }
  }
}
Set-Step 0
$stageSteps = @{ waiting=0; preparing=0; downloading=0; extracting=1; backingUp=2; installing=2; rollingBack=2; restarting=3; complete=4 }
$script:allowClose = $false
$Header.Add_MouseLeftButtonDown({ if ($_.OriginalSource -ne $CloseButton) { $window.DragMove() } })
$CloseButton.Add_Click({ $window.Close() })
$window.Add_Closing({ if (-not $script:allowClose) { $_.Cancel = $true } })
$window.Add_ContentRendered({ [Console]::Out.WriteLine('ready'); [Console]::Out.Flush() })

function Update-State($state) {
  if ($state.close) { $script:allowClose = $true; $window.Close(); return }
  if ($state.capture) {
    $window.UpdateLayout()
    $render = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Surface.ActualWidth, [int]$Surface.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($Surface)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $output = [IO.File]::Create($state.capture)
    try { $encoder.Save($output) } finally { $output.Dispose() }
    $snapshot = @{
      locale=$locale; title=$Title.Text; windowTitle=$window.Title; status=$Status.Text; detail=$Detail.Text;
      percent=$Percent.Text; value=$Progress.Value; indeterminate=$Progress.IsIndeterminate;
      surface=$Surface.Background.ToString(); primary=$Progress.Foreground.ToString();
      closeEnabled=$CloseButton.IsEnabled; hint=$Hint.Text
    } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine('captured:' + $snapshot)
    [Console]::Out.Flush()
    return
  }
  if (-not $state.stage) { return }
  $Status.Text = $text.($state.stage)
  if ($stageSteps.ContainsKey($state.stage)) { Set-Step $stageSteps[$state.stage] }
  $known = $null -ne $state.completed -and $null -ne $state.total -and $state.total -gt 0
  $Progress.IsIndeterminate = -not $known
  $Percent.Text = '—'
  $Detail.Text = $text.working
  if ($known) {
    $value = [Math]::Min(100, [Math]::Max(0, 100.0 * $state.completed / $state.total))
    $Progress.Value = $value
    $Percent.Text = '{0:0}%' -f [Math]::Floor($value)
    if ($state.unit -eq 'files') { $Detail.Text = '{0} / {1} {2}' -f $state.completed, $state.total, $text.files }
    else { $Detail.Text = '{0:0.0} / {1:0.0} MB' -f ($state.completed / 1MB), ($state.total / 1MB) }
  } elseif ($null -ne $state.completed -and $state.unit -eq 'bytes') {
    $Detail.Text = '{0:0.0} MB' -f ($state.completed / 1MB)
  }
  if ($state.stage -in @('complete', 'failed')) {
    $script:allowClose = $true
    $CloseButton.IsEnabled = $true
    $Title.Text = $text.($state.stage)
    $Progress.IsIndeterminate = $false
    if ($state.stage -eq 'complete') { $Progress.Value = 100; $Percent.Text = '100%'; $Detail.Text = $text.complete }
    else {
      $Hint.Text = $text.failedHint
      $Detail.Text = $text.failed
      $Subtitle.Text = $text.failedHint
      $Progress.Value = 0
      $Progress.Foreground = $palette.error
      $Percent.Foreground = $palette.error
    }
  }
}

# Read the latest state without blocking the dispatcher on a process pipe.
$script:lastState = ''
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
  try {
    if (-not (Get-Process -Id $options.parentPid -ErrorAction SilentlyContinue)) {
      $script:allowClose = $true; $window.Close(); return
    }
    try {
      $stream = [IO.FileStream]::new($options.statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
      try { $line = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if (-not $line -or $line -eq $script:lastState) { return }
      $state = $line | ConvertFrom-Json
    } catch { return }
    Update-State $state
    $script:lastState = $line
  } catch {
    [Console]::Error.WriteLine($_.ToString())
    $script:allowClose = $true
    $window.Close()
  }
})
$timer.Start()
try { $window.ShowDialog() | Out-Null }
finally { $timer.Stop() }
''';
