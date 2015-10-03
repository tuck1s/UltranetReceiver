// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

/*
 ============================================================================
 Name        : sdcard_test
 Description : SD card host driver test
 ============================================================================
 */

#include <stdio.h> /* for the printf function */
#include "ff.h"    /* file system routines */
#include "timing.h"
#include "diskio.h"     /* To get the bus mode definition for debugging */
#include "string.h"     /* To get memset function */


FATFS Fatfs;            /* File system object */
FIL Fil;                /* File object */
BYTE Buff[512*32];      /* File read buffer (Make Smaller temporary/ at least 32 SD card blocks to let multiblock operations (if file not fragmented) */
#define max(a,b) ((a)>(b))?(a):(b)
#define min(a,b) ((a)<(b))?(a):(b)

const unsigned nRuns = 512;               // Run each block test consecutively n times.  Note size limits differ in Debug mode
const unsigned detailedPrintWrite = 0;    // Control whether detailed results are printed or just summary
const unsigned detailedPrintRead = 0;

void die(FRESULT rc ) /* Stop with dying message */
{
  printf("\nFailed with rc=%u.\n", rc);
  for(;;);
}

// Readback testing functions
unsigned walk_the_crc(void);
void init_the_crc(void);
// Implemented in xs1.h
void crc32(unsigned *checksum, unsigned data, unsigned poly);
// Generate predictable pseudo-random traffic (that we can compare against for proof of testing)
#define CRC32_ETH_REV_POLY 0xEDB88320       // x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x^1 + x^0
                                            // See https://github.com/xcore/doc_tips_and_tricks/blob/master/doc/crc.rst


