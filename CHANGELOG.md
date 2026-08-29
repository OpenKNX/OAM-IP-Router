# Changes


## ec/ALPHA-DEV-v7.8.0: 2026-08-29

ETS product **7.8** (`IP-Router-Dev-v7.8.knxprod`), release variant **0.7**. Alpha dev build for testers,
covering everything since `6c1a294` (v7.6.0). All six release environments build; both knxprods generate
with OpenKNXproducer 4.3.12.

### ETS product
* Feature: FTC access protection reaches ETS — `FileTransfer.share.xml` is pulled as ModuleType 13 and folds into "Erweitert". The share carries no ComObjects, so the router stays KO-free
* Feature: HTTP service and LAN mode enabled; Info1 is driven as "(KNX-IP)" with function 11
* Change: the BASE channel is rebuilt in `TemplateRouter.xml` so the FTM block sits inside "Erweitert" instead of beside it, mirroring the interface template
* Change: `Common.Router.share.xml` is taken from `lib/OGM-Common` instead of `lib/OFM-Network` — this requires an OGM-Common that carries the file
* Change: product 7.6.0 -> 7.6.1 -> 7.6.2 -> 7.8.0; `op:verify` floors raised to OGM-Common 1.9 and OFM-Network 0.8

### Device
* Feature: the FileTransferClient module is registered as object 11 — PA to PA firmware push over the bus, with SD and external-flash storage backends
* Feature: tunnel status page in the web interface, listing the KNXnet/IP tunnels; the page ships as its own assets and is embedded like every other OpenKNX web asset. `showHelp()` lists the router console commands next to it
* Feature: REG2 variants (Pi Pico RP2040 and ESP32-S3, ETH or WiFi, with DeviceDisplay) — hardware config, module wiring and display widgets
* Fix: the router has no hardware busmonitor — `TUN_BUSMON` and `END_BUSMON` are only produced under `OPENKNX_HW_BUSMON`, which the router never sets, so both labels were dead and now sit behind the same guard
* Fix: the IP-Router widget hides the rotation-progress dot while rotation is paused, matching the shared pause glyph, and the dot position math is overflow-safe
* Change: `clang-format` over the router module and `main.cpp`, no behaviour change

### Build
* Change: the USB-exchange module is dropped — no USB-MSC config disk in this product, so it was compiled to nothing while still owning an `extra_configs` entry and a module slot
* Change: the ini is split by purpose — `platformio.custom.ini` keeps product flags, feature blocks and release environments, hardware moves to `platformio.hardware.ini`, develop bases and environments to `platformio.custom.dev.ini`
* Change: `libdeps_dir` points at `~/.pio-libdeps-openknx` instead of `/tmp/libdeps`, which macOS clears on reboot and on its periodic cleanup, so every build re-downloaded all dependencies
* Change: the FTC switch is `OPENKNX_FTC_CLIENT`; all release environments take `PROFILE_MANAGER` plus `CLIENT`, `CONSOLE` and `DELTA_UPDATE`. Flash and exchange offsets are stated per environment instead of relying on the platform default
* Fix: nine dead switches removed — `TPUART_BCU_AUTORECONNECT`, `_BACKSTOP`, `TPUART_TX_FAST`, `_STICKY_OFFSET`, `TPUART_RX_DRAIN_FAST`, `MAX_TX_QUEUE`, `MAX_RX_QUEUE_BYTES`, `KNX_FIXES_EC` and `DEVICE_DISPLAY_MODULE_SSD1315`. Each was checked for a successor first; none was renamed, they simply stopped being read (TPUart made its proven behaviours the default)
* Fix: `OPENKNX_SD_CARD_MODULE_ENABLE` is `OPENKNX_SDCARD` in the ini and in `main.cpp` — the file transfer module reads only the new name, so the router had **no `sd/` drive at all**
* Change: the four ETS debug XMLs are no longer tracked. They are OpenKNXproducer output, so every knxprod run left the repo dirty with over a thousand lines of regenerated markup. `doc/` and `.claude/` are ignored as well
* Change: the release script follows the shared structure — OpenKNX logo header, comment-based help, a mode parameter, `-Clean`, and the PC FileTransferClient matrix built first so a client failure aborts before the firmware build. The Tools/ftc-cli layout is left to OGM-Common's `Build-Release-Postprocess.ps1`

### Tests
* Test: suite-based test runner — `Run-Tests` drives feature and suite scripts against a real device over the bus; shared helpers, tools and runners live next to the suites instead of in one script
* Change: the former `Test-KnxRouter` script moves to `Test/stress/Invoke-Stress`

### Bus load and console

