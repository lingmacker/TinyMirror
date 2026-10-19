/* Run production startup/configuration with only network publication replaced. */
#define raop_start_httpd checked_start_httpd
#define dnssd_register_raop checked_register_raop
#define dnssd_register_airplay checked_register_airplay
#define raop_set_plist checked_set_plist
#include "../native/mirror_bridge.c"
#undef raop_start_httpd
#undef dnssd_register_raop
#undef dnssd_register_airplay
#undef raop_set_plist
#include <assert.h>

int raop_set_plist(raop_t *raop, const char *item, int value);
static int requested_fps, published, listening, reject_fps;

int checked_start_httpd(raop_t *raop, unsigned short *port) {
    assert(raop && port && requested_fps);
    listening++;
    return 0;
}
int checked_register_raop(dnssd_t *dnssd, unsigned short port) {
    (void)port;
    assert(dnssd && requested_fps);
    published++;
    return 0;
}
int checked_register_airplay(dnssd_t *dnssd, unsigned short port) {
    return checked_register_raop(dnssd, port);
}
int checked_set_plist(raop_t *raop, const char *item, int value) {
    if (!strcmp(item, "maxFPS")) {
        requested_fps = value;
        if (reject_fps) return 1;
    }
    return raop_set_plist(raop, item, value);
}
static void video(void *ctx, const uint8_t *data, int len, uint64_t local, uint64_t remote, int hevc) {
    (void)ctx; (void)data; (void)len; (void)local; (void)remote; (void)hevc;
}
static void audio(void *ctx, const uint8_t *data, int len, unsigned char ct, uint64_t time) {
    (void)ctx; (void)data; (void)len; (void)ct; (void)time;
}

int main(void) {
    mb_callbacks_t callbacks = {0};
    callbacks.on_video = video;
    callbacks.on_audio = audio;
    const int invalid[] = {-1, 0, 24, 59, 61, 120, 256};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        assert(mb_start_video_with_fps("No-network FPS check", &callbacks, 0, 1920, 1080, 0, invalid[i]) == -2);
        assert(!g_raop && !g_dnssd && !listening && !published);
    }
    for (int fps = 30; fps <= 60; fps += 30) {
        requested_fps = published = listening = 0;
        assert(mb_start_video_with_fps("No-network FPS check", &callbacks, 0, 2560, 1440, 1, fps) == 0);
        assert(requested_fps == fps && listening == 1 && published == 2);
        assert(mb_start_video_with_fps("Already running", &callbacks, 0, 1920, 1080, 0, fps) == -1);
        mb_stop();
        assert(!g_raop && !g_dnssd);
    }
    requested_fps = 0;
    assert(mb_start_video("Legacy video startup", &callbacks, 0, 1920, 1080, 0) == 0);
    assert(requested_fps == 30);
    mb_stop();
    requested_fps = 0;
    assert(mb_start("Legacy startup", &callbacks, 0) == 0);
    assert(requested_fps == 30);
    mb_stop();
    reject_fps = 1;
    listening = published = 0;
    assert(mb_start_video_with_fps("Rejected FPS", &callbacks, 0, 1920, 1080, 0, 60) == -7);
    assert(!g_raop && !g_dnssd && !listening && !published);
    puts("PASS native 30/60 FPS configuration, invalid inputs, legacy defaults and failed-start cleanup; no network opened");
    return 0;
}
