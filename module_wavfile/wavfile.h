/*
 * wavfile.h
 *
 *  Created on: 21 Oct 2015
 *      Author: steve
 */

#ifndef _WAVFILE_H_
#define _WAVFILE_H_

#include <stdint.h>

typedef struct WaveHeader {
    uint8_t chunkID[4];         // big endian
    uint8_t chunkSize[4];       // little endian
    uint8_t format[4];          // big endian
    uint8_t subchunk1ID[4];     // big endian
    uint8_t subchunk1Size[4];   // little endian
    uint8_t audioFormat[2];     // little endian
    uint8_t numChannels[2];     // little endian
    uint8_t sampleRate[4];      // little endian
    uint8_t byteRate[4];        // little endian
    uint8_t blockAlign[2];      // little endian
    uint8_t bitsPerSample[2];   // little endian
    uint8_t subchunk2ID[4];     // big endian
    uint8_t subchunk2Size[4];   // little endian
} WaveHeader;

void set_wav_header(WaveHeader *hdr, uint32_t numChannels, uint32_t sampleRate, uint32_t numSamples);

#endif // _WAVFILE_H_
