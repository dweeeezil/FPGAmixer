Alexander Kelly
3 August 2026

## Hardware
- Xilinx Arty Z7-20 Zynq-7000 Development Board (main device)
- 2x Digilent Pmod stereo i2s in/out AD/DA board (this makes 4in, 4out total analog IO)
- OWC Thunderbolt 10g ethernet adapter (for MacOS AVB connectivity)
- Raspberry Pi5 w/ PCIe board & Intel I350-T4V2 Ethernet Server Adapter (This will act as a network switch if needed)

## Goals & Project Outline
- Network based digital audio processor and matrix mixer
	- References: Meyer Nadia/D-Mitri, Neumann MT48, LCS Matrix3, SSL System T
- Passes audio through IP (AVB), USB, and onboard Pmod I2s AD/DA converters
- FPGA 3-layer matrix mixing & DSP
	- Inputs DSP layer (Dynamics, EQ, level)
	- Inputs -> Bus Matrix
	- Bus DSP layer (Dynamics, EQ, level, Delay)
	- Bus -> Outputs Matrix
	- Outputs DSP layer (Dynamics, EQ, level)
- OSC Control
	- MacOS control software written in Swift (see: Meyer CueStation, Nebra, SpaceMap Go)
	- Onboard UDP OSC receiver (OPTIONAL)
	- Onboard TCP Server/Client for two-way OSC communication with control software. Device receives message, echoes data back for confirmation
- Control parameters save as they're set, system should restore after loss of power
- All digital audio streams will be converted to raw PCM and routed through matrix mixer IPs together. Analog, IP, and USB audio streams will all be in the same format and treated the same.

## Considerations & possible choices to make
- AVB vs Milan
	- AVB much preferred, Milan may be easier
- Variable sample rates
	- 48khz/24bit to start
	- Compatibility with other formats would be nice (even if it's not a true conversion), but not strictly required - Low priority

## Draft Roadmap (Starting with JTAG programming, skipping Petalinux for now)
- i2s Tx/Rx functionality
	- Basic loopback in vivado, no reformatting. Audio should loop from one Pmod input to one Pmod output.
- i2s -> PCM stream & PCM stream -> i2s converter IPs
	- Convert i2s to raw PCM and back again
	- Still just loopback, no processing
	- Signal Chain should be i2s receiver -> convert to PCM -> convert to i2s -> i2s transmitter
- PCM stream matrix mixer IP
	- Takes in n PCM streams, outputs n PCM streams
	- Crosspoint levels set on compilation, no control yet
- - Pause, take a break, re-assess
- Initial Petalinux build
	- Most features beyond this point will be FPGA + SoC
- UDP OSC control implementation
	- Stupid receive message, write value to memory process
	- Get crosspoint control working
- TCP OSC control implementation
	- Server/Client relationship & message echoing
- Value preservation
	- Save parameter values on change, auto-load on startup
- USB audio device implementation
	- Possibly issue with mirroring in/out count between USB and network later on?
	- Ensure FPGA / SoC clocking and sample rate sync
	- Converting USB audio stream (whichever format) to raw PCM for mixing & DSP
- - Pause, take a break, re-assess, this is where the pain begins and my knowledge tapers
- Figure out IP audio clocking
	- How to handle PTP timestamping given that the Zynq PS GEM's 1588 registers are non-latching.
	- External clock? Internal FPGA clock?
- Packet syncing & hardware timestamping
- Implement EQ, Dynamics, Delay DSP in each channel