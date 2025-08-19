#!/usr/bin/env bash
set -euo pipefail

# qemu-windows-vnc: Create and run a Windows VM on QEMU/KVM with VNC access (safe, non-destructive).
# Usage:
#   ./script.sh install --win-iso /path/Win.iso --virtio-iso /path/virtio-win.iso [options]
#   ./script.sh run [options]
#
# Common options:
#   --disk PATH           Path to VM disk (qcow2). Default: $HOME/win.qcow2
#   --size SIZE           Disk size for 'install' if disk does not exist (e.g., 80G). Default: 80G
#   --cpus N              vCPU count. Default: 4
#   --mem MB              Memory (MiB). Default: 8192
#   --vnc HOST:DISPLAY    VNC bind host and display. Default: 127.0.0.1:1  (port 5901, LOCAL ONLY)
#   --vnc-password        Require VNC password (set interactively via QEMU monitor)
#   --monitor PORT        Monitor telnet port to control the VM. Default: 9001 (localhost)
#   --uefi/--no-uefi      Enable/disable UEFI via OVMF if available. Default: enabled if OVMF present
#   --rdp                 Forward host TCP 3389 to guest 3389 (use after enabling RDP in Windows)
#   --name NAME           QEMU VM name. Default: winvm
#
# Examples:
#   Install (with two ISOs attached):
#     ./script.sh install --win-iso ~/ISO/Win10.iso --virtio-iso ~/ISO/virtio-win.iso --disk ~/win.qcow2 --size 80G
#
#   Run from disk (after Windows installation completes):
#     ./script.sh run --disk ~/win.qcow2 --vnc 127.0.0.1:1 --rdp
#
# SECURITY NOTES:
# - By default VNC listens on 127.0.0.1 (localhost). Use SSH tunnel from your client:
#     ssh -L 5901:127.0.0.1:5901 user@host
#     Then connect your viewer to: 127.0.0.1:5901
# - If you pass --vnc-password, QEMU will require a password. Set it via the monitor:
#     telnet 127.0.0.1 9001
#     (qemu) change vnc password
#     Password: ********
# - This script does NOT write to physical disks. It only touches the qcow2 image you specify.
#
# Tested on: Ubuntu/Debian based hosts with qemu-kvm, qemu-utils, ovmf installed.

die() { echo "Error: $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  for c in qemu-system-x86_64 qemu-img; do
    have_cmd "$c" || die "Missing dependency: $c (install qemu-kvm and qemu-utils)"
  done
}

# Defaults
DISK="${HOME}/win.qcow2"
SIZE="80G"
CPUS=4
MEM=8192
VNC_HOST="127.0.0.1"
VNC_DISPLAY="1"      # 5901
VNC_PASSWORD="no"
MON_PORT=9001
NAME="winvm"
USE_UEFI="auto"
FORWARD_RDP="no"
WIN_ISO=""
VIRTIO_ISO=""

SUBCMD="${1:-}"
[[ -n "${SUBCMD}" ]] || { echo "Usage: $0 {install|run} [options]"; exit 1; }
shift || true

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    --mem)  MEM="$2"; shift 2;;
    --vnc)  # format host:display  e.g., 127.0.0.1:1 or :1 or 0.0.0.0:5
      VAL="$2"; shift 2
      if [[ "$VAL" == :* ]]; then
        VNC_HOST=""; VNC_DISPLAY="${VAL#:}"
      else
        VNC_HOST="${VAL%%:*}"; VNC_DISPLAY="${VAL##*:}"
      fi
      ;;
    --vnc-password) VNC_PASSWORD="yes"; shift;;
    --monitor) MON_PORT="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --uefi) USE_UEFI="yes"; shift;;
    --no-uefi) USE_UEFI="no"; shift;;
    --rdp) FORWARD_RDP="yes"; shift;;
    --win-iso) WIN_ISO="$2"; shift 2;;
    --virtio-iso) VIRTIO_ISO="$2"; shift 2;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *)
      die "Unknown option: $1 (use --help)";;
  esac
done

ensure_deps

# OVMF detection
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
OVMF_VARS_DIR="${HOME}/.local/share/qemu"
OVMF_VARS="${OVMF_VARS_DIR}/win_VARS.fd"

detect_uefi() {
  if [[ "${USE_UEFI}" == "no" ]]; then
    echo "no"; return
  fi
  if [[ -f "${OVMF_CODE}" ]]; then
    mkdir -p "${OVMF_VARS_DIR}"
    [[ -f "${OVMF_VARS}" ]] || cp /usr/share/OVMF/OVMF_VARS.fd "${OVMF_VARS}" 2>/dev/null || true
    echo "yes"
  else
    if [[ "${USE_UEFI}" == "yes" ]]; then
      die "Requested --uefi but OVMF not found at ${OVMF_CODE}. Install package 'ovmf'."
    fi
    echo "no"
  fi
}

