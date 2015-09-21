// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

///////////////////////////////////////////////////////////////////////////////
//
// Multichannel I2S_SLAVE slave receiver-transmitter

#include <xs1.h>
#include <xclib.h>
#include "i2s_slave.h"

#pragma unsafe arrays
void i2s_slave_rx32_loop(in buffered port:32 din[], streaming chanend c_in, in port wck)
{
    int lr = 0;
    while (1) {
        int t;
        unsigned x;

        // wait for WCK edge
        // timestamp this edge
        wck when pinsneq(lr) :> lr @ t;

        // set time for audio data input
        // split SETPT from IN using asm
        // basically a split transaction to allow multichannel timed input
        // input is always "up to" given time
        // I2S_SLAVE sample starts at t + 1, so capture "up to" t + 1 + 31 for full 32-bit input
#pragma loop unroll
        //for (int i = 0; i < I2S_SLAVE_NUM_IN; i++) {
          asm("setpt res[%0], %1" :: "r"(din[0]), "r"(t + 31));
        //}
        // Output code removed

        // Read full 32-bit value and send to the channel
#pragma loop unroll
        //for (int i = 0; i < I2S_SLAVE_NUM_IN; i++) {
                asm("in %0, res[%1]" : "=r"(x)  : "r"(din[0]));
                c_in <: bitrev(x);
        //}
        //        din[1] :>x;
        //        c_in <: bitrev(x);
     }
}

void i2s_slave_rx32_task(struct i2s_slave_rx32 &r_i2s_slave, streaming chanend c_in)
{
  // clock block clocked off external BCK
  set_clock_src(r_i2s_slave.cb, r_i2s_slave.bck);

  // WCK and all data ports clocked off BCK
  set_port_clock(r_i2s_slave.wck, r_i2s_slave.cb);
  for (int i = 0; i < I2S_SLAVE_NUM_IN; i++)
  {
    set_port_clock(r_i2s_slave.din[i], r_i2s_slave.cb);
  }

  // start clock block after configuration
  start_clock(r_i2s_slave.cb);

  // fast mode - instructions repeatedly issued instead of paused
  set_thread_fast_mode_on();

  i2s_slave_rx32_loop(r_i2s_slave.din, c_in, r_i2s_slave.wck);

  set_thread_fast_mode_off();
}
