#import "CDPixelArt.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>

// The dot-matrix screen used to dither the whole cover, which turned busy artwork into a field of stray dots.
// This works like a pixel artist instead: cut the subject out, draw it as flat shapes with a firm outline, and
// keep only a few clean contours of the background.

#pragma mark - Subject

CGImageRef CDCreateSubjectMask(CGImageRef image) {
    VNGenerateForegroundInstanceMaskRequest *request = [VNGenerateForegroundInstanceMaskRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL]) return NULL;
    VNInstanceMaskObservation *observation = request.results.firstObject;
    if (!observation || !observation.allInstances.count) return NULL;
    CVPixelBufferRef buffer = [observation generateScaledMaskForImageForInstances:observation.allInstances fromRequestHandler:handler error:NULL];
    if (!buffer) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:buffer];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef mask = [[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}] createCGImage:ci fromRect:ci.extent format:kCIFormatL8 colorSpace:gray];
    CGColorSpaceRelease(gray);
    CVPixelBufferRelease(buffer);
    return mask;
}

BOOL CDFindFaces(CGImageRef image, CGRect *faces) {
    VNDetectFaceRectanglesRequest *request = [VNDetectFaceRectanglesRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL] || !request.results.count) return NO;
    CGFloat total = 0, x = 0, y = 0, w = 0, h = 0;
    for (VNFaceObservation *face in request.results) {
        CGRect b = face.boundingBox;                           // Vision: normalised, origin at the bottom-left
        CGFloat weight = b.size.width * b.size.height;
        x += b.origin.x * weight; y += (1 - CGRectGetMaxY(b)) * weight; w += b.size.width * weight; h += b.size.height * weight; total += weight;
    }
    if (total <= 0) return NO;
    *faces = CGRectMake(x / total, y / total, w / total, h / total);
    return YES;
}

#pragma mark - Sampling

/// Centre square of `image`, area-averaged down to side × side from a 4× supersampled render. Values 0…1.
static float *CDSampleSquare(CGImageRef image, int side, BOOL luminance) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image), edge = MIN(w, h);
    CGImageRef square = CGImageCreateWithImageInRect(image, CGRectMake((w - edge) / 2, (h - edge) / 2, edge, edge));
    const int ss = 4, big = side * ss;
    uint8_t *pixels = calloc((size_t)big * big * 4, 1);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels, big, big, 8, big * 4, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(srgb);
    CGContextSetRGBFillColor(ctx, luminance ? 1 : 0, luminance ? 1 : 0, luminance ? 1 : 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, big, big));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, big, big), square ?: image);
    CGContextRelease(ctx);
    if (square) CGImageRelease(square);
    float *out = calloc((size_t)side * side, sizeof(float));
    for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
        float acc = 0;
        for (int sy = 0; sy < ss; sy++) for (int sx = 0; sx < ss; sx++) {
            const uint8_t *c = pixels + ((size_t)(y * ss + sy) * big + x * ss + sx) * 4;
            acc += luminance ? .2126f * c[0] + .7152f * c[1] + .0722f * c[2] : c[0];
        }
        out[y * side + x] = acc / (ss * ss * 255.f);
    }
    free(pixels);
    return out;
}

#pragma mark - Small image-processing kit (all on n × n planes, row 0 at the top)

/// Value below which `p` of the selected pixels fall.
static float CDPercentile(const float *v, const uint8_t *select, int count, float p) {
    int histogram[1024] = {0}, total = 0;
    for (int i = 0; i < count; i++) if (!select || select[i]) { histogram[MAX(0, MIN(1023, (int)(v[i] * 1023)))]++; total++; }
    int target = (int)(total * p), seen = 0;
    for (int b = 0; b < 1024; b++) { seen += histogram[b]; if (seen > target) return b / 1023.f; }
    return 1;
}

static void CDStretch(const float *in, float *out, const uint8_t *select, int count, float lowP, float highP, float minRange) {
    float lo = CDPercentile(in, select, count, lowP), hi = CDPercentile(in, select, count, highP);
    float range = MAX(minRange, hi - lo);
    for (int i = 0; i < count; i++) out[i] = MAX(0, MIN(1, (in[i] - lo) / range));
}

/// Kuwahara filter: each pixel takes the mean of the flattest of its four neighbouring squares — smooths texture, keeps edges.
static void CDKuwahara(const float *in, float *out, int n, int r) {
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        float bestVar = INFINITY, bestMean = in[y * n + x];
        for (int q = 0; q < 4; q++) {
            int ox = (q & 1) ? 0 : -r, oy = (q & 2) ? 0 : -r;
            float sum = 0, sum2 = 0; int count = 0;
            for (int dy = 0; dy <= r; dy++) for (int dx = 0; dx <= r; dx++) {
                float v = in[MAX(0, MIN(n - 1, y + oy + dy)) * n + MAX(0, MIN(n - 1, x + ox + dx))];
                sum += v; sum2 += v * v; count++;
            }
            float mean = sum / count, var = sum2 / count - mean * mean;
            if (var < bestVar) { bestVar = var; bestMean = mean; }
        }
        out[y * n + x] = bestMean;
    }
}

