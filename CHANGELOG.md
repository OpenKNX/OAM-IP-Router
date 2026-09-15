# Changes


## unreleased

**Conformance test suite**
* Fix: a lost TUNNELLING_ACK is answered the way 03_08_04 2.6.1 requires -- the frame is repeated once with the same sequence number and the connection is ended when two attempts go unconfirmed. Keeping the counter made the next, different frame a duplicate that a server acknowledges with `E_NO_ERROR` and discards, so a positive ack was read for a frame that never went out; advancing past a frame the server never saw put every later frame outside its window, where it must not reply at all, and silenced the shared traffic connection for the rest of a run
* Fix: B-14 judges a telegram on the bus by the device's own `L_Data.con` with the confirm flag cleared (03_06_03 p.80), not by the tunnel acknowledgement, which only reports that the interface took the packet. The connection is drained before every probe, because five of the probes and the canary share destination and payload and differ only in the control field, which an interface may rewrite
* Fix: the busmonitor is read while the probes are sent. An unacknowledged indication makes the device end the connection, which emptied the capture the case is about
* Fix: the hop count is read from CtrlE on an extended frame, where index 5 is the destination low byte -- the reported value was never on the bus
* Fix: a traffic interface whose slots are still held is a skip, not a failure, and the wait for a slot happens before the exclusive busmonitor is opened rather than while it sits unread
* Fix: the mask version comes from PID 83 over device management. 03_08_02 Table 5 p.31 lists the Extended Device Information DIB as not allowed in a DESCRIPTION_RESPONSE, so looking for it there could only ever answer `unknown`
* Fix: the last-run state survives on Windows PowerShell 5.1 -- `ConvertFrom-Json -AsHashtable` arrived with PowerShell 6, so the call threw and the runner forgot every previous answer on the platform it has to run on
* The hardening stage writes into the run's report directory instead of the other repository's, so one report of a combined run no longer lies elsewhere than the rest
* The OpenKNX header sits above the help block instead of inside it. PowerShell exposed neither synopsis nor parameters while it was in there, so `Get-Help` was empty for every script in the suite

* The suite is the identical copy the interface carries; propagated with `lib/Sync-TestLib.ps1`, which reports by default and only writes with an explicit direction

## ec/ALPHA-DEV-v8.0.0: 2026-09-05

ETS product **8.0** (`IP-Router-Dev-v8.0.knxprod`), release variant **0.8**. Alpha dev build for testers,
covering everything since `6c1a294` (v7.6.0). All six release environments build; both knxprods generate
with OpenKNXproducer 4.3.12.

### Product
* Feature: the tunnel page becomes `/ipro`, a device and routing view -- role, multicast, routed/filtered/lost counters and bus load, the tunnel list with its connect and disconnect history, the routing decisions (last 32 with hop count, the most frequent group addresses, the filter table as ranges), and bus and NCN diagnostics in a collapsed section. The status bar carries a refresh control (2/5/10/30 s or off) and an arrow that reloads once; bus, routing and history are fetched only while their section or tab is open
* Feature: the tunnel list names the assignment when tunnels are reserved in ETS -- on its reserved slot, on a fallback because that slot was busy, or handed out freely -- and a tab lists every slot with its reservation and state. A slot reserved without an IP address can be reached by no client and is also out of the free pool, which the list states per slot
* Change: the filter table is read in slices. Scanning the 8 kB bitfield took ~22 ms inside the HTTP handler, a quarter of the loop-time warning, every two seconds while its tab was open; it is scanned under `freeLoopTime()` and kept as a finished fragment, so a request costs the transfer and nothing else. Measured on the RP2040, the routing document with the filter table drops from 58 ms to 39 ms
* Change: the `DLC-1` test case and the `DOWNLOAD_COUNTER` property id are out of the test suite, and the README no longer lists the counter -- the knx stack does not expose PID 30 any more. This product kept the counter in RAM and never persisted it, so nothing changes at runtime

