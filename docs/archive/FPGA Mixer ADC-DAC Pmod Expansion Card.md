## Project Overview
I'm working on creating an FPGA based digital audio processor. The goal is to have it be a standalone device that can send/receive lossless audio over IP (AVB Protocol), USB, and analog through a set of onboard DAC/ADC cards.

This system is designed to be realtime with sub 5ms latency io between any domains. Because of this, the protocols I'm using have *extremely* strict timing and clocking rules, especially on the network side of things.

The Xilinx Arty Z7-20 Zynq-7000 Development Board has several 12pin Pmod expansion slots, right now these are populated by Digilent Pmod stereo i2s in/out AD/DA board (this makes 4in, 4out total analog IO). These are terrible, and only output unbalanced line level signals. I'd like to make my own converter boards that can input and output *balanced* line level signals.

The current converters also have independent clocks for each channel. I'm still researching this, but ideally we could share a common clock across all channels, this would then free up more data pins and allow for more channels of IO

## Hardware
- Xilinx Arty Z7-20 Zynq-7000 Development Board (main device)
- 2x Digilent Pmod stereo i2s in/out AD/DA board (this makes 4in, 4out total analog IO)
- OWC Thunderbolt 10g ethernet adapter (for MacOS AVB connectivity)
- Raspberry Pi5 w/ PCIe board & Intel I350-T4V2 Ethernet Server Adapter (This will act as a network switch if needed)