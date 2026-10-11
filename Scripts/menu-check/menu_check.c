/*
 * menu_check: plays a Lacquer menu disc through libbluray's HDMV navigation
 * (the code VLC uses for Blu-ray menus) and checks that the menu works.
 *
 *   menu_check DISC --chapters 0,20,40 [--subtitles] [--still] [--verbose]
 *
 * --still: the menu is a still (infinite PlayItem still) rather than a
 * loop, so check that it holds instead of checking the loop restart.
 *
 * DISC is a BDMV folder or an ISO. The checks assume the layout of
 * Lacquer's --menu-demo menu: a main page of Play, Scenes and (with
 * --subtitles) Subtitles On / Subtitles Off stacked vertically; scene pages
 * of chapter buttons in rows of four with Back and Next below; the film as
 * playlist 00000 and menu page p as playlist 01000 + p.
 *
 * Button states are told apart by brightness, as the demo draws them:
 * normal is a dark plate, selected amber, activated white.
 *
 * Prints one PASS/FAIL line per check and exits non-zero on any failure.
 */
#include <libbluray/bluray.h>
#include <libbluray/keys.h>
#include <libbluray/log_control.h>
#include <libbluray/overlay.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FILM_PLAYLIST 0
#define MENU_PLAYLIST 1000
#define MAX_DRAWS 1024

typedef struct {
    int x, y, w, h;
    int luma; /* mean Y of the opaque pixels */
} Draw;

typedef struct {
    int verbose;
    int playlist, title, chapter;
    int playlist_starts;
    int pg_stream, pg_enabled;
    int ig_flushes;
    Draw draws[MAX_DRAWS];
    int ndraws;
} Ctx;

static int failures = 0;

static void check(int ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (!ok) failures++;
}

/* ---- Overlay callback: record every IG draw with its brightness. */

static int mean_luma(const BD_OVERLAY *ov)
{
    long sum = 0, n = 0, pixels = (long)ov->w * ov->h, done = 0;
    const BD_PG_RLE_ELEM *e = ov->img;
    if (!e || !ov->palette) return -1;
    while (done < pixels) {
        if (e->len == 0) { e++; continue; } /* end of line */
        const BD_PG_PALETTE_ENTRY *p = &ov->palette[e->color];
        if (p->T > 128) { sum += (long)p->Y * e->len; n += e->len; }
        done += e->len;
        e++;
    }
    return n ? (int)(sum / n) : -1;
}

static void overlay_cb(void *handle, const BD_OVERLAY *ov)
{
    Ctx *c = handle;
    if (!ov || ov->plane != BD_OVERLAY_IG) return;
    switch (ov->cmd) {
    case BD_OVERLAY_DRAW:
        if (c->ndraws < MAX_DRAWS) {
            Draw *d = &c->draws[c->ndraws++];
            d->x = ov->x; d->y = ov->y; d->w = ov->w; d->h = ov->h;
            d->luma = mean_luma(ov);
            if (c->verbose) printf("      draw %4d,%4d %4dx%-4d luma %d\n", d->x, d->y, d->w, d->h, d->luma);
        }
        break;
    case BD_OVERLAY_FLUSH:
        c->ig_flushes++;
        break;
    default:
        break;
    }
}

/* ---- Button bookkeeping. */

enum { NORMAL, SELECTED, ACTIVATED, UNKNOWN };
static const char *state_name[] = { "normal", "selected", "activated", "unknown" };

static int classify(int luma)
{
    if (luma < 0) return UNKNOWN;
    if (luma < 100) return NORMAL;
    if (luma < 200) return SELECTED;
    return ACTIVATED;
}

typedef struct { int x, y, w, h; } Rect;

static int rect_cmp(const void *a, const void *b)
{
    const Rect *p = a, *q = b;
    return p->y != q->y ? p->y - q->y : p->x - q->x;
}

/* Distinct rectangles drawn since the log was cleared, top to bottom, left
 * to right: the page's buttons in id order for the demo layout. */
static int page_buttons(const Ctx *c, Rect *out, int max)
{
    int n = 0;
    for (int i = 0; i < c->ndraws; i++) {
        int seen = 0;
        for (int j = 0; j < n; j++)
            if (out[j].x == c->draws[i].x && out[j].y == c->draws[i].y) seen = 1;
        if (!seen && n < max) {
            out[n].x = c->draws[i].x; out[n].y = c->draws[i].y;
            out[n].w = c->draws[i].w; out[n].h = c->draws[i].h;
            n++;
        }
    }
    qsort(out, n, sizeof(Rect), rect_cmp);
    return n;
}

