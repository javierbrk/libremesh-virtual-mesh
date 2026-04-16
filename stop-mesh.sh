#!/usr/bin/env bash
set -euo pipefail

# ========= Config (must match start-mesh.sh) =========
SESSION="libremesh_mesh"
LIBREMESH_DIR="${LIBREMESH_DIR:-libremesh-virtual-mesh/images}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

IMAGES=(
  "$LIBREMESH_DIR/vm1-overlay.qcow2"
  "$LIBREMESH_DIR/vm2-overlay.qcow2"
  "$LIBREMESH_DIR/vm3-overlay.qcow2"
  "$LIBREMESH_DIR/vm-test-overlay.qcow2"
  "$LIBREMESH_DIR/base.img"
)

# ========= Helpers =========
step() { echo "[stop-mesh] $*"; }

# ========= Kill QEMU processes =========
kill_qemus() {
  local pids
  # Find all qemu-system-x86_64 processes that are using our overlay images
  pids=$(pgrep -f "$QEMU_BIN" 2>/dev/null || true)
  if [[ -z "$pids" ]]; then
    step "No running QEMU processes found."
    return
  fi
  step "Sending SIGTERM to QEMU pids: $pids"
  echo "$pids" | xargs kill -TERM 2>/dev/null || true
  # Give them 3 s to exit cleanly, then force-kill
  sleep 3
  local remaining
  remaining=$(pgrep -f "$QEMU_BIN" 2>/dev/null || true)
  if [[ -n "$remaining" ]]; then
    step "Force-killing remaining QEMU pids: $remaining"
    echo "$remaining" | xargs kill -KILL 2>/dev/null || true
  fi
  step "QEMU processes stopped."
}

# ========= Kill vwifi-server =========
kill_vwifi() {
  local pids
  pids=$(pgrep -f "vwifi-server" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    step "Stopping vwifi-server (pids: $pids)"
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
  fi
}

# ========= Kill tmux session =========
kill_tmux() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    step "Killing tmux session '$SESSION'"
    tmux kill-session -t "$SESSION"
  else
    step "tmux session '$SESSION' not found (already gone)."
  fi
}

# ========= Delete generated images =========
delete_images() {
  step "Deleting generated image files:"
  for f in "${IMAGES[@]}"; do
    if [[ -f "$f" ]]; then
      echo "  rm $f"
      rm -f "$f"
    else
      echo "  (not found) $f"
    fi
  done
  step "Done."
}

# ========= Main =========
WIPE=0
for arg in "$@"; do
  case "$arg" in
    --wipe|-w) WIPE=1 ;;
    --help|-h)
      echo "Usage: $0 [--wipe|-w]"
      echo "  (no flags)   Kill QEMU VMs, vwifi-server, and the tmux session."
      echo "  --wipe / -w  Also delete all generated image files (overlays + base.img)."
      exit 0
      ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

kill_qemus
kill_vwifi
kill_tmux

if [[ "$WIPE" -eq 1 ]]; then
  delete_images
else
  step "Image files kept. Run with --wipe to delete them too."
fi