### ETS product
* Fix: the product has its own hardware identity now -- both products declared `SerialNumber="1"`, so ETS derived the same Hardware Id and merged them into one hardware
* Fix: `SerialNumber` follows the convention NeoPixel already uses, OpenKnxId plus variant: `0xA101` dev, `0xA100` release
* Fix: the order number is `IP-Router` -- the device carries it in `PID_ORDER_INFO` as `PDT_GENERIC_10`, ten bytes, where `OpenKnxIPRouter` arrived truncated as `OpenKnxIPR`
* Change: the release application name loses the `-Beta`, which duplicated the program version beside it
* Feature: FTC access protection reaches ETS — `FileTransfer.share.xml` is pulled as ModuleType 13 and folds into "Erweitert". The share carries no ComObjects, so the router stays KO-free
* Feature: HTTP service and LAN mode enabled; Info1 is driven as "(KNX-IP)" with function 11
* Change: the BASE channel is rebuilt in `TemplateRouter.xml` so the FTM block sits inside "Erweitert" instead of beside it, mirroring the interface template
* Change: `Common.Router.share.xml` is taken from `lib/OGM-Common` instead of `lib/OFM-Network` — this requires an OGM-Common that carries the file
* Change: product 7.6.0 -> 7.6.1 -> 7.6.2 -> 8.0.0; `op:verify` floors raised to OGM-Common 2.0 and OFM-Network 0.8

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
* knx: a tunnel connect that is turned away is recorded -- three of the four reject paths wrote a history entry, the one for "no slot free" and for a reserved slot configured to decline left no trace at all
* tpuart: a parity error on the host UART no longer counts as a receive overflow -- the NCN encodes a bus-side bit error in that parity bit, so a single disturbed telegram marked the receiver desynchronised and the device stopped transmitting for 20 s
* knx: the ETS writability probe on `PID_DEVICE_ADDR` and `PID_SUBNET_ADDR` is answered instead of refused with `Read_Only`, which ETS reported as a failed write to the memory area
* knx: the management path is bounded against the cEMI frame buffer, the association-table lookup terminates when the first group object is unassigned, and negative values encode on the signed datapoint types
* knx: `PID_DOWNLOAD_COUNTER` is removed from the device object
* OGM-Common: the download counter is gone from the device information, and the console refuses the flash, memory and bcu commands over the diagnose group object
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
* Doc: the README gains the test suite -- stages with scope and duration, how to run it, and what PASS, FAIL, SKIP and N-A mean, with skipped and non-applicable cases counted and named rather than folded into a pass
* Fix: the README claimed 95 test cases; those were call sites in the sources, the conformance stage covers 117 cases
* Doc: the last full run against hardware is recorded, which passed every stage with no failures
* Doc: the example addresses are marked as an isolated lab VLAN, with the note that 11.0.0.0/8 is publicly allocated space rather than an RFC 1918 range

### Libraries

The commits below are pinned in `dependencies.txt`. Each library carries its own CHANGELOG with the full
list; this is what matters for this product.

**knx** `b8b6931` -> `609312e` (tag `ec/v2.5.0-beta.1`)
* Memory-safety pass over the paths the router runs on: `CemiFrame::valid()` out-of-bounds read, truncated `M_PropRead`/`M_PropWrite` frames, the `TpUart sendFrame` malloc guard, the LC-config property pointer in `isAckRequired`, and two memory leaks (TPUart frames on discarded TP frames, cEMI `M_PropRead` on a negative response)
* Tunnel-slot exhaustion fixed: all expired slots are reaped, not just the first occupied one, and the dangling `addresses` pointer in `HandleConnectRequest` is gone
* Inbound routing cEMI is validated before it is forwarded to TP, and a frame dropped by the routing send limit produces a negative `L_Data.con`
* Coupler: hop count 7 is decremented on closed-media routing (post-AN189), `functionRouteTableControl` is guarded against a short PDU
* Tunnelling conformance: `L_Data.con` with the real TP result once per request, config channel resend at 10 s / 3 attempts, responses routed back to the stored control endpoint, NAT route-back per field, header total length validated
* Per-tunnel FIFO for server-to-client requests, so a burst of communication objects is never dropped; session history and read-only introspection
* Local Transport Layer over cEMI (`T_Data_Individual`/`T_Data_Connected`, AN118)
* **Breaking:** `OPENKNX_FTC` is now `OPENKNX_FTC_CLIENT`

* Fix: the counter header is included outside the architecture guards -- an ESP32 target without `KNX_TUNNELING` did not compile; this product was never affected, its builds carry tunnelling
* Since `e75b123`: the coupler records its routing decisions and counts telegrams dropped for hop count 0; the filter table is exposed for diagnostics; the bus monitor is refused on a routing device; a tunnel reports which slot it holds and which one is reserved for it, and a connect that is turned away is recorded

