#include "diskio.h"
#ifdef BUS_MODE_4BIT
#include <xs1.h>
#include <xclib.h>
#include <stdint.h>                 // Standard sized integer types
#include "timing.h"
#include <stdio.h>                  //todo: temp


void dead_parrot(int rc)            /* Stop with dying message */
{
    printf("\nSDCardhost4Bit:  Failed with rc=%u.\n", rc);
    while(1)
        ;
}


// Instrumentation:  Measure max/min response times
unsigned SendCmd_twr_max = 0;
unsigned SendCmd_twr_min = 9999999;
#define max(a,b) ((a)>(b))?(a):(b)
#define min(a,b) ((a)<(b))?(a):(b)

typedef struct SDHostInterface
{
  out port Clk; // a 1 bit port
  port Cmd; // a 1 bit port. Need an external pull-up resistor if not an XS1_G core
  port Dat; // a 4 bit port. Beware: connect D0 to PortBit3, D1 to PortBit2, D2 to PortBit1, D3 to PortBit0
            // D0 (PortBit3) need an external pull-up resistor if not an XS1_G core
/*
   D D C     C   D D
   a a m     l   a a
   t t d     k   t t
   1 0           3 2
   __________________
  /  | | | | | | | | |
  || D C - + C - D D |
  |D 3 M G 3 L G 0 1 |
  |2   D N . K N     |
  |      D 3   D     |
  |        V         |
*/
  /* fields returned after initialization */
  unsigned long Rca; // RCA returned by SD card during initialization. Relative card address.
  unsigned char Ccs; // CCS returned by SD card during initialization. Card capacity status: 0 = SDSC; 1 = SDHC/SDXC
  unsigned long BlockNr; // number of 512 bytes blocks. Returned by initialization.
} SDHostInterface;

static SDHostInterface SDif[] = {
// LIST HERE THE PORTS USED FOR THE INTERFACES
//       CLK,         CMD,     DAT3..0,
{XS1_PORT_1M, XS1_PORT_1N, XS1_PORT_4E, 0, 0, 0}, // ports used for interface #0
//{XS1_PORT_1O, XS1_PORT_1P, XS1_PORT_4F, 0, 0, 0}; // ports used for interface #1
};

/***************************/

typedef enum RespType
{R0, R1, R1B, R2, R3, R6, R7} RESP_TYPE;

typedef unsigned char RESP[17]; // type for SD responses

#define RESP_WAITING_START_BIT   1
#define RESP_RECEIVING_BITS      2

#define DAT_WAITING_START_NIBBLE 1
#define DAT_RECEIVING_NIBBLE_H   2
#define DAT_RECEIVING_NIBBLE_L   3
#define DAT_RECEIVING_CRC        4

#define CRC7_POLY (0x91 >> 1) //x^7+X^3+x^0
#define CRC16_POLY (0x10811 >> 1) //x^16+X^12+x^5+x^0

// Temp - add no-ops
#define NOP_PAUSE_SETUP asm("nop");asm("nop");
#define NOP_PAUSE_HOLD  asm("nop");asm("nop");

// Writes should need shorter setup time and longer hold time
#define NOP_PAUSE_WR_SETUP asm("nop");
#define NOP_PAUSE_WR_HOLD  asm("nop");asm("nop");

// Commands go from XMOS -> SDcard therefore use write timings
#define CMD_BIT(Data) SDif[IfNum].Cmd <: >> Data;NOP_PAUSE_WR_SETUP; SDif[IfNum].Clk <: 1; NOP_PAUSE_WR_HOLD; SDif[IfNum].Clk <: 0;

int Is_XS1_G_Core = 0;

void ToggleClock(int count, out port clk)
{
  // Use timer instead of NOPs, as it allows co-op multitasking.
  // Doing this part somewhat slowly has little effect on the overall throughput
  //Clock idle low
  timer t;
  uint32_t time;
  int clkState = 0;
  const uint32_t clkPeriod = 8;           // Units of 10ns. this is about as fast as a StartKit can go in this loop

  t :> time;                              // get the initial timer value
  count<<=1;                              // both edges
  while(count--) {                        // send 'count' clock toggles
    select {
      case t when timerafter(time) :> void:     // perform periodic task
        clkState = !clkState;
        clk <: clkState;
        time += clkPeriod;
        break;
    }
  }
}


