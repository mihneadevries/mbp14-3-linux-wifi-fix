#!/bin/bash
# Fix slow / 2.4 GHz-only Wi-Fi on the 2017 15" MacBook Pro (MacBookPro14,3,
# Broadcom BCM43602 [14e4:43ba], brcmfmac driver) under Linux.
#
#   sudo ./install.sh                 install (Wi-Fi country = US)
#   sudo ./install.sh --country DE    install with another Wi-Fi country
#   sudo ./install.sh --undo          remove everything this script installed
#   sudo ./install.sh --force         install on a machine without a BCM43602
#
# Three changes, all outside package-managed files except the regdom line:
#   1. /usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt  (board NVRAM / calibration)
#   2. /etc/NetworkManager/conf.d/90-mbp-wifi.conf            (no random MAC while scanning)
#   3. WIRELESS_REGDOM in /etc/conf.d/wireless-regdom         (Wi-Fi country, VN -> US here)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"

NVRAM=/usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt
NMCONF=/etc/NetworkManager/conf.d/90-mbp-wifi.conf
LEGACY_NMCONF=/etc/NetworkManager/conf.d/90-wlp3s0-no-scan-rand.conf
REGDOM=/etc/conf.d/wireless-regdom
REGDOM_BAK=/etc/conf.d/wireless-regdom.before-mbp-wifi-fix
# MikeRatcliffe's gist, pinned to one revision and checked by hash.
NVRAM_URL=https://gist.githubusercontent.com/MikeRatcliffe/9614c16a8ea09731a9d5e91685bd8c80/raw/38180b6a0ce552e1a3a2826ffea2bf1f52d05e9f/brcmfmac43602-pcie.txt
NVRAM_SHA256=b109f3e6663b0e888c2559e36f7e0109f2a3a6b9765786d11f849f16d4b32d06

say() { printf '==> %s\n' "$*"; }

wifi_if() {  # first network interface bound to brcmfmac
  local d
  for d in /sys/class/net/*; do
    [[ $(readlink -f "$d/device/driver" 2>/dev/null) == */brcmfmac ]] && { basename "$d"; return; }
  done
}

reload_driver() {
  say "reloading brcmfmac (Wi-Fi drops for ~10 s)"
  modprobe -r brcmfmac_wcc 2>/dev/null || true
  modprobe -r brcmfmac
  sleep 1
  modprobe brcmfmac
  local i
  for i in $(seq 20); do [[ -n $(wifi_if) ]] && break; sleep 1; done
}

COUNTRY=US FORCE=0 UNDO=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --undo) UNDO=1 ;;
    --force) FORCE=1 ;;
    --country) COUNTRY=${2^^}; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if (( UNDO )); then
  rm -fv "$NVRAM" "$NMCONF" "$LEGACY_NMCONF"
  if [[ -f $REGDOM_BAK ]]; then
    mv -v "$REGDOM_BAK" "$REGDOM"
    old=$(sed -n 's/^WIRELESS_REGDOM="\(..\)".*/\1/p' "$REGDOM")
    [[ -n $old ]] && iw reg set "$old"
  fi
  nmcli general reload conf 2>/dev/null || true
  reload_driver
  say "Removed. Rebooting is the cleanest way to be sure the old state is back."
  exit 0
fi

[[ $COUNTRY =~ ^[A-Z]{2}$ ]] || { echo "--country needs a 2-letter code, got '$COUNTRY'" >&2; exit 1; }
if ! lspci -nn 2>/dev/null | grep -qi '14e4:43ba' && (( ! FORCE )); then
  echo "No BCM43602 [14e4:43ba] found. This fix is only for that card." >&2
  echo "Read the README, then re-run with --force if you want it anyway." >&2
  exit 1
fi
model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
[[ $model == MacBookPro14,3 ]] || say "note: tested on MacBookPro14,3, this is '$model' (same card, should be fine)"

# 1. NVRAM. Keep the MAC the card has now (the gist ships macaddr=xx:...).
IF=$(wifi_if)
[[ -n $IF ]] || { echo "No brcmfmac interface found. Is the driver loaded? (modprobe brcmfmac)" >&2; exit 1; }
MAC=$(cat "/sys/class/net/$IF/address")
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [[ -f files/brcmfmac43602-pcie.txt ]]; then
  say "NVRAM: using local files/brcmfmac43602-pcie.txt"
  cp files/brcmfmac43602-pcie.txt "$tmp"
else
  say "NVRAM: downloading pinned gist revision"
  curl -fsSL -o "$tmp" "$NVRAM_URL"
  echo "$NVRAM_SHA256  $tmp" | sha256sum -c --quiet - || {
    echo "Checksum mismatch. See docs/lessons-learned.md for fallbacks." >&2; exit 1; }
fi
sed -i "s/^macaddr=.*/macaddr=$MAC/" "$tmp"
install -Dm644 "$tmp" "$NVRAM"
say "NVRAM installed at $NVRAM (macaddr=$MAC)"

# 2. NetworkManager: no random MAC while scanning.
say "NetworkManager: scan-rand-mac-address=no for brcmfmac"
rm -f "$LEGACY_NMCONF"
install -Dm644 files/90-mbp-wifi.conf "$NMCONF"
nmcli general reload conf 2>/dev/null || say "NetworkManager not running; config applies on its next start"

# 3. Wi-Fi country.
if [[ -f $REGDOM ]]; then
  [[ -f $REGDOM_BAK ]] || cp -a "$REGDOM" "$REGDOM_BAK"
  if grep -q '^WIRELESS_REGDOM=' "$REGDOM"; then
    sed -i "s/^WIRELESS_REGDOM=.*/WIRELESS_REGDOM=\"$COUNTRY\"/" "$REGDOM"
  else
    echo "WIRELESS_REGDOM=\"$COUNTRY\"" >>"$REGDOM"
  fi
  say "Wi-Fi country: $COUNTRY (in $REGDOM)"
else
  say "no $REGDOM (not Arch?): set the country permanently your distro's way; applying for this boot only"
fi
iw reg set "$COUNTRY"

# Load the new NVRAM now.
reload_driver
IF=$(wifi_if)
phy=$(cat "/sys/class/net/$IF/phy80211/name" 2>/dev/null || true)
if [[ -n $phy ]] && iw phy "$phy" info | grep -q 'Band 2'; then
  say "OK: 5 GHz band present on $phy ($IF)"
else
  say "WARNING: 5 GHz band not visible yet. Reboot, then check: iw phy | grep -c 'Band 2'"
fi
say "Done. Join the 5 GHz network (often named <name>_5G) and prefer it."
