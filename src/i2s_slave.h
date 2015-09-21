// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

///////////////////////////////////////////////////////////////////////////////
//
// Multichannel I2S_SLAVE slave
// 32-bit receive only version

#ifndef _I2S_SLAVE_H_
#define _I2S_SLAVE_H_

#define I2S_SLAVE_NUM_IN 2          // Ultranet has two channels

#ifdef __i2s_slave_conf_h_exists__
#include "i2s_slave_conf.h"
#endif

/** Resources for I2S_SLAVE
 */
struct i2s_slave_rx32 {
  clock cb; /**< Clock block for external BCK */

  in port bck; /**< Clock port for BCK */
  in port wck; /**< Clock port for WCK */

  in buffered port:32 din[I2S_SLAVE_NUM_IN]; /**< Array of I2S_SLAVE_NUM_IN x 1-bit ports for audio input */
};

/** I2S Slave Task - call from main() loop, never returns
 *
 * Samples are full 32-bit values
 *
 * \param r_i2s_slave_rx32  Structure to configure the i2s_slave
 *
 * \param c_in              Input streaming channel for sample data.
 *                          Samples are returned in the following order:
 *                          Left (din[0]), .., Left (din[I2S_SLAVE_NUM_IN - 1]),
 *                          Right (din[0]), .., Right (din[I2S_SLAVE_NUM_IN - 1])
 * Output channel removed
 */
void i2s_slave_rx32_task(struct i2s_slave_rx32 &r_i2s_slave, streaming chanend c_in);

#endif // _I2S_SLAVE_H_
