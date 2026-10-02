using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CDGlass.Windows;

// The native wall has square sleeves, with captions outside the object.
public sealed class WallSleeve : FrameworkElement
{
    public int PlayerStyle { get; init; }
    public int Theme { get; init; }
    public Color Body { get; init; }
    public Color Ink { get; init; }
    public BitmapSource? Cover { get; init; }
    BitmapSource? skin;
    public Rect ArtworkBounds()
    {
        double s=ActualWidth;
        return PlayerStyle switch {
            1=>new Rect(Math.Round(s*.085),Math.Max(1.5,Math.Round(s*.016)),s-Math.Round(s*.085)-Math.Max(1.5,Math.Round(s*.016)),s-2*Math.Max(1.5,Math.Round(s*.016))),
            2=>new Rect(Math.Round(s*.052),Math.Round(s*.052),s-2*Math.Round(s*.052),s-2*Math.Round(s*.052)),
            3=>new Rect(3,3,Math.Max(1,s-6),Math.Max(1,s-6)),_=>new Rect(0,0,s,s)};
    }
    protected override void OnRender(DrawingContext d)
    {
        base.OnRender(d);if(ActualWidth<4)return;
        double s=ActualWidth,r=PlayerStyle switch{0=>Math.Round(Math.Max(6,s*.05)),1=>3,2=>1.5,_=>0};
        Color body=PlayerStyle switch{1=>Color.FromRgb(26,26,28),2=>Theme>=4?Color.FromRgb(249,245,237):Color.FromRgb(230,224,212),3=>Ink,_=>Body};
        var box=new Rect(0,0,s,s);d.DrawRoundedRectangle(new SolidColorBrush(body),null,box,r,r);
        var art=ArtworkBounds();d.PushClip(new RectangleGeometry(art,PlayerStyle==0?r:PlayerStyle==1?1:0,PlayerStyle==0?r:PlayerStyle==1?1:0));
        if(Cover!=null){double ratio=Math.Max(art.Width/Cover.PixelWidth,art.Height/Cover.PixelHeight);double w=Cover.PixelWidth*ratio,h=Cover.PixelHeight*ratio;d.DrawImage(Cover,new Rect(art.X+(art.Width-w)/2,art.Y+(art.Height-h)/2,w,h));}
        else d.DrawRectangle(new SolidColorBrush(Body),null,art);
        d.Pop();skin??=new BitmapImage(new Uri($"pack://application:,,,/Assets/Materials/wall-{PlayerStyle}-{Theme}.png"));d.DrawImage(skin,box);
    }
}
