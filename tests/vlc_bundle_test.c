#include <vlc/vlc.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: vlc_bundle_test <bundled plugins> <audio file>\n");
        return 2;
    }
    setenv("VLC_PLUGIN_PATH", argv[1], 1);
    const char *options[] = {"--quiet", "--no-video", "--no-metadata-network-access", "--aout=dummy"};
    libvlc_instance_t *vlc = libvlc_new(4, options);
    if (!vlc) { fprintf(stderr, "bundled libVLC did not initialize\n"); return 1; }
    libvlc_media_t *media = libvlc_media_new_path(vlc, argv[2]);
    libvlc_media_player_t *player = media ? libvlc_media_player_new_from_media(media) : NULL;
    if (media) libvlc_media_release(media);
    int started = player ? libvlc_media_player_play(player) : -1;
    int playable = 0;
    for (int i = 0; started == 0 && i < 50; i++) {
        libvlc_state_t state = libvlc_media_player_get_state(player);
        if ((state == libvlc_Playing && libvlc_media_player_get_time(player) >= 200) ||
            (state == libvlc_Ended && libvlc_media_player_get_length(player) > 0)) { playable = 1; break; }
        if (state == libvlc_Error) break;
        usleep(100000);
    }
    if (player) { libvlc_media_player_stop(player); libvlc_media_player_release(player); }
    libvlc_release(vlc);
    if (!playable) { fprintf(stderr, "bundled VLC could not play the test audio\n"); return 1; }
    puts("bundled VLC initialized and played audio");
    return 0;
}
