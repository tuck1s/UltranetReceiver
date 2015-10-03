// MMCv3/SDv1/SDv2 (in SPI mode) control module
// Features and Limitations:
// * No Media Change Detection - Application program must re-mount the volume after media change or it results a hard error.

#include "diskio.h"    /* Common include file for FatFs and disk I/O layer */
#ifndef BUS_MODE_4BIT
#include <stdio.h> /* for the printf function */
#include <xs1.h>
#include <xclib.h>

// Structure for the ports to access the SD Card
typedef struct SDHostInterface
{
  clock ClkBlk1, ClkBlk2;
  out port cs; // a 1 bit port
  out buffered port:32 sclk; // a 1 bit port
  out buffered port:32 mosi; // a 1 bit port
  in buffered port:32 miso; // a 1 bit port. Need an external pull-up resistor if not an XS1_G core
/*
     C M     S   M
     s o     c   i
       s     l   s
       i     k   o
   __________________
  /  | | | | | | | | |
  || C D - + C - D   |
  |  S I G 3 L G O   |
  |      N . K N     |
  |      D 3   D     |
  |        V         |
*/
  /* fields returned after initialization */
  BYTE CardType; /* b0:MMC, b1:SDv1, b2:SDv2, b3:Block addressing */
  DSTATUS Stat; /* Disk status */
} SDHostInterface;

static SDHostInterface SDif[] = // LIST HERE THE PORTS USED FOR THE INTERFACES
//                                    cs,        sclk,        Mosi,         miso
{XS1_CLKBLK_1, XS1_CLKBLK_2, XS1_PORT_1O, XS1_PORT_1M, XS1_PORT_1N, XS1_PORT_1P, 0, 0}; // resources used for interface #0
//{XS1_CLKBLK_1, XS1_CLKBLK_2, XS1_PORT_1A, XS1_PORT_1B, XS1_PORT_1C, XS1_PORT_1D, 0, 0}; // resources used for interface #1

/*-------------------------------------------------------------------------*/
/* Platform dependent macros and functions needed to be modified           */
/*-------------------------------------------------------------------------*/

void init_port(BYTE drv)
{
  unsigned int i;

  // configure ports and clock blocks
  configure_clock_ref(SDif[drv].ClkBlk1, 64);  // about 800KHz vector rate
  configure_out_port(SDif[drv].sclk, SDif[drv].ClkBlk1, 1);
  configure_clock_src(SDif[drv].ClkBlk2, SDif[drv].sclk);
  configure_out_port(SDif[drv].mosi, SDif[drv].ClkBlk2, 1);
  configure_in_port(SDif[drv].miso, SDif[drv].ClkBlk2);
  read_sswitch_reg(get_core_id(), 0, i); // get core type
  if((i & 0xFFFF) == 0x0200)
    set_port_pull_up(SDif[drv].miso); // if an XS1_G core can enable internal pull-up
  SDif[drv].cs <: 1;
  start_clock(SDif[drv].ClkBlk1);
  start_clock(SDif[drv].ClkBlk2);
  SDif[drv].Stat = STA_NOINIT;
}

void dly_us(int n)
{
  timer tmr;
  unsigned t;

  tmr :> t;
  t += 100*n;
  tmr when timerafter(t) :> void;
}

#define INIT_PORT(drv) { init_port(drv); }  /* Initialize control port (CS=H, CLK=L, DI=H, DO=pu) */
#define DLY_US(n) { dly_us(n); }    /* Delay n microseconds */

#define CS_H(drv) { sync(SDif[drv].sclk); SDif[drv].cs <: 1; } /* Set MMC CS 'H' */
#define CS_L(drv) { sync(SDif[drv].sclk); SDif[drv].cs <: 0; }  /* Set MMC CS 'L' */

/*--------------------------------------------------------------------------

   Module Private Functions

---------------------------------------------------------------------------*/

