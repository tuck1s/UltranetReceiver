/*
 * Simple parallel streaming tests
 */

#include <xs1.h>
#include <stdint.h>

void display_task(streaming chanend c);
void disk_write_read_task(streaming chanend c);
void dual_i2s_in_task(streaming chanend c);

#include <stdio.h>
#define NSAMPLES (0x2000)
// Display up to n incoming samples, then wait a bit
void display_task(streaming chanend c) {
    unsigned v[NSAMPLES], i;

    printf("Starting ..");
    //dump a block of samples
    for(i=0; i<NSAMPLES; i++) {
        c:> v[i];        // Receive an integer from the channel
    }
    for(i=0; i<NSAMPLES; i++) {
        if(i % 8 == 0) {
            printf("\n%04x: ",i);
        }
        printf("%08x ", v[i]);
    }
    printf("\nDone\n");
    while(1) {
        delay_milliseconds(10);
    }
}


void devnull_task(streaming chanend c) {
    uint32_t v;
    while(1) {
        c:> v;
    }
}

int main(void)
{
    streaming chan c;
    par {

        disk_write_read_task(c);
        dual_i2s_in_task(c);
        //devnull_task(c);
        //display_task(c);
    }
    return 0;
}
