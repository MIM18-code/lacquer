/*
 * menu_check: plays a Lacquer menu disc through libbluray's HDMV navigation
 * (the code VLC uses for Blu-ray menus) and checks it against the menu map
 * the headless CLI writes next to the disc (<name>.menu.json):
 *
 *   menu_check DISC --map DISC_NAME.menu.json [--verbose]
 *
 * DISC is a BDMV folder or an ISO. For every page in the map:
 *   - entering it draws exactly its buttons with the default one selected;
 *   - every up/down/left/right edge moves the selection where the map says,
 *     and a missing edge leaves it alone;
 *   - every button does what its action says: playFilm starts the film at
 *     0 s in chapter 1, playChapter(n) starts chapter n+1 at its time,
 *     goToPage(q) opens page q, setSubtitles keeps the menu up and the film
 *     then plays with subtitle stream 1 shown or hidden;
 * and Top Menu from the film returns to the first page, and the selection
 * survives the menu clip looping (or a still menu holds).
 *
 * Rapid presses: libbluray runs a button's commands on the next read, and a
 * second activation before that replaces them. VLC doesn't read while
 * paused, and handles quick key presses between reads, so Subtitles Off
 * followed by Play could start the film with subtitles still on. For each
 * subtitle button on a page with a Play button, the check presses it and
 * then walks to Play and presses that without reading in between; the film
 * must still play with the subtitle state the first button chose.
 *
 * libbluray doesn't export its player registers, so the selected button
 * comes from the overlay: each draw's position names the button, and the
 * FNV-1a of its palette indices names the state (the map lists the hash of
 * every button's normal, selected and activated image).
 *
 * Prints one PASS/FAIL line per check and exits non-zero on any failure.
 */
#include <libbluray/bluray.h>
#include <libbluray/keys.h>
#include <libbluray/log_control.h>
#include <libbluray/overlay.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- JSON */

enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ };
typedef struct J {
    int type;
    double num;
    char *str;
    struct J **items;
    char **keys;
    int n;
} J;

static const char *jp;
static void jws(void) { while (*jp && isspace((unsigned char)*jp)) jp++; }

static J *jnew(int type) { J *j = calloc(1, sizeof *j); j->type = type; return j; }

static char *jstring(void)
{
    const char *start = ++jp;
    while (*jp && *jp != '"') { if (*jp == '\\') jp++; jp++; }
    size_t len = (size_t)(jp - start);
    char *s = malloc(len + 1);
    memcpy(s, start, len); s[len] = 0;
    if (*jp) jp++;
    return s;
}

static J *jvalue(void)
{
    jws();
    if (*jp == '{' || *jp == '[') {
        int obj = *jp == '{';
        J *j = jnew(obj ? J_OBJ : J_ARR);
        jp++;
        for (;;) {
            jws();
            if (*jp == (obj ? '}' : ']')) { jp++; break; }
            if (*jp == ',') { jp++; continue; }
            j->items = realloc(j->items, sizeof(J *) * (size_t)(j->n + 1));
            if (obj) {
                j->keys = realloc(j->keys, sizeof(char *) * (size_t)(j->n + 1));
                j->keys[j->n] = jstring();
                jws(); if (*jp == ':') jp++;
            }
            j->items[j->n++] = jvalue();
        }
        return j;
    }
    if (*jp == '"') { J *j = jnew(J_STR); j->str = jstring(); return j; }
    if (!strncmp(jp, "true", 4)) { jp += 4; J *j = jnew(J_BOOL); j->num = 1; return j; }
    if (!strncmp(jp, "false", 5)) { jp += 5; return jnew(J_BOOL); }
    if (!strncmp(jp, "null", 4)) { jp += 4; return jnew(J_NULL); }
    J *j = jnew(J_NUM);
    char *end;
    j->num = strtod(jp, &end);
    jp = end;
    return j;
}