static void CDGaussian(const float *in, float *out, int n, float sigma) {
    int r = MIN(15, (int)ceilf(sigma * 3));
    float kernel[31], sum = 0;
    for (int k = -r; k <= r; k++) { kernel[k + r] = expf(-(k * k) / (2 * sigma * sigma)); sum += kernel[k + r]; }
    for (int k = 0; k <= 2 * r; k++) kernel[k] /= sum;
    float *tmp = malloc(sizeof(float) * n * n);
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        float acc = 0;
        for (int k = -r; k <= r; k++) acc += kernel[k + r] * in[y * n + MAX(0, MIN(n - 1, x + k))];
        tmp[y * n + x] = acc;
    }
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        float acc = 0;
        for (int k = -r; k <= r; k++) acc += kernel[k + r] * tmp[MAX(0, MIN(n - 1, y + k)) * n + x];
        out[y * n + x] = acc;
    }
    free(tmp);
}

/// Two thresholds splitting the selected values into three classes with the most separation (multi-level Otsu).
static void CDOtsu3(const float *v, const uint8_t *select, int count, float *t1, float *t2) {
    double p[64] = {0}, total = 0;
    for (int i = 0; i < count; i++) if (!select || select[i]) { p[MAX(0, MIN(63, (int)(v[i] * 64)))]++; total++; }
    double w[65] = {0}, m[65] = {0};
    for (int b = 0; b < 64; b++) { p[b] /= MAX(1, total); w[b + 1] = w[b] + p[b]; m[b + 1] = m[b] + p[b] * (b + .5) / 64; }
    double mt = m[64], best = -1;
    *t1 = 1 / 3.f; *t2 = 2 / 3.f;
    for (int a = 1; a < 63; a++) for (int b = a + 1; b < 64; b++) {
        double w0 = w[a], w1 = w[b] - w[a], w2 = 1 - w[b];
        if (w0 <= 0 || w1 <= 0 || w2 <= 0) continue;
        double m0 = m[a] / w0, m1 = (m[b] - m[a]) / w1, m2 = (mt - m[b]) / w2;
        double between = w0 * (m0 - mt) * (m0 - mt) + w1 * (m1 - mt) * (m1 - mt) + w2 * (m2 - mt) * (m2 - mt);
        if (between > best) { best = between; *t1 = a / 64.f; *t2 = b / 64.f; }
    }
}

/// Visits the connected region of pixels with `labels[i] == label` around `start` (breadth first).
/// The region's pixel indices are left in `queue[0 …< returned count]`.
static int CDRegion(const uint8_t *labels, uint8_t label, int n, int start, BOOL eightWay, uint8_t *seen, int *queue) {
    int head = 0, tail = 0;
    queue[tail++] = start; seen[start] = 1;
    while (head < tail) {
        int i = queue[head++], x = i % n, y = i / n;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            if ((!dx && !dy) || (!eightWay && dx && dy)) continue;
            int nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= n || ny >= n) continue;
            int j = ny * n + nx;
            if (!seen[j] && labels[j] == label) { seen[j] = 1; queue[tail++] = j; }
        }
    }
    return tail;
}

/// Specks: any 4-connected patch smaller than `minSize` takes the label most common along its border. Two passes.
static void CDMergeSpecks(uint8_t *labels, int n, int labelCount, int minSize) {
    int count = n * n, *queue = malloc(sizeof(int) * count);
    uint8_t *seen = malloc(count);
    for (int pass = 0; pass < 2; pass++) {
        memset(seen, 0, count);
        for (int i = 0; i < count; i++) {
            if (seen[i]) continue;
            uint8_t label = labels[i];
            int size = CDRegion(labels, label, n, i, NO, seen, queue);
            if (size >= minSize) continue;
            int votes[8] = {0};
            for (int k = 0; k < size; k++) {
                int j = queue[k], x = j % n, y = j / n;
                int nb[4][2] = {{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}};
                for (int q = 0; q < 4; q++) {
                    int nx = nb[q][0], ny = nb[q][1];
                    if (nx < 0 || ny < 0 || nx >= n || ny >= n) continue;
                    uint8_t other = labels[ny * n + nx];
                    if (other != label && other < labelCount) votes[other]++;
                }
            }
            int best = -1;
            for (int l = 0; l < labelCount; l++) if (votes[l] && (best < 0 || votes[l] > votes[best])) best = l;
            if (best >= 0) for (int k = 0; k < size; k++) labels[queue[k]] = (uint8_t)best;
        }
    }
    free(queue); free(seen);
}

