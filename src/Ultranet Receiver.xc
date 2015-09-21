/*
 * Ultranet Receiver.xc
 *
 *  Created on: 11 Aug 2015
 *      Author: steve
 *
 *  Captures incoming data from I2S port and streams it via a channel to a debug process.
 */
#include <stdio.h>
#include <xscope.h>
#include <xs1.h>
#include <platform.h>
#include <timer.h>
#include <xclib.h>
#include "i2s_slave.h"

struct i2s_slave_rx32 myports =
{
   XS1_CLKBLK_1,        // Clock Block
   XS1_PORT_1H,         // J7 pin 2 = BLCK from WM8804      Bit Clock
   XS1_PORT_1F,         // J7 pin 1 = LRCLK from WM8804     Word Clock
   { XS1_PORT_1G,       // J7 pin 3 = DOUT from WM8804      Ultranet Channels 1 .. 8 data
     XS1_PORT_1E }      // J7 pin 4 = DOUT_9_16 from WM8804 Ultranet Channels 9 .. 16 data
};

#define NSAMPLES 1024
// Display up to n incoming samples, then wait a bit
void display_task(streaming chanend c) {
    unsigned v[NSAMPLES], i;

    printf("Purging %d samples\n", NSAMPLES);
    for(i=0; i<NSAMPLES; i++) {
         c:> v[0];      // Receive an integer from the channel
     }

    printf("Searching for frame sync\n");
    c:> v[0];
    // Wait for frame sync pattern in the LS byte
    while((v[0] & 0xff)!=0x09) {
        c:> v[0];
    }
    // Got sample 0 already
    for(i=1; i<NSAMPLES; i++) {
        c:> v[i];      // Receive an integer from the channel
    }
    //Now dump a block of samples
    for(i=0; i<NSAMPLES; i++) {
        printf("%08x\n", v[i]);
    }

    // Discard any more samples
    while(1) {
        c:> v[0];
    }
}


// Simulate input to the channel as a sequence of incrementing integers
/* void gen_task(streaming chanend c) {
    int v = 0;
    while(1) {
        v++;
        c<: v;      // Output an integer to the channel
        //delay_milliseconds(1);
    }
}
*/

int main() {
    streaming chan c;
    par {
            // Capture input from the i2s interface.
            i2s_slave_rx32_task(myports, c);

            display_task(c);

            // Keep the output channel full in case it causes blocking
            //gen_task(d);
        }
    return 0;
}
