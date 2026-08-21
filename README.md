# Minecraft CC - Draconic Energy Storage Display

CC:Tweaked telemetry and foyer display for a Draconic Evolution Energy Core.

## Architecture

```text
Draconic Energy Pylon
        |
   Wired Modem
        |
 Relay Computer + Wireless Modem
        )))
        ))) Rednet telemetry
        )))
 Display Computer + Wireless Modem
        |
 Advanced Monitor (direct or wired-network attached)
```

Only one Energy Pylon needs to be exposed to the relay. The `draconic_rf_storage` peripheral reports core-wide storage and transfer telemetry.

## Installer

On either new CC computer run:

```text
wget run https://raw.githubusercontent.com/Draze08/Minecraft-CC-DEStorage_display/main/install.lua
```

Choose:

```text
1. Relay
2. Display
```

The installer downloads the selected role as `destorage.lua`, creates `startup.lua`, and reboots.

## Relay requirements

- CC:Tweaked computer
- Wireless Modem
- Wired Modem / wired CC peripheral network exposing one Draconic Evolution Energy Pylon
- Peripheral type must appear as `draconic_rf_storage`

The relay broadcasts at 10 Hz using Rednet protocol `destorage.telemetry.v1`.

Telemetry fields: stored OP, maximum capacity, input OP/t, output OP/t, net transfer OP/t, packet sequence, sender computer ID, and timestamp.

## Display requirements

- CC:Tweaked computer
- Wireless Modem
- Advanced Monitor, either directly attached or available over a wired peripheral network

On first boot the display asks for a display name and stores it in `.destorage_display.cfg`.

To rename the display later, delete that config file and reboot:

```text
delete .destorage_display.cfg
reboot
```

The display automatically detects monitor dimensions and uses text scale `0.5`. A large monitor such as 5x4 is recommended.

## Dashboard

The dashboard currently includes configurable display name, Draconic Energy Core heading, stored energy and maximum capacity, storage percentage and segmented storage bar, live Input / Output / Net OP/t gauges, 10-second rolling averages, session peak input/output, charging/discharging/idle state, estimated time to full, telemetry link status, and a `TELEMETRY LOST` warning after 2 seconds without packets.

The relay samples/broadcasts at 10 Hz while the display renderer runs at 20 Hz for smooth CC monitor animation.

## DE peripheral methods used

These methods were verified against the target Draconic Evolution Energy Core peripheral:

```text
getEnergyStored
getMaxEnergyStored
getInputPerTick
getOutputPerTick
getTransferPerTick
```
