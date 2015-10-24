Can now read two I2S streams, write contents via FIFO to SDcard.
Known issues:
- Wav file header corrected, calculates number of samples from the file size when it should really be the other way around (so it rounds sample counts down slightly)
- SDcard code can write up to 16 channels of 48k/16 bit audio, providing the SDcard is fast enough (recommended: 32GB SanDisk Extreme Pro card).
- Basic User interface
