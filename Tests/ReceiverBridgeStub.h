#include <stdint.h>
int mb_test_frame_rate(void);
int mb_test_start_count(void);
void mb_test_event(int event, int value, const char *info);
void mb_test_audio(const uint8_t *data, int len, unsigned char ct, uint64_t timestamp);
