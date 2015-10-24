/*
 * i2s-32bit-simple.xc
 *
 *  Created on: 22 Sep 2015
 *      Author: steve
 */

#include <stdio.h>
#include <xs1.h>
#include <xclib.h>
#include <stdint.h>
#include "wavfile.h"                    // Helper functions for filling in WAV file header

clock cb = XS1_CLKBLK_1;                // Clock Block
in port bclk = XS1_PORT_1H;             // J7 pin 2 = BLCK from WM8804      Bit Clock
in port lrclk = XS1_PORT_1F;            // J7 pin 1 = LRCLK from WM8804     Word Clock
in buffered port:32 dinA = XS1_PORT_1G; // J7 pin 3 = DOUT from WM8804      Ultranet Channels 1 .. 8 data
in buffered port:32 dinB = XS1_PORT_1E; // J7 pin 4 = DOUT_9_16 from WM8804 Ultranet Channels 9 .. 16 data

// out port scopetcrig = XS1_PORT_1J;       // Debug scope trigger on J7 pin 10

enum i2s_state { search_lr_sync, search_multiframe_sync, check_second_multiframe_sync, in_sync };
#define FRAME_SIZE 0x180

inline void status_leds_good();
inline void status_leds_error();

extern void send_ab_to_chan(streaming chanend c, uint32_t a, uint32_t b);

/*
 * Send two values a and b to the channel (helper function).
 * Formatting will be adjusted to fit the bandwidth available in the SDcard write process.
 *
 * Initial version:  just send channel A, most significant 16 bits contains the audio.
 * Double-pack the words written to the channel.
 */
#define B_CHANNELS_ON
uint32_t ahalfword = 0;
uint32_t currChan = 0;
const uint32_t nChans = 8;              //todo: increase this

inline void send_ab_to_chan(streaming chanend c, uint32_t a, uint32_t b) {
    if(currChan<nChans) {
        // This is an active channel - send it
#ifdef B_CHANNELS_ON
        c<: (a&0xffff0000)|(b>>16);
#else
        // Compact mode - Write two 16-bit A-channel signed values into a single 32-bit channel-word
        if(ahalfword) {
            c<: (a&0xffff0000)|(ahalfword);      // Pack two words in, little-endian word order
            ahalfword = 0;              // Clear the pending value
        }
        else {
            ahalfword = a>>16;          // Store the pending value
        }
#endif
    }
    currChan++;
    currChan &=0x7;       // Only one in 8 channels
}

#ifdef B_CHANNELS_ON
#define totChans (nChans*2)
#else
#define totChans (nChans)
#endif
/*
 * Insert a WAV header to the downstream channel
 * Based on the parameters we have on the sample sender above
 */
#define hdrLen (sizeof(WaveHeader)/4)

void insert_wav_header(streaming chanend c, uint32_t fileSize) {
    uint32_t p[hdrLen+1];       // working storage for the header allow some spare
    uint32_t numSamples = (fileSize-sizeof(WaveHeader))/(2*totChans);
    printf("WAV header:  numSamples = %d, totChans = %d, fileSize = %d\n\n", numSamples, totChans, fileSize);

    set_wav_header((WaveHeader *)p, totChans, 48000, numSamples);
    for(int i=0; i<hdrLen; i++) {
        c<: p[i];               // Send the header 32 bits at a time
    }
}

/* Input on two i2s streams A and B in parallel
 * - Get LR sync
 * - Get multiframe sync (signalled by LS byte = 0x09)
 * - Process frames, while checking we're still in sync
 * - if data doesn't match, drop back to reacquire LR sync in case of missed or erroneous data
 */