**OFM-FileTransferModule** `178f186` -> `9c53ab5` (tag `ec/v0.2.0-beta.1`)
* The whole FTC feature set arrives in this product: file transfer, firmware update, console tunnel and access control over cEMI/KNX, with one shared client core driving both the on-device `ftc` command and the desktop `ftc-cli`
* Access control with password login, gated from ETS; reads stay open except in the blocked stage
* Firmware update as a difference to the running image (`.okd`) — about 2 min instead of 78 min for a 1.8 MB image
* `fast` and `safe` transfer modes, SD and external-flash backends, non-blocking CRC, knxOTA
* The German documents are replaced by an English set
* Since `9e1c03d`: knxOTA names the devices a scan finds and merges start and cancel into one button; the installer copies the binary with a plain read/write loop; the ETS download counter is out of the device profile

**TPUart** (new pin, tag `ec/1.3.0-beta.1` at `50a4d7e`)
* Proven behaviours are the default now: BCU auto-reconnect, sticky TX data offset, fast TX and RX drain on ESP32, BCU health counters and the lost-CON backstop. This is why nine switches could be dropped from the ini
* Three signed-char bugs that only hit ESP32: a `0xFF` UART byte was dropped, any octet `>= 0x80` corrupted CRC and addresses, and the receiver control-byte comparisons were dead code
* Medium-access priority honoured on TP egress, so an ETS system-priority frame does not queue behind a low-priority backlog
* A control byte is never interpreted while the receiver is desynced; a `0x2703` CRC low byte was once taken for a chip reset and dropped the whole transmit queue
* The line time every received frame occupied is counted in bit times per 03_02_02, including the ACK only when one was actually on the line -- this is what the bus load figure is built on
* `busOperational()` for the tunnel heartbeat — the host-to-chip link stays up on an externally powered NCN when the bus voltage drops
* Since `80210c8` (`ec/1.2.0-beta.1` -> `ec/1.3.0-beta.1`): the volatile counters are no longer incremented with `++`/`--`; the NCN chip identity is read in a receiver-off window; a switch for the chip's own acknowledge; a blocked acknowledge is parked instead of losing its window; a dropped frame is reported only when one was in flight; the probed baud rate is verified before it is accepted; the UART byte status is split into framing, parity, break and overrun

**OFM-Network** `876598e` -> `b7d3fdd`
* Webserver, web console, file manager (internal / SD / external flash), group monitor, MQTT client and broker, HTTP(S) client, ping
* KNX-IP status LED, IP capabilities reported per 03_08_03, multicast rebind on IP change, the RP2040 W5500 robustness layer restored
* Link mode from ETS instead of from flash, whole-interface packet counters, TLS chain validated against a root certificate, file download from a URL straight onto the device
* OTA stays open while the device is unconfigured — an unconfigured device used to evaluate erased parameter memory and could lock itself out of OTA
* Since `1f95c5d`: `net phy` reads the W5500 over SPI (register read at a chosen clock, timed RSTn pulse, 1 Hz square wave); the self-heal no longer spends 62 ms of `delay()` in one loop pass every 5 s while the chip is down, which starved the TPUart receive path; mDNS announces product, KNX order number and board

**OGM-Common** `c703d7b` -> `b0e1779` (tag `ec/v2.0.0-beta.1`)
* Build-time flash and knxOTA reporting, unified reports that also work on Windows, `Prepare-Firmware.ps1` with a real file browser, module release hooks by convention
* Web assets are generated from `web/assets/` into `webassets.h` at build time, so modules no longer hand-minify into C++ string literals
* PSRAM helpers, `pausePeriodicSave()`, uptime rollover and unreadable bus counters fixed
* **Breaking:** the trace filter was reworked — `OPENKNX_TRACE1..5` are replaced by a single `OPENKNX_TRACE`, and the regex dependency (about 80 kB flash when tracing was on) is gone
* Since `420d94c`: the OTA upload names the product and refuses a mismatched target; identity and provenance are written next to the firmware; `InternalTime` moves out of the aliased parameter bit; `bcu stat` gives the NCN chip its own row and shows it only when a register answered; the busmonitor console command is refused on a routing device; device commands stay off the diagnose object

**OFM-DeviceDisplay** `0838614` -> `4fab100` (tag `v0.1.0`)
* The widget manager owns the top-right corner: a blinking busmon badge and the rotation state, so both are visible whatever widget is on screen
* Clock, console header and system-info widget show local time instead of UTC

**OGM-HardwareConfig** `51dc43e` -> `0f59ba5`
* Datasheets for the REG board components

**OFM-SDCard** `638cf14` -> `3ba0aa4` (tag `v0.1.0`)

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
