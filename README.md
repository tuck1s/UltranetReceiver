Can now read two I2S streams, write contents via FIFO to SDcard.
- Wav file header corrected, calculates number of samples from the file size when it should really be the other way around (so it rounds sample counts down slightly)
- SDcard code can write up to 2x8 channels of 48k/16 bit audio, providing the SDcard is fast enough (recommended: 32GB SanDisk Extreme Pro card).
- Up to 2x4 channels on 32GB SanDisk Ultra 40MB/s card.
- Basic User interface using the start/stop button