// Wait for in port p (masked with bitmask) to give chkval, while toggling clk
unsigned WaitForTimed(in port p, unsigned bitmask, unsigned chkval, out port clk)
{
  unsigned val;
  uint32_t start_t, time;
  timer t;
  int clkState = 0;
  int i;
  const uint32_t clkHighPeriod = 32;
  const uint32_t nFastClks = 64;            // try this number of fast clocks first, then go slow (as the card is taking a while anyway)
  const uint32_t clkLowPeriodFast = 32;     // Units of 10ns
  const uint32_t clkLowPeriodSlow = 1000;   // Units of 10ns
  const uint32_t MaxSlowClks = 100000000/clkLowPeriodSlow;   // Wait a maximum of 1 second in slow mode

  t :> time;                            // get the initial timer value
  start_t = time;                       //todo: temp

  for(i=0; i<MaxSlowClks;i++)
  {
    select {
      case t when timerafter(time) :> void:   // perform periodic task
        if(clkState)
        {
          // If the clock is currently high, then the in port will have settled and we can read it
          p :> val;
          clkState=0;                          // must return clock to low (idle) again
          clk <: clkState;
          if( (val & bitmask) == chkval)
          {
            // RecordTiming(get_time()-start_t);
            return val;                       // Got the expected response
          }
          else
          {
            // try n fast periods first, then slow down
            // time += (i<nFastClks)? clkLowPeriodFast: clkLowPeriodSlow;
            if(i<nFastClks)
            {
              time += clkLowPeriodFast;
            }
            else
            {
              time += clkLowPeriodSlow;
            }
          }
        }
        else
        {
          clkState = 1;
          clk <: clkState;
          time += clkHighPeriod;
        }
        break;
    }
  }
  return 0;                                 // Error - timeout
}

#pragma unsafe arrays

// compacting each bit of the 8 nibbles...
// todo: do this in assembly
#define calc_sdcard_crc(Dat, D0, D1, D2, D3, Crc0, Crc1, Crc2, Crc3) D3 = Dat & 0x11111111;D3 |= D3 >> 3; D3 &= 0x03030303; D3 |= D3 >> 6; D3 |= D3 >> 12;crc8shr(Crc3, D3, CRC16_POLY);D2 = (Dat >> 1) & 0x11111111;D2 |= D2 >> 3; D2 &= 0x03030303; D2 |= D2 >> 6; D2 |= D2 >> 12;crc8shr(Crc2, D2, CRC16_POLY);D1 = (Dat >> 2) & 0x11111111;D1 |= D1 >> 3; D1 &= 0x03030303; D1 |= D1 >> 6; D1 |= D1 >> 12;crc8shr(Crc1, D1, CRC16_POLY);D0 = (Dat >> 3) & 0x11111111;D0 |= D0 >> 3; D0 &= 0x03030303; D0 |= D0 >> 6; D0 |= D0 >> 12;crc8shr(Crc0, D0, CRC16_POLY);

// Send the nibbles to the port
// Add no-ops to allow setup and hold times
// todo: do this in assembly
#define send_8_nibbles for(i = 8; i; i--) { SDif[IfNum].Dat <: >> Dat; NOP_PAUSE_WR_SETUP; SDif[IfNum].Clk <: 1; NOP_PAUSE_WR_HOLD; SDif[IfNum].Clk <: 0; }


/**********************************************************************************
 * XMOS specific STREAMED version of commands
 *
 * Memory buffer:   Pass valid buff[], set c to null.
 * Streamed:        Set buff[] as null, and channel c will be used to read/write data instead
 **********************************************************************************/
static DRESULT SendCmd(BYTE IfNum, BYTE Cmd, DWORD Arg, RESP_TYPE RespType, int DataBlocks, BYTE buff[], RESP Resp, streaming chanend ?c)

