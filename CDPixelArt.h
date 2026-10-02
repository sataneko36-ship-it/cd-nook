#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lifts the main subject (characters, people, a logo…) off the cover with Vision, on device.
/// Returns an 8-bit gray mask the size of the image (white = subject), or NULL when nothing stands out.
/// Slow-ish (tens of ms, more on first use): call it off the main thread.
CGImageRef _Nullable CDCreateSubjectMask(CGImageRef image) CF_RETURNS_RETAINED;

/// Detects faces (works on photos, rarely on drawn characters). On success, `faces` is the area-weighted union
/// of the faces, normalised 0…1 with y measured from the top.
BOOL CDFindFaces(CGImageRef image, CGRect *faces);

/// Turns a cover into clean one-bit pixel art, `side` × `side`, centre-cropped. One byte per pixel, 1 = lit ink.
/// With a subject mask, the subject keeps its outline and a few flat tones, and the background shows only its
/// light and dark areas as a sparse, regular dot screen; without one, the whole cover is posterised.
/// `lightInk` is for screens whose lit pixels are lighter than the glass, so the art does not come out as a negative.
NSData *CDPixelArtRender(CGImageRef image, CGImageRef _Nullable mask, int side, BOOL lightInk);

NS_ASSUME_NONNULL_END
