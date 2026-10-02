using System.Windows;
using System.Windows.Media;
using System.Windows.Documents;

namespace CDGlass.Windows;

// Consistent vector controls: no platform-dependent emoji or boxed transport glyphs.
public sealed class Glyph : FrameworkElement
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(Glyph), new FrameworkPropertyMetadata("play", FrameworkPropertyMetadataOptions.AffectsRender));
    public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
    protected override void OnRender(DrawingContext d)
    {
        var brush = TextElement.GetForeground(this); var p = new Pen(brush, 1.65) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        double scale = Math.Min(ActualWidth, ActualHeight) / 24;
        d.PushTransform(new TranslateTransform((ActualWidth-24*scale)/2,(ActualHeight-24*scale)/2));d.PushTransform(new ScaleTransform(scale,scale));
        void Shape(string path, bool filled=false) => d.DrawGeometry(filled ? brush : null, filled ? null : p, Geometry.Parse(path));
        if (Kind == "play") Shape("M 7,3 L 21,12 L 7,21 Z",true);
        else if (Kind == "pause") { d.DrawRoundedRectangle(brush,null,new Rect(6,3,4,18),.8,.8);d.DrawRoundedRectangle(brush,null,new Rect(14,3,4,18),.8,.8); }
        else if (Kind is "previous" or "next") { if(Kind=="previous") {d.PushTransform(new ScaleTransform(-1,1,12,12));} Shape("M 2,5 L 12,12 L 2,19 Z M 12,5 L 22,12 L 12,19 Z",true); if(Kind=="previous")d.Pop(); }
        else if (Kind == "wall") foreach(int x in new[]{3,14})foreach(int y in new[]{3,14})d.DrawRoundedRectangle(null,p,new Rect(x,y,7,7),1,1);
        else if (Kind == "settings") { for(int i=0;i<8;i++){d.PushTransform(new RotateTransform(i*45,12,12));d.DrawRoundedRectangle(brush,null,new Rect(10.4,1,3.2,4),.6,.6);d.Pop();}d.DrawEllipse(null,new Pen(brush,2),new Point(12,12),7.8,7.8);d.DrawEllipse(null,p,new Point(12,12),3.1,3.1); }
        else if (Kind == "volume" || Kind=="mute") { Shape("M 3,9 L 7,9 L 12,5 L 12,19 L 7,15 L 3,15 Z",true); if(Kind=="volume")Shape("M 16,8 Q 20,12 16,16 M 19,5 Q 25,12 19,19");else Shape("M 16,8 L 22,16 M 22,8 L 16,16"); }
        else if (Kind == "folder") Shape("M 2,7 L 2,19 Q 2,21 4,21 L 20,21 Q 22,21 22,19 L 22,8 Q 22,6 20,6 L 11,6 L 9,3 L 4,3 Q 2,3 2,5 Z");
        else if (Kind == "demo") {d.DrawEllipse(null,p,new Point(12,12),10,10);Shape("M 9,7 L 17,12 L 9,17 Z",true);}
        else if (Kind == "fullscreen") Shape("M 3,9 L 3,3 L 9,3 M 15,3 L 21,3 L 21,9 M 21,15 L 21,21 L 15,21 M 9,21 L 3,21 L 3,15");
        d.Pop();d.Pop();
    }
}
