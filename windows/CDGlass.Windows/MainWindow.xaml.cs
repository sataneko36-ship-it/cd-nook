using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using System.Windows.Interop;
using System.Windows.Shapes;
using Color = System.Windows.Media.Color;
using Path = System.IO.Path;

namespace CDGlass.Windows;

public partial class MainWindow : Window
{
    readonly MusicLibrary library = new();
    AudioPlayer? player;
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(75) };
    readonly DispatcherTimer animation = new() { Interval = TimeSpan.FromMilliseconds(40) };
    readonly DispatcherTimer discTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly HashSet<string> selected = [];
    readonly Dictionary<string, string> coverOverrides = new(StringComparer.OrdinalIgnoreCase);
    string? openedStack, returnStack, returnAlbum, focusedAlbum, currentFolder;
    string? ignoredDiscSignature;
    AudioDisc? currentDisc;
    bool grouped = true, seeking, isWall, particles = true, discScanRunning, listVisible = true;
    bool isFullscreen, chromeHidden, menuOpen;
    WindowState savedWindowState;
    WindowStyle savedWindowStyle;
    ResizeMode savedResizeMode;
    DateTime lastActivity = DateTime.UtcNow;
    int missingDiscTicks;
    int style, theme = 4, backgroundMode = 2, blurLevel = 1;
    Color? coverColor;
    readonly BitmapSource?[] blurredCovers = new BitmapSource?[3];
    double animationSeconds, priorVolume = 75;
    readonly Random random = new(29);
    readonly List<(Ellipse dot, double speed, double phase)> stars = [];
    readonly string preferencesPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Settings.json");
    readonly string coverIndexPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CD Glass", "Covers.json");
    static readonly string[] styleNames = ["空灵", "CD 唱机", "卡带", "像素屏"];
    static readonly string[] themeNames = ["深空灰", "海雾蓝", "暮光紫", "暖茶棕", "白粉色", "玻璃浅绿", "奶油白", "晴空浅蓝"];
    static readonly (string Base, string Glow, string Ink, string Accent, string Body)[] palettes = [
        ("#0E1013", "#354152", "#F4F5F7", "#C9D3E0", "#2B2E34"),
        ("#07151E", "#0D4C66", "#EEF7FB", "#7CC6EC", "#1B3544"),
        ("#130C1E", "#4C2C72", "#F7F1FC", "#C4A3F6", "#2F2443"),
        ("#18100A", "#5C3B1E", "#FBF4EC", "#E3B17B", "#3B2A1D"),
        ("#FBF2F5", "#F8C3D4", "#3B2A31", "#E0809F", "#F6D9E3"),
        ("#ECF6F1", "#BDE7D2", "#22342E", "#3FA578", "#D2EADE"),
        ("#FAF6EC", "#F5E1BA", "#39332A", "#BE9146", "#F0E6CF"),
        ("#ECF4FB", "#C2DCF6", "#21303D", "#3F8CCF", "#D4E6F5")];

    public MainWindow()
    {
        InitializeComponent();
        InputMethod.SetIsInputMethodEnabled(this, false);
        LoadSettings(); ApplyTheme();
        try { player = new AudioPlayer(); player.Changed += () => Dispatcher.BeginInvoke(RefreshPlayer); player.Finished += () => Dispatcher.BeginInvoke(() => player?.Next()); player.Volume = (int)Volume.Value; }
        catch (Exception e) { ShowToast("VLC 音频引擎启动失败：" + e.Message); }
        tick.Tick += (_, _) => UpdateClock(); tick.Start();
        discTimer.Tick += async (_, _) => await CheckDisc(); discTimer.Start();
        animation.Tick += (_, _) => { animationSeconds += .04; Hero.Seconds = animationSeconds; Hero.Advance(.04); Hero.InvalidateVisual(); AnimateParticles(); }; animation.Start();
        PreviewMouseMove += (_, e) => { RegisterActivity(); if(seeking&&Progress.IsMouseCaptured)Progress.Value=1000*Math.Clamp(e.GetPosition(Progress).X/Math.Max(1,Progress.ActualWidth),0,1); };
        PreviewMouseDown += (_, _) => RegisterActivity();
        SizeChanged += (_, _) => RefreshLayout();
        DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || paths.Length == 0) return;
            var path = paths[0];
            if (CurrentCoverKey != null && new[] { ".jpg", ".jpeg", ".png", ".webp", ".bmp" }.Contains(Path.GetExtension(path).ToLowerInvariant()))
                try { SaveCover(File.ReadAllBytes(path), Path.GetExtension(path).ToLowerInvariant()); }
                catch (Exception ex) { ShowToast("无法使用拖入的封面：" + ex.Message); }
            else OpenPath(path);
        };
        Hero.MouseLeftButtonDown += (_, e) =>
        {
            if (style != 3 || player == null) return;
            var screen = Hero.PixelScreenBounds(); var point = e.GetPosition(Hero);
            if (!screen.Contains(point)) return;
            double x = (point.X-screen.X)/screen.Width*300, y=(point.Y-screen.Y)/screen.Height*195;
            if (player.Tracks.Count == 0) { OpenFolder_Click(this,e); return; }
            if (Hero.PixelPage==1) Hero.PixelPage=0;
            else if (y>=164 && y<=179) player.Seek((x-7)/286);
            else if (x<105 && y>18 && y<110) Hero.PixelPage=1;
            Hero.InvalidateVisual();
        };
        BurstItems.MouseLeftButtonUp+=(_,e)=>{if(e.OriginalSource==BurstItems)WallBack_Click(this,e);};
        Hero.MouseWheel += (_,e) => { if(style==3){Volume.Value=Math.Clamp(Volume.Value+Math.Sign(e.Delta)*5,0,100);e.Handled=true;} };
        PreviewKeyDown += HandleKey;
        Closed += (_, _) => { tick.Stop(); animation.Stop(); discTimer.Stop(); SaveSettings(); player?.Dispose(); };
        RefreshPlayer(); RenderWall();
        Loaded += async (_, _) =>
        {
            var args = Environment.GetCommandLineArgs();
            if (args.Length > 3 && args[1] == "--visual-qa") { await CaptureVisualQA(args[2],args[3]); return; }
            if (args.Length > 2 && args[1] == "--scan" && Directory.Exists(args[2]))
            {
                try { await library.ScanAsync(args[2]); RenderWall(); ShowWall(); }
                catch (Exception ex) { ShowToast("扫描失败：" + ex.Message); }
            }
            else if (args.Length > 1) OpenPath(args[1]);
        };
    }
    async Task CaptureVisualQA(string folder, string output)
    {
        try {
            Directory.CreateDirectory(output);
            Content=null; Stage.Width=1500;Stage.Height=1000;
            double dpi=VisualTreeHelper.GetDpi(this).DpiScaleX;
            using var captureSource=new HwndSource(new HwndSourceParameters("CD Glass visual QA") {Width=(int)(1500*dpi),Height=(int)(1000*dpi),PositionX=-10000,PositionY=-10000,WindowStyle=unchecked((int)0x80000000)});
            captureSource.RootVisual=Stage;Stage.Measure(new Size(1500,1000));Stage.Arrange(new Rect(0,0,1500,1000));Stage.UpdateLayout();
            theme=4;backgroundMode=1;blurLevel=1;listVisible=true;OpenPath(folder);
            await Task.Delay(1000);if(player?.IsPlaying==true)player.Toggle();
            for(int face=0;face<4;face++) {
                style=face;ApplyTheme();RefreshPlayer();
                await Task.Delay(1100);Stage.Measure(new Size(1500,1000));Stage.Arrange(new Rect(0,0,1500,1000));Stage.UpdateLayout();
                var bitmap=new RenderTargetBitmap(1500,1000,96,96,PixelFormats.Pbgra32);bitmap.Render(Stage);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var stream=File.Create(Path.Combine(output,$"windows-{face}.png"));encoder.Save(stream);
            }
            library.Albums.Clear();
            for(int i=0;i<3;i++)library.Albums.Add(new Album{Id=$"visual-{i}",SourcePath=folder,Title=i==0?"Glass Sessions":$"Glass Sessions {i+1}",Artist="CD Glass Demo",SeriesKey=i<2?"glass":"night",SeriesTitle=i<2?"Glass Sessions":"Nightfall",CoverPath=Path.Combine(folder,"cover.jpg"),TrackCount=3});
            style=0;ApplyTheme();openedStack=null;RenderWall();ShowWall();await Task.Delay(1200);Stage.UpdateLayout();
            void SnapWall(string name){var bitmap=new RenderTargetBitmap(1500,1000,96,96,PixelFormats.Pbgra32);bitmap.Render(Stage);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(Path.Combine(output,name+".png"));encoder.Save(stream);}
            SnapWall("windows-wall");openedStack="glass";RenderWall();await Task.Delay(600);Stage.UpdateLayout();SnapWall("windows-stack");
            var returnCard=BurstItems.Children.OfType<Border>().First(c=>c.Tag as string=="visual-0");
            PlayAlbum(library.Albums[0],returnCard);await Task.Delay(600);
            if(isWall||returnStack!="glass"||returnAlbum!="visual-0")throw new InvalidOperationException("Stack-to-player navigation failed");
            WallButton_Click(this,new RoutedEventArgs());await Task.Delay(700);
            if(!isWall||openedStack!="glass"||focusedAlbum!="visual-0")throw new InvalidOperationException("First wall-button return did not restore the same stack/CD");
            File.WriteAllText(Path.Combine(output,"result.txt"),$"Rendered four live WPF faces; tracks={player?.Tracks.Count}, canvas={Stage.ActualWidth}x{Stage.ActualHeight}, title={SoloTitle.Text}; first return restored the same stack/CD.");
        } catch(Exception error) {File.WriteAllText(Path.Combine(output,"error.txt"),error.ToString());}
        Close();
    }
    static Color C(string hex) => (Color)ColorConverter.ConvertFromString(hex);
    static Color Mix(Color a, Color b, double amount) => Color.FromRgb(
        (byte)Math.Round(a.R * (1 - amount) + b.R * amount),
        (byte)Math.Round(a.G * (1 - amount) + b.G * amount),
        (byte)Math.Round(a.B * (1 - amount) + b.B * amount));
    void ApplyTheme()
    {
        var p = palettes[theme];
        RefreshBackground();
        Foreground = new SolidColorBrush(C(p.Ink));
        WallPage.Background = new RadialGradientBrush(C(p.Glow), C(p.Base)){Center=new Point(.3,.2),GradientOrigin=new Point(.3,.2),RadiusX=.95,RadiusY=1.1};
        Hero.Accent = C(p.Accent); Hero.Body = C(p.Body); Hero.Ink = C(p.Ink); Hero.PlayerStyle = style;
        RefreshLayout();
        foreach (var b in Descendants<Button>(Stage)) b.Foreground = Foreground;
        foreach (var t in Descendants<TextBlock>(Stage)) t.Foreground = Foreground;
        foreach (var slider in new[] {Progress,Volume}) { slider.Foreground = new SolidColorBrush(Mix(C(p.Ink),C(p.Accent),p.Base=="#FBF2F5"?.45:.3)); slider.Background=new SolidColorBrush(Color.FromArgb(theme>=4?(byte)31:(byte)41,C(p.Ink).R,C(p.Ink).G,C(p.Ink).B)); }
        Hero.InvalidateVisual(); CreateParticles();
    }
    double layoutUnit = .74;
    static void Place(FrameworkElement view, double x, double y, double width, double height)
    {
        Canvas.SetLeft(view, Math.Round(x)); Canvas.SetTop(view, Math.Round(y));
        view.Width = Math.Max(0, Math.Round(width)); view.Height = Math.Max(0, Math.Round(height));
    }
    void RefreshLayout()
    {
        double w = Stage.ActualWidth, h = Stage.ActualHeight;
        if (w < 100 || h < 100) return;
        bool session = player?.Tracks.Count > 0, list = listVisible && session, pixel = style == 3;
        double u = layoutUnit = Math.Clamp(Math.Min(h / 1000, w / 1500), .74, 1.4);
        Hero.ThemeIndex = theme;
        double margin = Math.Round(36*u), top = Math.Round(64*u), right = w-margin;
        double cy = h-Math.Round(22*u)-40*u, progressY = cy-40*u-Math.Round(12*u), gap = Math.Round(18*u);
        double listWidth = Math.Round(250*u), listHeight = Math.Round((26+Math.Min(6,player?.Tracks.Count ?? 0)*(style==2?30:29)+4)*u);
        var listRect = new Rect(right-listWidth, (style==1 ? progressY-22*u : cy+26*u)-listHeight, listWidth,listHeight);
        DetailsPanel.Visibility = list ? Visibility.Visible : Visibility.Collapsed;
        Place(DetailsPanel,listRect.X,listRect.Y,listWidth,listHeight);
        ListButton.FontSize = Math.Round(10*u);
        foreach(var row in TrackList.Children.OfType<Button>()) { row.Height = Math.Round((style==2?30:29)*u); row.FontSize = Math.Round((style==3?12.5:13.5)*u); }
        double center = style==1 ? right-14*u-64*u : w/2;
        Place(TopBar,0,0,w,80); Place(WallButton,Math.Round(30*u)+20-24,18,48,48);Place(SettingsButton,w-Math.Round(30*u)-20-24,18,48,48);
        Place(PlaybackFooter,0,0,w,h);
        Place(PlaybackActions,center-104*u,cy-40*u,208*u,80*u);
        Place(PreviousButton,11*u,11*u,58*u,58*u);Place(PlayButton,64*u,0,80*u,80*u);Place(NextButton,139*u,11*u,58*u,58*u);
        foreach(var button in new[]{PreviousButton,NextButton}) if(button.Content is Glyph glyph){glyph.Width=glyph.Height=Math.Round(18*u);}
        PlayGlyph.Width=PlayGlyph.Height=Math.Round(27*u);
        double volumeWidth=134*u+2, volumeX=style==1 ? center-64*u-29*u-22*u-volumeWidth : margin;
        Place(VolumeActions,volumeX,cy-20*u,volumeWidth,40*u);Place(MuteButton,0,0,40*u,40*u);Place(Volume,40*u+2,20*u-9,92*u,18);
        double progressWidth = style==1 ? Math.Min(430*u,right-volumeX) : Math.Min(560*u,w*.42);
        double progressX = style==1 ? right-progressWidth : w/2-progressWidth/2;
        double label=56*u, timeGap=10*u, bar=Math.Max(80,progressWidth-2*(label+timeGap));
        Place(Elapsed,progressX,progressY-8,label,18);Place(Progress,progressX+label+timeGap,progressY-9,bar,18);Place(Remaining,progressX+label+timeGap*2+bar,progressY-8,label,18);
        Elapsed.FontSize=Remaining.FontSize=Math.Round(11.5*u);
        PlaybackActions.Visibility=VolumeActions.Visibility=session?Visibility.Visible:Visibility.Collapsed;
        Elapsed.Visibility=Remaining.Visibility=Progress.Visibility=session&&!pixel?Visibility.Visible:Visibility.Collapsed;
        OpenActions.Visibility=session?Visibility.Collapsed:Visibility.Visible;
        SoloInfo.Visibility=pixel?Visibility.Collapsed:Visibility.Visible;
        SoloIndex.Visibility=session?Visibility.Visible:Visibility.Collapsed;
        SoloTitle.FontFamily=new FontFamily(style==0?"Georgia, SimSun":style==2?"Segoe UI, Microsoft YaHei UI":"Segoe UI");
        SoloTitle.FontSize=Math.Round((style==2?24:30)*u);SoloTitle.FontWeight=style==2?FontWeights.Medium:FontWeights.Normal;
        SoloArtist.FontSize=Math.Round(13.5*u);SoloIndex.FontSize=Math.Round(11.5*u);
        SoloTitle.Text=session?player!.Current?.Name??"—":"放入一张 CD";
        SoloArtist.Text=session?AlbumTitle.Text+(AlbumArtist.Text.Length>0&&AlbumArtist.Text!="虚拟 CD"?"  ·  "+AlbumArtist.Text:""):"或把音乐文件夹拖进窗口";
        SoloIndex.Text=$"{(player?.Index??0)+1}  /  {player?.Tracks.Count??0}";
        SoloInfo.Height=double.NaN;
        double textWidth=Math.Min(w*.62,760*u);
        if(list&&style!=1)textWidth=Math.Min(textWidth,2*(listRect.Left-gap-w/2));
        textWidth=Math.Max(120,textWidth);
        SoloInfo.Width=textWidth;SoloInfo.Measure(new Size(textWidth,double.PositiveInfinity));
        double textHeight=pixel?0:SoloInfo.DesiredSize.Height, heroGap=pixel?0:34*u, buttons=session?0:70*u;
        double aspect=pixel?300d/195:Hero.Aspect;
        Rect hero;
        if(style==1)
        {
            textWidth=session?Math.Min(w*.4,Math.Max(220*u,volumeX-margin-60*u)):Math.Min(w*.5,620*u);
            SoloInfo.Width=textWidth;SoloInfo.Measure(new Size(textWidth,double.PositiveInfinity));textHeight=SoloInfo.DesiredSize.Height;
            double textTop=(session?cy+40*u-10*u:h-40*u)-textHeight-(session?0:66*u);
            Place(SoloInfo,margin,textTop,textWidth,textHeight);
            SoloTitle.TextAlignment=SoloArtist.TextAlignment=SoloIndex.TextAlignment=TextAlignment.Left;
            double bottom=Math.Min(textTop,session?progressY-12:h)-26*u;
            double heroHeight=Math.Min(Math.Min(bottom-top,h*.7),w*.84/aspect);
            if(list&&top+(bottom-top-heroHeight)/2+heroHeight>listRect.Top-gap)heroHeight=Math.Min(heroHeight,2*(listRect.Left-gap-w/2)/aspect);
            heroHeight=Math.Max(40,heroHeight);hero=new Rect(w/2-heroHeight*aspect/2,top+(bottom-top-heroHeight)/2,heroHeight*aspect,heroHeight);
        }
        else
        {
            SoloTitle.TextAlignment=SoloArtist.TextAlignment=SoloIndex.TextAlignment=TextAlignment.Center;
            double floor=session?(pixel?cy-40*u:progressY-12)-28*u:h-48*u;
            Rect Fit(double bottom,double maxWidth)
            {
                double available=Math.Max(40,bottom-top-textHeight-heroGap-buttons), hh,hw;
                if(style==2){hw=Math.Min(Math.Min(w*.64,maxWidth),available*aspect);hh=hw/aspect;}
                else if(pixel){hh=Math.Min(available,Math.Min(w*.84,maxWidth)/aspect);hw=hh*aspect;}
                else {hh=Math.Min(Math.Min(available,Math.Min(h*.62,w*.44)),maxWidth);hw=hh;}
                return new Rect(w/2-hw/2,top+(bottom-top-hh-heroGap-textHeight-buttons)/2,hw,hh);
            }
            hero=Fit(floor,w);
            var safety=hero;safety.Inflate(gap,gap);
            if(list&&safety.IntersectsWith(listRect)) {
                var narrow=Fit(floor,Math.Max(40,2*(listRect.Left-gap-w/2)));
                var lifted=Fit(Math.Min(floor,listRect.Top-gap+textHeight+heroGap),w);
                hero=narrow.Width>=lifted.Width?narrow:lifted;
            }
            if(pixel) {
                double side=Math.Max(Math.Round(36*u),w*.05), floorY=session?cy-40*u-Math.Round(18*u):h-Math.Round(48*u)-buttons;
                var limits=new Rect(side,top+Math.Round(6*u),w-side*2,Math.Max(1,floorY-top-Math.Round(6*u)));
                var avoid=listRect;avoid.Inflate(gap,gap);
                double scale=VisualTreeHelper.GetDpi(this).DpiScaleX;
                int largest=(int)Math.Floor(Math.Min(hero.Width*scale/300,hero.Height*scale/195));
                bool fitted=false;
                for(int pitch=largest;pitch>=3;pitch--) {
                    double lcdWidth=300*pitch/scale, hw=lcdWidth*1.17,hh=lcdWidth*.903;
                    if(hw>limits.Width||hh>limits.Height)continue;
                    var device=new Rect(w/2-hw/2,limits.Top+(limits.Height-hh)/2,hw,hh);
                    if(list&&device.IntersectsWith(avoid)) {
                        double lift=device.Bottom-avoid.Top;
                        if(device.Top-lift<limits.Top)continue;
                        device.Y-=lift;
                    }
                    hero=device;fitted=true;break;
                }
                if(!fitted)hero=new Rect(w/2-70.2,limits.Top,140.4,108.36);
            }
            Place(SoloInfo,w/2-textWidth/2,hero.Bottom+heroGap,textWidth,textHeight);
        }
        Place(HeroHost,hero.X,hero.Y,hero.Width,hero.Height);
        LayoutWall(w);
        if(!session) {
            double actionY=pixel?hero.Bottom+26*u:Canvas.GetTop(SoloInfo)+textHeight+26*u;
            Place(OpenActions,style==1?margin-14*u:w/2-210*u,actionY,420*u,44*u);
        }
    }
    void AnimatePlayerEntrance()
    {
        Hero.RenderTransformOrigin = new Point(.5, .5);
        var scale = new ScaleTransform(); Hero.RenderTransform = scale;
        var duration = TimeSpan.FromMilliseconds(420);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(.94, 1, duration) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(.94, 1, duration) { EasingFunction = ease });
        Hero.BeginAnimation(OpacityProperty, new DoubleAnimation(.35, 1, duration));
    }
    void ListButton_Click(object sender, RoutedEventArgs e)
    {
        if (player?.Tracks.Count is not > 0) return;
        listVisible = !listVisible; RefreshLayout(); AnimatePlayerEntrance(); SaveSettings();
    }
    void Fullscreen_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();
    void ToggleFullscreen()
    {
        RegisterActivity();
        if (!isFullscreen)
        {
            savedWindowState = WindowState; savedWindowStyle = WindowStyle; savedResizeMode = ResizeMode;
            WindowState = WindowState.Normal; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
            WindowState = WindowState.Maximized; isFullscreen = true;
        }
        else
        {
            WindowState = WindowState.Normal; WindowStyle = savedWindowStyle; ResizeMode = savedResizeMode;
            WindowState = savedWindowState; isFullscreen = false;
        }
        RefreshLayout();
    }
    void RegisterActivity()
    {
        lastActivity = DateTime.UtcNow;
        SetChromeHidden(false);
    }
    void SetChromeHidden(bool hidden)
    {
        if (chromeHidden == hidden) return;
        chromeHidden = hidden;
        foreach (var bar in new[] { TopBar, PlaybackFooter })
        {
            bar.IsHitTestVisible = !hidden;
            bar.BeginAnimation(OpacityProperty, new DoubleAnimation(hidden ? 0 : 1, TimeSpan.FromMilliseconds(280)));
        }
        Cursor = hidden ? Cursors.None : null;
    }
    void HandleKey(object sender, KeyEventArgs e)
    {
        RegisterActivity();
        if (e.OriginalSource is System.Windows.Controls.Primitives.TextBoxBase) return;
        var key = e.Key == Key.ImeProcessed ? e.ImeProcessedKey : e.Key;
        bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        bool control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (key == Key.F11 || key == Key.F && !control) ToggleFullscreen();
        else if (key == Key.Escape)
        {
            if (isWall) { if (openedStack != null) { openedStack = focusedAlbum = null; RenderWall(); } else ShowPlayer(); }
            else if (isFullscreen) ToggleFullscreen();
            else return;
        }
        else if (key == Key.B && control) WallButton_Click(sender, e);
        else if (key == Key.O && control) OpenFolder_Click(sender, e);
        else if (key == Key.W && control) EndSession(true);
        else if (key == Key.L && !control) ListButton_Click(sender, e);
        else if (Keyboard.FocusedElement is Slider) return;
        else if (key == Key.Space) player?.Toggle();
        else if (key == Key.Right) { if (shift) player?.SeekBy(10_000); else player?.Next(); }
        else if (key == Key.Left) { if (shift) player?.SeekBy(-10_000); else player?.Previous(); }
        else if (key == Key.Up) Volume.Value = Math.Min(100, Volume.Value + 5);
        else if (key == Key.Down) Volume.Value = Math.Max(0, Volume.Value - 5);
        else return;
        e.Handled = true;
    }
    void RefreshBackground()
    {
        var p = palettes[theme];
        var baseColor = C(p.Base);
        var tint = backgroundMode == 2 && coverColor is { } sampled ? sampled : C(p.Glow);
        BaseColor.Color = backgroundMode == 2 && coverColor != null ? Mix(baseColor, tint, .18) : baseColor;
        GlowColor.Color = backgroundMode == 2 && coverColor != null ? Mix(C(p.Glow), tint, .58) : C(p.Glow);
        bool showCover = backgroundMode == 1 && Hero.Cover != null;
        BackgroundCover.Source = showCover ? blurredCovers[blurLevel] ??= VisualArtwork.BlurBackground(Hero.Cover!, blurLevel) : null;
        double veil = (theme >= 4 ? new[] { .56, .36, .20 } : new[] { .50, .34, .20 })[blurLevel];
        BackgroundVeil.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(veil * 255), baseColor.R, baseColor.G, baseColor.B));
        Color TransparentBase(double opacity)=>Color.FromArgb((byte)Math.Round(opacity*255),baseColor.R,baseColor.G,baseColor.B);
        double edge=showCover?new[]{.15,.45,.62}[blurLevel]:0;
        BackgroundScrim.Background=new LinearGradientBrush(new GradientStopCollection{new(TransparentBase(edge),0),new(TransparentBase(edge*.55),.14),new(TransparentBase(0),.62),new(TransparentBase(edge*.7),1)},new Point(.5,0),new Point(.5,1));
        BackgroundVignette.Background=new RadialGradientBrush(new GradientStopCollection{new(TransparentBase(0),0),new(TransparentBase(0),.5),new(TransparentBase(theme>=4?.55:.7),1)}){RadiusX=.58,RadiusY=.62};
        var duration = TimeSpan.FromMilliseconds(420);
        BackgroundCover.BeginAnimation(OpacityProperty, new DoubleAnimation(showCover ? 1 : 0, duration));
        BackgroundVeil.BeginAnimation(OpacityProperty, new DoubleAnimation(showCover ? 1 : 0, duration));
    }
    static Color? AverageCover(BitmapSource source)
    {
        try
        {
            var small = new TransformedBitmap(source, new ScaleTransform(24d / source.PixelWidth, 24d / source.PixelHeight));
            var pixels = new FormatConvertedBitmap(small, PixelFormats.Bgra32, null, 0);
            int stride = pixels.PixelWidth * 4;
            var bytes = new byte[stride * pixels.PixelHeight]; pixels.CopyPixels(bytes, stride, 0);
            long red = 0, green = 0, blue = 0, count = 0;
            for (int i = 0; i < bytes.Length; i += 4)
            {
                int alpha = bytes[i + 3];
                blue += bytes[i] * alpha; green += bytes[i + 1] * alpha; red += bytes[i + 2] * alpha; count += alpha;
            }
            return count == 0 ? null : Color.FromRgb((byte)(red / count), (byte)(green / count), (byte)(blue / count));
        }
        catch { return null; }
    }
    static IEnumerable<T> Descendants<T>(DependencyObject node) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
        {
            var child = VisualTreeHelper.GetChild(node, i);
            if (child is T match) yield return match;
            foreach (var grandchild in Descendants<T>(child)) yield return grandchild;
        }
    }
    void CreateParticles()
    {
        Particles.Children.Clear(); stars.Clear();
        if (!particles) return;
        for (int i = 0; i < 38; i++)
        {
            var size = 1 + random.NextDouble() * 2;
            var dot = new System.Windows.Shapes.Ellipse { Width = size, Height = size, Fill = new SolidColorBrush(C(palettes[theme].Accent)), Opacity = .09 + random.NextDouble() * .19 };
            Particles.Children.Add(dot); stars.Add((dot, .2 + random.NextDouble() * .7, random.NextDouble() * 100));
        }
    }
    void AnimateParticles()
    {
        var w = Math.Max(1, Stage.ActualWidth); var h = Math.Max(1, Stage.ActualHeight);
        for (int i = 0; i < stars.Count; i++)
        {
            var (dot, speed, phase) = stars[i];
            Canvas.SetLeft(dot, ((i * 197 + phase * 29) % 1000) / 1000 * w + Math.Sin(animationSeconds * speed + phase) * 5);
            Canvas.SetTop(dot, ((i * 151 + phase * 19) % 1000) / 1000 * h + Math.Cos(animationSeconds * speed + phase) * 7);
        }
    }
    void LoadSettings()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(preferencesPath)); var r = doc.RootElement;
            style = Math.Clamp(r.GetProperty("style").GetInt32(), 0, 3); theme = Math.Clamp(r.GetProperty("theme").GetInt32(), 0, 7);
            if (r.TryGetProperty("grouped", out var v)) grouped = v.GetBoolean();
            if (r.TryGetProperty("particles", out v)) particles = v.GetBoolean();
            if (r.TryGetProperty("volume", out v)) Volume.Value = v.GetDouble();
            if (r.TryGetProperty("backgroundMode", out v)) backgroundMode = Math.Clamp(v.GetInt32(), 0, 2);
            if (r.TryGetProperty("blurLevel", out v)) blurLevel = Math.Clamp(v.GetInt32(), 0, 2);
            if (r.TryGetProperty("listVisible", out v)) listVisible = v.GetBoolean();
        }
        catch { }
        try { foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(coverIndexPath)) ?? []) coverOverrides[pair.Key] = pair.Value; }
        catch { }
    }
    void SaveSettings()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(preferencesPath)!);
        File.WriteAllText(preferencesPath, JsonSerializer.Serialize(new { style, theme, grouped, particles, backgroundMode, blurLevel, listVisible, volume = Volume.Value }));
    }
    void RefreshPlayer()
    {
        RefreshLayout();
        Hero.Playing = player?.IsPlaying ?? false;
        Hero.HasSession = player?.Tracks.Count > 0;
        Hero.Track = player?.Current?.Name ?? "WELCOME";
        Hero.Artist = AlbumArtist.Text;
        Hero.TrackPosition = (player?.Index ?? 0) + 1;
        Hero.TrackTotal = player?.Tracks.Count ?? 0;
        DiscNumber.Text = player?.Current is { } current ? $"DISC / {player!.Index + 1:00}  ·  {player.Tracks.Count:00}" : "NO DISC / 00";
        TrackCountLabel.Text = $"{player?.Tracks.Count ?? 0:00}";
        PlayGlyph.Kind = player?.IsPlaying == true ? "pause" : "play";
        TrackList.Children.Clear();
        if (player?.Tracks.Count > 0)
        {
            for (int i = 0; i < player.Tracks.Count; i++)
            {
                int n = i; double u=layoutUnit;
                var row = new Button { HorizontalContentAlignment=HorizontalAlignment.Stretch,Height=Math.Round((style==2?30:29)*u),Padding=new Thickness(6,0,2,0),
                    Background=i==player.Index?new RadialGradientBrush(Color.FromArgb(28,Hero.Accent.R,Hero.Accent.G,Hero.Accent.B),Colors.Transparent):Brushes.Transparent };
                var grid=new Grid();grid.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(32*u)});grid.ColumnDefinitions.Add(new ColumnDefinition());
                var number=new TextBlock{Text=i==player.Index?"▂▅▃":$"{i+1}.",Opacity=i==player.Index?.8:.6,FontSize=Math.Round(11*u),Foreground=i==player.Index?new SolidColorBrush(Hero.Accent):Foreground,VerticalAlignment=VerticalAlignment.Center};
                var title=new TextBlock{Text=player.Tracks[i].Name,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=Math.Round((style==3?12.5:13.5)*u),FontWeight=i==player.Index?FontWeights.Medium:FontWeights.Normal,FontFamily=new FontFamily(style==2?"Segoe UI, Microsoft YaHei UI":style==3?"Consolas":"Segoe UI"),Foreground=Foreground,Opacity=i==player.Index?1:.75,VerticalAlignment=VerticalAlignment.Center};
                Grid.SetColumn(title,1);grid.Children.Add(number);grid.Children.Add(title);row.Content=grid;
                row.Click += (_, _) => player?.Play(n); TrackList.Children.Add(row);
            }
        }
        else TrackList.Children.Add(new TextBlock { Text = "唱片正在等你。", Margin = new Thickness(14), Opacity = .55 });
        Hero.InvalidateVisual();
    }
    void UpdateClock()
    {
        if (player == null) return;
        var length = player.Length; var time = Math.Clamp(player.Time, 0, Math.Max(0, length));
        Elapsed.Text = TimeSpan.FromMilliseconds(time).ToString(@"m\:ss");
        Remaining.Text = "−" + TimeSpan.FromMilliseconds(Math.Max(0, length - time)).ToString(@"m\:ss");
        if (!seeking) Progress.Value = length > 0 ? 1000 * time / length : 0;
        if (player.Current is { EndMs: > 0 } track && track.EndMs > track.StartMs && time >= length - 80) player.Next();
        Hero.Playing = player.IsPlaying;
        Hero.ElapsedMs = time;
        Hero.LengthMs = length;
        Hero.Artist = AlbumArtist.Text;
        Hero.Album = AlbumTitle.Text;
        PlayGlyph.Kind = player.IsPlaying ? "pause" : "play";
        SoloTitle.Text = player.Tracks.Count > 0 ? player.Current?.Name ?? "—" : "放入一张 CD";
        SoloArtist.Text = player.Tracks.Count > 0 ? AlbumTitle.Text + "  ·  " + AlbumArtist.Text : "或把音乐文件夹拖进窗口";
        SetChromeHidden(isFullscreen && player.IsPlaying && !isWall && !menuOpen && (DateTime.UtcNow - lastActivity).TotalSeconds > 3.5);
    }
    void ShowToast(string message)
    {
        ToastText.Text = message; Toast.Visibility = Visibility.Visible;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        timer.Tick += (_, _) => { timer.Stop(); Toast.Visibility = Visibility.Collapsed; }; timer.Start();
    }
    string? PickFolder(string description)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = description };
        return dialog.ShowDialog(this) == true ? dialog.FolderName : null;
    }
    void OpenPath(string path)
    {
        var folder = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
        if (folder == null || !Directory.Exists(folder)) return;
        try
        {
            if (currentDisc != null) ignoredDiscSignature = currentDisc.Signature;
            currentDisc = null;
            player?.LoadFolder(folder); currentFolder = folder;
            AlbumTitle.Text = player?.CueInfo?.Title ?? Path.GetFileName(folder);
            AlbumArtist.Text = player?.CueInfo?.Artist ?? "虚拟 CD";
            var meta = Path.Combine(folder, "album.json");
            if (File.Exists(meta)) try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(meta));
                if (doc.RootElement.TryGetProperty("title", out var value)) AlbumTitle.Text = value.GetString() ?? AlbumTitle.Text;
                if (doc.RootElement.TryGetProperty("artist", out value)) AlbumArtist.Text = value.GetString() ?? AlbumArtist.Text;
            }
            catch { }
            Hero.Album = AlbumTitle.Text; SetCover(CoverFor(folder));
            returnStack = null; returnAlbum = null; RefreshLayout(); ShowPlayer(); AnimatePlayerEntrance();
        }
        catch (Exception ex) { ShowToast("无法打开文件夹：" + ex.Message); }
    }
    string? CurrentCoverKey => currentFolder ?? (currentDisc is { } disc ? "disc:" + (disc.DiscId ?? disc.Signature) : null);
    string? OverrideCover(string? key) => key != null && coverOverrides.TryGetValue(key, out var path) && File.Exists(path) ? path : null;
    string? CoverFor(string folder) => OverrideCover(folder) ?? Artwork.Find(folder, cueName: player?.CueInfo?.CoverName);
    void SaveCover(byte[] bytes, string extension)
    {
        var coverKey = CurrentCoverKey;
        if (coverKey == null) return;
        var store = Path.Combine(Path.GetDirectoryName(coverIndexPath)!, "Covers"); Directory.CreateDirectory(store);
        var key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(coverKey)))[..16];
        var target = Path.Combine(store, key + extension); File.WriteAllBytes(target, bytes);
        coverOverrides[coverKey] = target;
        File.WriteAllText(coverIndexPath, JsonSerializer.Serialize(coverOverrides));
        if (currentFolder != null)
        {
            foreach (var album in library.Albums.Where(a => a.SourcePath.Equals(currentFolder, StringComparison.OrdinalIgnoreCase) || a.PlayablePath.Equals(currentFolder, StringComparison.OrdinalIgnoreCase))) album.CoverPath = target;
            library.Save(); RenderWall();
        }
        SetCover(target);
    }
    void ResetCover_Click(object sender, RoutedEventArgs e)
    {
        var coverKey = CurrentCoverKey;
        if (coverKey == null || !coverOverrides.Remove(coverKey)) return;
        File.WriteAllText(coverIndexPath, JsonSerializer.Serialize(coverOverrides));
        if (currentFolder != null)
        {
            var automatic = Artwork.Find(currentFolder, cueName: player?.CueInfo?.CoverName);
            foreach (var album in library.Albums.Where(a => a.SourcePath.Equals(currentFolder, StringComparison.OrdinalIgnoreCase) || a.PlayablePath.Equals(currentFolder, StringComparison.OrdinalIgnoreCase))) album.CoverPath = automatic;
            library.Save(); RenderWall(); SetCover(automatic);
        }
        else SetCover(DiscMetadata.Cached(currentDisc?.DiscId)?.CoverPath);
        ShowToast("已恢复自动封面。");
    }
    void SetCover(string? path)
    {
        Hero.Cover = null; BackgroundCover.Source = null; coverColor = null; Array.Clear(blurredCovers);
        if (path != null && File.Exists(path)) try
        {
            using var stream = File.OpenRead(path); var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
            image.DecodePixelWidth = 1800; image.StreamSource = stream; image.EndInit(); image.Freeze();
            Hero.Cover = image; BackgroundCover.Source = image; coverColor = AverageCover(image);
        } catch { }
        RefreshBackground();
        Hero.InvalidateVisual();
    }
    void OpenFolder_Click(object sender, RoutedEventArgs e) { var folder = PickFolder("选择包含音频文件的 CD 文件夹"); if (folder != null) OpenPath(folder); }
    void Demo_Click(object sender, RoutedEventArgs e)
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "Demo CD");
        if (Directory.Exists(folder)) OpenPath(folder);
        else ShowToast("内置示例 CD 文件缺失，请重新解压完整安装包。");
    }
    void EndSession_Click(object sender, RoutedEventArgs e) => EndSession(true);
    void EndSession(bool ignoreDisc)
    {
        if (ignoreDisc && currentDisc != null) ignoredDiscSignature = currentDisc.Signature;
        currentDisc = null; missingDiscTicks = 0;
        player?.EndSession(); currentFolder = returnStack = returnAlbum = null;
        AlbumTitle.Text = ""; AlbumArtist.Text = "";
        Hero.Album = "CD GLASS"; SetCover(null); ShowPlayer();
    }
    async void Optical_Click(object sender, RoutedEventArgs e)
    {
        var drives = await Task.Run(OpticalDisc.AudioDrives);
        if (drives.Count == 0) { ShowToast("没有检测到音频 CD；请检查光驱和唱片。"); return; }
        LoadDisc(drives[0]);
    }
    async Task CheckDisc()
    {
        if (discScanRunning || player == null || currentDisc == null && player.Tracks.Count > 0) return;
        discScanRunning = true;
        try
        {
            var drives = await Task.Run(OpticalDisc.AudioDrives);
            if (currentDisc != null)
            {
                if (drives.Any(d => d.Signature == currentDisc.Signature && d.Letter == currentDisc.Letter)) missingDiscTicks = 0;
                else if (++missingDiscTicks >= 2) EndSession(false);
            }
            else
            {
                if (drives.Count == 0) ignoredDiscSignature = null;
                var disc = drives.FirstOrDefault(d => d.Signature != ignoredDiscSignature);
                if (disc != null) LoadDisc(disc);
            }
        }
        catch { /* A disconnected or spinning drive will be retried on the next scan. */ }
        finally { discScanRunning = false; }
    }
    void LoadDisc(AudioDisc disc)
    {
        currentDisc = disc; ignoredDiscSignature = null; missingDiscTicks = 0; currentFolder = null;
        returnStack = returnAlbum = null;
        try { player?.LoadCd(disc.Letter, disc.Tracks); }
        catch (Exception ex) { currentDisc = null; ShowToast("无法播放音频 CD：" + ex.Message); return; }
        AlbumTitle.Text = "音频 CD"; AlbumArtist.Text = "正在识别专辑…"; Hero.Album = AlbumTitle.Text; SetCover(OverrideCover(CurrentCoverKey)); RefreshLayout(); ShowPlayer(); AnimatePlayerEntrance();
        if (disc.DiscId == null) { AlbumArtist.Text = disc.Letter + ": 光驱"; return; }
        if (DiscMetadata.Cached(disc.DiscId) is { } cached) ApplyDiscDetails(cached);
        else _ = LookupDisc(disc);
    }
    async Task LookupDisc(AudioDisc disc)
    {
        try
        {
            var details = await DiscMetadata.FetchAsync(disc.DiscId, disc.Tracks.Count);
            if (currentDisc?.Signature == disc.Signature && details != null) ApplyDiscDetails(details);
            else if (currentDisc?.Signature == disc.Signature) AlbumArtist.Text = "未找到在线资料";
        }
        catch
        {
            if (currentDisc?.Signature == disc.Signature) AlbumArtist.Text = "资料查询暂不可用";
        }
    }
    void ApplyDiscDetails(DiscDetails details)
    {
        AlbumTitle.Text = details.Title; AlbumArtist.Text = details.Artist;
        Hero.Album = details.Title; player?.ApplyTrackNames(details.Tracks);
        SetCover(OverrideCover(CurrentCoverKey) ?? details.CoverPath);
    }
    void Play_Click(object sender, RoutedEventArgs e) => player?.Toggle();
    void Previous_Click(object sender, RoutedEventArgs e) => player?.Previous();
    void Next_Click(object sender, RoutedEventArgs e) => player?.Next();
    void Mute_Click(object sender, RoutedEventArgs e) => Volume.Value = Volume.Value <= 0 ? priorVolume : 0;
    void Volume_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (e.NewValue > 0) priorVolume = e.NewValue;
        if (player != null) player.Volume = (int)e.NewValue;
        if (VolumeGlyph != null) { VolumeGlyph.Kind = e.NewValue <= 0 ? "mute" : "volume"; MuteButton.ToolTip = $"音量 {e.NewValue:0}% · ↑ / ↓"; }
    }
    void Progress_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if(e.ChangedButton!=MouseButton.Left)return;
        seeking=true;Progress.CaptureMouse();Progress.Value=1000*Math.Clamp(e.GetPosition(Progress).X/Math.Max(1,Progress.ActualWidth),0,1);e.Handled=true;
    }
    void Progress_PreviewMouseUp(object sender, MouseButtonEventArgs e) {
        if(!seeking)return;Progress.Value=1000*Math.Clamp(e.GetPosition(Progress).X/Math.Max(1,Progress.ActualWidth),0,1);seeking=false;Progress.ReleaseMouseCapture();player?.Seek(Progress.Value/1000);e.Handled=true;
    }
    void Progress_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e) { }
    void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        var open = new MenuItem { Header = "打开音乐文件夹…", InputGestureText = "Ctrl+O" }; open.Click += OpenFolder_Click; menu.Items.Add(open);
        var optical = new MenuItem { Header = "播放光驱中的 CD" }; optical.Click += Optical_Click; menu.Items.Add(optical);
        var list = new MenuItem { Header = "显示曲目列表", IsCheckable = true, IsChecked = listVisible, InputGestureText = "L" }; list.Click += ListButton_Click; menu.Items.Add(list);
        var fullscreen = new MenuItem { Header = "全屏", IsCheckable = true, IsChecked = isFullscreen, InputGestureText = "F11" }; fullscreen.Click += Fullscreen_Click; menu.Items.Add(fullscreen);
        menu.Items.Add(new Separator());
        var styles = new MenuItem { Header = "播放外观" };
        for (int i = 0; i < styleNames.Length; i++) { int n = i; var item = new MenuItem { Header = styleNames[i], IsCheckable = true, IsChecked = style == i }; item.Click += (_, _) => { style = n; ApplyTheme(); AnimatePlayerEntrance(); SaveSettings(); }; styles.Items.Add(item); }
        menu.Items.Add(styles);
        var themes = new MenuItem { Header = "配色" };
        for (int i = 0; i < themeNames.Length; i++) { int n = i; var item = new MenuItem { Header = themeNames[i], IsCheckable = true, IsChecked = theme == i }; item.Click += (_, _) => { theme = n; ApplyTheme(); RenderWall(); SaveSettings(); }; themes.Items.Add(item); }
        menu.Items.Add(themes);
        var backgrounds = new MenuItem { Header = "背景" };
        foreach (var choice in new[] { ("柔光纯色", 0, 0), ("封面柔焦 · 朦胧", 1, 0), ("封面柔焦 · 柔和", 1, 1),
                                       ("封面柔焦 · 清晰", 1, 2), ("封面取色柔焦", 2, 1) })
        {
            var item = new MenuItem { Header = choice.Item1, IsCheckable = true,
                IsChecked = backgroundMode == choice.Item2 && (choice.Item2 != 1 || blurLevel == choice.Item3) };
            item.Click += (_, _) => { backgroundMode = choice.Item2; blurLevel = choice.Item3; RefreshBackground(); SaveSettings(); };
            backgrounds.Items.Add(item);
        }
        menu.Items.Add(backgrounds);
        var dots = new MenuItem { Header = "漂浮粒子", IsCheckable = true, IsChecked = particles }; dots.Click += (_, _) => { particles = !particles; CreateParticles(); SaveSettings(); }; menu.Items.Add(dots);
        menu.Items.Add(new Separator());
        var scan = new MenuItem { Header = "扫描文件夹到专辑墙" }; scan.Click += Scan_Click; menu.Items.Add(scan);
        var demo = new MenuItem { Header = "播放内置测试 CD" }; demo.Click += Demo_Click; menu.Items.Add(demo);
        var end = new MenuItem { Header = "结束播放" }; end.Click += EndSession_Click; menu.Items.Add(end);
        var cover = new MenuItem { Header = "选择本地封面" }; cover.Click += ChooseCover_Click; menu.Items.Add(cover);
        var online = new MenuItem { Header = "在线查找封面" }; online.Click += SearchCover_Click; menu.Items.Add(online);
        var reset = new MenuItem { Header = "恢复自动封面", IsEnabled = CurrentCoverKey is { } key && coverOverrides.ContainsKey(key) };
        reset.Click += ResetCover_Click; menu.Items.Add(reset);
        menu.Opened += (_, _) => { menuOpen = true; RegisterActivity(); };
        menu.Closed += (_, _) => { menuOpen = false; RegisterActivity(); };
        menu.PlacementTarget = SettingsButton; menu.IsOpen = true;
    }
    void WallButton_Click(object sender, RoutedEventArgs e)
    {
        var source = HeroArtworkRect(); var image = Hero.Cover; var albumId = returnAlbum;
        openedStack = returnStack;
        focusedAlbum = returnAlbum;
        if (openedStack != null && !library.Albums.Any(a => a.SeriesKey == openedStack)) openedStack = null;
        RenderWall(); ShowWall();
        if (openedStack != null) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => {
            var card = BurstItems.Children.OfType<Border>().FirstOrDefault(c => c.Tag as string == albumId);
            if (card != null) FlyCover(source, CardArtworkRect(card), image);
            AnimateBurst(burstOrigin, false);
        });
        returnStack = null; returnAlbum = null;
    }
    void WallBack_Click(object sender, RoutedEventArgs e)
    {
        if (openedStack == null) { ShowPlayer(); return; }
        var center = burstOrigin;
        AnimateBurst(center, true);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(260) };
        timer.Tick += (_, _) => { timer.Stop(); openedStack = null; focusedAlbum = null; RenderWall(); }; timer.Start();
    }
    void Group_Click(object sender, RoutedEventArgs e) { grouped = !grouped; openedStack = null; RenderWall(); SaveSettings(); }
    void ShowWall()
    {
        RegisterActivity();
        isWall = true; WallPage.Visibility = Visibility.Visible;
        var anim = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(340)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        WallPage.BeginAnimation(OpacityProperty, anim);
        PlayerPage.IsHitTestVisible = false;
    }
    void ShowPlayer()
    {
        RegisterActivity();
        isWall = false; PlayerPage.IsHitTestVisible = true;
        var anim = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(300));
        anim.Completed += (_, _) => { if (!isWall) WallPage.Visibility = Visibility.Collapsed; };
        WallPage.BeginAnimation(OpacityProperty, anim);
    }
    void RenderWall()
    {
        WallItems.Children.Clear();BurstItems.Children.Clear();
        bool burst=openedStack!=null;WallScroll.Visibility=burst?Visibility.Collapsed:Visibility.Visible;BurstItems.Visibility=burst?Visibility.Visible:Visibility.Collapsed;
        foreach(var control in new FrameworkElement[]{WallHeading,WallTotal,GroupButton,WallArchive,WallScan})control.Visibility=burst?Visibility.Hidden:Visibility.Visible;
        WallTotal.Text=$"{library.Albums.Select(a=>a.SeriesKey).Distinct().Count()} 部作品  ·  {library.Albums.Count} 张唱片";
        WallHeading.Text=openedStack==null?"音乐收藏":library.Albums.FirstOrDefault(a=>a.SeriesKey==openedStack)?.SeriesTitle??"音乐收藏";
        GroupButton.Content=grouped?"▦  按番剧堆叠":"▤  展开全部";
        if (openedStack != null)
        {
            var group = library.Albums.Where(a => a.SeriesKey == openedStack).ToArray();
            WallHint.Text = group.FirstOrDefault()?.SeriesTitle ?? "CD";
            RenderBurst(group);
            return;
        }
        WallHint.Text = "选择一张 CD，让它从墙上飞入播放器。";
        if (grouped)
        {
            foreach (var group in library.Albums.GroupBy(a => a.SeriesKey).OrderBy(g => g.First().SeriesTitle)) WallItems.Children.Add(group.Count()==1?AlbumCard(group.First()):StackCard(group.ToArray()));
        }
        else foreach (var album in library.Albums) WallItems.Children.Add(AlbumCard(album));
        if (library.Albums.Count == 0) WallItems.Children.Add(new TextBlock { Text = "专辑墙还没有唱片。点击下方扫描文件夹。", Margin = new Thickness(28), FontSize = 18, Opacity = .55 });
    }
    Point burstOrigin=new(172,212);
    readonly Dictionary<string,Point> stackOrigins=[];
    double wallSide=188,wallGap=36;
    void RenderBurst(Album[] albums)
    {
        if(albums.Length==0)return;
        double w=Math.Max(780,Stage.ActualWidth),h=Math.Max(500,Stage.ActualHeight),margin=Math.Round(Math.Clamp(w*.05,28,84));
        burstOrigin=stackOrigins.TryGetValue(albums[0].SeriesKey,out var origin)?origin:new Point(margin+wallSide/2,154+Math.Round(wallSide*.135)+wallSide/2-64);
        var family=new FontFamily(style==0?"Georgia, SimSun":style==3?"Consolas":"Segoe UI");
        var title=new TextBlock{Text=albums[0].SeriesTitle,FontSize=28,FontFamily=family,Foreground=Foreground,TextAlignment=TextAlignment.Center};title.Measure(new Size(w*.42,double.PositiveInfinity));
        double titleWidth=Math.Max(250,Math.Min(w*.42,title.DesiredSize.Width+8));
        var layout=BurstLayout.Place(albums.Length,burstOrigin,new Rect(margin*.55,0,w-margin*1.1,h-64-26),new Size(titleWidth,64),albums[0].SeriesKey);
        Place(title,layout.Title.X-20,layout.Title.Y+2,layout.Title.Width+40,38);BurstItems.Children.Add(title);
        var detail=new TextBlock{Text=$"{albums.Length} 张唱片   ·   点唱片播放，点空白处收起",FontSize=11.5,Foreground=Foreground,Opacity=.6,TextAlignment=TextAlignment.Center};Place(detail,layout.Title.X-60,layout.Title.Y+48,layout.Title.Width+120,18);BurstItems.Children.Add(detail);
        for(int i=0;i<albums.Length&&i<layout.Spots.Count;i++) {
            var album=albums[i];var card=new Border{Width=layout.Side,Height=layout.Side,Tag=album.Id,Cursor=Cursors.Hand,Background=Brushes.Transparent};card.Child=Sleeve(album.CoverPath,layout.Side);
            double angle=style==3?0:BurstLayout.Tilt(album.Id);card.LayoutTransform=new RotateTransform(angle);
            var box=layout.Spots[i];Canvas.SetLeft(card,box.X-layout.Side/2);Canvas.SetTop(card,box.Y-layout.Side/2);BurstItems.Children.Add(card);
            if(album.Id==focusedAlbum)card.Effect=new DropShadowEffect{Color=Hero.Accent,BlurRadius=18,ShadowDepth=0,Opacity=.4};
            var menu=new ContextMenu();var select=new MenuItem{Header="选择归档",IsCheckable=true,IsChecked=selected.Contains(album.Id)};select.Click+=(_,_)=>{if(select.IsChecked)selected.Add(album.Id);else selected.Remove(album.Id);};menu.Items.Add(select);card.ContextMenu=menu;
            card.MouseLeftButtonUp+=(_,e)=>{e.Handled=true;PlayAlbum(album,card);};
            card.MouseEnter+=(_,_)=>{card.RenderTransformOrigin=new Point(.5,.5);card.RenderTransform=new ScaleTransform(1.07,1.07);};card.MouseLeave+=(_,_)=>card.RenderTransform=Transform.Identity;
        }
    }
    void LayoutWall(double w)
    {
        double margin=Math.Round(Math.Clamp(w*.05,28,84));
        wallGap=Math.Round(Math.Clamp(w*.024,26,46));
        int columns=Math.Max(2,(int)Math.Floor((w-2*margin+wallGap)/(176+wallGap)));
        double side=Math.Floor(Math.Min(262,(w-2*margin-(columns-1)*wallGap)/columns));
        if(Math.Abs(side-wallSide)>1){wallSide=side;RenderWall();}
        WallItems.Width=columns*(wallSide+wallGap);
        Place(WallHeader,0,0,w,154);Place(WallBack,Math.Round(30*layoutUnit)-4,18,48,48);
        Place(WallHeading,margin-1,72,w*.5,44);Place(WallTotal,margin,118,w*.5,18);
        WallHeading.FontFamily=new FontFamily(style==0?"Georgia, SimSun":style==2?"Segoe UI, Microsoft YaHei UI":style==3?"Consolas":"Segoe UI");
        WallHeading.FontSize=style==3?25:32;
        double x=w-margin;
        foreach(var button in new[]{GroupButton,WallArchive,WallScan}) {button.Width=double.NaN;button.Measure(new Size(double.PositiveInfinity,34));double width=button.DesiredSize.Width+22;Place(button,x-width,78,width,34);x-=width+4;}
    }
    WallSleeve Sleeve(string? path,double side)
    {
        BitmapSource? cover=null;
        if(path!=null&&File.Exists(path))try{var image=new BitmapImage();image.BeginInit();image.UriSource=new Uri(path);image.DecodePixelWidth=600;image.CacheOption=BitmapCacheOption.OnLoad;image.EndInit();image.Freeze();cover=image;}catch{}
        return new WallSleeve{Width=side,Height=side,PlayerStyle=style,Theme=theme,Body=C(palettes[theme].Body),Ink=C(palettes[theme].Ink),Cover=cover,
            Effect=new DropShadowEffect{Color=style==3?C(palettes[theme].Ink):Colors.Black,BlurRadius=style==3?0:style==2?Math.Max(3,side*.03):Math.Max(6,side*.07),ShadowDepth=style==3?7:side*.045,Direction=style==3?315:270,Opacity=theme>=4?.22:.5}};
    }
    UIElement StackCard(Album[] albums)
    {
        double s=wallSide,peek=Math.Round(s*.135);
        var card=new Border{Width=s,Height=peek+s+Math.Round(s*.07)+37,Margin=new Thickness(wallGap/2,0,wallGap/2,Math.Round(wallGap*.8)),Background=Brushes.Transparent,Cursor=Cursors.Hand};
        var pile=new Canvas();card.Child=pile;
        var faces=albums.OrderByDescending(a=>a.CoverPath!=null&&File.Exists(a.CoverPath)).Take(3).ToArray();
        var layers=new List<(WallSleeve sleeve,int depth)>();
        for(int depth=faces.Length-1;depth>=0;depth--) {
            var face=Sleeve(faces[depth].CoverPath,s);face.IsHitTestVisible=false;face.RenderTransformOrigin=new Point(.5,.5);Canvas.SetTop(face,peek);pile.Children.Add(face);layers.Add((face,depth));
        }
        void Pose(bool hover) {
            foreach(var(face,depth) in layers) {
                double rotation=depth==0?0:depth==1?(hover?-9:-3.1):(hover?8:3.6),scale=depth==0?(hover?1.03:1):depth==1?.95:.89;
                double tx=depth==0?0:depth==1?s*(hover?-.15:-.026):s*(hover?.15:.03),ty=depth==0?(hover?-s*.03:0):depth==1?s*(hover?-.025:-.066):s*(hover?-.05:-.118);
                var transforms=new TransformGroup();transforms.Children.Add(new ScaleTransform(scale,scale));transforms.Children.Add(new RotateTransform(style==3?0:rotation));transforms.Children.Add(new TranslateTransform(tx,ty));face.RenderTransform=transforms;
            }
        }
        Pose(false);double caption=peek+s+Math.Round(s*.07);
        var title=new TextBlock{Text=albums[0].SeriesTitle,Width=s,TextAlignment=TextAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=13,FontWeight=FontWeights.Medium,Foreground=Foreground};Canvas.SetTop(title,caption);pile.Children.Add(title);
        var detail=new TextBlock{Text=$"{albums.Length} 张唱片",Width=s,TextAlignment=TextAlignment.Center,FontSize=11,Opacity=.6,Foreground=Foreground};Canvas.SetTop(detail,caption+21);pile.Children.Add(detail);
        card.MouseEnter+=(_,_)=>Pose(true);card.MouseLeave+=(_,_)=>Pose(false);
        card.MouseLeftButtonUp+=(_,_)=>{var center=card.TranslatePoint(new Point(card.ActualWidth/2,peek+s/2),BurstItems);stackOrigins[albums[0].SeriesKey]=center;openedStack=albums[0].SeriesKey;RenderWall();Dispatcher.BeginInvoke(DispatcherPriority.Loaded,()=>AnimateBurst(center,false));};
        return card;
    }
    void AnimateBurst(Point origin, bool reverse)
    {
        var cards = BurstItems.Children.OfType<Border>().ToArray();
        for (int i = 0; i < cards.Length; i++)
        {
            var card = cards[i]; var destination = card.TranslatePoint(new Point(card.ActualWidth / 2, card.ActualHeight / 2), BurstItems);
            var scale = new ScaleTransform(1, 1); var offset = new TranslateTransform();
            var transforms = new TransformGroup(); transforms.Children.Add(scale); transforms.Children.Add(offset);
            card.RenderTransformOrigin = new Point(.5, .5); card.RenderTransform = transforms;
            double seconds = reverse ? .22 : .38 + Math.Min(i, 7) * .025;
            var duration = TimeSpan.FromSeconds(seconds);
            var ease = new CubicEase { EasingMode = reverse ? EasingMode.EaseIn : EasingMode.EaseOut };
            var from = reverse ? 1.0 : .4; var to = reverse ? .4 : 1.0;
            var dx = origin.X - destination.X; var dy = origin.Y - destination.Y;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(from, to, duration) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(from, to, duration) { EasingFunction = ease });
            offset.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(reverse ? 0 : dx, reverse ? dx : 0, duration) { EasingFunction = ease });
            offset.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(reverse ? 0 : dy, reverse ? dy : 0, duration) { EasingFunction = ease });
            card.BeginAnimation(OpacityProperty, new DoubleAnimation(reverse ? 1 : 0, reverse ? 0 : 1, duration));
        }
    }
    UIElement AlbumCard(Album album)
    {
        var card = Card(album.Title, album.Artist.Length > 0 ? album.Artist : album.SeriesTitle, album.CoverPath, 218, 270);
        card.Tag = album.Id;
        if (album.Id == focusedAlbum)
        {
            card.BorderBrush = new SolidColorBrush(Hero.Accent);
            card.BorderThickness = new Thickness(2);
            card.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Hero.Accent, BlurRadius = 20, ShadowDepth = 0, Opacity = .55 };
        }
        var check = new System.Windows.Controls.CheckBox { Content = "归档", Foreground = Foreground, IsChecked = selected.Contains(album.Id), Margin = new Thickness(0, 5, 0, 0) };
        check.Checked += (_, _) => selected.Add(album.Id); check.Unchecked += (_, _) => selected.Remove(album.Id);
        ((StackPanel)card.Child).Children.Add(check);
        card.PreviewMouseLeftButtonUp += (_, e) => { if (!check.IsMouseOver) { e.Handled = true; PlayAlbum(album, card); } };
        return card;
    }
    Border Card(string title,string subtitle,string? artwork,double width,double height)
    {
        double s=wallSide,peek=Math.Round(s*.135);
        var card=new Border{Width=s,MinHeight=peek+s+Math.Round(s*.07)+37,Margin=new Thickness(wallGap/2,0,wallGap/2,Math.Round(wallGap*.8)),Background=Brushes.Transparent,Cursor=Cursors.Hand};
        var stack=new StackPanel();card.Child=stack;
        var cover=Sleeve(artwork,s);cover.Margin=new Thickness(0,peek,0,0);stack.Children.Add(cover);
        stack.Children.Add(new TextBlock{Text=title,TextAlignment=TextAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=13,FontWeight=FontWeights.Medium,Margin=new Thickness(0,Math.Round(s*.07),0,2),Foreground=Foreground});
        stack.Children.Add(new TextBlock{Text=subtitle,TextAlignment=TextAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=11,Opacity=.6,Foreground=Foreground});
        card.MouseEnter+=(_,_)=>{cover.RenderTransformOrigin=new Point(.5,.5);var transform=new ScaleTransform(1,1);cover.RenderTransform=transform;var duration=TimeSpan.FromMilliseconds(200);transform.BeginAnimation(ScaleTransform.ScaleXProperty,new DoubleAnimation(1.045,duration));transform.BeginAnimation(ScaleTransform.ScaleYProperty,new DoubleAnimation(1.045,duration));};
        card.MouseLeave+=(_,_)=>cover.RenderTransform=Transform.Identity;return card;
    }
    Rect HeroArtworkRect()
    {
        var rect = Hero.ArtworkBounds();
        return new Rect(Hero.TranslatePoint(rect.TopLeft, Stage), rect.Size);
    }
    Rect CardArtworkRect(Border card)
    {
        if(card.Child is WallSleeve sleeveOnly)return new Rect(sleeveOnly.TranslatePoint(sleeveOnly.ArtworkBounds().TopLeft,Stage),sleeveOnly.ArtworkBounds().Size);
        if (card.Child is StackPanel panel && panel.Children[0] is FrameworkElement cover)
            return cover is WallSleeve sleeve?new Rect(cover.TranslatePoint(sleeve.ArtworkBounds().TopLeft,Stage),sleeve.ArtworkBounds().Size):new Rect(cover.TranslatePoint(new Point(), Stage), cover.RenderSize);
        return Rect.Empty;
    }
    void FlyCover(Rect start, Rect end, ImageSource? source)
    {
        if (source == null || start.IsEmpty || end.IsEmpty || end.Width <= 0 || start.Width <= 0) return;
        TransitionLayer.Children.Clear();
        var flight = new Image { Source = source, Stretch = Stretch.UniformToFill, Width = start.Width, Height = start.Height,
            Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 6, Opacity = .25 } };
        Canvas.SetLeft(flight, start.X); Canvas.SetTop(flight, start.Y); TransitionLayer.Children.Add(flight);
        var duration = TimeSpan.FromMilliseconds(580);
        var ease = new CubicEase { EasingMode = EasingMode.EaseInOut };
        foreach (var move in new[] { (Canvas.LeftProperty, start.X, end.X), (Canvas.TopProperty, start.Y, end.Y),
                                     (WidthProperty, start.Width, end.Width), (HeightProperty, start.Height, end.Height) })
            flight.BeginAnimation(move.Item1, new DoubleAnimation(move.Item2, move.Item3, duration) { EasingFunction = ease });
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(180)) { BeginTime = TimeSpan.FromMilliseconds(400) };
        fade.Completed += (_, _) => TransitionLayer.Children.Remove(flight);
        flight.BeginAnimation(OpacityProperty, fade);
    }
    void PlayAlbum(Album album, Border card)
    {
        var source = CardArtworkRect(card);
        var stack = openedStack; OpenPath(album.PlayablePath);
        AlbumTitle.Text = album.Title; AlbumArtist.Text = album.Artist.Length > 0 ? album.Artist : album.SeriesTitle;
        Hero.Album = album.Title; SetCover(album.CoverPath != null && File.Exists(album.CoverPath) ? album.CoverPath : CoverFor(album.PlayablePath));
        if (stack != null) { returnStack = stack; returnAlbum = album.Id; }
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => FlyCover(source, HeroArtworkRect(), Hero.Cover));
    }
    async void Scan_Click(object sender, RoutedEventArgs e)
    {
        var folder = PickFolder("选择要加入专辑墙的 CD 文件夹"); if (folder == null) return;
        ShowToast("正在扫描唱片文件夹…");
        try { var added = await library.ScanAsync(folder); RenderWall(); ShowToast($"扫描完成，新增 {added} 张 CD。"); }
        catch (Exception ex) { ShowToast("扫描失败：" + ex.Message); }
    }
    async void Archive_Click(object sender, RoutedEventArgs e)
    {
        var albums = library.Albums.Where(a => selected.Contains(a.Id)).ToArray();
        if (albums.Length == 0) { ShowToast("请先勾选要归档的 CD。"); return; }
        var folder = PickFolder("选择归档目标文件夹"); if (folder == null) return;
        try { var count = await library.ArchiveAsync(albums, folder); selected.Clear(); RenderWall(); ShowToast($"已归档 {count} 张 CD 到所选文件夹。"); }
        catch (Exception ex) { ShowToast("归档失败：" + ex.Message); }
    }
    void ChooseCover_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentCoverKey == null) { ShowToast("先打开一张 CD，再选择封面。"); return; }
        var picker = new Microsoft.Win32.OpenFileDialog { Filter = "图片|*.jpg;*.jpeg;*.png;*.webp;*.bmp", Title = "选择 CD 封面" };
        if (picker.ShowDialog(this) == true) try { SaveCover(File.ReadAllBytes(picker.FileName), Path.GetExtension(picker.FileName).ToLowerInvariant()); }
        catch (Exception ex) { ShowToast("封面保存失败：" + ex.Message); }
    }
    async void SearchCover_Click(object sender, RoutedEventArgs e)
    {
        var coverKey = CurrentCoverKey;
        if (coverKey == null) { ShowToast("先打开一张 CD，再查找封面。"); return; }
        var query = AlbumTitle.Text + (AlbumArtist.Text.Length > 0 ? " " + AlbumArtist.Text : "");
        ShowToast("正在查找候选封面…");
        List<CoverCandidate> candidates;
        try { candidates = await CoverSearch.SearchAsync(query); }
        catch (Exception ex) { ShowToast("封面查询失败：" + ex.Message); return; }
        if (CurrentCoverKey != coverKey) return;
        if (candidates.Count == 0) { ShowToast("没有找到可用的封面。可从本地图片选择。"); return; }
        var popup = new Window { Owner = this, Title = "选择封面", Width = 720, Height = 570, MinWidth = 480, MinHeight = 400,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = new SolidColorBrush(C(palettes[theme].Base)), Foreground = Foreground };
        var grid = new Grid { Margin = new Thickness(20) }; grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition());
        grid.Children.Add(new TextBlock { Text = "选择与这张 CD 对应的封面", FontSize = 21, Margin = new Thickness(5, 0, 0, 16) });
        var wrap = new WrapPanel(); var scroll = new ScrollViewer { Content = wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1); grid.Children.Add(scroll); popup.Content = grid;
        foreach (var candidate in candidates)
        {
            var image = new BitmapImage(); using (var mem = new MemoryStream(candidate.Image))
            { image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = mem; image.EndInit(); image.Freeze(); }
            var tile = new Button { Width = 153, Height = 200, Margin = new Thickness(5), ToolTip = candidate.Title + " / " + candidate.Artist };
            var stack = new StackPanel(); stack.Children.Add(new Image { Source = image, Width = 137, Height = 137, Stretch = Stretch.UniformToFill });
            stack.Children.Add(new TextBlock { Text = candidate.Title, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 11, Margin = new Thickness(0, 8, 0, 0) });
            stack.Children.Add(new TextBlock { Text = candidate.Artist, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = .55, FontSize = 10 });
            tile.Content = stack; tile.Click += (_, _) => { if (CurrentCoverKey == coverKey) SaveCover(candidate.Image, ".jpg"); popup.Close(); }; wrap.Children.Add(tile);
        }
        popup.ShowDialog();
    }
}