{ //01CMD[6]ARG[32]CRC[7]1
  unsigned int i, j, Crc0 = 0, Crc1, Crc2, Crc3;
  unsigned int D0, D1, D2, D3;
  unsigned int RespStat, RespBitLen, RespBitCount, RespByteCount;
  unsigned int DatStat, DatBytesLen, DatByteCount, Dat;
  unsigned char R;

  set_port_drive(SDif[IfNum].Cmd);
  i = bitrev(Cmd | 0b01000000) >> 24; // build first byte of command: start bit, host sending bit, Cmd
  crc8shr(Crc0, i, CRC7_POLY);

  SDif[IfNum].Clk <: 0;                 // Clock is idle low, so begin in that state

  CMD_BIT(i) // send first byte of command
  Arg = bitrev(Arg);
  CMD_BIT(i)
  crc32(Crc0, Arg, CRC7_POLY);
  CMD_BIT(i)
  crc32(Crc0, 0, CRC7_POLY); // flush crc engine
  CMD_BIT(i)
  Crc0 |= 0x80; // build last byte of command: crc7 and stop bit
  CMD_BIT(i)
  RespStat = ((R0 == RespType) ? 0 : RESP_WAITING_START_BIT);
  CMD_BIT(i)
  RespBitLen = (R2 == RespType) ? 136 : 48;
  CMD_BIT(i)
  RespBitCount = 0;
  CMD_BIT(i)
  for(i = 32; i; i--) { CMD_BIT(Arg) } // send arg
  CMD_BIT(Crc0) // send CRC7 and stop bit
  RespByteCount = 0;
  CMD_BIT(Crc0)
  Dat = 0xFFFFFFFF;
  CMD_BIT(Crc0)
  R = 0xFF;
  CMD_BIT(Crc0)
  DatStat = (0 < DataBlocks) ? DAT_WAITING_START_NIBBLE : 0;
  CMD_BIT(Crc0)
  DatBytesLen = DataBlocks * 512;
  CMD_BIT(Crc0)
  DatByteCount = 0;
  CMD_BIT(Crc0)
  i = 0;
  CMD_BIT(Crc0)

  if(Is_XS1_G_Core) // check if an XS1-G can enable internal pull-up
    set_port_pull_up(SDif[IfNum].Cmd); // otherwise need an external pull-up resistor for Cmd pin
  SDif[IfNum].Cmd :> void;
  while(RespStat || DatStat)
  {
    // Add no-ops to allow setup and hold times
    SDif[IfNum].Clk <: 1; NOP_PAUSE_HOLD; // 1 clock pulse
    // We  read both R and Dat, we'll use one or the other below
    SDif[IfNum].Cmd :> >> R; SDif[IfNum].Dat :> >> Dat; SDif[IfNum].Clk <: 0;      //Clock back to idle
    i++;

    switch(RespStat)
    {
      case RESP_WAITING_START_BIT:
        if(0xFF == R)
        {
          if(4000000 == i) return RES_ERROR; // busy timeout
          break;
        }
        RespBitCount = 1;
        RespStat = RESP_RECEIVING_BITS; // next state
        break;
      case RESP_RECEIVING_BITS:
        if(++RespBitCount % 8) break;
        if(RespBitCount == RespBitLen)
          RespStat = 0;
        Resp[RespByteCount++] = R;
        break;
    }

    switch(DatStat)
    {
      case DAT_WAITING_START_NIBBLE:
        if(0x0FFFFFFF == Dat) DatStat = DAT_RECEIVING_NIBBLE_H; // if start nibble arrived -> next state
        else if(400000 == i) return RES_ERROR; // busy timeout
        break;

      case DAT_RECEIVING_NIBBLE_H:
        DatStat = DAT_RECEIVING_NIBBLE_L; // next state
        break;

      case DAT_RECEIVING_NIBBLE_L:
        if(buff == NULL) {
            dead_parrot(0);                         //todo: streaming mode
        }
        buff[DatByteCount++] = bitrev(Dat);
        if(!RespStat) // if response received... (can continue just sampling dat lines)
        {
          while(DatByteCount & 511)
          { /* todo: doing this stuff with assembly would highly increase performance */

          /* Information from http://wiki.seabright.co.nz/wiki/SdCardProtocol.html
               * Data is clocked into the host or card on the rising edge of CLK and changes on the falling edge.
               * This is equivalent to the SPI (0, 0) mode.
               */
            SDif[IfNum].Clk <: 1; NOP_PAUSE_SETUP; SDif[IfNum].Dat :> >> Dat; SDif[IfNum].Clk <: 0; NOP_PAUSE_HOLD; // 1 clock pulse
            SDif[IfNum].Clk <: 1; NOP_PAUSE_SETUP; SDif[IfNum].Dat :> >> Dat; SDif[IfNum].Clk <: 0; NOP_PAUSE_HOLD; // 1 clock pulse
            buff[DatByteCount++] = bitrev(Dat);
          }
          j = 17; DatStat = DAT_RECEIVING_CRC; // next state
          break;
        }
        if(DatByteCount & 511) DatStat = DAT_RECEIVING_NIBBLE_H;
        else { j = 17; DatStat = DAT_RECEIVING_CRC; }
        break;

      case DAT_RECEIVING_CRC: // ignoring crc. todo?
        //SDif.Dat :> Dat;
        if(--j) break; // discard 17 nibbles ( 8 bytes CRC + 1 nibble end data )
        if(DatByteCount < DatBytesLen)
        {
          Dat = 0xFFFFFFFF; i = 0;
          DatStat = DAT_WAITING_START_NIBBLE;
        }
        else DatStat = 0;
        break;
    }
  }

  switch(RespType) // response check
  {
    case R0: break;
    case R1:
    case R1B:
    case R6:
    case R7:
      Crc0 = 0;
      crc8shr(Crc0, Resp[0], CRC7_POLY);
      i = bitrev(Resp[0]) >> 24;
      if(i != Cmd)
        return RES_ERROR;
      Arg = (Resp[4] << 24) | (Resp[3] << 16) | (Resp[2] << 8) | Resp[1];
      crc32(Crc0, Arg, CRC7_POLY);
      Arg = bitrev(Arg); // if R1: card status; if R6: RCA; if R7: voltage accepted, echo pattern
      crc32(Crc0, 0, CRC7_POLY); // flush crc engine
      if(Crc0 != (Resp[5] & 0x7F))
        return RES_ERROR; //crc error
      if((Resp[5] & 0x80) == 0)
        return RES_ERROR; //end bit error
      break;
    case R2: // 136 bit response
      if(0xFC != Resp[0])
        return RES_ERROR; // R2 beginning error
      if(0x80 != (Resp[16] & 0x80))
        return RES_ERROR; // R2 end bit error
      break;
    case R3:
      if(0xFC != Resp[0])
        return RES_ERROR; // R3 beginning error
      if(0xFF != Resp[5])
        return RES_ERROR; // R3 end byte error
      break;
  }

  ToggleClock(8, SDif[IfNum].Clk);            // Send 8 clock toggles

/**********************************************************************************
 * Write operation
 **********************************************************************************/
  if(0 > DataBlocks)
  {
    do
    {
      unsigned T = get_time();              // Instrument times taken to write
      set_port_drive(SDif[IfNum].Dat);

      Crc0 = Crc1 = Crc2 = Crc3 = 0;
      /* Information from http://wiki.seabright.co.nz/wiki/SdCardProtocol.html
       * Data is clocked into the host or card on the rising edge of CLK and changes on the falling edge.
       * This is equivalent to the SPI (0, 0) mode.
       */
      SDif[IfNum].Dat <: 0; NOP_PAUSE_WR_SETUP; SDif[IfNum].Clk <: 1; NOP_PAUSE_WR_HOLD; SDif[IfNum].Clk <: 0;  // start data block

#ifdef _STREAM_FS
      if(buff == NULL) {
          // Data is coming from the streaming channel
          for(j = 512/4; j; j--) // send bytes of data (512/4 int)
          {
            c :> Dat;                           // XMOS Streaming version
            Dat = byterev(bitrev(Dat));
            DatByteCount++;
            calc_sdcard_crc(Dat, D0, D1, D2, D3, Crc0, Crc1, Crc2, Crc3);
            send_8_nibbles;
          }
      }
      else {
          // Data is coming from the buff[]
          for(j = 512/4; j; j--) // send bytes of data (512/4 int)
          {
            Dat = byterev(bitrev((buff, int[])[DatByteCount++]));
            calc_sdcard_crc(Dat, D0, D1, D2, D3, Crc0, Crc1, Crc2, Crc3);
            send_8_nibbles;
          }
      }
#else
      // Normal behaviour
      // Data is coming from the buff[]
      for(j = 512/4; j; j--) // send bytes of data (512/4 int)
      {
        Dat = byterev(bitrev((buff, int[])[DatByteCount++]));
        calc_sdcard_crc(Dat, D0, D1, D2, D3, Crc0, Crc1, Crc2, Crc3);
        send_8_nibbles;
      }
  }
#endif

      // write CRCs, end nibble and wait busy
      crc32(Crc0, 0, CRC16_POLY); // flush crc engine
      crc32(Crc1, 0, CRC16_POLY); // flush crc engine
      crc32(Crc2, 0, CRC16_POLY); // flush crc engine
      crc32(Crc3, 0, CRC16_POLY); // flush crc engine
      for(i = 16; i; i--)
      {
        Dat = (Crc3 & 1) | ((Crc2 & 1) << 1) | ((Crc1 & 1) << 2) | ((Crc0 & 1) << 3);
        // Add no-ops to allow setup and hold times
        SDif[IfNum].Dat <: Dat; NOP_PAUSE_WR_SETUP; SDif[IfNum].Clk <: 1;NOP_PAUSE_WR_HOLD; SDif[IfNum].Clk <: 0;
        Crc3 >>= 1; Crc2 >>= 1; Crc1 >>= 1; Crc0 >>= 1;
      }
      SDif[IfNum].Dat <: 0xF; NOP_PAUSE_WR_SETUP; SDif[IfNum].Clk <: 1;NOP_PAUSE_WR_HOLD; SDif[IfNum].Clk <: 0;

      if(Is_XS1_G_Core) // check if an XS1-G can enable internal pull-up
        set_port_pull_up(SDif[IfNum].Dat); // otherwise need an external pull-up resistor D0 (Dat3) pin
      SDif[IfNum].Dat :> void;

      ToggleClock(8, SDif[IfNum].Clk);            // Send 8 clock toggles

      // Wait for Dat bit 3 to go high
      Dat = WaitForTimed(SDif[IfNum].Dat, 0x8, 0x8, SDif[IfNum].Clk);
      if(!(Dat &0x08)) return RES_ERROR;

      unsigned this_t = get_time()-T;            // Instrument times taken to write
      SendCmd_twr_max = max(SendCmd_twr_min, this_t);
      SendCmd_twr_min = min(SendCmd_twr_min, this_t);
    }
    while(++DataBlocks);
  }

  if(R1B == RespType)
  {
    // Wait for Dat bit 3 to go high
    Dat = WaitForTimed(SDif[IfNum].Dat, 0x8, 0x8, SDif[IfNum].Clk);
    if(!(Dat &0x08)) return RES_ERROR;
  }
  return RES_OK;
}


