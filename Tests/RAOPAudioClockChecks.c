/* Include the actual receiver so its private RTP timestamp conversion is exercised. */
#include "../vendor/UxPlay/lib/raop_rtp.c"
#include <math.h>

int main(void) {
    logger_t *logger = logger_init();
    raop_callbacks_t callbacks = {0};
    const char remote[] = "127.0.0.1";
    const unsigned char key[16] = {0}, iv[16] = {0};
    for (int codec = 0; codec < 2; codec++) {
        unsigned char ct = codec == 0 ? 2 : 8;
        unsigned int sample_rate = 44100;
        unsigned short remote_port = 0, control_port = 0, data_port = 0;
        raop_rtp_t *rtp = raop_rtp_init(logger, &callbacks, NULL, remote, 4, key, iv);
        assert(rtp);
        raop_rtp_start_audio(rtp, &remote_port, &control_port, &data_port, &ct, &sample_rate);
        assert(raop_rtp_is_running(rtp));
        raop_rtp_stop(rtp);
        rtp->initial_sync = true;
        rtp->rtp_sync = UINT32_MAX - 500;
        rtp->client_ntp_sync = 1700000000000000000ULL;
        const uint32_t frames = codec == 0 ? 352 : 480;
        uint64_t first = rtp_time_to_client_ntp(rtp, rtp->rtp_sync);
        uint64_t one_second = rtp_time_to_client_ntp(rtp, rtp->rtp_sync + sample_rate);
        double error = fabs((double)(one_second - first) - 1000000000.0);
        printf("ct=%u RTP clock error over one second: %.0f ns\n", ct, error);
        fflush(stdout);
        assert(error < 512 && "RTP time must not truncate nanoseconds per audio sample");
        uint64_t next = rtp_time_to_client_ntp(rtp, rtp->rtp_sync + frames);
        assert(fabs((double)(next - first) - (double)frames * 1000000000.0 / sample_rate) < 512);
        uint64_t previous = rtp_time_to_client_ntp(rtp, rtp->rtp_sync - frames);
        assert(fabs((double)(first - previous) - (double)frames * 1000000000.0 / sample_rate) < 512);
        raop_rtp_destroy(rtp);
    }
    logger_destroy(logger);
    puts("PASS ALAC/AAC-ELD RTP sample clock precision, signed offsets and sequence-time wraparound");
    return 0;
}