/* MMC/SD command (SPI mode) */
#define CMD0   (0)     /* GO_IDLE_STATE */
#define CMD1   (1)     /* SEND_OP_COND */
#define ACMD41 (0x80+41) /* SEND_OP_COND (SDC) */
#define CMD8   (8)     /* SEND_IF_COND */
#define CMD9   (9)     /* SEND_CSD */
#define CMD10  (10)    /* SEND_CID */
#define CMD12  (12)    /* STOP_TRANSMISSION */
#define CMD13  (13)    /* SEND_STATUS */
#define ACMD13 (0x80+13) /* SD_STATUS (SDC) */
#define CMD16  (16)    /* SET_BLOCKLEN */
#define CMD17  (17)    /* READ_SINGLE_BLOCK */
#define CMD18  (18)    /* READ_MULTIPLE_BLOCK */
#define CMD23  (23)    /* SET_BLOCK_COUNT */
#define ACMD23 (0x80+23)  /* SET_WR_BLK_ERASE_COUNT (SDC) */
#define CMD24  (24)    /* WRITE_BLOCK */
#define CMD25  (25)    /* WRITE_MULTIPLE_BLOCK */
#define CMD41  (41)    /* SEND_OP_COND (ACMD) */
#define CMD55  (55)    /* APP_CMD */
#define CMD58  (58)    /* READ_OCR */

/* Card type flags (CardType) */
#define CT_MMC    0x01    /* MMC ver 3 */
#define CT_SD1    0x02    /* SD ver 1 */
#define CT_SD2    0x04    /* SD ver 2 */
#define CT_SDC    (CT_SD1|CT_SD2)  /* SD */
#define CT_BLOCK  0x08    /* Block addressing */

#define CLK_PATTERN 0xAAAAAAAA

/*-----------------------------------------------------------------------*/
/* Transmit bytes to the card (bitbanging)                               */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
static
void xmit_mmc (BYTE drv,
  const BYTE buff[],  /* Data to be sent */
  UINT bc        /* Number of bytes to send */
)
{
  sync(SDif[drv].sclk);
  for(int i = 0; i < bc; i++)
  {
    partout(SDif[drv].mosi, 8, bitrev(buff[i]) >> 24);
    partout(SDif[drv].sclk, 16, CLK_PATTERN); // load 8 clock
  }
  sync(SDif[drv].sclk);
}

/*-----------------------------------------------------------------------*/
/* Receive bytes from the card (bitbanging)                              */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
static
void rcvr_mmc (BYTE drv,
  BYTE buff[],  /* Pointer to read buffer */
  UINT bc    /* Number of bytes to receive */
)
{
  BYTE d;

  partout(SDif[drv].mosi, 8, 0xFF);  // mosi high
  clearbuf(SDif[drv].miso);
  for(int i = 0; i < bc; i++)
  {
    partout(SDif[drv].sclk, 16, CLK_PATTERN); // load 8 clock
    d = partin(SDif[drv].miso, 8);
    buff[i] = bitrev(d) >> 24;
  }
}

/*-----------------------------------------------------------------------*/
/* Wait for card ready                                                   */
/*-----------------------------------------------------------------------*/

static
int wait_ready (BYTE drv)  /* 1:OK, 0:Timeout */
{
  BYTE d[1];
  UINT tmr;

  for (tmr = 5000; tmr; tmr--)
  {  /* Wait for ready in timeout of 500ms */
    rcvr_mmc(drv, d, 1);
    if (d[0] == 0xFF) break;
    DLY_US(100);
  }
  return tmr ? 1 : 0;
}

/*-----------------------------------------------------------------------*/
/* Deselect the card and release SPI bus                                 */
/*-----------------------------------------------------------------------*/

static
void deselect (BYTE drv)
{
  BYTE d[1];

  CS_H(drv);
  rcvr_mmc(drv, d, 1);  /* Dummy clock (force DO hi-z for multiple slave SPI) */
}

/*-----------------------------------------------------------------------*/
/* Select the card and wait for ready                                    */
/*-----------------------------------------------------------------------*/

static
int Select (BYTE drv)  /* 1:OK, 0:Timeout */
{
  BYTE d[1];

  CS_L(drv);
  rcvr_mmc(drv, d, 1);  /* Dummy clock (force DO enabled) */

  if (wait_ready(drv)) return 1;  /* OK */
  deselect(drv);
  return 0;      /* Failed */
}

