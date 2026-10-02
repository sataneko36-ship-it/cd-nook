using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CDGlass.Windows;

public sealed class HeroVisual : FrameworkElement
{
    public int PlayerStyle { get; set; }
    public int ThemeIndex { get; set; } = 4;
    public Color Accent { get; set; }
    public Color Body { get; set; }
    public Color Ink { get; set; }
    public BitmapSource? Cover { get; set; }
    public string Album { get; set; } = "CD GLASS";
    public string Track { get; set; } = "";
    public string Artist { get; set; } = "";
    public int TrackPosition { get; set; }
    public int TrackTotal { get; set; }
    public long ElapsedMs { get; set; }
    public long LengthMs { get; set; }
    public bool Playing { get; set; }
    public bool HasSession { get; set; }
    public double Seconds { get; set; }
    public int PixelPage { get; set; }
    public double Aspect => PlayerStyle switch { 1 => 1.66, 2 => 100/63.8, 3 => 1.17/.903, _ => 1 };
    double playBlend, discAngle, reelAngle, discSlide=.55;
    int materialTheme=-1;
    readonly Dictionary<string,BitmapSource> materials=[];
    readonly PixelDisplay screen = new();
    public void Advance(double delta)
    {
        playBlend += ((Playing?1:0)-playBlend)*Math.Min(1,delta*(Playing?1.6:.9));
        discAngle=(discAngle+delta*151.2*playBlend)%360;
        reelAngle=(reelAngle+delta*180*playBlend)%360;
        discSlide+=((HasSession?1:.55)-discSlide)*Math.Min(1,delta*2.4);
    }
    Rect ObjectRect()
    {
        double width=ActualWidth,height=ActualHeight;
        if(width/Math.Max(1,height)>Aspect)width=height*Aspect;else height=width/Aspect;
        return new Rect((ActualWidth-width)/2,(ActualHeight-height)/2,width,height);
    }
    public Rect ArtworkBounds()
    {
        var r=ObjectRect();
        return PlayerStyle switch {
            1 => new Rect(r.X+r.Height*.0949,r.Y+r.Height*.022,r.Height*1.008,r.Height*.956),
            2 => new Rect(r.X+r.Width*.059,r.Y+r.Height*.0643,r.Width*.882,r.Height*.602),
            3 => new Rect(r.X+r.Width*.073,r.Y+r.Height*.12,r.Width*.8547,r.Width*.5556), _=>r };
    }
    BitmapSource Material(string name)
    {
        if(materialTheme!=ThemeIndex){materials.Clear();materialTheme=ThemeIndex;}
        name+=$"-{ThemeIndex}";
        if(!materials.TryGetValue(name,out var value)) {
            value=new BitmapImage(new Uri($"pack://application:,,,/Assets/Materials/{name}.png"));value.Freeze();materials[name]=value;
        }
        return value;
    }
    static SolidColorBrush B(Color c,byte alpha=255)=>new(Color.FromArgb(alpha,c.R,c.G,c.B));
    static Color C(string value)=>(Color)ColorConverter.ConvertFromString(value);
    static void RectImage(DrawingContext d,ImageSource image,Rect box)=>d.DrawImage(image,box);
    void CoverImage(DrawingContext d,Rect box,double radius=0)
    {
        d.PushClip(new RectangleGeometry(box,radius,radius));
        if(Cover!=null) {
            double ratio=Math.Max(box.Width/Cover.PixelWidth,box.Height/Cover.PixelHeight);
            double width=Cover.PixelWidth*ratio,height=Cover.PixelHeight*ratio;
            d.DrawImage(Cover,new Rect(box.X+(box.Width-width)/2,box.Y+(box.Height-height)/2,width,height));
        } else {
            d.DrawRectangle(new LinearGradientBrush(B(Body).Color,C("#1A1D22"),70),null,box);
            var center=new Point(box.X+box.Width/2,box.Y+box.Height*.47);
            foreach(double fraction in new[]{.293,.12,.037})d.DrawEllipse(null,new Pen(B(Ink,45),Math.Max(.6,box.Width*.002)),center,box.Width*fraction,box.Width*fraction);
            Text(d,"C D  G L A S S",box.X,box.Y+box.Height*.84,box.Width,box.Width*.028,Ink,"Segoe UI",true);
        }
        d.Pop();
    }
    static void Text(DrawingContext d,string value,double x,double y,double width,double size,Color color,string family="Segoe UI",bool center=false)
    {
        var text=new FormattedText(value,CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface(family),size,new SolidColorBrush(color),1){MaxTextWidth=Math.Max(1,width),MaxLineCount=1,Trimming=TextTrimming.CharacterEllipsis,TextAlignment=center?TextAlignment.Center:TextAlignment.Left};
        d.DrawText(text,new Point(x,y));
    }
    static void Shadow(DrawingContext d,Rect box,double strength)
    {
        var brush=new RadialGradientBrush(Color.FromArgb((byte)(strength*255),0,0,0),Colors.Transparent){RadiusX=.5,RadiusY=.5};
        d.DrawEllipse(brush,null,new Point(box.X+box.Width/2,box.Y+box.Height*.87),box.Width*.64,box.Height*.38);
    }
    protected override void OnRender(DrawingContext d)
    {
        base.OnRender(d);if(ActualWidth<10||ActualHeight<10)return;
        var box=ObjectRect();
        if(PlayerStyle==0) {
            double scale=HasSession ? .955+.045*playBlend : 1;
            var r=new Rect(box.X+box.Width*(1-scale)/2,box.Y+box.Height*(1-scale)/2,box.Width*scale,box.Height*scale);
            // A floating square cover, as in CDEtherealHero; the artwork remains still.
            var glow=new RadialGradientBrush(B(Accent,60).Color,Colors.Transparent){RadiusX=.5,RadiusY=.5};
            d.DrawEllipse(glow,null,new Point(r.X+r.Width/2,r.Y+r.Height*.6),r.Width*.78,r.Height*.74);
            Shadow(d,r,ThemeIndex>=4?.16:.42);CoverImage(d,r,r.Width*.028);
            d.DrawRoundedRectangle(null,new Pen(B(ThemeIndex>=4?Colors.Black:Colors.White,ThemeIndex>=4?(byte)18:(byte)36),1),r,r.Width*.028,r.Width*.028);
            d.DrawRoundedRectangle(new LinearGradientBrush(Color.FromArgb(30,255,255,255),Colors.Transparent,45),null,r,r.Width*.028,r.Width*.028);
            return;
        }
        d.PushTransform(new TranslateTransform(box.X,box.Y));
        double designWidth=PlayerStyle==1?996:PlayerStyle==2?1000:1053;
        double designHeight=PlayerStyle==1?600:PlayerStyle==2?638:813;
        d.PushTransform(new ScaleTransform(box.Width/designWidth,box.Height/designHeight));
        if(PlayerStyle==1)Disc(d);else if(PlayerStyle==2)Cassette(d);else Pixel(d);
        d.Pop();d.Pop();
    }
    void Disc(DrawingContext d)
    {
        const double h=600,diameter=564,w=678;
        double cx=h*.62+(996-diameter/2-h*.62)*discSlide,cy=300;
        var plate=new Rect(cx-diameter/2,cy-diameter/2,diameter,diameter);
        Shadow(d,new Rect(0,0,996,600),ThemeIndex>=4?.2:.5);
        var hole=new CombinedGeometry(GeometryCombineMode.Exclude,new EllipseGeometry(new Point(cx,cy),diameter/2,diameter/2),new EllipseGeometry(new Point(cx,cy),diameter*.0375,diameter*.0375));
        d.PushClip(hole);d.PushTransform(new RotateTransform(discAngle,cx,cy));
        RectImage(d,Material("disc-rotor"),plate);
        for(int i=0;i<90;i++) {
            double radius=diameter*(.225+i*.00275);
            d.DrawEllipse(null,new Pen(new SolidColorBrush(Color.FromArgb(i%3==0?(byte)22:(byte)10,90,95,100)),.45),new Point(cx,cy),radius,radius);
        }
        string label=HasSession?$"{Album}  ·  {Artist}  ·  {TrackTotal} TRACKS  ·  ":"CD GLASS  ·  COMPACT  ·  DIGITAL  ·  ";
        double angle=-90,r=diameter*.196;
        foreach(char ch in label) { var t=new FormattedText(ch.ToString(),CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface("Segoe UI"),diameter*.021,new SolidColorBrush(Color.FromArgb(150,56,56,56)),1);double arc=t.Width+diameter*.003;double mid=angle+arc/r*180/Math.PI/2;d.PushTransform(new RotateTransform(mid+90,cx,cy));d.DrawText(t,new Point(cx-t.Width/2,cy-r-t.Height));d.Pop();angle+=arc/r*180/Math.PI;if(angle>250)break; }
        d.Pop();RectImage(d,Material("disc-light"),plate);d.Pop();
        var shell=new Rect(0,0,w,h);RectImage(d,Material("disc-back"),shell);
        CoverImage(d,new Rect(56.95,13.2,604.87,573.6));RectImage(d,Material("disc-glass"),shell);
    }
    static Geometry CassetteWindow()
    {
        Geometry left=new EllipseGeometry(new Point(287,253),122,122),right=new EllipseGeometry(new Point(713,253),122,122);
        var bridge=new RectangleGeometry(new Rect(287,193,426,120),12,12);
        return new CombinedGeometry(GeometryCombineMode.Union,new CombinedGeometry(GeometryCombineMode.Union,left,right),bridge);
    }
    void Cassette(DrawingContext d)
    {
        var all=new Rect(0,0,1000,638);Shadow(d,all,ThemeIndex>=4?.25:.5);
        RectImage(d,Material("cassette-interior"),all);
        double progress=LengthMs>0?(TrackPosition-1+Math.Clamp(ElapsedMs/(double)LengthMs,0,1))/Math.Max(1,TrackTotal):.5;
        for(int i=0;i<2;i++) {
            double x=i==0?287:713,radius=Math.Sqrt(113*113+(225*225-113*113)*(i==0?1-progress:progress));
            d.DrawEllipse(new RadialGradientBrush(C("#33261D"),C("#17120E")),new Pen(B(Colors.Black,200),2),new Point(x,253),radius,radius);
            for(double r=110;r<radius;r+=2)d.DrawEllipse(null,new Pen(B(Colors.White,12),.55),new Point(x,253),r,r);
            d.PushTransform(new RotateTransform(reelAngle*(i==0?1:-1),x,253));RectImage(d,Material("cassette-leftHub"),new Rect(x-106,147,212,212));d.Pop();
        }
        RectImage(d,Material("cassette-reelLight"),all);RectImage(d,Material("cassette-skin"),all);
        var print=new RectangleGeometry(new Rect(59,41,882,384),16,16);
        d.PushClip(new CombinedGeometry(GeometryCombineMode.Exclude,print,CassetteWindow()));CoverImage(d,new Rect(59,41,882,384),16);d.Pop();
        RectImage(d,Material("cassette-label"),all);
        d.PushTransform(new RotateTransform(1.1,500,36));Text(d,HasSession?Album:"Mixtape",315,15,370,37,C("#22346B"),"Comic Sans MS, Microsoft YaHei UI",true);d.Pop();
        RectImage(d,Material("cassette-glass"),all);
    }
    public Rect PixelScreenBounds()
    {
        var r=ObjectRect();return new Rect(r.X+r.Width*.07265,r.Y+r.Height*.12066,r.Width*.8547,r.Height*.71956);
    }
    void Pixel(DrawingContext d)
    {
        Shadow(d,new Rect(0,0,1053,813),.32);
        RectImage(d,Material("pixel-shell"),new Rect(0,0,1053,813));
        var lcd=new Rect(76.5,98.1,900,585);
        var frame=screen.Render(this);
        d.PushClip(new RectangleGeometry(lcd,10.8,10.8));RectImage(d,frame,lcd);d.Pop();
        // Uneven backlight and a single reflection on the glass.
        d.DrawRoundedRectangle(new RadialGradientBrush(Color.FromArgb(12,255,255,255),Color.FromArgb(20,0,0,0)),null,lcd,10.8,10.8);
        RectImage(d,Material("pixel-glare"),new Rect(49.5,49.5,954,660.6));
        d.DrawEllipse(new SolidColorBrush(Playing?C("#A3B972"):C("#947249")),new Pen(B(Colors.Black,100),1),new Point(67.725,757.8),5.6,5.6);
    }
}
