/*
 * Based on https://github.com/lirongyuan/Music-Generator.git
 * For WAVE PCM soundfile format see http://soundfile.sapp.org/doc/WaveFormat/
 *
 */
#include "wavfile.h"

/*
 * Internal helper functions.
 * For some reason xc doesn't like *p++ construct - see https://www.xcore.com/forum/viewtopic.php?f=26&t=3047
 */
void assignLittleEndian4(uint8_t *p, uint32_t value) {
#pragma loop unroll
    for(int i=0; i<4; i++) {
        *p = value & 0xFF;
        p++;
        value >>= 8;
    }
}

void assignLittleEndian4str(uint8_t *p, char *s) {
#pragma loop unroll
    for(int i=0; i<4; i++) {
        *p = *s;        // Can just copy simple 8-bit chars without realignment
        p++;
        s++;
    }
}

#if 0                   // unused function
//Assume 16-bit signed values for samples currently - would need extensions to work with larger sample sizes
void assignLittleEndian2signed(uint8_t *p, int16_t value) {
#pragma loop unroll
    for(int i=0; i<2; i++) {
        *p = value & 0xFF;
        p++;
        value >>= 8;
    }
}
#endif


void assignLittleEndian2(uint8_t *p, uint16_t value) {
#pragma loop unroll
    for(int i=0; i<2; i++) {
        *p = value & 0xFF;
        p++;
        value >>= 8;
    }
}


/*
 * Set up a WAV header structure in situ, from parameters
 */
void set_wav_header(WaveHeader *hdr, uint32_t numChannels, uint32_t sampleRate, uint32_t numSamples) {
    const uint32_t bitsPerSample = 16;
    const uint32_t bytesPerSample = bitsPerSample/8;

    // Calculate the basic header parameters
    uint32_t dataSize = numSamples * numChannels * bytesPerSample;
    uint32_t byteRate = numChannels * sampleRate * bytesPerSample;
    uint32_t fileSize = sizeof(WaveHeader) + dataSize;          // no longer have a +1 data byte in the struct here

    // Start file with RIFF header
    assignLittleEndian4str(hdr->chunkID, "RIFF");
    assignLittleEndian4(hdr->chunkSize, fileSize - 8);          // chunkID and chunkSize longwords don't count towards the chunkSize itself

    // Subchunk 1 - WAVE header
    assignLittleEndian4str(hdr->format, "WAVE");
    assignLittleEndian4str(hdr->subchunk1ID, "fmt ");
    assignLittleEndian4(hdr->subchunk1Size,16);                 // Header is always 16 bytes
    assignLittleEndian2(hdr->audioFormat, 1);                   // PCM = 1
    assignLittleEndian2(hdr->numChannels, numChannels);
    assignLittleEndian4(hdr->sampleRate, sampleRate);
    assignLittleEndian4(hdr->byteRate, byteRate);
    assignLittleEndian2(hdr->blockAlign, numChannels * bytesPerSample);
    assignLittleEndian2(hdr->bitsPerSample, bitsPerSample);

    // Subchunk 2 - sample data
    assignLittleEndian4str(hdr->subchunk2ID, "data");
    assignLittleEndian4(hdr->subchunk2Size, dataSize);
}

