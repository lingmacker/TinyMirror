/* Test real UxPlay RTP ordering without recording or playing user audio. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "raop_buffer.h"

static int enqueue(raop_buffer_t *buffer, uint16_t seq, int silent, int header_only) {
    unsigned char data[16] = {0x80, 0x60};
    data[2] = (unsigned char)(seq >> 8);
    data[3] = (unsigned char)seq;
    if (silent) {
        const unsigned char marker[] = {0x00, 0x68, 0x34, 0x00};
        memcpy(data + 12, marker, 4);
    } else {
        /* Short tails are unencrypted: test ordering, not codec validity. */
        data[12] = 0x8c;
        data[13] = (unsigned char)(seq >> 8);
        data[14] = (unsigned char)seq;
        data[15] = 0x55;
    }
    return raop_buffer_enqueue(buffer, data, header_only ? 12 : 16, 1);
}

static int pop(raop_buffer_t *buffer, int no_resend) {
    unsigned int length = 0;
    uint32_t timestamp = 0;
    unsigned short seq = 0;
    unsigned char *payload = raop_buffer_dequeue(buffer, &length, &timestamp, &seq, no_resend);
    if (!payload) return -1;
    assert(length == 4 && payload[0] == 0x8c && payload[3] == 0x55);
    assert(payload[1] == (unsigned char)(seq >> 8) && payload[2] == (unsigned char)seq);
    free(payload);
    return seq;
}

struct resend { int calls; unsigned short seq; unsigned short count; };
static int request(void *context, unsigned short seq, unsigned short count) {
    struct resend *result = context;
    result->calls++;
    result->seq = seq;
    result->count = count;
    return 0;
}

int main(void) {
    setbuf(stdout, NULL);
    const unsigned char key[16] = {0}, iv[16] = {0};
    logger_t *logger = logger_init();
    logger_set_level(logger, LOGGER_ERR);
    raop_buffer_t *buffer = raop_buffer_init(logger, key, iv);
    assert(buffer);

    enqueue(buffer, 100, 0, 0);
    assert(pop(buffer, 0) == 100);
    enqueue(buffer, 101, 1, 0);
    enqueue(buffer, 102, 0, 0);
    if (pop(buffer, 0) != 102) {
        fprintf(stderr, "FAIL: known AAC-ELD silence is treated as loss; next clip opening is blocked\n");
        return 1;
    }
    puts("PASS first audio after a no-data marker is delivered immediately");

    raop_buffer_flush(buffer, -1);
    for (int i = 0; i < 100; i++) {
        enqueue(buffer, (uint16_t)i, 1, i % 2);
        assert(pop(buffer, 0) == -1);
    }
    enqueue(buffer, 100, 0, 0);
    assert(pop(buffer, 0) == 100);
    puts("PASS long silence, header-only packets, and resumed audio");

    enqueue(buffer, 102, 0, 0);
    assert(pop(buffer, 0) == -1);
    struct resend retry = {0};
    raop_buffer_handle_resends(buffer, request, &retry);
    assert(retry.calls == 1 && retry.seq == 101 && retry.count == 1);
    enqueue(buffer, 101, 1, 0);
    assert(pop(buffer, 0) == 102);
    puts("PASS reordered silence does not erase already received audio");

    enqueue(buffer, 104, 0, 0);
    assert(pop(buffer, 0) == -1);
    memset(&retry, 0, sizeof(retry));
    raop_buffer_handle_resends(buffer, request, &retry);
    assert(retry.calls == 1 && retry.seq == 103 && retry.count == 1);
    enqueue(buffer, 103, 0, 0);
    assert(pop(buffer, 0) == 103 && pop(buffer, 0) == 104);
    enqueue(buffer, 105, 1, 0);
    enqueue(buffer, 107, 0, 0);
    assert(pop(buffer, 0) == -1);
    memset(&retry, 0, sizeof(retry));
    raop_buffer_handle_resends(buffer, request, &retry);
    assert(retry.calls == 1 && retry.seq == 106 && retry.count == 1);
    enqueue(buffer, 106, 1, 0);
    assert(pop(buffer, 0) == 107);
    puts("PASS genuine packet loss still requests retransmission and preserves order");

    raop_buffer_flush(buffer, -1);
    enqueue(buffer, 65534, 0, 0);
    assert(pop(buffer, 0) == 65534);
    enqueue(buffer, 65535, 1, 0);
    enqueue(buffer, 0, 1, 1);
    enqueue(buffer, 1, 0, 0);
    assert(pop(buffer, 0) == 1);
    assert(enqueue(buffer, 0, 1, 0) == 0);
    enqueue(buffer, 2, 0, 0);
    assert(enqueue(buffer, 2, 0, 0) == 0);
    assert(pop(buffer, 0) == 2 && pop(buffer, 0) == -1);
    puts("PASS sequence wraparound and duplicate/redundant packets");

    raop_buffer_flush(buffer, -1);
    enqueue(buffer, 10, 0, 0);
    assert(pop(buffer, 0) == 10);
    for (int i = 12; i <= 266; i++) enqueue(buffer, (uint16_t)i, 0, 0);
    for (int i = 12; i <= 266; i++) assert(pop(buffer, 0) == i);
    assert(pop(buffer, 0) == -1);
    enqueue(buffer, 268, 0, 0);
    assert(pop(buffer, 1) == 268);
    puts("PASS full reorder window and no-resend mode drain without an extra datagram");

    raop_buffer_flush(buffer, -1);
    for (int i = 0; i < 4000; i++) {
        uint16_t seq = (uint16_t)(65000 + i);
        int silent = (i % 11) != 0;
        enqueue(buffer, seq, silent, silent && i % 2);
        enqueue(buffer, seq, silent, silent && i % 2);
        assert(pop(buffer, 0) == (silent ? -1 : seq));
    }
    unsigned char short_packet[16] = {0};
    for (unsigned short size = 0; size < 12; size++) {
        assert(raop_buffer_enqueue(buffer, short_packet, size, 1) == -1);
    }
    puts("PASS 4000 silence/audio transitions, retransmission duplicates, and short-packet validation");
    raop_buffer_destroy(buffer);
    logger_destroy(logger);
    return 0;
}
