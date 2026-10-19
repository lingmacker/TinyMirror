/* Test production connection teardown ordering without discovery or network listeners. */
#define raop_rtp_destroy checked_audio_join
#define raop_rtp_mirror_destroy checked_video_join
#define raop_ntp_destroy checked_clock_destroy
#include "../vendor/UxPlay/lib/raop.c"
#undef raop_rtp_destroy
#undef raop_rtp_mirror_destroy
#undef raop_ntp_destroy

static int audio_joined, video_joined, clock_destroyed, notified, failed;
void checked_audio_join(raop_rtp_t *rtp) {
    assert(rtp);
    if (notified) failed = 1;
    audio_joined = 1;
}
void checked_video_join(raop_rtp_mirror_t *mirror) {
    assert(mirror);
    if (notified) failed = 1;
    video_joined = 1;
}
void checked_clock_destroy(raop_ntp_t *ntp) {
    assert(ntp);
    clock_destroyed = 1;
}
static void disconnected(void *ctx) {
    (void)ctx;
    notified++;
    if (!audio_joined || !video_joined || !clock_destroyed) failed = 1;
}
static void audio(void *ctx, raop_ntp_t *ntp, audio_decode_struct *data) { (void)ctx; (void)ntp; (void)data; }
static void video(void *ctx, raop_ntp_t *ntp, video_decode_struct *data) { (void)ctx; (void)ntp; (void)data; }
int main(void) {
    raop_callbacks_t callbacks = {0};
    callbacks.audio_process = audio;
    callbacks.video_process = video;
    callbacks.conn_destroy = disconnected;
    raop_t *raop = raop_init(&callbacks);
    assert(raop);
    logger_set_level(raop->logger, LOGGER_ERR);
    assert(raop_init2(raop, 0, "02:00:00:00:00:01", "") == 0);
    unsigned char address[4] = {127, 0, 0, 1};
    raop_conn_t *conn = conn_init(raop, address, 4, address, 4, 0);
    assert(conn);
    /* The checked destructors stand in for joining producers; these tokens are never dereferenced. */
    conn->raop_rtp = (raop_rtp_t *)&audio_joined;
    conn->raop_rtp_mirror = (raop_rtp_mirror_t *)&video_joined;
    conn->raop_ntp = (raop_ntp_t *)&clock_destroyed;
    conn_destroy(conn);
    raop_destroy(raop);
    if (failed || notified != 1) {
        fprintf(stderr, "FAIL connection notified disconnect before media producers finished\n");
        return 1;
    }
    puts("PASS connection joins media producers before notifying disconnect; no network opened");
    return 0;
}
