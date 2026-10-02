// Reuses the macOS material renderer; exports only reusable shells and moving parts.
#import "../../CDHeroes.h"
#import "../../CDRetroPlayer.h"
#import <QuartzCore/QuartzCore.h>
#include "WallMaterial.generated.m"
static NSString *output;
static void Save(CALayer *layer, NSString *name) {
    CGSize size=layer.bounds.size;
    CGImageRef image=CDRenderImage(size, 2, ^(CGContextRef ctx, CGSize s){[layer renderInContext:ctx];});
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    CGImageRelease(image);
}
static CALayer *Layer(id view,NSString *key){return [view valueForKey:key];}
static void Hidden(id view,NSString *key,BOOL value){Layer(view,key).hidden=value;}
int main(int argc,char **argv) {@autoreleasepool {
    [NSApplication sharedApplication]; output=[NSString stringWithUTF8String:argv[1]];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(-9000,0,1000,1000) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    for(int theme=0;theme<8;theme++) {
        CDPalette *palette=[CDPalette paletteAtIndex:theme];
        for(int style=0;style<4;style++) {
            CGImageRef image=WallSkin(200,style,palette.light);
            NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
            NSString *name=[NSString stringWithFormat:@"wall-%d-%d.png",style,theme];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES];CGImageRelease(image);
        }
        CDNowPlaying *np=[CDNowPlaying new];np.album=@" ";np.hasSession=YES;
        CDDiscHero *disc=[[CDDiscHero alloc] initWithFrame:NSMakeRect(0,0,996,600)]; disc.np=np;disc.palette=palette;
        [window.contentView addSubview:disc];[disc layoutSubtreeIfNeeded];
        Hidden(disc,@"insert",YES);Hidden(disc,@"caseBack",YES);
        Save(Layer(disc,@"caseHost"),[NSString stringWithFormat:@"disc-glass-%d",theme]);
        Hidden(disc,@"caseBack",NO);Save(Layer(disc,@"caseBack"),[NSString stringWithFormat:@"disc-back-%d",theme]);
        Hidden(disc,@"print",YES);Save(Layer(disc,@"rotor"),[NSString stringWithFormat:@"disc-rotor-%d",theme]);
        Hidden(disc,@"rotor",YES);Save(Layer(disc,@"discHost"),[NSString stringWithFormat:@"disc-light-%d",theme]);
        [disc removeFromSuperview];
        CDCassetteHero *cassette=[[CDCassetteHero alloc] initWithFrame:NSMakeRect(0,0,1000,638)];cassette.np=np;cassette.palette=palette;
        [window.contentView addSubview:cassette];[cassette layoutSubtreeIfNeeded];
        for(NSString *key in @[@"interior",@"skin",@"label",@"glass",@"leftHub",@"reelLight"]) Save(Layer(cassette,key),[NSString stringWithFormat:@"cassette-%@-%d",key,theme]);
        [cassette removeFromSuperview];
        CDPixelScreenView *pixel=[[CDPixelScreenView alloc] initWithFrame:NSMakeRect(0,0,1053,813)];pixel.np=np;pixel.palette=palette;
        [window.contentView addSubview:pixel];[pixel layoutSubtreeIfNeeded];
        Save(Layer(pixel,@"shell"),[NSString stringWithFormat:@"pixel-shell-%d",theme]);
        Save(Layer(pixel,@"glare"),[NSString stringWithFormat:@"pixel-glare-%d",theme]);
        [pixel removeFromSuperview];
    }
    return 0;
}}