static J *jget(const J *o, const char *key)
{
    if (!o || o->type != J_OBJ) return NULL;
    for (int i = 0; i < o->n; i++) if (!strcmp(o->keys[i], key)) return o->items[i];
    return NULL;
}
static double jnum(const J *o, const char *key, double fallback)
{
    const J *v = jget(o, key);
    return v && (v->type == J_NUM || v->type == J_BOOL) ? v->num : fallback;
}

/* ----------------------------------------------------------------- map */

enum { UP, DOWN, LEFT, RIGHT };
static const uint32_t dir_key[4] = { BD_VK_UP, BD_VK_DOWN, BD_VK_LEFT, BD_VK_RIGHT };
static const char *dir_name[4] = { "up", "down", "left", "right" };

typedef struct {
    int x, y, w, h;
    int next[4];          /* -1: the key leaves the selection alone */
    char action[16];
    int value;
    uint32_t hash[3];     /* normal, selected, activated */
} Button;

typedef struct {
    int playlist, def, n;
    Button *b;
} Page;

typedef struct {
    int film, first, loops, subs, npages, nchapters;
    double chapters[512];
    Page *pages;
} Map;

static int load_map(const char *path, Map *m)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *text = malloc((size_t)size + 1);
    size_t got = fread(text, 1, (size_t)size, f);
    text[got] = 0;
    fclose(f);
    jp = text;
    J *root = jvalue();
    m->film = (int)jnum(root, "filmPlaylist", 0);
    m->first = (int)jnum(root, "firstPage", 0);
    m->loops = (int)jnum(root, "loops", 1);
    m->subs = (int)jnum(root, "filmSubtitles", 0);
    J *ch = jget(root, "chapters");
    m->nchapters = ch ? ch->n : 0;
    for (int i = 0; i < m->nchapters && i < 512; i++) m->chapters[i] = ch->items[i]->num;
    J *pages = jget(root, "pages");
    if (!pages || pages->type != J_ARR) return 0;
    m->npages = pages->n;
    m->pages = calloc((size_t)m->npages, sizeof(Page));
    for (int p = 0; p < m->npages; p++) {
        J *pj = pages->items[p];
        Page *pg = &m->pages[p];
        pg->playlist = (int)jnum(pj, "playlist", 0);
        pg->def = (int)jnum(pj, "defaultButton", 0);
        J *bs = jget(pj, "buttons");
        pg->n = bs ? bs->n : 0;
        pg->b = calloc((size_t)pg->n, sizeof(Button));
        for (int i = 0; i < pg->n; i++) {
            J *bj = bs->items[i];
            Button *b = &pg->b[i];
            J *r = jget(bj, "rect");
            b->x = (int)r->items[0]->num; b->y = (int)r->items[1]->num;
            b->w = (int)r->items[2]->num; b->h = (int)r->items[3]->num;
            const char *keys[4] = { "up", "down", "left", "right" };
            for (int d = 0; d < 4; d++) b->next[d] = (int)jnum(bj, keys[d], -1);
            J *a = jget(bj, "action");
            snprintf(b->action, sizeof b->action, "%s", jget(a, "type")->str);
            b->value = (int)jnum(a, "value", 0);
            J *h = jget(bj, "stateHashes");
            for (int s = 0; s < 3; s++) b->hash[s] = (uint32_t)h->items[s]->num;
        }
    }
    return 1;
}

/* ------------------------------------------------------- player state */

#define MAX_DRAWS 65536
typedef struct { int x, y, w, h; uint32_t hash; } Draw;

typedef struct {
    int verbose;
    int playlist, playlist_starts, title, chapter, pg_stream, pg_enabled;
    int ig_flushes;
    Draw draws[MAX_DRAWS];
    int ndraws;
} Ctx;

static Ctx c;
static Map m;
static BLURAY *bd;
static int failures, passes;

static void check(int ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (ok) passes++; else failures++;
}

