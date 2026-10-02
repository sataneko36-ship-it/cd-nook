using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace CDGlass.Windows;
// Mirrors the native 300 × 195 LCD design and 3-pixel dot cells.
public sealed class PixelDisplay
{
 static readonly string[] backgrounds=["#C6DBDF","#2E6BCB","#CDBDF2","#EDB457","#F3D1DD","#B8D49A","#E5DCBC","#BEDCF2"],inks=["#14232A","#E8F2FF","#271543","#3A2006","#4A1C2E","#1E3212","#36301B","#0F2F49"];
 string? key;BitmapSource? cached,art,cover;bool artLightInk;
 static int U(double v)=>(int)Math.Round(v*1.25);
 public BitmapSource Render(HeroVisual h)
 {
  string next=$"{h.ThemeIndex}|{h.PixelPage}|{h.Playing}|{h.HasSession}|{h.TrackPosition}|{h.TrackTotal}|{h.Track}|{h.Artist}|{h.Album}|{h.ElapsedMs/1000}|{h.LengthMs}|{Math.Floor(h.Seconds*(h.Playing?8:0))}|{(h.Cover==null?0:RuntimeHelpers.GetHashCode(h.Cover))}";
  if(next==key&&cached!=null)return cached;key=next;
  var v=new DrawingVisual();TextOptions.SetTextRenderingMode(v,TextRenderingMode.Aliased);TextOptions.SetTextFormattingMode(v,TextFormattingMode.Display);RenderOptions.SetEdgeMode(v,EdgeMode.Aliased);
  using(var d=v.RenderOpen()) {
   d.DrawRectangle(Brushes.White,null,new Rect(0,0,300,195));var pen=new Pen(Brushes.Black,1);
   void Line(double x,double y,double w,double z)=>d.DrawRectangle(Brushes.Black,null,new Rect(Math.Round(x),Math.Round(y),Math.Max(1,Math.Round(w)),Math.Max(1,Math.Round(z))));
   void Text(string value,double x,double y,double size,double width,bool mono=false) {var t=new FormattedText(value,CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface(mono?"Consolas":"Segoe UI, Microsoft YaHei UI"),U(size),Brushes.Black,1){MaxTextWidth=Math.Max(1,width),MaxLineCount=1,Trimming=TextTrimming.CharacterEllipsis};d.DrawText(t,new Point(Math.Round(x),Math.Round(y)));}
   if(h.HasSession){if(h.Playing)d.DrawGeometry(Brushes.Black,null,Geometry.Parse($"M {U(5)},{U(3)} L {U(5)},{U(10)} L {U(9)},{U(6.5)} Z"));else{Line(U(5),U(3),U(2),U(7));Line(U(8),U(3),U(2),U(7));}Text($"{h.TrackPosition}/{h.TrackTotal}",U(14),U(1),10,U(45),true);Text(h.PixelPage==1?"ART":"PLAY",140,U(1),10,65,true);}else Text("CD GLASS",U(5),U(1),10,150,true);
   int bx=300-U(21);d.DrawRectangle(null,pen,new Rect(bx+.5,U(3)+.5,U(13),U(6)));Line(bx+U(13)+1,U(5),U(2),U(3));for(int i=0;i<3;i++)Line(bx+U(2)+i*U(4),U(5),U(3),U(3));Line(0,U(13),300,1);
   if(!ReferenceEquals(h.Cover,cover)||artLightInk!=(h.ThemeIndex==1)){cover=h.Cover;artLightInk=h.ThemeIndex==1;art=cover==null?null:PixelArtwork.Render(cover,artLightInk);}
   void Artwork(int x,int y,int side){if(art!=null)d.DrawImage(art,new Rect(x,y,side,side));else{d.DrawEllipse(null,pen,new Point(x+side/2d,y+side/2d),side*.33,side*.33);d.DrawEllipse(null,pen,new Point(x+side/2d,y+side/2d),side*.13,side*.13);}}
   if(!h.HasSession){Artwork(104,35,92);Text("INSERT A CD",103,141,11,170,true);}else if(h.PixelPage==1){Artwork(74,19,152);Text(h.Track,7,176,10,286);}else{
    const int side=76;int x=U(6)+side+U(9);double width=300-x-U(6);Artwork(U(6),U(19),side);Text(h.Track,x,U(21),12,width);int y=U(40);
    if(h.Artist.Length>0){Text(h.Artist,x,y,11,width);y+=U(15);}if(h.Album.Length>0){Text(h.Album,x,y,11,width);y+=U(15);}Text($"TRACK {h.TrackPosition} OF {h.TrackTotal}",x,y+U(4),10,width,true);
    int barY=195-U(24),top=Math.Max(U(19)+side+U(7),y+U(4)+U(16));Line(U(6),barY-U(6),287,1);for(int i=0;i<32&&h.Playing;i++){double wave=.2+.8*Math.Abs(Math.Sin(i*.71+h.Seconds*3.2));int height=Math.Max(1,(int)((barY-U(6)-top)*wave));for(int yy=barY-U(6);yy>barY-U(6)-height;yy-=3)Line(U(6)+i*9,yy,6,2);}
    d.DrawRectangle(null,pen,new Rect(U(5)+.5,barY+.5,300-2*U(5)-1,U(7)));Line(U(7),barY+U(2),Math.Round((300-2*U(7))*Math.Clamp(h.LengthMs>0?h.ElapsedMs/(double)h.LengthMs:0,0,1)),U(4));
    string Time(long ms)=>$"{Math.Max(0,ms)/60000}:{Math.Max(0,ms)/1000%60:00}";Text(Time(h.ElapsedMs),U(6),195-U(13),10,90,true);string remaining="-"+Time(h.LengthMs-h.ElapsedMs);double remainingWidth=new FormattedText(remaining,CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface("Consolas"),U(10),Brushes.Black,1).Width;Text(remaining,300-U(6)-remainingWidth,195-U(13),10,remainingWidth+1,true);
   }
  }
  var maskImage=new RenderTargetBitmap(300,195,96,96,PixelFormats.Pbgra32);maskImage.Render(v);byte[] mask=new byte[300*195*4];maskImage.CopyPixels(mask,1200,0);
  var bg=(Color)ColorConverter.ConvertFromString(backgrounds[h.ThemeIndex]);var ink=(Color)ColorConverter.ConvertFromString(inks[h.ThemeIndex]);byte[] pixels=new byte[900*585*4];
  for(int y=0;y<195;y++)for(int x=0;x<300;x++) {bool on=mask[(y*300+x)*4]<128,left=x>0&&mask[(y*300+x-1)*4]<128,top=y>0&&mask[((y-1)*300+x)*4]<128;for(int iy=0;iy<3;iy++)for(int ix=0;ix<3;ix++){bool gap=ix==2||iy==2;double share=on?(gap?.62:1):(gap?.07:((left&&ix==0)||(top&&iy==0))?.2:0);int at=((y*3+iy)*900+x*3+ix)*4;pixels[at]=(byte)(bg.B*(1-share)+ink.B*share);pixels[at+1]=(byte)(bg.G*(1-share)+ink.G*share);pixels[at+2]=(byte)(bg.R*(1-share)+ink.R*share);pixels[at+3]=255;}}
  cached=BitmapSource.Create(900,585,96,96,PixelFormats.Bgra32,null,pixels,3600);cached.Freeze();return cached;
 }
}
