#include "../native/include/mirror_bridge.h"
#include "ReceiverBridgeStub.h"
#include <string.h>

static mb_callbacks_t callbacks;
int mb_start_video(const char *name, const mb_callbacks_t *cbs, int debug, int width, int height, int hevc) {
    (void) name; (void) debug; (void) width; (void) height; (void) hevc;
    callbacks = *cbs;
    return 0;
}
int mb_start(const char *name, const mb_callbacks_t *cbs, int debug) {
    return mb_start_video(name, cbs, debug, 1920, 1080, 0);
}
void mb_stop(void) { memset(&callbacks, 0, sizeof(callbacks)); }
void mb_test_event(int event, int value, const char *info) {
    if (callbacks.on_event) callbacks.on_event(callbacks.ctx, event, value, info);
}
void mb_test_audio(const uint8_t *data, int len, unsigned char ct, uint64_t timestamp) {
    if (callbacks.on_audio) callbacks.on_audio(callbacks.ctx, data, len, ct, timestamp);
}
