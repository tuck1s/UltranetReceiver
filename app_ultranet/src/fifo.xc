/*
 * fifo.xc
 *
 *  Created on: 21 Oct 2015
 *      Author: steve
 */

#include <print.h>
#include <xs1.h>
/*
 * Define FIFO size (in 32-bit ints)
 */
#define bufSize 0x2000                      // MUST be a power of two, to permit logical-AND wraparounds
#define bufMask (bufSize-1)                 // MUST be one less than bufSize .. compile-time constant
#define DEBUG_FIFO

/* ************************************************************************************
 * fifo_task
 * Consume values from c
 * Produce values out to a (non-streaming) channel through use of control tokens
 * ************************************************************************************/
void fifo_task(streaming chanend c, chanend d)
{
    unsigned bufHead = 0;                   // (head = tail) and (count = 0) when empty [likewise (head = tail) & (count = max) when full]
    unsigned bufTail = 0;
    unsigned bufCount = 0;                  // use separate count var as then we can use all entries in the ring buffer and correctly distinguish full/empty
    unsigned notified = 0;                  // Used for control-token passing
    unsigned buf[bufSize];                  // ring buffer

    while(1) {
        select {
          case c :> unsigned v:
            // Add new value to the buffer head
            if(bufCount < bufSize) {            // we have space
                buf[bufHead++] = v;
                bufHead &= bufMask;             // Cheap way to do wraparound
                bufCount++;
            }
#ifdef DEBUG_FIFO
            else {
                printstr("*");                  // fixme: Test code only:  Houston we have a problem, buffer overflow
            }
#endif
            if (!notified) {                    // Wake up the downstream consumer
              outct(d, XS1_CT_END);
              notified = 1;
            }
            break;

          case d :> int request:
            d <: buf[bufTail++];                // issue tail value to downstream channel
            bufTail &= bufMask;                 // Cheap way to do wraparound
            if(--bufCount==0) {
                notified = 0;                   // If buffer's empty we'll need to renotify later
            }
            else {
                outct(d, XS1_CT_END);
            }
            break;
        }
    }
}