* Feature: console command `ipro` — coupler role and coupled line derived from the individual address, routing multicast and TTL, open tunnels, the routing decision counters per direction, the KNXnet/IP telegram counters, and bus load as current value, one minute average and peak
* Feature: `ipro` names an address carrying a device part as no router, instead of showing a role the device cannot fulfil
* Feature: `ipro reset` clears the bus load history, average and peak, so a measurement starts from a defined point
* Change: the module log prefix is `ipro`, matching the command


**Inherited from the libraries** (arrives with the module update, no product change)
* knx: the four KNXnet/IP telegram counters of 03_08_03 (PID 72-75) exist for the first time and are answered by this product as a routing device -- they were enum values no code ever used, so ETS could not read them at all
* knx: the coupler counts its routing decision per direction, which is where the `ipro` routed and filtered figures come from
* knx: `PID_DOWNLOAD_COUNTER` on the device object
* tpuart: every received frame's line time is counted in bit times per 03_02_02, which is what makes a real bus load computable at all
* OGM-Common: the shared 1 Hz bus load sampler, the diagnose page of the system-info widget, and the download counter in the device info
* OGM-Common: the common widgets register from `loop()`, so they also appear on an unprogrammed device
* OFM-Network: the LAN speed widget and the new network-info widget ship with the module now
* OFM-DeviceDisplay: busmon badge and rotation state in the manager corner, and local time instead of UTC
* OFM-FileTransferModule: the dead device error-code read is gone, which cost 800 ms on every device-info query

### Documentation
* Doc: the README replaces a two-line placeholder -- routing and the filter table, the counters that make a blocking filter table visible, tunnelling, the web interface, what the REG2 display and SD card add, and a diagram showing that both directions pass the filter table
* Doc: the ETS identity, the absence of group objects and which environment runs on which MCU are stated
* Change: conformance evidence, the deliberate exceptions and a warranty disclaimer instead of certification wording
* Doc: the original author is credited and this branch's contribution named
* Fix: the `ipro` help line said "data load" while the command prints "Bus load"

### Libraries

The commits below are pinned in `dependencies.txt`. Each library carries its own CHANGELOG with the full
list; this is what matters for this product.

**knx** `b8b6931` -> `e75b123` (tag `ec/v2.5.0-beta.1`)
* Memory-safety pass over the paths the router runs on: `CemiFrame::valid()` out-of-bounds read, truncated `M_PropRead`/`M_PropWrite` frames, the `TpUart sendFrame` malloc guard, the LC-config property pointer in `isAckRequired`, and two memory leaks (TPUart frames on discarded TP frames, cEMI `M_PropRead` on a negative response)
* Tunnel-slot exhaustion fixed: all expired slots are reaped, not just the first occupied one, and the dangling `addresses` pointer in `HandleConnectRequest` is gone
* Inbound routing cEMI is validated before it is forwarded to TP, and a frame dropped by the routing send limit produces a negative `L_Data.con`
* Coupler: hop count 7 is decremented on closed-media routing (post-AN189), `functionRouteTableControl` is guarded against a short PDU
* Tunnelling conformance: `L_Data.con` with the real TP result once per request, config channel resend at 10 s / 3 attempts, responses routed back to the stored control endpoint, NAT route-back per field, header total length validated
* Per-tunnel FIFO for server-to-client requests, so a burst of communication objects is never dropped; session history and read-only introspection
* Local Transport Layer over cEMI (`T_Data_Individual`/`T_Data_Connected`, AN118)
* **Breaking:** `OPENKNX_FTC` is now `OPENKNX_FTC_CLIENT`

* Fix: the counter header is included outside the architecture guards -- an ESP32 target without `KNX_TUNNELING` did not compile; this product was never affected, its builds carry tunnelling

**OFM-FileTransferModule** `178f186` -> `a3b2153` (tag `ec/v0.2.0-beta.1`)
* The whole FTC feature set arrives in this product: file transfer, firmware update, console tunnel and access control over cEMI/KNX, with one shared client core driving both the on-device `ftc` command and the desktop `ftc-cli`
* Access control with password login, gated from ETS; reads stay open except in the blocked stage
* Firmware update as a difference to the running image (`.okd`) — about 2 min instead of 78 min for a 1.8 MB image
* `fast` and `safe` transfer modes, SD and external-flash backends, non-blocking CRC, knxOTA
* The German documents are replaced by an English set