/*-----------------------------------------------------------------------*/
/* Receive a data packet from the card                                   */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
static
int rcvr_datablock (BYTE drv,  /* 1:OK, 0:Failed */
  BYTE buff[],      /* Data buffer to store received data */
  UINT btr      /* Byte count */
)
{
  BYTE d[2];
  UINT tmr;

  for (tmr = 1000; tmr; tmr--)
  {  /* Wait for data packet in timeout of 100ms */
    rcvr_mmc(drv, d, 1);
    if (d[0] != 0xFF) break;
    DLY_US(100);
  }
  if (d[0] != 0xFE) return 0;    /* If not valid data token, return with error */

  rcvr_mmc(drv, buff, btr);      /* Receive the data block into buffer */
  rcvr_mmc(drv, d, 2);          /* Discard CRC */

  return 1;            /* Return with success */
}

/*-----------------------------------------------------------------------*/
/* Send a data packet to the card                                        */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
static
int xmit_datablock (BYTE drv,  /* 1:OK, 0:Failed */
  const BYTE ?buff[],  /* 512 byte data block to be transmitted */
  BYTE token      /* Data/Stop token */
)
{
  BYTE d[2];

  if (!wait_ready(drv)) return 0;

  d[0] = token;
  xmit_mmc(drv, d, 1);        /* Xmit a token */
  if (token != 0xFD)
  {    /* Is it data token? */
    xmit_mmc(drv, buff, 512);  /* Xmit the 512 byte data block to MMC */
    rcvr_mmc(drv, d, 2);      /* Xmit dummy CRC (0xFF,0xFF) */
    rcvr_mmc(drv, d, 1);      /* Receive data response */
    if ((d[0] & 0x1F) != 0x05)  /* If not accepted, return with error */
      return 0;
  }
  return 1;
}

/*-----------------------------------------------------------------------*/
/* Send a command packet to the card                                     */
/*-----------------------------------------------------------------------*/

static
BYTE send_cmd (BYTE drv,    /* Returns command response (bit7==1:Send failed)*/
  BYTE cmd,    /* Command byte */
  DWORD arg    /* Argument */
)
{
  BYTE n, d[1], buf[6];

  if (cmd & 0x80)
  {  /* ACMD<n> is the command sequense of CMD55-CMD<n> */
    cmd &= 0x7F;
    n = send_cmd(drv, CMD55, 0);
    if (n > 1) return n;
  }

  /* Select the card and wait for ready */
  deselect(drv);
  if (!Select(drv)) return 0xFF;

  /* Send a command packet */
  buf[0] = 0x40 | cmd;      /* Start + Command index */
  buf[1] = arg >> 24;    /* Argument[31..24] */
  buf[2] = arg >> 16;    /* Argument[23..16] */
  buf[3] = arg >> 8;    /* Argument[15..8] */
  buf[4] = arg;        /* Argument[7..0] */
  n = 0x01;            /* Dummy CRC + Stop */
  if (cmd == CMD0) n = 0x95;    /* (valid CRC for CMD0(0)) */
  if (cmd == CMD8) n = 0x87;    /* (valid CRC for CMD8(0x1AA)) */
  buf[5] = n;
  xmit_mmc(drv, buf, 6);

  /* Receive command response */
  if (cmd == CMD12) rcvr_mmc(drv, d, 1);  /* Skip a stuff byte when stop reading */
  n = 10;                /* Wait for a valid response in timeout of 10 attempts */
  do
    rcvr_mmc(drv, d, 1);
  while ((d[0] & 0x80) && --n);
  return d[0];      /* Return with the response value */
}

/*--------------------------------------------------------------------------

   Public Functions

---------------------------------------------------------------------------*/


/*-----------------------------------------------------------------------*/
/* Get Disk Status                                                       */
/*-----------------------------------------------------------------------*/

DSTATUS disk_status (
  BYTE drv      /* Drive number (always 0) */
)
{
  DSTATUS s;
  BYTE d[1];

  if(drv >= sizeof(SDif)/sizeof(SDHostInterface)) return STA_NOINIT;

  /* Check if the card is kept initialized */
  s = SDif[drv].Stat;
  if (!(s & STA_NOINIT))
  {
    if (send_cmd(drv, CMD13, 0))  /* Read card status */
      s = STA_NOINIT;
    rcvr_mmc(drv, d, 1);    /* Receive following half of R2 */
    deselect(drv);
  }
  SDif[drv].Stat = s;

  return s;
}

