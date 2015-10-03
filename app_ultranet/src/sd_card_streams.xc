/*
 * Simple parallel streaming tests
 */

#include <xs1.h>
#include <stdint.h>

// Generate predictable pseudo-random traffic (that we can compare against for proof of testing)
#define CRC32_ETH_REV_POLY 0xEDB88320       // x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x^1 + x^0
                                            // See https://github.com/xcore/doc_tips_and_tricks/blob/master/doc/crc.rst

const unsigned seedval = 0xf00dbeef;

void crc_stream_to(streaming chanend c)
{
    unsigned p = seedval;
    while(1) {
        c <: p;
        crc32(p, 0, CRC32_ETH_REV_POLY);
    }
}

extern void disk_write_read_task(streaming chanend c);

int main(void)
{
    streaming chan c;
    par {
        disk_write_read_task(c);
        crc_stream_to(c);

    }
    return 0;
}

/*
 * Equivalent CRC-32 functions as in the streaming write code
 * Note these simple functions use a static variable so they're not thread-safe
 */
unsigned p;
void init_the_crc(void)
{
    p = seedval;
}

unsigned walk_the_crc(void)
{
    unsigned oldp = p;
    crc32(p, 0, CRC32_ETH_REV_POLY);
    return oldp;
}
