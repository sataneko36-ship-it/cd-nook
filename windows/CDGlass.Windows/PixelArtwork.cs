using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CDGlass.Windows;

// Port of CDPixelArt's whole-cover path: percentile stretch, Kuwahara,
// three-class Otsu, region cleanup and isolated-dot sweep. Vision subject
// segmentation is macOS-only and is not reproduced by this fallback.
static class PixelArtwork
{
    public static BitmapSource Render(BitmapSource image, bool lightInk)
    {
        const int n=76, big=n*4;
        int edge=Math.Min(image.PixelWidth,image.PixelHeight);
        var square=new CroppedBitmap(image,new Int32Rect((image.PixelWidth-edge)/2,(image.PixelHeight-edge)/2,edge,edge));
        var resized=new TransformedBitmap(square,new ScaleTransform(big/(double)edge,big/(double)edge));
        var source=new FormatConvertedBitmap(resized,PixelFormats.Bgra32,null,0);
        var rgba=new byte[big*big*4];source.CopyPixels(rgba,big*4,0);
        var y=new float[n*n];
        for(int row=0;row<n;row++)for(int x=0;x<n;x++) {
            double total=0;
            for(int sy=0;sy<4;sy++)for(int sx=0;sx<4;sx++) {
                int at=((row*4+sy)*big+x*4+sx)*4;
                double alpha=rgba[at+3]/255d;
                total+=(.2126*rgba[at+2]+.7152*rgba[at+1]+.0722*rgba[at])*alpha+255*(1-alpha);
            }
            y[row*n+x]=(float)(total/(16*255));
            if(lightInk)y[row*n+x]=1-y[row*n+x];
        }
        var hist=new int[1024];foreach(float value in y)hist[Math.Clamp((int)(value*1023),0,1023)]++;
        float Percentile(double p) {int target=(int)(y.Length*p),seen=0;for(int b=0;b<1024;b++){seen+=hist[b];if(seen>target)return b/1023f;}return 1;}
        float low=Percentile(.015),range=Math.Max(.1f,Percentile(.985)-low);
        for(int i=0;i<y.Length;i++)y[i]=Math.Clamp((y[i]-low)/range,0,1);
        var smooth=new float[y.Length];
        for(int row=0;row<n;row++)for(int x=0;x<n;x++) {
            float best=float.PositiveInfinity,mean=y[row*n+x];
            for(int q=0;q<4;q++) {
                int ox=(q&1)!=0?0:-2,oy=(q&2)!=0?0:-2;float sum=0,sum2=0;
                for(int dy=0;dy<=2;dy++)for(int dx=0;dx<=2;dx++) {
                    float v=y[Math.Clamp(row+oy+dy,0,n-1)*n+Math.Clamp(x+ox+dx,0,n-1)];sum+=v;sum2+=v*v;
                }
                float m=sum/9,variance=sum2/9-m*m;if(variance<best){best=variance;mean=m;}
            }
            smooth[row*n+x]=mean;
        }
        var p=new double[64];foreach(float value in smooth)p[Math.Clamp((int)(value*64),0,63)]++;
        var w=new double[65];var m1=new double[65];
        for(int b=0;b<64;b++){p[b]/=y.Length;w[b+1]=w[b]+p[b];m1[b+1]=m1[b]+p[b]*(b+.5)/64;}
        double bestBetween=-1,mt=m1[64];float t1=1/3f,t2=2/3f;
        for(int a=1;a<63;a++)for(int b=a+1;b<64;b++) {
            double w0=w[a],w1=w[b]-w[a],w2=1-w[b];if(w0<=0||w1<=0||w2<=0)continue;
            double m0=m1[a]/w0,middle=(m1[b]-m1[a])/w1,m2=(mt-m1[b])/w2;
            double between=w0*Math.Pow(m0-mt,2)+w1*Math.Pow(middle-mt,2)+w2*Math.Pow(m2-mt,2);
            if(between>bestBetween){bestBetween=between;t1=a/64f;t2=b/64f;}
        }
        var labels=new byte[n*n];for(int i=0;i<labels.Length;i++)labels[i]=(byte)(smooth[i]<t1?0:smooth[i]<t2?1:2);
        var seen=new bool[n*n];var queue=new int[n*n];
        for(int pass=0;pass<2;pass++) {
            Array.Clear(seen);
            for(int i=0;i<labels.Length;i++) {
                if(seen[i])continue;byte label=labels[i];int head=0,tail=1;queue[0]=i;seen[i]=true;
                while(head<tail) {
                    int at=queue[head++],x=at%n,row=at/n;
                    foreach(int next in Neighbours(x,row,n))if(!seen[next]&&labels[next]==label){seen[next]=true;queue[tail++]=next;}
                }
                if(tail>=6)continue;var votes=new int[3];
                for(int k=0;k<tail;k++)foreach(int next in Neighbours(queue[k]%n,queue[k]/n,n))if(labels[next]!=label)votes[labels[next]]++;
                int replacement=-1;for(int l=0;l<3;l++)if(votes[l]>0&&(replacement<0||votes[l]>votes[replacement]))replacement=l;
                if(replacement>=0)for(int k=0;k<tail;k++)labels[queue[k]]=(byte)replacement;
            }
        }
        var ink=new bool[n*n];for(int i=0;i<ink.Length;i++)ink[i]=labels[i]==0||labels[i]==1&&(i%n+i/n)%2==0;
        var original=(bool[])ink.Clone();
        for(int i=0;i<ink.Length;i++)if(original[i]) {
            bool neighbour=false;int x=i%n,row=i/n;
            for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)if((dx!=0||dy!=0)&&x+dx>=0&&x+dx<n&&row+dy>=0&&row+dy<n&&original[(row+dy)*n+x+dx])neighbour=true;
            if(!neighbour)ink[i]=false;
        }
        var pixels=new byte[n*n*4];for(int i=0;i<ink.Length;i++){byte v=ink[i]?(byte)0:(byte)255;pixels[i*4]=pixels[i*4+1]=pixels[i*4+2]=v;pixels[i*4+3]=255;}
        var result=BitmapSource.Create(n,n,96,96,PixelFormats.Bgra32,null,pixels,n*4);result.Freeze();return result;
    }
    static IEnumerable<int> Neighbours(int x,int y,int n)
    {
        if(x+1<n)yield return y*n+x+1;if(x>0)yield return y*n+x-1;
        if(y+1<n)yield return (y+1)*n+x;if(y>0)yield return (y-1)*n+x;
    }
}