/******* public functions ********/

//todo: make null param conditional

DSTATUS disk_initialize(BYTE IfNum)
{
  unsigned int i, BlockLen;
  RESP Resp;
  unsigned char DummyData[1];

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_PARERR;

  read_sswitch_reg(get_local_tile_id(), 0, i);
  Is_XS1_G_Core = ((i & 0xFFFF) == 0x0200) ? 1 : 0; // get core type

  // configure ports and clock blocks
  SDif[IfNum].Cmd <: 1;
  SDif[IfNum].Dat <: 0xF;
  SDif[IfNum].Clk <: 1 @ i;
  for(BlockLen = 74; BlockLen; BlockLen--)
  { // send 74 clocks
    i += 125;
    SDif[IfNum].Clk @ i <: 0;
    i += 125;
    SDif[IfNum].Clk @ i <: 1;
  }

  // initialize card
  SDif[IfNum].Rca = 0;
  if(SendCmd(IfNum, 0, 0, R0, 0, DummyData, Resp, null)) return RES_ERROR;
  BlockLen = SendCmd(IfNum, 8, 0x1AA, R7, 0, DummyData, Resp, null) ? 0x00FF8000 : 0x50FF8000; // SDHC/XC or SDSC. 2.7V..3.6V
  do
  {
    if(SendCmd(IfNum, 55, 0, R1, 0, DummyData, Resp, null)) return RES_ERROR;

    if(SendCmd(IfNum, 41, BlockLen, R3, 0, DummyData, Resp, null)) return RES_ERROR;  // ACMD41

    if(i++ == 1000) return RES_ERROR; // busy timeout
  }
  while((Resp[1] & 1) == 0); // repeat while busy

  SDif[IfNum].Ccs = ((Resp[1] & 2)) ? 1 : 0;
  if(SendCmd(IfNum, 2, 0, R2, 0, DummyData, Resp, null)) return RES_ERROR; // get CID
  if(SendCmd(IfNum, 3, 0, R6, 0, DummyData, Resp, null)) return RES_ERROR; // get RCA
  SDif[IfNum].Rca = 0xFFFF0000 & bitrev(Resp[1] | (Resp[2] << 8) | (Resp[3] << 16) | (Resp[4] << 24)); // Rca to be used in addressed commands
  if(SendCmd(IfNum, 9, SDif[IfNum].Rca, R2, 0, DummyData, Resp, null)) return RES_ERROR; // get CSD
  if(0 == (Resp[1] & 0x3)) // CSD ver. 1.0
  { // evaluate card size
    BlockLen = bitrev(Resp[6] << 24) & 0x0F; // READ_BL_LEN
    BlockLen = 1 << BlockLen;
    i = ((bitrev(Resp[7]) >> 14) | (bitrev(Resp[8]) >> 22) | (bitrev(Resp[9]) >> 30)) & 0xFFF; // C_SIZE
    SDif[IfNum].BlockNr = ((bitrev(Resp[10]) >> 23) | (bitrev(Resp[11]) >> 31)) & 0x07; // C_SIZE_MULT
    SDif[IfNum].BlockNr = 4 << SDif[IfNum].BlockNr; // MULT
    SDif[IfNum].BlockNr = (i + 1) * SDif[IfNum].BlockNr;
    {SDif[IfNum].BlockNr, BlockLen} = lmul(SDif[IfNum].BlockNr, BlockLen, 0, 0); // evaluate card size bytes
    SDif[IfNum].BlockNr = (SDif[IfNum].BlockNr << 23) | (BlockLen >> 9); // n. of 512 bytes blocks
  }
  else // CSD ver. 2.0: // evaluate card size
  {
    SDif[IfNum].BlockNr = (bitrev(Resp[10]) >> 24) | (bitrev(Resp[9]) >> 16) | (bitrev(Resp[8]) >> 8); // C_SIZE
    SDif[IfNum].BlockNr = (SDif[IfNum].BlockNr + 1)*1024;  // n. of 512 bytes blocks
  }
  if(SendCmd(IfNum, 7, SDif[IfNum].Rca, R1B, 0, DummyData, Resp, null)) return RES_ERROR; // select card
  if(SendCmd(IfNum, 55, SDif[IfNum].Rca, R1, 0, DummyData, Resp, null)) return RES_ERROR; // ACMD6
  if(SendCmd(IfNum, 6, 0b10, R1, 0, DummyData, Resp, null)) return RES_ERROR; // set bus 4 bit

  // leaving card in transfer state
  return RES_OK;
}

