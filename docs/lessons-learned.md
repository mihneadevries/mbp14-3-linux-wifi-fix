# Lessons learned

These notes come from the original debugging session (Nov 2026) on a MacBookPro14,3 with a BCM43602. They cover what misled us and what to skip next time.

## Diagnosis

- **The real signal was the missing NVRAM, not distance.** -74 dBm from a router 3 m away, `txpower 31.00 dBm` and the MAC `00:90:4c:...` all point to a card running without board data. After the NVRAM file, the same spot measured -58 dBm on 2.4 GHz.
- **`no clm_blob available` is a red herring for the fix.** It's printed before and after. `linux-firmware` has clm_blobs for the 4356, 43570 and others, but never for the 43602.
- **`iw dev <if> link` rx bitrate is the last received frame only.** It jumps around. Trust it only when a real download agrees.
- **TX vs RX asymmetry** (tx 104 Mbit/s, rx 13 Mbit/s before the fix) means the router hears the laptop fine but the laptop's reception is bad. That fits the missing calibration.

## Pitfalls while fixing

- **The phy renumbers after `modprobe -r brcmfmac && modprobe brcmfmac`** (phy0 → phy1). A check against `phy0` fails with `command failed: No such file or directory (-2)` even though the fix worked. Resolve the phy from `/sys/class/net/<if>/phy80211/name`.
- **Unload `brcmfmac_wcc` before `brcmfmac`.** On newer kernels it depends on `brcmfmac` and blocks the unload.
- **The country problem only shows while disconnected.** With the laptop on the router's 2.4 GHz, `iw reg get` and `iw phy` show the 5 GHz channels as usable because of the router's country beacon. The channels switch off at the moment of disconnecting to join 5 GHz. Only wpa_supplicant debug output showed it.
- **The NetworkManager random-MAC scan failure looks like "network not found".** 2.4 GHz kept connecting from cached scan results, which made it look like a 5 GHz-specific problem.
- **Don't restart NetworkManager while another link (USB tether, Ethernet) carries the session.** `nmcli general reload conf` rereads `conf.d` without touching active connections.
- **A saved 5 GHz profile that can't connect makes NetworkManager keep retrying,** which interrupts the working 2.4 GHz link. Delete it (`nmcli con delete <name>`) until the fixes are in.

## Speed testing

- `speed.cloudflare.com/__down` started throttling to a few bytes per second after repeated large downloads. Use another server, for example `https://proof.ovh.net/files/100Mb.dat`, or the browser.
- Use `curl -4`. On some networks IPv6 is advertised but doesn't route, and the download stalls.
- A distant server (Europe from Asia, for example) caps a single TCP stream well below the link rate. A nearby speed-test server is the better number: 450+ Mbit/s here vs ~130 Mbit/s to a European single-stream server.
- To test Wi-Fi while another link is the default route, bind to it: `curl --interface <wifi-if> ...`.

## NVRAM file fallbacks

`install.sh` downloads MikeRatcliffe's gist pinned to revision `38180b6a0ce552e1a3a2826ffea2bf1f52d05e9f` (SHA-256 `b109f3e6...2d06`). If that gist disappears:

1. [madfatcat88's gist](https://gist.github.com/madfatcat88/fb17a3ef6364a48a19ed57c143ddd383) has an earlier version of the same file.
2. Put any `brcmfmac43602-pcie.txt` you trust in `files/`. `install.sh` uses a local `files/brcmfmac43602-pcie.txt` instead of downloading, and still rewrites `macaddr=`.
3. The file is plain `key=value` text. Read it before installing: it should only contain radio parameters (`boardtype`, `boardrev`, `pa*`, `rxgains*`, `maxp*`, `ccode`, `macaddr` ...).