UEFI_ON="$(detect_uefi)"

# Common args
QEMU_BIN="qemu-system-x86_64"
MACHINE_OPTS="-machine q35,accel=kvm -cpu host -smp ${CPUS} -m ${MEM}"
NAME_OPTS="-name ${NAME}"
MONITOR_OPTS="-monitor telnet:127.0.0.1:${MON_PORT},server,nowait"
DISPLAY_OPTS="-display none"

# VNC opts
if [[ -n "${VNC_HOST}" ]]; then
  VNC_BIND="${VNC_HOST}:${VNC_DISPLAY}"
else
  VNC_BIND=":${VNC_DISPLAY}"
fi
if [[ "${VNC_PASSWORD}" == "yes" ]]; then
  VNC_OPTS="-vnc ${VNC_BIND},password"
else
  VNC_OPTS="-vnc ${VNC_BIND}"
fi

# Net opts
if [[ "${FORWARD_RDP}" == "yes" ]]; then
  NIC_OPTS="-nic user,model=virtio-net-pci,hostfwd=tcp::3389-:3389"
else
  NIC_OPTS="-nic user,model=virtio-net-pci"
fi

# Disk (virtio) opts
DISK_OPTS="-drive file=${DISK},if=virtio,format=qcow2,discard=unmap,cache=none"

# UEFI opts (if enabled)
UEFI_OPTS=""
if [[ "${UEFI_ON}" == "yes" ]]; then
  UEFI_OPTS="-drive if=pflash,format=raw,readonly=on,file=${OVMF_CODE} -drive if=pflash,format=raw,file=${OVMF_VARS}"
fi

# Subcommands
case "${SUBCMD}" in
  install)
    [[ -n "${WIN_ISO}" ]] || die "--win-iso is required for 'install'"
    [[ -f "${WIN_ISO}" ]] || die "Windows ISO not found: ${WIN_ISO}"
    [[ -n "${VIRTIO_ISO}" ]] || die "--virtio-iso is required for 'install'"
    [[ -f "${VIRTIO_ISO}" ]] || die "virtio-win ISO not found: ${VIRTIO_ISO}"

    if [[ ! -f "${DISK}" ]]; then
      echo "Creating qcow2 disk at ${DISK} (size ${SIZE}) ..."
      qemu-img create -f qcow2 "${DISK}" "${SIZE}" >/dev/null
    else
      echo "Disk already exists at ${DISK} (will reuse)."
    fi

    echo
    echo "Starting Windows installer..."
    echo "  VNC: ${VNC_BIND}  (DEFAULT BINDS TO LOCALHOST)"
    if [[ "${VNC_PASSWORD}" == "yes" ]]; then
      echo "  To set VNC password: telnet 127.0.0.1 ${MON_PORT}  ->  'change vnc password'"
    fi
    echo "  Monitor (telnet): 127.0.0.1:${MON_PORT}"
    echo "  UEFI: ${UEFI_ON}"
    echo

    exec ${QEMU_BIN} \
      -enable-kvm \
      ${MACHINE_OPTS} \
      ${NAME_OPTS} \
      ${UEFI_OPTS} \
      ${DISK_OPTS} \
      -drive file="${WIN_ISO}",media=cdrom,if=ide \
      -drive file="${VIRTIO_ISO}",media=cdrom,if=ide \
      -boot order=d \
      ${NIC_OPTS} \
      ${VNC_OPTS} \
      ${MONITOR_OPTS} \
      ${DISPLAY_OPTS}
    ;;

  run)
    [[ -f "${DISK}" ]] || die "Disk image not found at ${DISK}. Did you run 'install' first?"
    echo
    echo "Booting Windows VM from disk..."
    echo "  VNC: ${VNC_BIND}"
    if [[ "${VNC_PASSWORD}" == "yes" ]]; then
      echo "  To set VNC password: telnet 127.0.0.1 ${MON_PORT}  ->  'change vnc password'"
    fi
    echo "  Monitor (telnet): 127.0.0.1:${MON_PORT}"
    echo "  UEFI: ${UEFI_ON}"
    echo

    exec ${QEMU_BIN} \
      -enable-kvm \
      ${MACHINE_OPTS} \
      ${NAME_OPTS} \
      ${UEFI_OPTS} \
      ${DISK_OPTS} \
      -boot order=c \
      ${NIC_OPTS} \
      ${VNC_OPTS} \
      ${MONITOR_OPTS} \
      ${DISPLAY_OPTS} \
      -daemonize
    ;;

  *)
    die "Unknown subcommand: ${SUBCMD} (use install|run)"
    ;;
esac