//todo: streaming version of this
#pragma unsafe arrays
DRESULT disk_read(BYTE IfNum, BYTE buff[], DWORD sector, UINT count)
{
  RESP Resp;
  unsigned char DummyData[1];

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_PARERR;
  if(1 < count)
  { // multiblock read
    //if(SendCmd(SDif, 23, NumBlocks, R1, 0, DummyData, Resp, null)) return RES_ERROR; // set foreseen multiple block read. Remarked because only optionally supported by cards
    if(SendCmd(IfNum, 18, SDif[IfNum].Ccs ? sector : 512 * sector, R1, count, buff, Resp, null)) return RES_ERROR; // multiblock read
    if(SendCmd(IfNum, 12, 0, R1, 0, DummyData, Resp, null)) return RES_ERROR; // stop multi-block read. (using stop command instead of cmd23)
  }
  else
    if(SendCmd(IfNum, 17, SDif[IfNum].Ccs ? sector : 512 * sector, R1, 1, buff, Resp, null)) return RES_ERROR; // single block read
  return RES_OK;
}

#pragma unsafe arrays
DRESULT disk_write(BYTE IfNum, const BYTE buff[], DWORD sector, UINT count)
{
  RESP Resp;
  unsigned char DummyData[1];

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_PARERR;
  if(1 < count)
  { // multiblock write
    //if(SendCmd(SDif, 23, NumBlocks, R1, 0, DummyData, Resp)) return 0; // set foreseen multiple block read. Remarked because only optionally supported by cards
    if(SendCmd(IfNum, 25, SDif[IfNum].Ccs ? sector : 512 * sector, R1, -count, (buff, BYTE[]), Resp, null)) return RES_ERROR; // multiblock write
    if(SendCmd(IfNum, 12, 0, R1B, 0, DummyData, Resp, null)) return RES_ERROR; // stop multi-block write. (using stop command instead of cmd23)
  }
  else
    if(SendCmd(IfNum, 24, SDif[IfNum].Ccs ? sector : 512 * sector, R1, -1, (buff, BYTE[]), Resp, null)) return RES_ERROR; // single block write
  return RES_OK;
}