static void overlay_cb(void *handle, const BD_OVERLAY *ov)
{
    (void)handle;
    if (!ov || ov->plane != BD_OVERLAY_IG) return;
    if (ov->cmd == BD_OVERLAY_FLUSH) { c.ig_flushes++; return; }
    /* A new menu (page change, loop restart) starts on a fresh plane. */
    if (ov->cmd == BD_OVERLAY_INIT || ov->cmd == BD_OVERLAY_CLOSE) { c.ndraws = 0; c.ig_flushes = 0; return; }
    if (ov->cmd != BD_OVERLAY_DRAW || c.ndraws >= MAX_DRAWS) return;
    /* FNV-1a over the palette indices, row by row, as the encoder hashes. */
    uint32_t h = 0x811C9DC5u;
    long left = (long)ov->w * ov->h;
    for (const BD_PG_RLE_ELEM *e = ov->img; e && left > 0; e++) {
        for (unsigned k = 0; k < e->len; k++) { h = (h ^ (uint8_t)e->color) * 0x01000193u; }
        left -= e->len;
    }
    Draw *d = &c.draws[c.ndraws++];
    d->x = ov->x; d->y = ov->y; d->w = ov->w; d->h = ov->h; d->hash = h;
    if (c.verbose) printf("      draw %4d,%4d %4dx%-4d %08x\n", d->x, d->y, d->w, d->h, h);
}

static void handle_event(const BD_EVENT *ev)
{
    switch (ev->event) {
    case BD_EVENT_PLAYLIST:         c.playlist = (int)ev->param; c.playlist_starts++; break;
    case BD_EVENT_TITLE:            c.title = (int)ev->param; break;
    case BD_EVENT_CHAPTER:          c.chapter = (int)ev->param; break;
    case BD_EVENT_PG_TEXTST_STREAM: c.pg_stream = (int)ev->param; break;
    case BD_EVENT_PG_TEXTST:        c.pg_enabled = (int)ev->param; break;
    default: break;
    }
    if (c.verbose && ev->event != BD_EVENT_NONE)
        printf("    event %-22s %u\n", bd_event_name(ev->event), ev->param);
}

static void drain(void)
{
    BD_EVENT ev;
    while (bd_get_event(bd, &ev)) handle_event(&ev);
}

typedef int (*cond_f)(int arg);

/* Reads the stream until cond holds or max_blocks aligned units pass. */
static int pump(int max_blocks, cond_f cond, int arg)
{
    static unsigned char buf[6144];
    drain();
    for (int i = 0; i < max_blocks; i++) {
        if (cond && cond(arg)) return 1;
        BD_EVENT ev;
        if (bd_read_ext(bd, buf, sizeof buf, &ev) < 0) return 0;
        handle_event(&ev);
        drain();
    }
    return cond ? cond(arg) : 1;
}

static void clear_log(void) { c.ndraws = 0; c.ig_flushes = 0; }

static void key(uint32_t k, const char *name)
{
    if (c.verbose) printf("  key %s\n", name);
    bd_user_input(bd, -1, k);
    drain();
}

enum { NORMAL, SELECTED, ACTIVATED, UNKNOWN, NOT_DRAWN };

/* State of a button from its latest draw since the log was cleared. */
static int state_of(const Page *pg, int b)
{
    const Button *bt = &pg->b[b];
    for (int i = c.ndraws - 1; i >= 0; i--) {
        const Draw *d = &c.draws[i];
        if (d->x != bt->x || d->y != bt->y) continue;
        int match = -1, count = 0;
        for (int s = 0; s < 3; s++) if (d->hash == bt->hash[s]) { match = s; count++; }
        return count == 1 ? match : (count > 1 && match == NORMAL ? NORMAL : UNKNOWN);
    }
    return NOT_DRAWN;
}

/* The one button drawn as selected; -1 for none, -2 for several. */
static int selected(const Page *pg)
{
    int found = -1;
    for (int b = 0; b < pg->n; b++) {
        if (state_of(pg, b) == SELECTED) { if (found >= 0) return -2; found = b; }
    }
    return found;
}

