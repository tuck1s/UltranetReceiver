/*
 * Simple parallel streaming tests
 */

#include <xs1.h>
#include <stdint.h>

void display_task(streaming chanend c);
void disk_write_read_task(chanend c);
void dual_i2s_in_task(streaming chanend c);
void fifo_task(streaming chanend c, chanend d);

int main(void)
{
    streaming chan c;
    chan d;

    // This version connects with a fifo task, thus:
    // producer -> fifo -> consumer
    par {
        dual_i2s_in_task(c);
        fifo_task(c, d);
        disk_write_read_task(d);
    }
    return 0;
}