#ifdef     _STREAM_FS

/*-----------------------------------------------------------------------*/
/* Write File - from an XMOS Streaming Channel                           */
/*-----------------------------------------------------------------------*/
DRESULT disk_write_streamed(BYTE IfNum, streaming chanend c, DWORD sector, UINT count)
{
  RESP Resp;
  unsigned char DummyData[1];

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_PARERR;
  if(1 < count)
  { // multiblock write
    //if(SendCmd(SDif, 23, NumBlocks, R1, 0, DummyData, Resp)) return 0; // set foreseen multiple block read. Remarked because only optionally supported by cards
    if(SendCmd(IfNum, 25, SDif[IfNum].Ccs ? sector : 512 * sector, R1, -count, (BYTE *)NULL, Resp, c)) return RES_ERROR; // multiblock write
    if(SendCmd(IfNum, 12, 0, R1B, 0, DummyData, Resp, c)) return RES_ERROR; // stop multi-block write. (using stop command instead of cmd23)
  }
  else
    if(SendCmd(IfNum, 24, SDif[IfNum].Ccs ? sector : 512 * sector, R1, -1, (BYTE *)NULL, Resp, c)) return RES_ERROR; // single block write
  return RES_OK;
}
#endif
/**********************************************************************************/

DSTATUS disk_status(BYTE IfNum)
{
  unsigned char DummyData[1];
  RESP Resp;

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return STA_NOINIT;
  if(!SDif[IfNum].Rca) return STA_NOINIT;
  if(SendCmd(IfNum, 13, SDif[IfNum].Rca, R1, 0, DummyData, Resp, null)) return STA_NOINIT; /* Read card status */
  return 0;
}