void dual_i2s_in_task(streaming chanend c, uint32_t fileSize) {
    enum i2s_state st;
    int t, lr;
    uint32_t s1A, s2A, s1B, s2B;
    const uint8_t lsb_mid = 0x01;                   // LSB values seen on Ultranet interface
    const uint8_t lsb_mframe = 0x09;

    // LRCLK and all data ports clocked off BCLK
    configure_in_port(dinA, cb);
    configure_in_port(dinB, cb);
    configure_in_port(lrclk, cb);

    // clock block clocked off external BCLK
    set_clock_src(cb, bclk);
    start_clock(cb);                            // start clock block after configuration
    st = search_lr_sync;
    status_leds_good();

    insert_wav_header(c, fileSize);             // Put this into the fifo before stream samples

    delay_milliseconds(1000*5);                 // Wait before starting to fill the buffer

    while(1){
        switch(st) {
        case search_lr_sync:
            lrclk :> lr;                        // Read the initial value
            lrclk when pinsneq(lr) :> lr @t;    // Wait for LRCLK edge, and timestamp it
            clearbuf(dinA);
            clearbuf(dinB);

            t+= 31;                             // Just had the LSB of previous word
            dinB @t :> s1B; s1B = bitrev(s1B);  // todo: why does this only work when in order B then A?
            dinA @t :> s1A; s1A = bitrev(s1A);

            // Change state only if we're strictly in mid-frame on both channels
            if( (s1A & 0xff) == lsb_mid ) {
                st = search_multiframe_sync;
                t = FRAME_SIZE;                 // limit acquisition time
            }
            break;

        case search_multiframe_sync:
            // Look for samples, on both channels, that match multiframe sync pattern
            // pre-req: t must be set to max acquisition time
            dinA :> s1A; s1A = bitrev(s1A);
            dinB :> s1B; s1B = bitrev(s1B);
            if((s1A & 0xff) == lsb_mframe && (s1B & 0xff) == lsb_mframe) {
                st = check_second_multiframe_sync;
            }
            else {
                if(--t <=0) {
                    status_leds_error();
                    st = search_lr_sync;        // Waited too long - start again from scratch
                }
            }
            break;

        case check_second_multiframe_sync:
            dinA :> s2A; s2A = bitrev(s2A);
            dinB :> s2B; s2B = bitrev(s2B);
            if((s2A & 0xff) == lsb_mframe && (s2B & 0xff) == lsb_mframe) {
                // Stream out the valid samples from the start of this multiframe
                send_ab_to_chan(c, s1A, s1B);
                send_ab_to_chan(c, s2A, s2B);
                st = in_sync;
            }
            else {
                status_leds_error();
                st = search_lr_sync;    // Mismatch - go back to initial state and re-acquire sync
            }
            break;

        case in_sync:
            // Process the remaining complete frame of data
            for(t=2; t<FRAME_SIZE; t++) {
                dinA :> s1A; s1A = bitrev(s1A);
                dinB :> s1B; s1B = bitrev(s1B);
                send_ab_to_chan(c, s1A, s1B);
            }
            // Check the next frame is starting with multiframe sync in the expected place
            t = 1;                      // Strict - only got 1 chance to get it
            st = search_multiframe_sync;

            // Indicate all is well on the 3x3 LEDs
            status_leds_good();
            break;
        }
    }
}


/* Display "spinning dot" LED when in sync
 * the patterns for each bit are:
 *   0x80000 0x40000 0x20000
 *   0x01000 0x00800 0x00400
 *   0x00200 0x00100 0x00080
 *
 * As the leds go to 3V3, 0x00000 drives all 9 leds on, and 0xE1F80 drives
 * all nine leds off.
 */
#define middle_led 0x00800
const int leds_3x3[] = {0xA1F80, 0xC1F80, 0xE1B80, 0xE1F00, 0xE1E80, 0xE1D80, 0xE0F80, 0x71F80};
port p32 = XS1_PORT_32A;                            // This the 3x3 LEDs port

// Counters
uint32_t frame_err_ctr = 0;
uint32_t frame_good_ctr = 0;

uint32_t err_led_on = 0;
uint32_t spin_bits = 0xA1F80;                       // Starting position
uint32_t spin_pos = 0;
uint32_t err_bit = 0;

const uint32_t err_led_on_time = 1*(48000/(FRAME_SIZE/8));

// 8-position spinning dot for good frames (changing every 2^n valid frames)
// xor'd with the middle one indicating errors
void status_leds_good() {
    frame_good_ctr++;
    if(!(frame_good_ctr & 0x3f)) {
        // Walk to the next position every 2^n frames
        spin_pos++; spin_pos &= 0x7;
        spin_bits = (leds_3x3[spin_pos]);
    }
    if(err_led_on) {
        err_led_on--;                   // count down, extinguish when zero
    }
    else {
        err_bit = 0;
    }
    p32 <: (spin_bits ^ err_bit);
}

void status_leds_error() {
    frame_err_ctr++;
    err_led_on = err_led_on_time;       // Light the Error LED through the next n seconds/frames
    err_bit = middle_led;
    p32 <: (spin_bits ^ err_bit);
}
