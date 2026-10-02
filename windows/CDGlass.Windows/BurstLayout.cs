using System.Windows;
namespace CDGlass.Windows;

// Same seeded ring placement and bounded jitter as CDWBurstLayout.
static class BurstLayout
{
    public sealed record Result(Point Center,double Side,double Caption,Rect Title,IReadOnlyList<Point> Spots);
    struct Rng
    {
        ulong value;
        public Rng(string key){value=1469598103934665603;foreach(char c in key){value^=c;value=unchecked(value*1099511628211);}value|=1;}
        public double Next(){value^=value<<13;value^=value>>7;value^=value<<17;return (value>>11)/9007199254740992d;}
    }
    public static double Tilt(string albumId){var rng=new Rng(albumId+"tilt");return (rng.Next()<.5?-1:1)*(3+rng.Next()*9);}
    static bool Free(Rect r,Rect area,Rect title,IReadOnlyList<Rect> taken,int skip=-1)
    {
        if(!area.Contains(r)||r.IntersectsWith(title))return false;
        for(int i=0;i<taken.Count;i++)if(i!=skip&&r.IntersectsWith(taken[i]))return false;return true;
    }
    public static Result Place(int count,Point origin,Rect area,Size titleSize,string seed)
    {
        double target=Math.Clamp(Math.Sqrt(area.Width*area.Height*.19/Math.Max(1,count)),96,280),side=target,cap=0;
        Point center=origin;Rect title=Rect.Empty;var slots=new List<Rect>();bool done=false;
        for(int k=0;k<28&&!done;k++) {
            side=Math.Max(44,target*Math.Pow(.93,k));cap=side>=128?Math.Round(Math.Min(30,18+side*.045)):0;
            double gap=Math.Max(12,side*.1),bw=side*1.13+gap,bh=(side+cap)*1.08+gap;
            foreach(double f in k<4?new[]{0,.2,.4}:new[]{0,.2,.4,.6,.8,1}) {
                double tw=titleSize.Width+24,th=titleSize.Height+14;
                center=new Point(Math.Clamp(origin.X+(area.Left+area.Width/2-origin.X)*f,area.Left+tw/2,area.Right-tw/2),Math.Clamp(origin.Y+(area.Top+area.Height/2-origin.Y)*f,area.Top+th/2,area.Bottom-th/2));
                title=new Rect(center.X-tw/2,center.Y-th/2,tw,th);var bounds=area;bounds.Inflate(gap/2,gap/2);
                var rng=new Rng(seed);slots.Clear();
                for(int ring=0;ring<24&&slots.Count<count;ring++) {
                    double rx=title.Width/2+bw/2+ring*bw*1.02,ry=title.Height/2+bh/2+ring*bh*1.02;
                    bool enclosing=center.X-rx+bw/2<area.Left&&center.X+rx-bw/2>area.Right&&center.Y-ry+bh/2<area.Top&&center.Y+ry-bh/2>area.Bottom;
                    int steps=Math.Min(1024,(int)Math.Ceiling(2*Math.PI*Math.Max(rx,ry)/(Math.Min(bw,bh)*.16)));double start=rng.Next()*2*Math.PI;var found=new List<Rect>();
                    for(int j=0;j<steps;j++){double t=start+j*2*Math.PI/steps;var r=new Rect(center.X+rx*Math.Cos(t)-bw/2,center.Y+ry*Math.Sin(t)-bh/2,bw,bh);if(Free(r,bounds,title,slots)&&Free(r,bounds,title,found))found.Add(r);}
                    int needed=count-slots.Count;
                    if(found.Count<=needed)slots.AddRange(found);else for(int j=0;j<needed;j++)slots.Add(found[(int)Math.Floor((j+.5)*found.Count/needed)]);
                    if(enclosing)break;
                }
                if(slots.Count<count)continue;
                for(int i=0;i<count;i++)for(int attempt=0;attempt<3;attempt++) {var moved=slots[i];moved.Offset((rng.Next()-.5)*side*.16,(rng.Next()-.5)*side*.12);if(Free(moved,bounds,title,slots,i)){slots[i]=moved;break;}}
                done=true;break;
            }
        }
        var points=slots.Select(r=>new Point(r.X+r.Width/2,r.Y+r.Height/2)).ToArray();
        return new Result(center,side,cap,new Rect(center.X-titleSize.Width/2,center.Y-titleSize.Height/2,titleSize.Width,titleSize.Height),points);
    }
}
