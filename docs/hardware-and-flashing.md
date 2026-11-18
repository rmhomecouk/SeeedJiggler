# Hardware and flashing

## Board

[Seeeduino XIAO](https://wiki.seeedstudio.com/Seeeduino-XIAO/) — Microchip SAMD21G18A, native USB, three LEDs (user/yellow on `LED_BUILTIN`, RX and TX on `PIN_LED_RXL` / `PIN_LED_TXL`), all **active-low**. Any SAMD21 board with native USB should work with small pin changes.

## Toolchain

```bash
brew install arduino-cli
arduino-cli config add board_manager.additional_urls https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
arduino-cli core update-index
arduino-cli core install Seeeduino:samd
arduino-cli lib install Keyboard Mouse
```

FQBN: `Seeeduino:samd:seeed_XIAO_m0`.

## Flashing

```bash
arduino-cli compile --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler
arduino-cli upload  -p /dev/cu.usbmodemXXXX --fqbn Seeeduino:samd:seeed_XIAO_m0 firmware/SeeedJiggler
```

Find the port with `arduino-cli board list` or `ls /dev/cu.usbmodem*`.

### Entering the bootloader

Once SeeedJiggler is on the board, `arduino-cli upload` triggers the bootloader automatically (a 1200-baud "touch" on the serial port) — no buttons needed.

For a board running something else (e.g. a first flash):

1. The XIAO has **no reset button**. Short the **RST** pad to **GND** briefly **twice** (double-tap), about half a second apart.
2. The bootloader appears as USB product "Seeeduino XIAO" and the yellow LED pulses.
3. Run the `upload` command.

### Boards that previously ran other firmware

This project was developed on a board that was running **Klipper**. Klipper firmware does not honour the 1200-baud touch, so the double-tap RST method was required. Flashing SeeedJiggler overwrites Klipper; restoring it means building and flashing Klipper again.

If double-tap does nothing, the chip may have no bootloader and was programmed over SWD — you would need an SWD programmer (ST-Link, J-Link, Raspberry Pi Pico running debugprobe) to recover.