/// Keeps only 8-connected runs of `mask` with at least `minSize` pixels.
static void CDKeepLong(uint8_t *mask, int n, int minSize) {
    int count = n * n, *queue = malloc(sizeof(int) * count);
    uint8_t *seen = calloc(count, 1);
    for (int i = 0; i < count; i++) {
        if (!mask[i] || seen[i]) continue;
        int size = CDRegion(mask, 1, n, i, YES, seen, queue);
        if (size < minSize) for (int k = 0; k < size; k++) mask[queue[k]] = 0;
    }
    free(queue); free(seen);
}

static void CDMorph(const uint8_t *in, uint8_t *out, int n, int r, BOOL dilate) {
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        uint8_t v = dilate ? 0 : 1;
        for (int dy = -r; dy <= r && v == (dilate ? 0 : 1); dy++) for (int dx = -r; dx <= r; dx++) {
            int nx = x + dx, ny = y + dy;
            uint8_t s = (nx < 0 || ny < 0 || nx >= n || ny >= n) ? 0 : in[ny * n + nx];
            if (dilate && s) { v = 1; break; }
            if (!dilate && !s) { v = 0; break; }
        }
        out[y * n + x] = v;
    }
}

/// Dark side of edges: difference of Gaussians below −k.
static void CDDarkEdges(const float *v, uint8_t *out, int n, float k) {
    float *a = malloc(sizeof(float) * n * n), *b = malloc(sizeof(float) * n * n);
    CDGaussian(v, a, n, .7f);
    CDGaussian(v, b, n, 1.6f);
    for (int i = 0; i < n * n; i++) out[i] = a[i] - b[i] < -k;
    free(a); free(b);
}

/// Threshold splitting the selected values into two classes with the most separation (Otsu).
static float CDOtsu2(const float *v, const uint8_t *select, int count) {
    double p[64] = {0}, total = 0;
    for (int i = 0; i < count; i++) if (!select || select[i]) { p[MAX(0, MIN(63, (int)(v[i] * 64)))]++; total++; }
    double w = 0, m = 0, mt = 0, best = -1;
    for (int b = 0; b < 64; b++) { p[b] /= MAX(1, total); mt += p[b] * (b + .5) / 64; }
    float threshold = .5f;
    for (int t = 1; t < 64; t++) {
        w += p[t - 1]; m += p[t - 1] * (t - .5) / 64;
        if (w <= 0 || w >= 1) continue;
        double m0 = m / w, m1 = (mt - m) / (1 - w), between = w * (1 - w) * (m0 - m1) * (m0 - m1);
        if (between > best) { best = between; threshold = t / 64.f; }
    }
    return threshold;
}

/// Clears ink pixels with no inked neighbour. `scratch` is n × n.
static void CDSweepLoneDots(uint8_t *ink, uint8_t *scratch, int n) {
    memcpy(scratch, ink, n * n);
    for (int i = 0; i < n * n; i++) {
        if (!scratch[i]) continue;
        int x = i % n, y = i / n, neighbours = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int nx = x + dx, ny = y + dy;
            if ((dx || dy) && nx >= 0 && ny >= 0 && nx < n && ny < n) neighbours += scratch[ny * n + nx];
        }
        if (!neighbours) ink[i] = 0;
    }
}

#pragma mark - Render

