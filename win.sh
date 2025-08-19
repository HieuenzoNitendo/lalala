#!/usr/bin/env bash
set -euo pipefail

# =====================
# QEMU Windows Runner
# =====================
# This script downloads (if needed) and runs a Windows image with QEMU,
# exposing display via VNC.
#
# Defaults can be overridden via environment variables:
#   IMG_URL, IMG_PATH, RAM, CPU, VNC_DISPLAY, VNC_ADDR
#
# Example:
#   RAM=6G CPU=4 VNC_DISPLAY=2 ./run_windows.sh
#
# VNC endpoint: vnc://<VNC_ADDR>:59<VNC_DISPLAY>
#
# =====================

# --- Config (override with env vars) ---
IMG_URL="${IMG_URL:-https://www.dropbox.com/scl/fi/2uoa2y5eiumfo1g3xlxlm/Win10Lite.img?rlkey=10f38hfgtkquiugyjbaxwfwum&st=4y6g1xuh&dl=1}"
IMG_PATH="${IMG_PATH:-$PWD/Win10Lite.img}"
RAM="${RAM:-4G}"
CPU="${CPU:-2}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"         # means TCP port 5900 + DISPLAY (e.g. 5901)
VNC_ADDR="${VNC_ADDR:-127.0.0.1}"       # change to 0.0.0.0 if you really need remote access

# --- Helpers ---
have() { command -v "$1" >/dev/null 2>&1; }

need_root_install() {
  # Attempt apt install if root and apt available
  if [ "$(id -u)" -eq 0 ] && have apt-get; then
    apt-get update -y
    apt-get install -y qemu-system-x86 wget
  else
    echo "Please install dependencies manually: qemu-system-x86_64, wget"
    exit 1
  fi
}

ensure_deps() {
  have wget || need_root_install
  have qemu-system-x86_64 || need_root_install
}

download_img_if_missing() {
  if [ ! -f "$IMG_PATH" ]; then
    echo "[+] Downloading Windows image to $IMG_PATH"
    mkdir -p "$(dirname "$IMG_PATH")"
    wget -O "$IMG_PATH" "$IMG_URL"
    echo "[+] Download complete."
  else
    echo "[=] Found existing image at $IMG_PATH"
  fi
}

detect_kvm() {
  if [ -e /dev/kvm ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
      echo "kvm"
    else
      # Try to add current user to kvm group (if possible)
      if have sudo; then
        sudo usermod -aG kvm "$(whoami)" || true
      fi
      echo "kvm-maybe"
    fi
  else
    echo "tcg"
  fi
}

run_qemu() {
  local accel cpu_model kvm_state
  kvm_state="$(detect_kvm)"
  case "$kvm_state" in
    kvm)
      accel="kvm"
      cpu_model="host"
      ;;
    kvm-maybe)
      accel="kvm:tcg"
      cpu_model="host"
      echo "[!] /dev/kvm present but not accessible; trying kvm first, will fallback to tcg."
      ;;
    *)
      accel="tcg"
      cpu_model="qemu64"
      echo "[!] /dev/kvm not found. Falling back to software emulation (tcg)."
      ;;
  esac

  local vnc_arg="${VNC_ADDR}:${VNC_DISPLAY}"
  # Properly compute port number for the hint (5900 + DISPLAY)
  local vnc_port=$((5900 + VNC_DISPLAY))
  local vnc_hint="vnc://${VNC_ADDR}:${vnc_port}"

  echo "[+] Starting QEMU..."
  echo "    RAM=$RAM, CPU cores=$CPU, accel=$accel"
  echo "    Image: $IMG_PATH"
  echo "    VNC:   $vnc_hint"
  echo

  # Add a USB controller for q35 (otherwise usb-tablet fails)
  # Note: use if=ide for broad compatibility with existing Windows images
  # If your image already has virtio drivers, you can switch to if=virtio for better performance.
  exec qemu-system-x86_64 \
    -machine type=q35,accel="$accel" \
    -cpu "$cpu_model" \
    -smp "$CPU" \
    -m "$RAM" \
    -rtc base=localtime \
    -boot c \
    -drive file="$IMG_PATH",if=ide,format=raw,cache=writeback \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -device virtio-keyboard-pci \
    -netdev user,id=n1,hostfwd=tcp::3389-:3389 \
    -device e1000,netdev=n1 \
    -display none \
    -vnc "$vnc_arg" \
    -no-reboot
}

main() {
  echo "=== QEMU Windows Runner ==="
  ensure_deps
  download_img_if_missing

  # Quick size check
  if [ -f "$IMG_PATH" ]; then
    echo "[=] Image size: $(du -h "$IMG_PATH" | awk '{print $1}')"
  fi

  run_qemu
}

main "$@"