/* Buttons of the page that have been drawn, and draws that aren't buttons. */
static int drawn_buttons(const Page *pg, int *strays)
{
    int n = 0;
    for (int b = 0; b < pg->n; b++) if (state_of(pg, b) != NOT_DRAWN) n++;
    *strays = 0;
    for (int i = 0; i < c.ndraws; i++) {
        int hit = 0;
        for (int b = 0; b < pg->n; b++) if (c.draws[i].x == pg->b[b].x && c.draws[i].y == pg->b[b].y) hit = 1;
        if (!hit) (*strays)++;
    }
    return n;
}

static int g_wait_page;
static int page_ready(int starts)
{
    const Page *pg = &m.pages[g_wait_page];
    int strays;
    return c.playlist_starts > starts && c.playlist == pg->playlist && c.ig_flushes > 0
        && drawn_buttons(pg, &strays) == pg->n;
}
static int film_started(int starts) { return c.playlist_starts > starts && c.playlist == m.film; }
static int on_chapter(int ch) { return c.playlist == m.film && c.chapter == ch; }
static int new_playlist(int starts) { return c.playlist_starts > starts; }
static int never(int arg) { (void)arg; return 0; }

/* Waits after an action for page p to open and draw. */
static int wait_page(int p, int starts)
{
    g_wait_page = p;
    return pump(6000, page_ready, starts);
}

/* ------------------------------------------------------- navigation */

/* Presses keys along the map's edges until button target is selected. */
static int select_button(const Page *pg, int target)
{
    for (int guard = 0; guard < 64; guard++) {
        int cur = selected(pg);
        if (cur == target) return 1;
        if (cur < 0) return 0;
        /* Breadth-first search for the first key towards the target. */
        int prev_dir[256], prev[256], queue[256], qh = 0, qt = 0;
        for (int i = 0; i < pg->n; i++) prev[i] = -2;
        prev[cur] = -1; queue[qt++] = cur;
        while (qh < qt && prev[target] == -2) {
            int u = queue[qh++];
            for (int d = 0; d < 4; d++) {
                int v = pg->b[u].next[d];
                if (v >= 0 && v < pg->n && prev[v] == -2) { prev[v] = u; prev_dir[v] = d; queue[qt++] = v; }
            }
        }
        if (prev[target] == -2) return 0;
        int v = target;
        while (prev[v] != cur) v = prev[v];
        key(dir_key[prev_dir[v]], dir_name[prev_dir[v]]);
    }
    return 0;
}

/* Page path from the first page: hop[i] = (page, button) pairs. */
static int page_path(int target, int *hop_page, int *hop_button)
{
    int prev[256], prev_btn[256], queue[256], qh = 0, qt = 0;
    for (int i = 0; i < m.npages; i++) prev[i] = -2;
    prev[m.first] = -1; queue[qt++] = m.first;
    while (qh < qt) {
        int u = queue[qh++];
        for (int b = 0; b < m.pages[u].n; b++) {
            const Button *bt = &m.pages[u].b[b];
            if (strcmp(bt->action, "goToPage") || bt->value < 0 || bt->value >= m.npages) continue;
            if (prev[bt->value] == -2) { prev[bt->value] = u; prev_btn[bt->value] = b; queue[qt++] = bt->value; }
        }
    }
    if (prev[target] == -2) return -1;
    int n = 0, v = target;
    while (prev[v] >= 0) { hop_page[n] = prev[v]; hop_button[n] = prev_btn[v]; n++; v = prev[v]; }
    for (int i = 0; i < n / 2; i++) {   /* reverse into path order */
        int t = hop_page[i]; hop_page[i] = hop_page[n - 1 - i]; hop_page[n - 1 - i] = t;
        t = hop_button[i]; hop_button[i] = hop_button[n - 1 - i]; hop_button[n - 1 - i] = t;
    }
    return n;
}

