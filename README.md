# mbp14-3-linux-wifi-fix

Fixes slow, 2.4 GHz-only Wi-Fi on the **2017 15" MacBook Pro (MacBookPro14,3, A1707)** under Linux. Its Wi-Fi card is the Broadcom **BCM43602** (`[14e4:43ba]`), which uses the in-kernel `brcmfmac` driver.

| | Before | After |
|---|---|---|
| Bands | 2.4 GHz only | 2.4 + 5 GHz |
| Signal from 3 m | -74 dBm | -58 dBm on 2.4 GHz |
| Link rate | 13 Mbit/s | 468-702 Mbit/s (5 GHz) |
| Download | ~9 Mbit/s | 450+ Mbit/s (limited by the internet plan) |

Tested on Arch / Omarchy, kernel 7.2, NetworkManager 1.58 with wpa_supplicant, `linux-firmware-broadcom` 20260916. Other 2016-2017 MacBook Pros with the BCM43602 should work the same way: the gist comments report success on a MacBookPro14,2 and late-2016 models.

Companion repo for sleep/resume on the same Mac: [mbp14-3-linux-sleep-fix](https://github.com/mihneadevries/mbp14-3-linux-sleep-fix).

## Quick start

```bash
git clone https://github.com/mihneadevries/mbp14-3-linux-wifi-fix
cd mbp14-3-linux-wifi-fix
sudo ./install.sh                  # Wi-Fi country = US
# or: sudo ./install.sh --country DE
```

Wi-Fi drops for about 10 seconds while the driver reloads. Then connect to the 5 GHz network (often named `<name>_5G`). Undo with `sudo ./install.sh --undo`.

## The three problems and fixes

There's no driver to replace. `brcmfmac` is the only Linux driver for this chip: Broadcom's proprietary `wl` doesn't support the BCM43602. It's the same driver and firmware as stock. The fixes are a config file for the card and two settings.

### 1. Missing board calibration file (NVRAM): no 5 GHz, weak signal

On macOS, Apple's driver gives the card its board-specific data: antenna setup, power tables and calibration. On Linux, `brcmfmac` looks for `brcm/brcmfmac43602-pcie.txt`, which no distro ships. Without it the card runs on generic defaults.

Symptoms:
- `iw phy` lists no "Band 2" (5 GHz) at all, so 5 GHz networks are invisible.
- Weak reception: -74 dBm from a router 3 m away.
- Transmit power shown as an unrealistic `txpower 31.00 dBm`.
- The MAC address is Broadcom's generic `00:90:4c:...` instead of an Apple one.
- The boot log shows `brcmf_c_process_clm_blob: no clm_blob available (err=-2), device may have limited channels available`. That warning stays even after the fix. Broadcom never released a `clm_blob` for the 43602, and the NVRAM file is what actually matters.

**Fix:** install the community NVRAM file for MacBook Pros with this card, from [MikeRatcliffe's gist](https://gist.github.com/MikeRatcliffe/9614c16a8ea09731a9d5e91685bd8c80), to `/usr/lib/firmware/updates/brcm/`. Files in `updates/` take priority over `linux-firmware` and are never overwritten by package updates. `install.sh` downloads a pinned revision, checks its SHA-256, and writes the card's current MAC into the `macaddr=` line.

### 2. NetworkManager's random-MAC scan breaks scanning

NetworkManager switches the card to a random MAC before scanning. On `brcmfmac` the scan right after that change fails (`wpa_supplicant: CTRL-EVENT-SCAN-FAILED ret=-22`). The retry comes back without the 5 GHz networks, so `nmcli con up <5G network>` fails with *"network could not be found"*. 2.4 GHz still connects because it reuses older scan results, which hides the problem.

**Fix:** [`files/90-mbp-wifi.conf`](files/90-mbp-wifi.conf) → `/etc/NetworkManager/conf.d/`, which sets `wifi.scan-rand-mac-address=no` for `brcmfmac` devices only.

### 3. Wi-Fi country (regulatory domain) disables the router's 5 GHz channels

With `WIRELESS_REGDOM="VN"` the Broadcom firmware marks most 5 GHz channels as disabled whenever the card isn't connected. That covers 5500-5720 MHz (channels 100-144) and 5745-5825 MHz (149-165). Our router used channels 100 and 161. While connected to the router on 2.4 GHz, the router's country information element (US) makes those channels look enabled, so every check looks fine. But joining 5 GHz means disconnecting first, the channels switch off, and wpa_supplicant skips every 5 GHz access point as "channel disabled".

How to see it: turn on wpa_supplicant debug logging (see [AGENTS.md](AGENTS.md)) and look for `Mode IEEE 802.11a: ... 5500[DISABLED] ... 5805[DISABLED]`.

**Fix:** set the Wi-Fi country to the one the router announces (US here) in `/etc/conf.d/wireless-regdom`, then run `iw reg set US`. `install.sh --country XX` picks another one. Pacman keeps your edited version of this file on updates (a new default arrives as `.pacnew`).

## Verify

```bash
iw phy | grep -c 'Band 2'                     # 1 = 5 GHz available
iw reg get | head -3                          # country US (or yours)
iw dev wlp3s0 link                            # freq 5xxx, signal, rx/tx bitrate
curl -4 -o /dev/null -w '%{speed_download} B/s\n' https://proof.ovh.net/files/100Mb.dat
```

Speed test caveats are in [docs/lessons-learned.md](docs/lessons-learned.md).

## Files installed

| Path | What | Undo |
|---|---|---|
| `/usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt` | NVRAM / calibration | `--undo` deletes it |
| `/etc/NetworkManager/conf.d/90-mbp-wifi.conf` | no random MAC while scanning | `--undo` deletes it |
| `WIRELESS_REGDOM=` in `/etc/conf.d/wireless-regdom` | Wi-Fi country | `--undo` restores the `.before-mbp-wifi-fix` backup |

All three persist across reboots and package updates. They work on any network, not only the one at home.

## Credits and sources

- NVRAM file: [MikeRatcliffe's gist](https://gist.github.com/MikeRatcliffe/9614c16a8ea09731a9d5e91685bd8c80), based on [madfatcat88's earlier version](https://gist.github.com/madfatcat88/fb17a3ef6364a48a19ed57c143ddd383). It isn't redistributed here. `install.sh` downloads it.
- [Kernel bug 193121: BCM43602 on MacBookPro14,3](https://bugzilla.kernel.org/show_bug.cgi?id=193121)
- [linux-wireless: missing brcmfmac43602-pcie.txt](https://lore.kernel.org/linux-wireless/907921df-34c1-6f08-1ece-bac896031397@jax.org/T/)
- [Arch Wiki: Broadcom wireless](https://wiki.archlinux.org/title/Broadcom_wireless)

Scripts and docs: GPL-2.0 (see LICENSE).