/* Latest state drawn at a rectangle since the log was cleared. */
static int state_at(const Ctx *c, Rect r)
{
    for (int i = c->ndraws - 1; i >= 0; i--)
        if (c->draws[i].x == r.x && c->draws[i].y == r.y) return classify(c->draws[i].luma);
    return UNKNOWN;
}

static void clear_log(Ctx *c) { c->ndraws = 0; c->ig_flushes = 0; }

/* ---- Event pump. */

static void handle_event(Ctx *c, const BD_EVENT *ev)
{
    switch (ev->event) {
    case BD_EVENT_PLAYLIST:          c->playlist = ev->param; c->playlist_starts++; break;
    case BD_EVENT_TITLE:             c->title = ev->param; break;
    case BD_EVENT_CHAPTER:           c->chapter = ev->param; break;
    case BD_EVENT_PG_TEXTST_STREAM:  c->pg_stream = ev->param; break;
    case BD_EVENT_PG_TEXTST:         c->pg_enabled = ev->param; break;
    default: break;
    }
    if (c->verbose && ev->event != BD_EVENT_NONE)
        printf("    event %-22s %u\n", bd_event_name(ev->event), ev->param);
}

static void drain_events(BLURAY *bd, Ctx *c)
{
    BD_EVENT ev;
    while (bd_get_event(bd, &ev)) handle_event(c, &ev);
}

typedef int (*cond_f)(const Ctx *, int arg);

/* Reads the stream until cond holds or max_blocks aligned units pass. */
static int pump(BLURAY *bd, Ctx *c, int max_blocks, cond_f cond, int arg)
{
    static unsigned char buf[6144];
    drain_events(bd, c);
    for (int i = 0; i < max_blocks; i++) {
        if (cond(c, arg)) return 1;
        BD_EVENT ev;
        int r = bd_read_ext(bd, buf, sizeof buf, &ev);
        if (r < 0) { if (c->verbose) printf("    read error\n"); return 0; }
        handle_event(c, &ev);
        drain_events(bd, c);
    }
    return cond(c, arg);
}

static int menu_drawn(const Ctx *c, int playlist)
{
    return c->playlist == playlist && c->ig_flushes > 0 && c->ndraws > 0;
}
static int on_playlist(const Ctx *c, int playlist) { return c->playlist == playlist; }
static int looped(const Ctx *c, int starts) { return c->playlist_starts > starts && c->ig_flushes > 0; }
static int on_chapter(const Ctx *c, int chapter) { return c->playlist == FILM_PLAYLIST && c->chapter == chapter; }

static void key(BLURAY *bd, Ctx *c, uint32_t k, const char *name)
{
    if (c->verbose) printf("  key %s\n", name);
    bd_user_input(bd, -1, k);
    drain_events(bd, c);
}

/* Opens the menu page shown after Top Menu and returns its buttons. */
static int top_menu(BLURAY *bd, Ctx *c, Rect *buttons, int max)
{
    clear_log(c);
    c->playlist = -1;
    if (c->verbose) printf("  Top Menu\n");
    bd_menu_call(bd, -1);
    if (!pump(bd, c, 4000, menu_drawn, MENU_PLAYLIST)) return 0;
    return page_buttons(c, buttons, max);
}

