#!/bin/zsh
set -euo pipefail
root="${0:A:h:h:h}"
build_dir=$(mktemp -d /tmp/cdglass-materials.XXXXXX)
# The label's artwork is supplied dynamically by Windows. Keep its paper margin,
# wear, reflections and blank title tape, and leave the print area transparent.
python3 - "$root/CDHeroes.m" "$build_dir/CDHeroes.m" <<'PY'
import sys
s=open(sys.argv[1]).read()
s=s.replace('CGContextSetFillColorWithColor(ctx, paper.CGColor);\n            CGContextFillPath(ctx);','CGContextSetFillColorWithColor(ctx, [paper colorWithAlphaComponent:look == CDCassetteLookCoverLabel ? 0 : 1].CGColor);\n            CGContextFillPath(ctx);')
s=s.replace('CGContextSetFillColorWithColor(ctx, CDMix(p.accent, paper, .4).CGColor); CGContextFillRect(ctx, art);','CGContextSetFillColorWithColor(ctx, NSColor.clearColor.CGColor); CGContextFillRect(ctx, art);')
s=s.replace('[NSColor colorWithWhite:.5 alpha:.14].CGColor','[NSColor colorWithWhite:.5 alpha:0].CGColor')
s=s.replace('text.size.width + 11 * k','38 * k')
s=s.replace('[text drawWithRect:CGRectMake(-w / 2 + 3 * k, -text.size.height / 2 + .3 * k, w - 6 * k, text.size.height) options:NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];','')
open(sys.argv[2],'w').write(s)
PY
python3 - "$root/CDAlbumWall.m" "$build_dir/WallMaterial.generated.m" <<'PYWALL'
import sys
s=open(sys.argv[1]).read()
helpers=s[s.index('static uint64_t CDWHash64'):s.index('// Springs always')]
helpers+=s[s.index('static CGColorSpaceRef CDWSRGB'):s.index('/// Text into an unflipped')]
art=s[s.index('- (CGRect)artRectForSide:'):s.index('- (CGFloat)cornerForSide:')].replace('- (CGRect)artRectForSide:(CGFloat)s {','static CGRect WallArt(CGFloat s, NSInteger style) {').replace('self.playerStyle','style')
corner=s[s.index('- (CGFloat)cornerForSide:'):s.index('- (id)skinForSide:')].replace('- (CGFloat)cornerForSide:(CGFloat)s {','static CGFloat WallCorner(CGFloat s, NSInteger style) {').replace('self.playerStyle','style')
body=s[s.index('    CGFloat r = [self cornerForSide:s];'):s.index('- (id)tapeImageForSide:')]
body=body.replace('[self cornerForSide:s]','WallCorner(s,style)').replace('[self artRectForSide:s]','WallArt(s,style)').replace('    NSInteger style = self.playerStyle;\n','').replace('    BOOL light = self.palette.light;\n','').replace('self.scale','2')
body=body[:body.index('    id object = image ?')]+ '    return image;\n}\n'
open(sys.argv[2],'w').write(helpers+art+corner+'static CGImageRef WallSkin(CGFloat s, NSInteger style, BOOL light) {\n'+body)
PYWALL
CLANG_MODULE_CACHE_PATH="$root/../clang-cache" clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 -w -I "$root" -I "$build_dir" "$root/windows/tools/export_materials.m" "$build_dir/CDHeroes.m" "$root/CDTheme.m" "$root/CDPixelArt.m" "$root/CDRetroPlayer.m" -o "$build_dir/export" -framework AppKit -framework QuartzCore -framework CoreImage -framework Vision
"$build_dir/export" "$root/windows/CDGlass.Windows/Assets/Materials"
rm -rf "$build_dir"