/* Top Menu, then through goToPage buttons to page p. */
static int open_page(int p)
{
    int starts = c.playlist_starts;
    clear_log();
    if (c.verbose) printf("  Top Menu\n");
    bd_menu_call(bd, -1);
    if (!wait_page(m.first, starts)) return 0;
    int hp[256], hb[256];
    int hops = page_path(p, hp, hb);
    if (hops < 0) return 0;
    for (int i = 0; i < hops; i++) {
        const Page *pg = &m.pages[hp[i]];
        if (!select_button(pg, hb[i])) return 0;
        starts = c.playlist_starts;
        clear_log();
        key(BD_VK_ENTER, "ENTER");
        int next = i + 1 < hops ? hp[i + 1] : p;
        if (!wait_page(next, starts)) return 0;
    }
    return 1;
}

/* Keys (map edges) from button `from` to `to`, without looking at draws:
 * what a fast remote sends before the player reads again. */
static int key_path(const Page *pg, int from, int to, int *dirs)
{
    int prev_dir[256], prev[256], queue[256], qh = 0, qt = 0;
    for (int i = 0; i < pg->n; i++) prev[i] = -2;
    prev[from] = -1; queue[qt++] = from;
    while (qh < qt) {
        int u = queue[qh++];
        for (int d = 0; d < 4; d++) {
            int v = pg->b[u].next[d];
            if (v >= 0 && v < pg->n && prev[v] == -2) { prev[v] = u; prev_dir[v] = d; queue[qt++] = v; }
        }
    }
    if (prev[to] == -2) return -1;
    int n = 0;
    for (int v = to; v != from; v = prev[v]) dirs[n++] = prev_dir[v];
    for (int i = 0; i < n / 2; i++) { int t = dirs[i]; dirs[i] = dirs[n - 1 - i]; dirs[n - 1 - i] = t; }
    return n;
}

/* Finds a playFilm button: its page and index. */
static int find_play(int *page, int *button)
{
    for (int p = 0; p < m.npages; p++)
        for (int b = 0; b < m.pages[p].n; b++)
            if (!strcmp(m.pages[p].b[b].action, "playFilm")) { *page = p; *button = b; return 1; }
    return 0;
}

/* ------------------------------------------------------------ checks */

static void check_entry(int p, const char *how)
{
    const Page *pg = &m.pages[p];
    int strays;
    int n = drawn_buttons(pg, &strays);
    int sel = selected(pg);
    check(n == pg->n && strays == 0 && sel == pg->def,
          "page %d (%05d) %s: %d of %d buttons drawn%s, button %d selected (default %d)",
          p + 1, pg->playlist, how, n, pg->n, strays ? ", plus stray draws" : "", sel, pg->def);
}

static void check_edges(int p)
{
    const Page *pg = &m.pages[p];
    int ok = 0, total = 0;
    for (int b = 0; b < pg->n; b++) {
        for (int d = 0; d < 4; d++) {
            total++;
            if (!select_button(pg, b)) {
                printf("      FAIL page %d: can't reach button %d along the map's edges\n", p + 1, b);
                continue;
            }
            /* The log runs from page entry, so the latest draw of every
             * button is known; a key that changes nothing draws nothing. */
            int mark = c.ndraws;
            key(dir_key[d], dir_name[d]);
            int want = pg->b[b].next[d] >= 0 ? pg->b[b].next[d] : b;
            int got = c.ndraws == mark ? b : selected(pg);
            if (got == want) ok++;
            else printf("      FAIL page %d: %s from button %d selected %d, map says %d\n",
                        p + 1, dir_name[d], b, got, want);
        }
    }
    check(ok == total, "page %d: %d of %d remote edges move the selection as mapped", p + 1, ok, total);
}

