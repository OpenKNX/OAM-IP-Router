# This script is just a template and has to be copied and modified per project
# This script should be called from .vscode/tasks.json with
#
#   scripts/Build-Release.ps1            - for Beta builds
#   scripts/Build-Release.ps1 Release    - for Release builds
#
# {
#     "label": "Build-Release",
#     "type": "shell",
#     "command": "scripts/Build-Release.ps1 Release",
#     "args": [],
#     "problemMatcher": [],
#     "group": "test"
# },
# {
#     "label": "Build-Beta",
#     "type": "shell",
#     "command": "scripts/Build-Release.ps1 ",
#     "args": [],
#     "problemMatcher": [],
#     "group": "test"
# }



# set product names, allows mapping of (devel) name in Project to a more consistent name in release
# $settings = scripts/OpenKNX-Build-Settings.ps1

# execute generic pre-build steps
lib/OGM-Common/scripts/setup/reusable/Build-Release-Preprocess.ps1 $args[0]
if (!$?) { exit 1 }

# build firmware based on generated headerfile 
# the following build steps are project specific and must be adopted accordingly
# see comment in Build-Step.ps1 for argument description

# Example call, the following 2 lines might be there multiple times for each firmware which should be built
 ../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG1_ETH firmware-IP-Router-REG1-Eth rp2040-ip
 if (!$?) { exit 1 }

 ../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG1_LAN_TP_BASE firmware-IP-Router-REG1-LAN-TP-Base esp32-ip
 if (!$?) { exit 1 }

# REG2 Releases (Display + SD-Card variants; GPIO via OGM-Common native)
 ../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG2_PICO_ETH_DD firmware-IP-Router-REG2-Pico-Eth-DD rp2040-ip
 if (!$?) { exit 1 }
 #../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG2_PICO_W_ETH_DD firmware-IP-Router-REG2-PicoW-Eth-DD rp2040-ip
 #if (!$?) { exit 1 }
 ../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG2_PICO2_ETH_DD firmware-IP-Router-REG2-Pico2-Eth-DD rp2040-ip
 if (!$?) { exit 1 }
 ../OGM-Common/scripts/setup/reusable/Build-Step.ps1 release_REG2_PICO_ESP_ETH_DD firmware-IP-Router-REG2-Pico-Esp-Eth-DD esp32-ip
 if (!$?) { exit 1 }

# execute generic post-build steps
lib/OGM-Common/scripts/setup/reusable/Build-Release-Postprocess.ps1 $args[0]
if (!$?) { exit 1 }
