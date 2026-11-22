# Instructions for AI agents

You're helping someone whose Wi-Fi is slow or 2.4 GHz-only on Linux. This repo was written for, and tested on, one exact machine:

| | |
|---|---|
| Model | **MacBook Pro (15-inch, 2017)**, `MacBookPro14,3`, model number A1707, T1 chip / Touch Bar |
| Wi-Fi card | **Broadcom BCM43602** 802.11ac, PCI id **`14e4:43ba`** (shows as `03:00.0` on this Mac) |
| Driver | `brcmfmac` (in-kernel) + `linux-firmware-broadcom`: firmware `BCM43602/2 ... version 7.35.177.61` |
| OS | Arch / Omarchy, NetworkManager + wpa_supplicant |

The answer is already known. **Don't research from scratch.** Check that the machine matches, run `install.sh`, verify. The whole fix takes about 5 minutes.

## 1. Confirm it's the same situation (read-only, no sudo)

```bash
cat /sys/class/dmi/id/product_name                       # MacBookPro14,3 (others with 43ba: probably fine)
lspci -nn | grep -i 14e4:43ba                            # the BCM43602
journalctl -k -b | grep -iE 'brcmf.*(clm_blob|Firmware:)'# "no clm_blob available" + firmware 7.35.177.61
ls /usr/lib/firmware/updates/brcm/ /usr/lib/firmware/brcm/ 2>/dev/null | grep 43602-pcie.txt   # empty = not fixed
iw phy | grep -c 'Band 2'                                 # 0 = no 5 GHz -> needs the fix
grep '^WIRELESS_REGDOM' /etc/conf.d/wireless-regdom       # country
iw dev; iw dev <if> link                                  # band, signal, bitrates
```

Telltales of the unfixed state: only 2.4 GHz networks in `nmcli dev wifi list`, signal around -74 dBm even near the router, `txpower 31.00 dBm` in `iw dev`, and a MAC starting `00:90:4c` (Broadcom placeholder).

## 2. Install

`install.sh` needs sudo. If you can't enter a password, ask the user to run it in a **separate terminal window**. The sudo prompt doesn't work well through an agent's shell.

```bash
sudo ./install.sh                 # country US
sudo ./install.sh --country XX    # if the user wants their real country (see the caveat below)
```

Wi-Fi drops for about 10 seconds. If the user is working over that Wi-Fi (for example over SSH), warn them first. The script prints `OK: 5 GHz band present` at the end.

## 3. Verify

```bash
iw phy | grep -c 'Band 2'               # 1
nmcli -f SSID,CHAN,SIGNAL dev wifi list --rescan yes   # 5 GHz networks (CHAN 36-165) now visible
nmcli con up <name_5G>                  # or connect from the desktop's Wi-Fi menu
iw dev <if> link                        # freq 5xxx, rx bitrate in the hundreds
curl -4 -o /dev/null -w '%{speed_download} B/s\n' https://proof.ovh.net/files/100Mb.dat
```

Make the 5 GHz profile preferred: `nmcli con mod <name_5G> connection.autoconnect-priority 10`.

## If 5 GHz still won't connect

Work through these in order. They are the exact failure modes found on this machine:

0. **Did it work before and suddenly stop, with every join rejected instantly (`ASSOC-REJECT ... status_code=16`)?** Check `journalctl -b -k | grep 'brcmfmac 0000:03:00.0: enabling device'`. If that line is present, the card started in a bad state, most likely after the battery was drained flat. Don't change any config. Have the user charge with a proper charger, then shut down and power on. Details are in docs/lessons-learned.md ("5 GHz refused after the battery ran flat"). If the user needs internet meanwhile, use an iPhone USB tether, and wake the USB-C controllers first if the phone isn't detected (same section).
1. **Is Band 2 present?** If not, the NVRAM file didn't load. Check `journalctl -k -b | grep -i brcmf` for the file being requested, then reboot. Don't read `phy0` after a driver reload: the phy renumbers (phy0 → phy1). Use `cat /sys/class/net/<if>/phy80211/name`.
2. **"network could not be found" + `CTRL-EVENT-SCAN-FAILED ret=-22`** in `journalctl -u wpa_supplicant`: the random-MAC scan problem. Check that `/etc/NetworkManager/conf.d/90-mbp-wifi.conf` exists and run `nmcli general reload conf`.
3. **Scans for ~20 s, sees the network, never tries to join:** a regulatory-domain problem. Turn on wpa_supplicant debug logging, retry, then read the log:
   ```bash
   sudo busctl set-property fi.w1.wpa_supplicant1 /fi/w1/wpa_supplicant1 fi.w1.wpa_supplicant1 DebugLevel s debug
   nmcli con up <name_5G>; journalctl -u wpa_supplicant --since -2min | grep -E 'DISABLED|skip|disabled'
   sudo busctl set-property fi.w1.wpa_supplicant1 /fi/w1/wpa_supplicant1 fi.w1.wpa_supplicant1 DebugLevel s info
   ```
   Lines like `5500[DISABLED] ... 5805[DISABLED]` or "channel disabled" mean the country blocks the router's channel. Find the router's channel (`nmcli -f SSID,CHAN dev wifi list`), then set a country that allows it (`install.sh --country US`). **Check while disconnected.** While connected on 2.4 GHz, the router's own country beacon makes the channels look enabled, and that misled us for a while.

## Things that are NOT the answer (already tried or ruled out)

- **Another driver.** Broadcom `wl` / `broadcom-wl-dkms` doesn't support the BCM43602. `brcmfmac` is the only driver.
- **Finding a `clm_blob`.** Broadcom never released one for the 43602. The warning stays after the fix and is harmless.
- **Driver module options** (`roamoff=1`, `feature_disable`, power save). These don't fix a missing NVRAM file.
- **Extracting Apple's firmware from macOS.** That path works for T2 Macs (BCM4364/4377) but not for this card. The NVRAM text file is all that's needed.
- **Moving closer to the router / changing networks.** -74 dBm at 3 m was the missing calibration, not distance.

More detail, including speed-test pitfalls, is in [docs/lessons-learned.md](docs/lessons-learned.md).

## Ground rules

- Explain what a command will do before asking the user to run something with sudo. Give the undo for each change (`sudo ./install.sh --undo`).
- Don't delete or replace the user's saved Wi-Fi profiles. Add or modify only the 5 GHz one.
- If the user has a USB tether, Ethernet or VPN up, don't restart NetworkManager. Use `nmcli general reload conf`, which `install.sh` already does.
- This Mac also needs the sleep fixes in [mbp14-3-linux-sleep-fix](https://github.com/mihneadevries/mbp14-3-linux-sleep-fix). Its sleep hook unloads and reloads `brcmfmac` around suspend. That's compatible: the NVRAM file loads again on every reload.
- If you learn something new, add it to `docs/lessons-learned.md` so the next agent doesn't have to rediscover it.