/* The selection survives a loop restart, or a still menu holds. */
static void check_hold(int p)
{
    const Page *pg = &m.pages[p];
    int target = -1;
    for (int d = 0; d < 4 && target < 0; d++) {
        int v = pg->b[pg->def].next[d];
        if (v >= 0 && v != pg->def) target = v;
    }
    if (target < 0) target = pg->def;
    select_button(pg, target);
    int starts = c.playlist_starts;
    clear_log();
    if (m.loops) {
        int ok = pump(60000, new_playlist, starts);
        g_wait_page = p;
        ok = ok && pump(6000, page_ready, starts);
        check(ok && selected(pg) == target, "page %d: after the menu loops, button %d is still selected (got %d)",
              p + 1, target, selected(pg));
    } else {
        pump(5000, never, 0);
        check(c.playlist_starts == starts && c.ndraws == 0 && c.playlist == pg->playlist,
              "page %d: the still menu holds", p + 1);
    }
    /* Leave the page with its full picture redrawn. */
    open_page(p);
}

static void check_action(int p, int b)
{
    const Page *pg = &m.pages[p];
    const Button *bt = &pg->b[b];
    if (!open_page(p) || !select_button(pg, b)) {
        check(0, "page %d button %d (%s): couldn't select it", p + 1, b, bt->action);
        return;
    }
    int starts = c.playlist_starts;
    clear_log();
    c.chapter = -1;
    key(BD_VK_ENTER, "ENTER");
    int activated = state_of(pg, b) == ACTIVATED;

    if (!strcmp(bt->action, "playFilm") || !strcmp(bt->action, "playChapter")) {
        int ch = strcmp(bt->action, "playFilm") ? bt->value : 0;
        int ok = pump(6000, film_started, starts);
        ok = ok && pump(400, on_chapter, ch + 1);
        double t = bd_tell_time(bd) / 90000.0;
        double want = ch < m.nchapters ? m.chapters[ch] : 0;
        check(activated && ok && c.title == 1 && t > want - 0.5 && t < want + 1.0,
              "page %d button %d (%s%s): %s, title %d, playlist %05d, chapter %d at %.2f s (want chapter %d at %.2f s)",
              p + 1, b, bt->action, ch ? "" : "", activated ? "drawn activated" : "NOT drawn activated",
              c.title, c.playlist, c.chapter, t, ch + 1, want);
    } else if (!strcmp(bt->action, "goToPage")) {
        int q = bt->value;
        int ok = q >= 0 && q < m.npages && wait_page(q, starts);
        if (ok) check_entry(q, "from goToPage");
        else check(0, "page %d button %d (goToPage %d): page %d didn't open", p + 1, b, q + 1, q + 1);
    } else if (!strcmp(bt->action, "setSubtitles")) {
        int on = bt->value;
        pump(30, new_playlist, starts);
        int stayed = c.playlist_starts == starts && c.playlist == pg->playlist && selected(pg) == b;
        int fp, fb, ok = find_play(&fp, &fb) && open_page(fp) && select_button(&m.pages[fp], fb);
        if (ok) {
            starts = c.playlist_starts;
            key(BD_VK_ENTER, "ENTER");
            ok = pump(6000, film_started, starts);
            pump(60, never, 0);
        }
        check(stayed && ok && c.pg_stream == 1 && c.pg_enabled == on,
              "page %d button %d (setSubtitles %s): menu %s, then the film plays with subtitle stream %d %s",
              p + 1, b, on ? "on" : "off", stayed ? "stays" : "DIDN'T STAY", c.pg_stream,
              c.pg_enabled ? "shown" : "hidden");

        /* Rapid: the opposite setting first, then this button and Play on
         * this page with no read in between. */
        int other_p = -1, other_b = -1, play = -1;
        for (int q = 0; q < m.npages && other_p < 0; q++)
            for (int k = 0; k < m.pages[q].n; k++)
                if (!strcmp(m.pages[q].b[k].action, "setSubtitles") && m.pages[q].b[k].value != on) { other_p = q; other_b = k; break; }
        for (int k = 0; k < pg->n; k++) if (!strcmp(pg->b[k].action, "playFilm")) { play = k; break; }
        int dirs[256], nd = play >= 0 ? key_path(pg, b, play, dirs) : -1;
        if (other_p >= 0 && nd >= 0 && open_page(other_p) && select_button(&m.pages[other_p], other_b)) {
            starts = c.playlist_starts;
            key(BD_VK_ENTER, "ENTER");
            pump(30, new_playlist, starts);
            ok = open_page(p) && select_button(pg, b);
            if (ok) {
                starts = c.playlist_starts;
                key(BD_VK_ENTER, "ENTER (no read before the next keys)");
                for (int i = 0; i < nd; i++) key(dir_key[dirs[i]], dir_name[dirs[i]]);
                key(BD_VK_ENTER, "ENTER on Play");
                ok = pump(6000, film_started, starts);
                if (!ok) {
                    /* The quick Play press was ignored; press it again. */
                    ok = select_button(pg, play);
                    starts = c.playlist_starts;
                    key(BD_VK_ENTER, "ENTER on Play again");
                    ok = ok && pump(6000, film_started, starts);
                }
                pump(60, never, 0);
            }
            check(ok && c.pg_enabled == on,
                  "page %d button %d (setSubtitles %s) then Play before the player reads: the film plays with subtitles %s",
                  p + 1, b, on ? "on" : "off", c.pg_enabled ? "shown" : "hidden");
        }
    } else {
        check(0, "page %d button %d: unknown action %s", p + 1, b, bt->action);
    }
}

