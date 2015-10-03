// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

#include <xs1.h>
#include <platform.h>

timer t;

// Functions to get the time from a timer.
unsigned int get_time(void)
{
  unsigned int time;

  t :> time;
  return time;
}