void disk_write_read_task(streaming chanend c)
{
  FRESULT rc;                     /* Result code */
  DIR dir;                        /* Directory object */
  FILINFO fno;                    /* File information object */

  // Stats collection
  UINT read_time[nRuns], write_time[nRuns];
  UINT bw[nRuns], br[nRuns], i, T, k;

#ifdef BUS_MODE_4BIT
  printf("Starting with BUS_MODE_4BIT\n");
#else
  printf("Starting with SPI 1 bit mode\n");
#endif

  //for( i = 0; i < sizeof(Buff); i++) Buff[i] = i + i / 512; // fill the buffer with some data

  f_mount(0, &Fatfs);             /* Register volume work area (never fails) for SD host interface #0 */
  {
    FATFS *fs;
    DWORD fre_clust, fre_sect, tot_sect;

    /* Get volume information and free clusters of drive 0 */
    printf("Getting free cluster info ...\n");
    rc = f_getfree("0:", &fre_clust, &fs);
    if(rc) die(rc);

    /* Get total sectors and free sectors */
    tot_sect = (fs->n_fatent - 2) * fs->csize;
    fre_sect = fre_clust * fs->csize;

    /* Print free space in unit of KB (assuming 512 bytes/sector) */
    printf("%lu KB total drive space.\n"
           "%lu KB available.\n",
           fre_sect / 2, tot_sect / 2);
  }

  /****************************/

  printf("\nDeleting file Data.bin if existing...");
  rc = f_unlink ("Data.bin");    /* delete file if exist */
  if( FR_OK == rc) printf("deleted.\n");
  else printf("done.\n");

  /****************************/

  printf("\nCreating a new file Data.bin...");
  rc = f_open(&Fil, "Data.bin", FA_WRITE | FA_CREATE_ALWAYS);
  if(rc) die(rc);
  printf("done.\n");

  // Just give maxes and mins as quicker printing
  unsigned bw_max = 0;
  unsigned bw_min = 9999999;
  unsigned bw_sum = 0;

  unsigned br_max = 0;
  unsigned br_min = 9999999;
  unsigned br_sum = 0;

  unsigned this_b;
  const unsigned nIters = 511;          // Can't quite get to 4G size

  printf("\nWriting data to the file... %d times over .. expected file size %u bytes (0 means 4G!)\n", nIters, nIters*nRuns*sizeof(Buff));
  for(k=1; k<=nIters; k++) {
      for(i=0; i<nRuns; i++) {
        T = get_time();
        rc = f_write_streamed(&Fil, c, sizeof(Buff), &bw[i]);     // Streamed I/O, not buffered
        write_time[i] = get_time() - T;
        if(rc) die(rc);
      }
      // Print separately from the actual timing loop, to avoid printf slowing down and affecting results
      bw_sum = 0;
      for(i=0; i<nRuns; i++) {
          this_b = (bw[i]*100000)/write_time[i];
          // Collect stats
          bw_min = min(bw_min, this_b);
          bw_max = max(bw_max, this_b);
          bw_sum += this_b;

          // Check size of each transaction
          if(bw[i]!=sizeof(Buff)){
              printf("Run %d: error - %8u bytes written\n", i, bw[i]);
              die(0);
          }
      }
      printf("Iter %04d: %d blocks of size %d bytes: Write rate min: %u, max: %u, avg: %u Kbytes/sec\n", k, i, sizeof(Buff), bw_min, bw_max, bw_sum/i);

      // Dump out detailed results
      if(detailedPrintWrite) {
        for(i=0; i<nRuns; i++) {
          printf("Run %4d: %u bytes written. Write rate: %u KBytes/Sec\n", i, bw[i], (bw[i]*100000)/write_time[i]);
        }
      }
  }

  printf("\nClosing the file...");
  rc = f_close(&Fil);
  if(rc) die(rc);
  printf("done.\n");

  /****************************/

  printf("\nOpening an existing file: Data.bin...");
  rc = f_open(&Fil, "Data.bin", FA_READ);
  if(rc) die(rc);
  printf("done.\n");

  int j;
  printf("\nReading file content...");
  init_the_crc();                           // Checking code

  for(k=1; k<=nIters; k++) {
      for(i=0; i<nRuns; i++) {
        memset(Buff, 0, sizeof(Buff));
        T = get_time();
        rc = f_read(&Fil, Buff, sizeof(Buff), &br[i]);
        read_time[i] = get_time() - T;
        if(rc) die(rc);

        // Check the read back contents of the buffer
        unsigned *lBuff;
        lBuff = (unsigned *)&Buff;               // Cast the pointer so we read & check unsigned 32-bit values
        for(j=0; j<sizeof(Buff)/sizeof(signed); j++) {
            //if(j%8 ==0) printf("\n%08x: ", j);
            //printf("%08x ", l[j]);

            if(lBuff[j] != walk_the_crc() ) {
                printf("\nError on run %d, file offset %08x = %08x\n", i, j*4, lBuff[j]);
                die(0);
            }
        }
      }
      printf("done.\n");

      // Print separately from the actual timing loop, to avoid printf slowing down and affecting results
       br_sum = 0;
       for(i=0; i<nRuns; i++) {
           this_b = (br[i]*100000)/read_time[i];
           // Collect stats
           br_min = min(br_min, this_b);
           br_max = max(br_max, this_b);
           br_sum += this_b;

           // Check size of each transaction
           if(br[i]!=sizeof(Buff)){
               printf("Run %d: error - %8u bytes read\n", i, br[i]);
               die(0);
           }
       }
       printf("Iter %04d: File has %d blocks of size %d bytes: Read rate min: %u, max: %u, avg: %u Kbytes/sec\n", k, i, sizeof(Buff), br_min, br_max, br_sum/i);

       // Dump out detailed results (read)
       if(detailedPrintRead) {
        for(i=0; i<nRuns; i++) {
           printf("Run %4d: %u bytes read. Read rate: %u KBytes/Sec\n", i, br[i], (br[i]*100000)/read_time[i]);
        }
       }
  }

  printf("\nClosing the file...");
  rc = f_close(&Fil);
  if(rc) die(rc);
  printf("done.\n");

  /****************************/

  printf("\nOpen root directory.\n");
  rc = f_opendir(&dir, "");
  if(rc) die(rc);

  printf("\nDirectory listing...\n");
  for(;;)
  {
    rc = f_readdir(&dir, &fno);    /* Read a directory item */
    if(rc || !fno.fname[0]) break; /* Error or end of dir */
    if(fno.fattrib & AM_DIR)
      printf("   <dir>  %s\n", fno.fname);
    else
    {
      printf("%8lu  %s\n", fno.fsize, fno.fname);
    }
  }
  if(rc) die(rc);

  /****************************/

  printf("\nTest completed.\n");
}




