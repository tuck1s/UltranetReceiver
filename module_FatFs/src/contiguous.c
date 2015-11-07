/*----------------------------------------------------------------------/
/ Allocate a contiguous area to the file
/-----------------------------------------------------------------------/
/ This function checks if the file is contiguous with desired size.
/ If not, a block of contiguous sectors is allocated to the file.
/ If the file has been opened without FA_WRITE flag, it only checks if
/ the file is contiguous and returns the resulut. */


#include "ff.h"
#include "diskio.h"         /* Declarations of low level disk I/O functions */
#include "integer.h"
#include <stdio.h>

#if _FATFS != 64180         /* Check if R0.11 */
#error This function may not be compatible with this revision of FatFs module.
#endif

/* Declarations of FatFs internal functions accessible from applications.
/  This is intended to be used for disk checking/fixing or dirty hacks :-) */
DWORD clust2sect (FATFS* fs, DWORD clst);
DWORD get_fat (FATFS* fs, DWORD clst);
FRESULT put_fat (FATFS* fs, DWORD clst, DWORD val);

DWORD allocate_contiguous_clusters (    /* Returns the first sector in LBA (0:error or not contiguous) */
    FIL* fp,    /* Pointer to the open file object */
    DWORD len   /* Number of bytes to allocate */
)
{
    DWORD csz, tcl, ncl, ccl, cl;


    if (f_lseek(fp, 0) || !len)     /* Check if the given parameters are valid */
        return 0;
    csz = 512UL * fp->fs->csize;    /* Cluster size in unit of byte (assuming 512 bytes/sector) */
    tcl = (len + csz - 1) / csz;    /* Total number of clusters required */
    len = tcl * csz;                /* Round-up file size to the cluster boundary */

    /* Check if the existing cluster chain is contiguous */
    if (len == fp->fsize) {
        ncl = 0; ccl = fp->sclust;
        do {
            printf("Checking existing cluster: %ld\n", cl);
            cl = get_fat(fp->fs, ccl);  /* Get the cluster status */
            if (cl + 1 < 3) return 0;   /* Hard error? */
            if (cl != ccl + 1 && cl < fp->fs->n_fatent) break;  /* Not contiguous? */
            ccl = cl;
        } while (++ncl < tcl);
        if (ncl == tcl)             /* Is the file contiguous? */
            return clust2sect(fp->fs, fp->sclust);  /* File is contiguous. Return the start sector */
    }
    /* File is not contiguous */
#if _FS_READONLY
    return 0;
#else
    if (!(fp->flag & FA_WRITE)) return 0;   /* Exit if the file object is for read-only */
    if (f_truncate(fp)) return 0;           /* Remove the existing chain */

    /* Find a free contiguous area */
    ccl = cl = 2; ncl = 0;
    do {
        if (cl >= fp->fs->n_fatent) return 0;   /* No contiguous area is found. */
        if (get_fat(fp->fs, cl)) {  /* Encounterd a cluster in use */
            do {    /* Skip the block of used clusters */
                cl++;
                if (cl >= fp->fs->n_fatent) return 0;   /* No contiguous area is found. */
            } while (get_fat(fp->fs, cl));
            ccl = cl; ncl = 0;
        }
        cl++; ncl++;
    } while (ncl < tcl);

    /* Create a contiguous cluster chain */
    fp->fs->last_clust = ccl - 1;
    if (f_lseek(fp, len)) return 0;
    printf("New contiguous cluster range from : %ld to %ld\n Sector numbers: %ld to %ld\n",
            fp->sclust, fp->fs->last_clust,
            clust2sect(fp->fs, fp->sclust), clust2sect(fp->fs, fp->fs->last_clust) );

    return clust2sect(fp->fs, fp->sclust);  /* Return file start sector */
#endif
}
