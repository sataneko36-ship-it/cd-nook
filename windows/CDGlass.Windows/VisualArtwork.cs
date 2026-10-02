using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CDGlass.Windows;

public static class VisualArtwork
{
    // Precompute a small background once; a live WPF blur is expensive under ARM emulation.
    public static BitmapSource BlurBackground(BitmapSource source, int level)
    {
        double scale = Math.Min(1, 384d / Math.Max(source.PixelWidth, source.PixelHeight));
        var small = new TransformedBitmap(source, new ScaleTransform(scale, scale));
        var image = new FormatConvertedBitmap(small, PixelFormats.Pbgra32, null, 0);
        int width = image.PixelWidth, height = image.PixelHeight, stride = width * 4;
        var pixels = new byte[stride * height]; image.CopyPixels(pixels, stride, 0);
        var buffer = new byte[pixels.Length];
        int radius = new[] { 17, 6, 2 }[Math.Clamp(level, 0, 2)];
        for (int pass = 0; pass < 3; pass++)
        {
            Box(pixels, buffer, width, height, radius, true);
            Box(buffer, pixels, width, height, radius, false);
        }
        var result = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
        result.Freeze(); return result;
    }
    static void Box(byte[] input, byte[] output, int width, int height, int radius, bool horizontal)
    {
        int lines = horizontal ? height : width, length = horizontal ? width : height;
        int step = horizontal ? 4 : width * 4, divisor = radius * 2 + 1;
        for (int line = 0; line < lines; line++)
        {
            int start = horizontal ? line * width * 4 : line * 4;
            for (int channel = 0; channel < 4; channel++)
            {
                int sum = 0;
                for (int n = -radius; n <= radius; n++) sum += input[start + Math.Clamp(n, 0, length - 1) * step + channel];
                for (int n = 0; n < length; n++)
                {
                    output[start + n * step + channel] = (byte)(sum / divisor);
                    sum += input[start + Math.Clamp(n + radius + 1, 0, length - 1) * step + channel]
                        - input[start + Math.Clamp(n - radius, 0, length - 1) * step + channel];
                }
            }
        }
    }
}