/*-----------------------------------------------------------------------*/
/* Initialize Disk Drive                                                 */
/*-----------------------------------------------------------------------*/

DSTATUS disk_initialize (
  BYTE drv    /* Physical drive nmuber (0) */
)
{
  BYTE n, ty, cmd, buf[4];
  UINT tmr;
  DSTATUS s;

  if(drv >= sizeof(SDif)/sizeof(SDHostInterface)) return RES_NOTRDY;

  INIT_PORT(drv);        /* Initialize control port */
  for (n = 10; n; n--) rcvr_mmc(drv, buf, 1);  /* 80 dummy clocks */

  ty = 0;
  if (send_cmd(drv, CMD0, 0) == 1) {      /* Enter Idle state */
    if (send_cmd(drv, CMD8, 0x1AA) == 1) {  /* SDv2? */
      rcvr_mmc(drv, buf, 4);              /* Get trailing return value of R7 resp */
      if (buf[2] == 0x01 && buf[3] == 0xAA) {    /* The card can work at vdd range of 2.7-3.6V */
        for (tmr = 1000; tmr; tmr--) {      /* Wait for leaving idle state (ACMD41 with HCS bit) */
          if (send_cmd(drv, ACMD41, 1UL << 30) == 0) break;
          DLY_US(1000);
        }
        if (tmr && send_cmd(drv, CMD58, 0) == 0) {  /* Check CCS bit in the OCR */
          rcvr_mmc(drv, buf, 4);
          ty = (buf[0] & 0x40) ? CT_SD2 | CT_BLOCK : CT_SD2;  /* SDv2 */
        }
      }
    } else {              /* SDv1 or MMCv3 */
      if (send_cmd(drv, ACMD41, 0) <= 1)   {
        ty = CT_SD1; cmd = ACMD41;  /* SDv1 */
      } else {
        ty = CT_MMC; cmd = CMD1;  /* MMCv3 */
      }
      for (tmr = 1000; tmr; tmr--) {      /* Wait for leaving idle state */
        if (send_cmd(drv, ACMD41, 0) == 0) break;
        DLY_US(1000);
      }
      if (!tmr || send_cmd(drv, CMD16, 512) != 0)  /* Set R/W block length to 512 */
        ty = 0;
    }
  }
  SDif[drv].CardType = ty;
  s = ty ? 0 : STA_NOINIT;
  SDif[drv].Stat = s;

  deselect(drv);

  stop_clock(SDif[drv].ClkBlk1);
  set_clock_div(SDif[drv].ClkBlk1, 1);
  start_clock(SDif[drv].ClkBlk1);
  return s;
}


typedef unsigned char DATABLOCK[512];

/*-----------------------------------------------------------------------*/
/* Read Sector(s)                                                        */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
DRESULT disk_read (
  BYTE drv,      /* Physical drive nmuber (0) */
  BYTE buff[],      /* Pointer to the data buffer to store read data */
  DWORD sector,    /* Start sector number (LBA) */
  BYTE count      /* Sector count (1..128) */
)
{
  BYTE BlockCount = 0;

  if (disk_status(drv) & STA_NOINIT) return RES_NOTRDY;
  if (!count) return RES_PARERR;
  if (!(SDif[drv].CardType & CT_BLOCK)) sector *= 512;  /* Convert LBA to byte address if needed */

  if (count == 1) {  /* Single block read */
    if ((send_cmd(drv, CMD17, sector) == 0)  /* READ_SINGLE_BLOCK */
      && rcvr_datablock(drv, buff, 512))
      count = 0;
  }
  else {        /* Multiple block read */
    if (send_cmd(drv, CMD18, sector) == 0) {  /* READ_MULTIPLE_BLOCK */
      do {
        if (!rcvr_datablock(drv, (buff, DATABLOCK[])[BlockCount++], 512)) break;
      } while (--count);
      send_cmd(drv, CMD12, 0);        /* STOP_TRANSMISSION */
    }
  }
  deselect(drv);

  return count ? RES_ERROR : RES_OK;
}



