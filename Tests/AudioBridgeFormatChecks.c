/* Exercise the real native callback without starting a receiver or discovery. */
#include "../native/mirror_bridge.c"
#include <assert.h>

static char captured[32];
static int captured_ct, captured_screen, mode_pending;
static void capture(void *ctx, int event, int value, const char *info) {
    (void) ctx;
    if (event == MB_EVENT_AUDIO_MODE) {
        captured_screen = value;
        mode_pending = 1;
    } else {
        assert(event == MB_EVENT_AUDIO_FORMAT && mode_pending);
        captured_ct = value;
        snprintf(captured, sizeof(captured), "%s", info);
        mode_pending = 0;
    }
}

int main(void) {
    g_cbs.on_event = capture;
    unsigned char ct = 2;
    unsigned short spf = 352;
    bool screen = false, media = true;
    uint64_t format = 0;
    cb_audio_get_format(NULL, &ct, &spf, &screen, &media, &format);
    assert(captured_ct == 2 && captured_screen == 0 && !strcmp(captured, "352"));
    ct = 8;
    spf = 480;
    screen = true;
    cb_audio_get_format(NULL, &ct, &spf, &screen, &media, &format);
    assert(captured_ct == 8 && captured_screen == 1 && !strcmp(captured, "480"));
    puts("PASS native audio format preserves the sender's usingScreen flag");
    return 0;
}