int main(int argc, char **argv)
{
    const char *disc = NULL;
    double chapters[64];
    int nchapters = 0, subtitles = 0, still = 0;
    Ctx c;
    memset(&c, 0, sizeof c);
    c.playlist = c.title = c.chapter = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--verbose")) c.verbose = 1;
        else if (!strcmp(argv[i], "--subtitles")) subtitles = 1;
        else if (!strcmp(argv[i], "--still")) still = 1;
        else if (!strcmp(argv[i], "--chapters") && i + 1 < argc) {
            char *s = argv[++i];
            while (*s && nchapters < 64) {
                chapters[nchapters++] = strtod(s, &s);
                if (*s == ',') s++;
            }
        } else disc = argv[i];
    }
    if (!disc || nchapters == 0) {
        fprintf(stderr, "usage: menu_check DISC --chapters 0,20,40 [--subtitles] [--verbose]\n");
        return 2;
    }
    if (!c.verbose) bd_set_debug_mask(0);

    BLURAY *bd = bd_open(disc, NULL);
    check(bd != NULL, "libbluray opens %s", disc);
    if (!bd) return 1;
    const BLURAY_DISC_INFO *info = bd_get_disc_info(bd);
    check(info && info->first_play_supported && info->top_menu_supported && info->num_hdmv_titles == 1,
          "index.bdmv has First Play, Top Menu and one HDMV title");

    bd_register_overlay_proc(bd, &c, overlay_cb);
    int expect_main = subtitles ? 4 : 2;
    int scene_tiles = nchapters < 8 ? nchapters : 8;
    int expect_scene = scene_tiles + 1 + (nchapters > 8);
    Rect main_btn[64], scene_btn[64];

    /* 1. First Play opens the menu page with its buttons. */
    check(bd_play(bd) > 0, "bd_play starts navigation");
    int ok = pump(bd, &c, 4000, menu_drawn, MENU_PLAYLIST);
    int n = ok ? page_buttons(&c, main_btn, 64) : 0;
    check(ok && n == expect_main, "First Play shows menu playlist %05d with %d buttons (drew %d)",
          MENU_PLAYLIST, expect_main, n);
    if (n != expect_main) goto done;
    check(state_at(&c, main_btn[0]) == SELECTED && state_at(&c, main_btn[1]) == NORMAL,
          "Play is selected by default, Scenes is normal (%s, %s)",
          state_name[state_at(&c, main_btn[0])], state_name[state_at(&c, main_btn[1])]);

    /* 2. Down moves the selection. */
    clear_log(&c);
    key(bd, &c, BD_VK_DOWN, "DOWN");
    check(state_at(&c, main_btn[1]) == SELECTED && state_at(&c, main_btn[0]) == NORMAL,
          "DOWN selects Scenes and deselects Play (%s, %s)",
          state_name[state_at(&c, main_btn[1])], state_name[state_at(&c, main_btn[0])]);
    if (still) {
        /* A still menu holds: reading on changes nothing and keeps the menu. */
        int starts = c.playlist_starts;
        clear_log(&c);
        pump(bd, &c, 5000, looped, starts);
        check(c.playlist_starts == starts && c.playlist == MENU_PLAYLIST && c.ndraws == 0,
              "the still menu holds with Scenes selected");
    } else {
        /* The menu clip loops; the selection should survive the restart. */
        int starts = c.playlist_starts;
        clear_log(&c);
        ok = pump(bd, &c, 40000, looped, starts);
        check(ok && c.playlist == MENU_PLAYLIST && state_at(&c, main_btn[1]) == SELECTED
                 && state_at(&c, main_btn[0]) == NORMAL,
              "after the menu loops, Scenes is still selected (%s)", state_name[state_at(&c, main_btn[1])]);
    }
    clear_log(&c);
    key(bd, &c, BD_VK_RIGHT, "RIGHT");
    check(c.ndraws == 0, "RIGHT with no button to the right leaves the selection alone");
    key(bd, &c, BD_VK_UP, "UP");
    check(state_at(&c, main_btn[0]) == SELECTED, "UP selects Play again");

    /* 3. Play starts the film at the beginning. */
    clear_log(&c);
    key(bd, &c, BD_VK_ENTER, "ENTER");
    int activated = state_at(&c, main_btn[0]) == ACTIVATED;
    ok = pump(bd, &c, 4000, on_playlist, FILM_PLAYLIST);
    uint64_t t = bd_tell_time(bd);
    check(activated && ok && c.title == 1 && t < 90000,
          "Play draws activated, starts title 1 = playlist %05d at %.2f s", FILM_PLAYLIST, t / 90000.0);
    pump(bd, &c, 200, on_chapter, 1);
    check(c.chapter == 1, "film starts in chapter 1");

    /* 4. Top Menu during the film returns to the menu. */
    pump(bd, &c, 300, on_playlist, -2); /* play a little of the film */
    n = top_menu(bd, &c, main_btn, 64);
    check(n == expect_main, "Top Menu during the film returns to playlist %05d with %d buttons", MENU_PLAYLIST, n);

    /* 5. Scenes opens the chapter page. */
    clear_log(&c);
    key(bd, &c, BD_VK_DOWN, "DOWN");
    key(bd, &c, BD_VK_ENTER, "ENTER");
    clear_log(&c);
    ok = pump(bd, &c, 4000, menu_drawn, MENU_PLAYLIST + 1);
    n = ok ? page_buttons(&c, scene_btn, 64) : 0;
    check(ok && n == expect_scene, "Scenes opens playlist %05d with %d buttons (drew %d)",
          MENU_PLAYLIST + 1, expect_scene, n);

    /* 6. Each chapter button starts the film at its chapter. */
    for (int ch = 0; ch < scene_tiles && n == expect_scene; ch++) {
        if (ch > 0) {
            n = top_menu(bd, &c, main_btn, 64);
            key(bd, &c, BD_VK_DOWN, "DOWN");
            key(bd, &c, BD_VK_ENTER, "ENTER");
            clear_log(&c);
            n = pump(bd, &c, 4000, menu_drawn, MENU_PLAYLIST + 1) ? page_buttons(&c, scene_btn, 64) : 0;
            if (n != expect_scene) { check(0, "Scenes page reopens"); break; }
        }
        /* Chapter buttons sit in rows of four; chapter 1 starts selected. */
        clear_log(&c);
        for (int r = 0; r < ch / 4; r++) key(bd, &c, BD_VK_DOWN, "DOWN");
        for (int k = 0; k < ch % 4; k++) key(bd, &c, BD_VK_RIGHT, "RIGHT");
        int sel = ch == 0 || state_at(&c, scene_btn[ch]) == SELECTED;
        clear_log(&c);
        c.chapter = -1;
        key(bd, &c, BD_VK_ENTER, "ENTER");
        ok = pump(bd, &c, 4000, on_chapter, ch + 1);
        t = bd_tell_time(bd);
        double want = chapters[ch];
        check(sel && ok && t / 90000.0 > want - 0.5 && t / 90000.0 < want + 1.0,
              "Chapter %d button %s, starts playlist %05d in chapter %d at %.2f s (chapter at %.2f s)",
              ch + 1, sel ? "selected" : "NOT selected", c.playlist, c.chapter, t / 90000.0, want);
    }

    /* 7. Back returns to the main page. */
    n = top_menu(bd, &c, main_btn, 64);
    key(bd, &c, BD_VK_DOWN, "DOWN");
    key(bd, &c, BD_VK_ENTER, "ENTER");
    clear_log(&c);
    if (pump(bd, &c, 4000, menu_drawn, MENU_PLAYLIST + 1)) {
        page_buttons(&c, scene_btn, 64);
        /* Back is the first button below the chapter rows. */
        for (int r = 0; r < (scene_tiles + 3) / 4; r++) key(bd, &c, BD_VK_DOWN, "DOWN");
        clear_log(&c);
        key(bd, &c, BD_VK_ENTER, "ENTER");
        ok = pump(bd, &c, 4000, menu_drawn, MENU_PLAYLIST);
        check(ok, "Back on the Scenes page returns to playlist %05d", MENU_PLAYLIST);
    }

    /* 8. Subtitles On / Off decide whether the film shows subtitle stream 1. */
    if (subtitles) {
        for (int on = 1; on >= 0; on--) {
            n = top_menu(bd, &c, main_btn, 64);
            int steps = on ? 2 : 3;
            for (int s = 0; s < steps; s++) key(bd, &c, BD_VK_DOWN, "DOWN");
            clear_log(&c);
            key(bd, &c, BD_VK_ENTER, "ENTER");
            pump(bd, &c, 20, on_playlist, -2);
            int stayed = c.playlist == MENU_PLAYLIST && state_at(&c, main_btn[steps]) == SELECTED;
            for (int s = 0; s < steps; s++) key(bd, &c, BD_VK_UP, "UP");
            key(bd, &c, BD_VK_ENTER, "ENTER");
            ok = pump(bd, &c, 4000, on_playlist, FILM_PLAYLIST);
            pump(bd, &c, 50, on_playlist, -2);
            check(stayed && ok && c.pg_stream == 1 && c.pg_enabled == on,
                  "Subtitles %s keeps the menu up, then the film plays with subtitle stream %d %s",
                  on ? "On" : "Off", c.pg_stream, c.pg_enabled ? "shown" : "hidden");
        }
    }

done:
    bd_close(bd);
    printf("%s: %d check(s) failed\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