/*-----------------------------------------------------------------------*/
/* Write Sector(s)                                                       */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
DRESULT disk_write (
  BYTE drv,      /* Physical drive nmuber (0) */
  const BYTE buff[],  /* Pointer to the data to be written */
  DWORD sector,    /* Start sector number (LBA) */
  BYTE count      /* Sector count (1..128) */
)
{
  BYTE BlockCount = 0;

  if (disk_status(drv) & STA_NOINIT) return RES_NOTRDY;
  if (!count) return RES_PARERR;
  if (!(SDif[drv].CardType & CT_BLOCK)) sector *= 512;  /* Convert LBA to byte address if needed */

  if (count == 1) {  /* Single block write */
    if ((send_cmd(drv, CMD24, sector) == 0)  /* WRITE_BLOCK */
      && xmit_datablock(drv, buff, 0xFE))
      count = 0;
  }
  else {        /* Multiple block write */
    if (SDif[drv].CardType & CT_SDC) send_cmd(drv, ACMD23, count);
    if (send_cmd(drv, CMD25, sector) == 0) {  /* WRITE_MULTIPLE_BLOCK */
      do {
        if (!xmit_datablock(drv, (buff, DATABLOCK[])[BlockCount++], 0xFC)) break;
      } while (--count);
      if (!xmit_datablock(drv, null, 0xFD))  /* STOP_TRAN token */
        count = 1;
    }
  }
  deselect(drv);

  return count ? RES_ERROR : RES_OK;
}



/*-----------------------------------------------------------------------*/
/* Miscellaneous Functions                                               */
/*-----------------------------------------------------------------------*/
#pragma unsafe arrays
DRESULT disk_ioctl (
  BYTE drv,    /* Physical drive nmuber (0) */
  BYTE ctrl,    /* Control code */
  BYTE buff[]    /* Buffer to send/receive control data */
)
{
  DRESULT res;
  BYTE n, i, csd[16];
  WORD cs;


  if (disk_status(drv) & STA_NOINIT) return RES_NOTRDY;  /* Check if card is in the socket */

  res = RES_ERROR;
  switch (ctrl) {
    case CTRL_SYNC:    /* Make sure that no pending write process */
      if (Select(drv)) {
        deselect(drv);
        res = RES_OK;
      }
      break;

    case GET_SECTOR_COUNT :  /* Get number of sectors on the disk (DWORD) */
      if ((send_cmd(drv, CMD9, 0) == 0) && rcvr_datablock(drv, csd, 16)) {
        if ((csd[0] >> 6) == 1) {  /* SDC ver 2.00 */
          cs= csd[9] + ((WORD)csd[8] << 8) + 1;
          //*(DWORD*)buff = (DWORD)cs << 10;
          for(DWORD Val = cs << 10, i = 0; i < sizeof(DWORD); i++)
            buff[i] = (Val, BYTE[])[i];
        } else {          /* SDC ver 1.XX or MMC */
          n = (csd[5] & 15) + ((csd[10] & 128) >> 7) + ((csd[9] & 3) << 1) + 2;
          cs = (csd[8] >> 6) + ((WORD)csd[7] << 2) + ((WORD)(csd[6] & 3) << 10) + 1;
          //*(DWORD*)buff = (DWORD)cs << (n - 9);
          for(DWORD Val = (DWORD)cs << (n - 9), i = 0; i < sizeof(DWORD); i++)
            buff[i] = (Val, BYTE[])[i];
        }
        res = RES_OK;
      }
      break;

    case GET_BLOCK_SIZE :  /* Get erase block size in unit of sector (DWORD) */
      //*(DWORD*)buff = 128;
      for(DWORD Val = 128, i = 0; i < sizeof(DWORD); i++)
        buff[i] = (Val, BYTE[])[i];
      res = RES_OK;
      break;

    default:
      res = RES_PARERR;
      break;
  }

  deselect(drv);

  return res;
}

#endif //BUS_MODE_4BIT
