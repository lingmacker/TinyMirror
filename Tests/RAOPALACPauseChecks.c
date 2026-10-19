/* Real UDP transport and AES-CBC with an Apple-encoded 352-frame silent ALAC packet. */
#include "../vendor/UxPlay/lib/raop_rtp.c"
#include "crypto.h"
#include <stdatomic.h>

static const unsigned char silence[32] = {
    32,0,0,4,0,19,8,9,129,248,193,255,128,0,0,19,
    8,9,129,248,193,255,128,0,0,255,128,175,191,224,43,252
};
struct capture { atomic_uint count; unsigned short seq[8]; unsigned int silent_count; };
static void audio(void *opaque, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void) ntp;
    struct capture *capture = opaque;
    unsigned int count = atomic_load_explicit(&capture->count, memory_order_relaxed);
    assert(count < 8);
    capture->seq[count] = data->seqnum;
    if (data->data_len == sizeof(silence)) {
        assert(!memcmp(data->data, silence, sizeof(silence)));
        capture->silent_count++;
        FILE *file = fopen(".build/audio-tests/transported-alac-silence.bin", "wb");
        assert(file && fwrite(data->data, 1, sizeof(silence), file) == sizeof(silence));
        fclose(file);
    }
    atomic_store_explicit(&capture->count, count + 1, memory_order_release);
}
static void send_packet(int fd, unsigned short port, unsigned short seq, uint32_t time, int silent, int resent) {
    unsigned char bytes[64] = {0}, plain[48] = {0};
    const unsigned char key[16] = {0}, iv[16] = {0};
    int offset = resent ? 4 : 0;
    if (resent) { bytes[0] = 0x80; bytes[1] = 0xd6; }
    bytes[offset] = 0x80;
    bytes[offset + 1] = 0x60;
    bytes[offset + 2] = seq >> 8;
    bytes[offset + 3] = seq;
    for (int i = 0; i < 4; i++) bytes[offset + 4 + i] = time >> (24 - 8 * i);
    if (silent) memcpy(plain, silence, sizeof(silence));
    int payload_length = silent ? sizeof(silence) : sizeof(plain);
    aes_ctx_t *cipher = aes_cbc_init(key, iv, AES_ENCRYPT);
    assert(cipher);
    aes_cbc_encrypt(cipher, plain, bytes + offset + 12, payload_length);
    aes_cbc_destroy(cipher);
    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    destination.sin_port = htons(port);
    int length = offset + 12 + payload_length;
    assert(sendto(fd, bytes, length, 0, (struct sockaddr *)&destination, sizeof(destination)) == length);
}
static void wait_for(struct capture *capture, unsigned int wanted) {
    for (int i = 0; i < 200 && atomic_load_explicit(&capture->count, memory_order_acquire) < wanted; i++) usleep(1000);
}
int main(void) {
    remove(".build/audio-tests/transported-alac-silence.bin");
    int failed = 0;
    logger_t *logger = logger_init();
    logger_set_level(logger, LOGGER_ERR);
    for (int scenario = 0; scenario < 4; scenario++) {
        int resent = scenario == 1;
        struct capture capture = {0};
        atomic_init(&capture.count, 0);
        raop_callbacks_t callbacks = {0};
        callbacks.cls = &capture;
        callbacks.audio_process = audio;
        timing_protocol_t protocol = NTP;
        raop_ntp_t *ntp = raop_ntp_init(logger, &callbacks, "127.0.0.1", 4, 0, &protocol);
        const unsigned char key[16] = {0}, iv[16] = {0};
        raop_rtp_t *rtp = raop_rtp_init(logger, &callbacks, ntp, "127.0.0.1", 4, key, iv);
        assert(ntp && rtp);
        int sender = socket(AF_INET, SOCK_DGRAM, 0);
        assert(sender >= 0);
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(sender, (struct sockaddr *)&address, sizeof(address)) == 0);
        socklen_t size = sizeof(address);
        assert(getsockname(sender, (struct sockaddr *)&address, &size) == 0);
        memcpy(&rtp->control_saddr, &address, sizeof(address));
        rtp->control_saddr_len = sizeof(address);
        rtp->initial_sync = scenario != 3;
        rtp->rtp_sync = 10000;
        rtp->client_ntp_sync = raop_ntp_get_local_time();
        unsigned short remote_port = ntohs(address.sin_port), control_port = 0, data_port = 0;
        unsigned char ct = 2;
        unsigned int sr = 44100;
        raop_rtp_start_audio(rtp, &remote_port, &control_port, &data_port, &ct, &sr);
        assert(raop_rtp_is_running(rtp));
        if (scenario >= 2) {
            send_packet(sender, data_port, 100, 10000, 1, 0);
            if (scenario == 2) {
                wait_for(&capture, 1);
                send_packet(sender, data_port, 102, 10704, 1, 0);
                struct timeval timeout = {0, 200000};
                assert(setsockopt(sender, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
                unsigned char request[32];
                assert(recv(sender, request, sizeof(request), 0) == 8);
                assert(request[1] == 0xd5 && request[4] == 0 && request[5] == 101);
                send_packet(sender, control_port, 101, 10352, 1, 1);
            } else {
                send_packet(sender, data_port, 101, 10352, 1, 0);
                usleep(10000);
                unsigned char sync[20] = {0x90, 0xd4, 0, 4};
                uint32_t sync_rtp = htonl(10000U - 77175U), next_rtp = htonl(10000U);
                memcpy(sync + 4, &sync_rtp, sizeof(sync_rtp));
                byteutils_put_ntp_timestamp(sync, 8, raop_ntp_get_local_time());
                memcpy(sync + 16, &next_rtp, sizeof(next_rtp));
                struct sockaddr_in destination = {0};
                destination.sin_family = AF_INET;
                destination.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                destination.sin_port = htons(control_port);
                assert(sendto(sender, sync, sizeof(sync), 0, (struct sockaddr *)&destination, sizeof(destination)) == sizeof(sync));
            }
            unsigned int expected = scenario == 2 ? 3 : 2;
            wait_for(&capture, expected);
            raop_rtp_stop(rtp);
            unsigned int received = atomic_load_explicit(&capture.count, memory_order_acquire);
            if (received != expected) {
                fprintf(stderr, "FAIL ALAC %s waited for another data datagram: received=%u expected=%u\n",
                        scenario == 2 ? "last retransmission" : "initial sync", received, expected);
                failed = 1;
            } else {
                for (unsigned int i = 0; i < expected; i++) assert(capture.seq[i] == 100 + i);
                printf("PASS ALAC %s releases queued packets without a later data datagram\n",
                       scenario == 2 ? "last retransmission" : "initial sync");
            }
            raop_rtp_destroy(rtp);
            raop_ntp_destroy(ntp);
            close(sender);
            continue;
        }
        unsigned short first = resent ? 65533 : 100;
        send_packet(sender, data_port, first, 10000, 1, 0);
        send_packet(sender, data_port, first + 1, 10352, 0, 0);
        wait_for(&capture, 1);
        send_packet(sender, resent ? control_port : data_port, first + 2, 10704, 1, resent);
        usleep(10000);
        send_packet(sender, data_port, first + 3, 11056, 0, 0);
        wait_for(&capture, 4);
        raop_rtp_stop(rtp);
        unsigned int count = atomic_load_explicit(&capture.count, memory_order_acquire);
        int ordered = count == 4;
        for (int i = 0; ordered && i < 4; i++) ordered = capture.seq[i] == (unsigned short)(first + i);
        if (!ordered || capture.silent_count != 2) {
            fprintf(stderr, "FAIL ALAC %s: valid 32-byte silent audio discarded (received=%u silence=%u)\n", resent ? "retransmitted" : "direct", count, capture.silent_count);
            failed = 1;
        } else {
            printf("PASS ALAC %s valid silence survives UDP, AES, startup/resume and RTP wraparound\n", resent ? "retransmitted" : "direct");
        }
        raop_rtp_destroy(rtp);
        raop_ntp_destroy(ntp);
        close(sender);
    }
    logger_destroy(logger);
    return failed;
}
