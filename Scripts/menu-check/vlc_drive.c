/* vlc_drive: plays a Blu-ray menu disc in real VLC (libvlc 3, from
 * /Applications/VLC.app) and reports which subtitle track VLC selected.
 *
 *   Scripts/menu-check/vlc_drive.sh DISC "STEPS"
 *
 * STEPS: R L U D E = right/left/up/down/enter with a pause after each;
 * r l e = the same with no pause (a fast remote); T = Top Menu; P = toggle
 * pause; Kn = seek to n s; Wn = wait n s; S = print the selected SPU track.
 * Example (titleCard menu: Play, Scenes, Subtitles On, Subtitles Off):
 *   "W4RRE W1LLE W5S T W3 rrrelllE W2S LLLE W6S"
 * turns subtitles on, plays, goes back to the menu, presses Off and quickly
 * Play, then Play again, and prints the SPU state after each film start.
 */
#include <vlc/vlc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void logcb(void *data, int level, const libvlc_log_t *ctx, const char *fmt, va_list args)
{
    (void)data; (void)level;
    const char *module = NULL, *file = NULL; unsigned line;
    libvlc_log_get_context(ctx, &module, &file, &line);
    char buf[1024];
    vsnprintf(buf, sizeof buf, fmt, args);
    if (strstr(buf, "ES ") || strstr(buf, "spu") || strstr(buf, "PG") || strstr(buf, "Trashing") || strstr(buf, "TopMenu"))
        if (module && (!strcmp(module, "libbluray") || !strcmp(module, "bluray") || strstr(file ? file : "", "bluray")))
            printf("    [vlc %s] %s\n", module, buf);
}

static void report(libvlc_media_player_t *mp, const char *label)
{
    int spu = libvlc_video_get_spu(mp);
    int count = libvlc_video_get_spu_count(mp);
    printf("%s: selected spu %d (%#x), %d spu tracks, time %.1f s, title %d\n", label, spu, spu, count,
           libvlc_media_player_get_time(mp) / 1000.0, libvlc_media_player_get_title(mp));
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: vlcdrive DISC STEPS\n"); return 2; }
    const char *args[] = { "--vout=dummy", "--aout=dummy", "--no-video-title-show", "--verbose=2" };
    libvlc_instance_t *vlc = libvlc_new(4, args);
    if (!vlc) { fprintf(stderr, "libvlc_new failed\n"); return 1; }
    libvlc_log_set(vlc, logcb, NULL);
    char mrl[4096];
    snprintf(mrl, sizeof mrl, "bluray://%s", argv[1]);
    libvlc_media_t *m = libvlc_media_new_location(vlc, mrl);
    libvlc_media_player_t *mp = libvlc_media_player_new_from_media(m);
    libvlc_media_player_play(mp);
    for (const char *s = argv[2]; *s; s++) {
        switch (*s) {
        case 'R': libvlc_media_player_navigate(mp, libvlc_navigate_right); usleep(300000); break;
        case 'L': libvlc_media_player_navigate(mp, libvlc_navigate_left); usleep(300000); break;
        case 'U': libvlc_media_player_navigate(mp, libvlc_navigate_up); usleep(300000); break;
        case 'D': libvlc_media_player_navigate(mp, libvlc_navigate_down); usleep(300000); break;
        case 'E': printf("  activate\n"); libvlc_media_player_navigate(mp, libvlc_navigate_activate); usleep(500000); break;
        case 'T': printf("  top menu\n"); libvlc_media_player_set_title(mp, 0); usleep(500000); break;
        case 'r': libvlc_media_player_navigate(mp, libvlc_navigate_right); break;
        case 'l': libvlc_media_player_navigate(mp, libvlc_navigate_left); break;
        case 'e': printf("  activate (fast)\n"); libvlc_media_player_navigate(mp, libvlc_navigate_activate); break;
        case 'S': report(mp, "  state"); break;
        case 'P': printf("  pause toggle\n"); libvlc_media_player_pause(mp); usleep(300000); break;
        case 'K': { int n = atoi(s + 1); while (s[1] >= '0' && s[1] <= '9') s++;
                    printf("  seek to %d s\n", n); libvlc_media_player_set_time(mp, (libvlc_time_t)n * 1000); usleep(500000); break; }
        case 'W': { int n = atoi(s + 1); while (s[1] >= '0' && s[1] <= '9') s++; sleep((unsigned)n); break; }
        default: break;
        }
    }
    libvlc_media_player_stop(mp);
    libvlc_media_player_release(mp);
    libvlc_media_release(m);
    libvlc_release(vlc);
    return 0;
}