int main(int argc, char **argv)
{
    const char *disc = NULL, *map_path = NULL;
    c.playlist = c.title = c.chapter = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--verbose")) c.verbose = 1;
        else if (!strcmp(argv[i], "--map") && i + 1 < argc) map_path = argv[++i];
        else disc = argv[i];
    }
    if (!disc || !map_path) {
        fprintf(stderr, "usage: menu_check DISC --map NAME.menu.json [--verbose]\n");
        return 2;
    }
    if (!load_map(map_path, &m) || m.npages == 0) {
        fprintf(stderr, "can't read the menu map %s\n", map_path);
        return 2;
    }
    if (!c.verbose) bd_set_debug_mask(0);

    bd = bd_open(disc, NULL);
    check(bd != NULL, "libbluray opens %s", disc);
    if (!bd) return 1;
    const BLURAY_DISC_INFO *info = bd_get_disc_info(bd);
    check(info && info->first_play_supported && info->top_menu_supported && info->num_hdmv_titles == 1,
          "index.bdmv has First Play, Top Menu and one HDMV title");
    bd_register_overlay_proc(bd, NULL, overlay_cb);

    /* First Play opens the first page. */
    int starts = c.playlist_starts;
    clear_log();
    check(bd_play(bd) > 0, "bd_play starts navigation");
    if (!wait_page(m.first, starts)) {
        check(0, "First Play opens page %d (playlist %05d)", m.first + 1, m.pages[m.first].playlist);
        goto done;
    }
    check_entry(m.first, "on First Play");
    check_hold(m.first);

    /* Top Menu from the film returns to the first page. */
    int fp, fb;
    if (find_play(&fp, &fb) && open_page(fp) && select_button(&m.pages[fp], fb)) {
        starts = c.playlist_starts;
        key(BD_VK_ENTER, "ENTER");
        pump(6000, film_started, starts);
        pump(300, never, 0);
        starts = c.playlist_starts;
        clear_log();
        bd_menu_call(bd, -1);
        int ok = wait_page(m.first, starts);
        check(ok, "Top Menu during the film returns to page %d", m.first + 1);
        if (ok) check_entry(m.first, "from Top Menu");
    }

    for (int p = 0; p < m.npages; p++) {
        if (!open_page(p)) { check(0, "page %d can't be reached from the first page", p + 1); continue; }
        if (p != m.first) check_entry(p, "via its goToPage path");
        check_edges(p);
        for (int b = 0; b < m.pages[p].n; b++) check_action(p, b);
    }

done:
    bd_close(bd);
    printf("%s: %d passed, %d failed\n", failures ? "FAILED" : "ALL PASSED", passes, failures);
    return failures ? 1 : 0;
}
