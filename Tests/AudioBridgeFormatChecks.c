/* Exercise the real native callback without starting a receiver or discovery. */
#include "../native/mirror_bridge.c"
#include <assert.h>

static char captured[32];
static int captured_ct, captured_screen, mode_pending, position_pending;
static uint32_t captured_position;
static void capture(void *ctx, int event, int value, const char *info) {
    (void) ctx;
    if (event == MB_EVENT_AUDIO_MODE) {
        captured_screen = value;
        mode_pending = 1;
    } else if (event == MB_EVENT_AUDIO_POSITION) {
        assert(!info);
        captured_position = (uint32_t)value;
        position_pending = 1;
    } else {
        assert(event == MB_EVENT_AUDIO_FORMAT && mode_pending);
        captured_ct = value;
        snprintf(captured, sizeof(captured), "%s", info);
        mode_pending = 0;
    }
}

static void capture_audio(void *ctx, const uint8_t *data, int length, unsigned char ct, uint64_t timestamp) {
    (void)ctx; (void)timestamp;
    assert(position_pending && data && length == 1 && ct == 2);
    position_pending = 0;
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
    g_cbs.on_audio = capture_audio;
    uint8_t byte = 0;
    audio_decode_struct packet = {0};
    packet.ct = 2; packet.data = &byte; packet.data_len = 1;
    const uint32_t positions[] = {0, UINT32_MAX, 0x80000000U, 352};
    for (unsigned i = 0; i < sizeof(positions) / sizeof(positions[0]); i++) {
        packet.rtp_time = positions[i];
        cb_audio_process(NULL, NULL, &packet);
        assert(captured_position == positions[i] && !position_pending);
    }
    packet.data_len = 0;
    cb_audio_process(NULL, NULL, &packet);
    assert(!position_pending);
    puts("PASS native audio format/mode and paired full-width RTP positions; callback ABI unchanged");
    return 0;
}
