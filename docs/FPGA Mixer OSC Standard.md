Alexander Kelly
18 Aug 2026

## Command Structure

All OSC commands operate under a set/get structure. Set commands pass a value which is then echoed back to the controller to confirm. Get commands just retrieve a value, useful for synchronization.

Set commands can be sent by controllers to set mixer values, but are also sent by the mixer itself to all network controllers on a value change to ensure synchronization.

The mixer hardware should never need to send get commands. It is the overarching authority on any value conflict.

Set/Get commands follow the same naming convention:
```
	/<mixer name>/set/<zone>/<index>/<module>     <value>
	/<mixer name>/get/<zone>/<index>/<module>
```

Mixer name: Host device name

Zone: Where the value exists:
- inputChannel
- busChannel
- outputChannel
- inputMatrix (input-> bus matrix)
- busMatrix (bus -> output matrix)
- system

Index: Which part of the corresponding zone you're referring to. This can be a channel index or a matrix crosspoint written as "rowIndex_columnIndex". See matrix controls below.

Module: The actual value you're setting/getting. Can be as simple as level, but can also refer to more complex DSP values such as "eq_band4_freq"

Value: In most cases is a float, but can also be used for config strings:
```
/mixer/set/system/deviceName/     "FOHmixer"
/FOHmixer/set/inputChannel/0/level     -6.0
```

NOTE: changing settings like deviceName will require you to change your OSC address space to reflect the change. This may cause issues with device/controller sync if controllers don't know to start listening to the new address space they just assigned.

## Channel Control Examples

```
/<mixer name>/set/inputChannel/0/level     -6.0
/<mixer name>/set/inputChannel/10/compressor_threshold     -16.4
```

## Matrix Control Examples
```
/mixer/set/inputMatrix/5_8/level     -24.0
/mixer/set/inputMatrix/5_8/delay     2.39
```
Sets the level of input 5 going to bus 8 to -24db, and delays it by 2.39ms