#pragma unsafe arrays
DRESULT disk_ioctl (BYTE IfNum, BYTE ctrl, BYTE RetVal[])
{
  unsigned long i;

  if(IfNum >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_PARERR;
  if (disk_status(IfNum) & STA_NOINIT) return RES_NOTRDY;   /* Check if card is in the socket */
  switch (ctrl)
  {
    case CTRL_SYNC:                /* Make sure that no pending write process */
      return RES_OK;
    case GET_SECTOR_COUNT: /* Get number of sectors on the disk (DWORD) */
      for(i = 0; i < sizeof(DWORD); i++)
        RetVal[i] = (SDif[IfNum].BlockNr, BYTE[])[i];
      return RES_OK;
    case GET_BLOCK_SIZE:   /* Get erase block size in unit of sector (DWORD) */
      for(DWORD Val = 128, i = 0; i < sizeof(DWORD); i++)
        RetVal[i] = (Val, BYTE[])[i];
      return RES_OK;
  }
  return RES_PARERR;
}

#endif //BUS_MODE_4BIT

#ifndef _FS_NORTC
// User Provided Timer Function for FatFs module
DWORD get_fattime(void)
{
  return ((DWORD)(2010 - 1980) << 25)  /* Fixed to Jan. 1, 2010 */
          | ((DWORD)1 << 21)
          | ((DWORD)1 << 16)
          | ((DWORD)0 << 11)
          | ((DWORD)0 << 5)
          | ((DWORD)0 >> 1);
}
#endif