NSData *CDPixelArtRender(CGImageRef image, CGImageRef mask, int n, BOOL lightInk) {
    int count = n * n, r = n < 100 ? 2 : 3, minSize = MAX(6, count / 1200), rr = MAX(1, (int)lroundf(n / 40.f));
    float *y = CDSampleSquare(image, n, YES);
    if (lightInk) for (int i = 0; i < count; i++) y[i] = 1 - y[i];
    NSMutableData *result = [NSMutableData dataWithLength:count];
    uint8_t *ink = result.mutableBytes;
    uint8_t *subject = calloc(count, 1), *labels = malloc(count), *tmp = malloc(count), *tmp2 = malloc(count);
    float *ys = malloc(sizeof(float) * count), *smooth = malloc(sizeof(float) * count);
    int subjectCount = 0;
    BOOL backgroundDone = NO;
    if (mask) {
        float *alpha = CDSampleSquare(mask, n, NO);
        for (int i = 0; i < count; i++) labels[i] = alpha[i] > .5f;
        free(alpha);
        CDMergeSpecks(labels, n, 2, minSize);
        for (int i = 0; i < count; i++) { subject[i] = labels[i]; subjectCount += labels[i]; }
    }
    if (subjectCount >= count * .02f) {
        // Subject. Thin, logo-like shapes (lettering, a symbol) become solid; anything with body gets three flat
        // tones (solid, an even checkerboard, blank), its own contours and features, and a firm outline.
        CDMorph(subject, tmp, n, rr, NO);
        int core = 0;
        for (int i = 0; i < count; i++) core += tmp[i];
        if (core < .3f * subjectCount) {
            for (int i = 0; i < count; i++) ink[i] |= subject[i];
        } else {
            CDStretch(y, ys, subject, count, .02f, .98f, .1f);
            CDKuwahara(ys, smooth, n, r);
            float t1, t2;
            CDOtsu3(smooth, subject, count, &t1, &t2);
            for (int i = 0; i < count; i++) labels[i] = subject[i] ? (smooth[i] < t1 ? 0 : smooth[i] < t2 ? 1 : 2) : 3;
            CDMergeSpecks(labels, n, 4, 4);
            for (int i = 0; i < count; i++) if (!subject[i]) labels[i] = 3;
            for (int i = 0; i < count; i++) {
                int x = i % n, yy = i / n;
                if (labels[i] == 0 || (labels[i] == 1 && (x + yy) % 2 == 0)) ink[i] = 1;
            }
            CDDarkEdges(smooth, tmp2, n, .035f);
            CDKeepLong(tmp2, n, 5);
            for (int i = 0; i < count; i++) if (tmp2[i] && subject[i] && labels[i] != 0) ink[i] = 1;
            CDDarkEdges(ys, tmp2, n, .03f);
            for (int i = 0; i < count; i++) tmp2[i] = tmp2[i] && subject[i] && labels[i] == 2;
            CDKeepLong(tmp2, n, 2);
            for (int i = 0; i < count; i++) ink[i] |= tmp2[i];
            // Outline, and thin parts (fingers, strands) solid.
            CDMorph(tmp, tmp2, n, rr, YES);
            for (int i = 0; i < count; i++) {
                int x = i % n, yy = i / n;
                if (!subject[i]) continue;
                BOOL edge = x == 0 || yy == 0 || x == n - 1 || yy == n - 1 || !subject[i - 1] || !subject[i + 1] || !subject[i - n] || !subject[i + n];
                if (edge || !tmp2[i]) ink[i] = 1;
            }
        }
        // Background: its light and dark areas only, the darker ones laid in a sparse, perfectly regular dot
        // screen (one pixel in four) — the composition shows, but never a stray dot. Lightly smoothed, and only
        // patches of a few dots or more, so the shading follows the real background closely.
        CDMorph(subject, tmp, n, 1, YES);
        int backgroundCount = 0;
        for (int i = 0; i < count; i++) { tmp[i] = !tmp[i]; backgroundCount += tmp[i]; }
        if (backgroundCount > count * .05f) {
            CDKuwahara(y, ys, n, 1);
            CDGaussian(ys, smooth, n, .6f);
            float t = CDOtsu2(smooth, tmp, count);
            for (int i = 0; i < count; i++) labels[i] = tmp[i] ? (smooth[i] < t ? 0 : 1) : 2;
            CDMergeSpecks(labels, n, 3, MAX(8, count / 200));
            int dark = 0;
            for (int i = 0; i < count; i++) { if (!tmp[i]) labels[i] = 2; dark += labels[i] == 0; }
            if (dark >= .04f * backgroundCount) {
                CDSweepLoneDots(ink, tmp2, n);
                for (int i = 0; i < count; i++) if (labels[i] == 0 && (i / n) % 2 == 0 && (i % n) % 2 == 0) ink[i] = 1;
                backgroundDone = YES;
            }
        }
    } else {
        // Nothing stands out (abstract art, pure typography): posterise the whole cover into clean flat shapes.
        CDStretch(y, ys, NULL, count, .015f, .985f, .1f);
        CDKuwahara(ys, smooth, n, r);
        float t1, t2;
        CDOtsu3(smooth, NULL, count, &t1, &t2);
        for (int i = 0; i < count; i++) labels[i] = smooth[i] < t1 ? 0 : smooth[i] < t2 ? 1 : 2;
        CDMergeSpecks(labels, n, 3, minSize);
        for (int i = 0; i < count; i++) {
            int x = i % n, yy = i / n;
            if (labels[i] == 0 || (labels[i] == 1 && (x + yy) % 2 == 0)) ink[i] = 1;
        }
    }
    // Last sweep: no lone dots (the background screen, added after its own sweep, is the one deliberate exception).
    if (!backgroundDone) CDSweepLoneDots(ink, tmp, n);
    free(y); free(subject); free(labels); free(tmp); free(tmp2); free(ys); free(smooth);
    return result;
}