**TPUart** (new pin, tag `ec/1.2.0-beta.1` at `80210c8`)
* Proven behaviours are the default now: BCU auto-reconnect, sticky TX data offset, fast TX and RX drain on ESP32, BCU health counters and the lost-CON backstop. This is why nine switches could be dropped from the ini
* Three signed-char bugs that only hit ESP32: a `0xFF` UART byte was dropped, any octet `>= 0x80` corrupted CRC and addresses, and the receiver control-byte comparisons were dead code
* Medium-access priority honoured on TP egress, so an ETS system-priority frame does not queue behind a low-priority backlog
* A control byte is never interpreted while the receiver is desynced; a `0x2703` CRC low byte was once taken for a chip reset and dropped the whole transmit queue
* The line time every received frame occupied is counted in bit times per 03_02_02, including the ACK only when one was actually on the line -- this is what the bus load figure is built on
* `busOperational()` for the tunnel heartbeat — the host-to-chip link stays up on an externally powered NCN when the bus voltage drops

**OFM-Network** `876598e` -> `1f95c5d`
* Webserver, web console, file manager (internal / SD / external flash), group monitor, MQTT client and broker, HTTP(S) client, ping
* KNX-IP status LED, IP capabilities reported per 03_08_03, multicast rebind on IP change, the RP2040 W5500 robustness layer restored
* Link mode from ETS instead of from flash, whole-interface packet counters, TLS chain validated against a root certificate, file download from a URL straight onto the device
* OTA stays open while the device is unconfigured — an unconfigured device used to evaluate erased parameter memory and could lock itself out of OTA

**OGM-Common** `c703d7b` -> `420d94c`
* Build-time flash and knxOTA reporting, unified reports that also work on Windows, `Prepare-Firmware.ps1` with a real file browser, module release hooks by convention
* Web assets are generated from `web/assets/` into `webassets.h` at build time, so modules no longer hand-minify into C++ string literals
* PSRAM helpers, `pausePeriodicSave()`, uptime rollover and unreadable bus counters fixed
* **Breaking:** the trace filter was reworked — `OPENKNX_TRACE1..5` are replaced by a single `OPENKNX_TRACE`, and the regex dependency (about 80 kB flash when tracing was on) is gone

**OFM-DeviceDisplay** `0838614` -> `f90faca`
* The widget manager owns the top-right corner: a blinking busmon badge and the rotation state, so both are visible whatever widget is on screen
* Clock, console header and system-info widget show local time instead of UTC

**OFM-SDCard**, **OGM-HardwareConfig** — pinned unchanged, see `dependencies.txt`.

**OFM-UsbExchange** — removed from this product.

## v7.6.0

Earlier release, see commit `6c1a294`.

## 7.5.0-Dev / 0.7.0: 2026-03-05

* Change: new knx stack (`v1dev`) and OGM-Common 1.7.2
* Fix: GPIO LED handling, carried over from 7.4.3-Dev

## 7.4.0-Dev .. 7.4.2-Dev: 2026-02-25/26

* Feature: `apdu` and `route apdu` console commands set the APDU properties
* Change: the application is loaded after a firmware update with a newer ETS version
* Change: switch to OGM-Common v1.6
* Fix: IGMP handling (7.4.1), followed by 7.4.2-Dev

## 6.0.1-Dev / 0.6.1: 2026-01-18

* Change: maintenance release on top of 6.0.0-Dev

## 6.0.0-Dev / 0.6.0: 2025-12-04

* Feature: adapted to the new status LED
* Change: adapted to OGM-Common 1.6, and the release target definition reworked

## 0.4.1: 2025-11-25

* Change: tunnel refactoring

## 5.4.0-Dev / 0.4.0: 2025-10-28

* Change: TPUart and OGM-Common 1.5, new producer; knxprod plus RP2040 and ESP firmware builds

## 5.2.2-Beta: 2025-08-15

* Fix: the repeat flag and individual-address assignment over TP

## 5.2.0-Beta / 0.3.0: 2025-07-11

* Change: switch to branch `v1` and the lwIP work merged

## 5.1.0-Beta / 5.1.1-Beta: 2025-07-03

* Fix: the TPUart timeout of 60 is removed in favour of the new knx stack with TPUart 1.0.1, which carries the timeout fix

## 5.0.0-Beta .. 5.0.2-Beta: 2025-01-09 .. 2025-02-13

The tunnelling generation.

* Feature: reserved tunnels, configured through a custom property, and the tunnel list shown as a table in ETS
* Change: the ETS product moves to `Template.xml` / `TemplateRouter.xml`
* Change: the tunnel branch of the knx stack, later `v1dev` with a new TPUart and corrected property numbers
* Change: USB environments removed; restore scripts extended; console help improved

## 2.12.0-Beta .. 2.12.3-Beta / 0.1.0 .. 0.1.3: 2024-01-24 .. 2024-02-24

The first published generation, built up over 117 commits from 2023-05-14.

* Note: the commit subjects of this period do not carry feature detail; the entries above are what
  the history states. For anything older, read the commits themselves.
