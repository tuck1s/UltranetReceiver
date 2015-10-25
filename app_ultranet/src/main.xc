/*
 * Simple parallel streaming tests
 */

#include <xs1.h>
#include <stdint.h>

const unsigned targetFileSize = 4*1024*1024;  //4096UL*1024*1024*1024-32768;   // Can't quite get to 4G size


void disk_write_read_task(chanend c, uint32_t targetFileSize);
void dual_i2s_in_task(streaming chanend c, uint32_t targetFileSize);
void fifo_task(streaming chanend c, chanend d);

int main(void)
{
    streaming chan c;
    chan d;

    // This version connects with a fifo task, thus:
    // producer -> fifo -> consumer
    par {
        dual_i2s_in_task(c, targetFileSize);
        fifo_task(c, d);
        disk_write_read_task(d, targetFileSize);
    }
    return 0;
}
