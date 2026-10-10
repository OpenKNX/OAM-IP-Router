# repro/ — quick & dirty investigation scripts

Ad-hoc scripts to reproduce & diagnose the interface's behaviour under an unpaced incrementing-sequence
tunnel flood. Not polished, not part of the normal test run — **keep them** for re-investigation. Most
default to `-Ip 11.11.0.126`; pass `-Ip <ip>` for another device. `pwsh <script>`.

| Script | Quick & dirty |
|---|---|
| `jet_repro.ps1` | The core repro: opens a tunnel, jets an unpaced incrementing-seq flood for `-Secs` and watches if the device drops off. |
| `jet_serial.ps1` | Same flood as `jet_repro`, but also tails the device's **serial console** in parallel (`SER\|` lines) — correlates the UDP flood with on-device output / a reboot banner. `-Port <serial>`. |
| `jet_diag.ps1` | Hammer a `DESCRIPTION_REQUEST` probe during the flood: it still answers while all tunnels are busy, so a **missing** answer = the device actually rebooted (not just "tunnels full"). |
| `Test-FloodBisect.ps1` | Runs the flood and **counts watchdog resets** it caused — used to bisect which flood shape triggers the reboot. |
| `Test-WdWindow.ps1` | Decides **why** the interface goes away under flood: CPU genuinely stuck (watchdog) vs. a clean disconnect. |
| `search.ps1` | Fire a `SEARCH_REQUEST` to multicast `224.0.23.12`, print the `SEARCH_RESPONSE` device-info DIBs (what ETS's connection list shows). |
| `describe.ps1` | Fire a unicast `DESCRIPTION_REQUEST`, print the device-info DIB (PA, serial, name). Quick "is it alive / what does it report". |
