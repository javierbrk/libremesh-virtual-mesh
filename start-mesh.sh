#!/usr/bin/env bash
set -euo pipefail
set -x


# ========= Config =========
SESSION="libremesh_mesh"         # tmux session name (when starting outside tmux)
WINDOW="VM_network"                # tmux window name (created inside current session if already in tmux)

BASE_IMAGE_GZ="${BASE_IMAGE_GZ:-bin/targets/x86/64/openwrt-x86-64-generic-ext4-combined.img.gz}"
LIBREMESH_DIR="${LIBREMESH_DIR:-libremesh-virtual-mesh/images}"
RAW_IMAGE="$LIBREMESH_DIR/base.img"
VM1_IMAGE="$LIBREMESH_DIR/vm1-overlay.qcow2"
VM2_IMAGE="$LIBREMESH_DIR/vm2-overlay.qcow2"
VM3_IMAGE="$LIBREMESH_DIR/vm3-overlay.qcow2"
VM_TEST="$LIBREMESH_DIR/vm-test-overlay.qcow2"

SETUP_VM_CMD=${SETUP_VM_CMD:-libremesh-virtual-mesh/setup-vm.sh}

VWIFI_CMD="${VWIFI_CMD:-vwifi-server -u}"   # pane 0
VM1_SSH_PORT=2201                           # pane 1
VM2_SSH_PORT=2202                           # pane 2
VM3_SSH_PORT=2203                           # pane 3

# QEMU common
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
QEMU_COMMON=(-enable-kvm -M q35 -cpu host -smp 2 -m 512M -nographic)

# SSH options (this prevents fingerprints errors when rerunning multiple times)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2)

# If you re-build the base image, set RECREATE_OVERLAYS=1 to force fresh overlays
RECREATE_OVERLAYS="${RECREATE_OVERLAYS:-0}"

# ========= Helpers =========
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found."; exit 1; }; }

prepare_images() {
  require gzip
  require "$QEMU_IMG"
  
  # Ensure the directory that will hold VM images exists
  mkdir -p "$LIBREMESH_DIR"

  if [[ ! -f "$BASE_IMAGE_GZ" ]]; then
    echo "ERROR: $BASE_IMAGE_GZ not found. Build OpenWrt first."
    exit 1
  fi

  # (Re)decompress raw base image if missing or older than gz
  if [[ ! -f "$RAW_IMAGE" || "$BASE_IMAGE_GZ" -nt "$RAW_IMAGE" ]]; then
    echo "[+] Decompressing base image -> $RAW_IMAGE"
    set +e
    gzip -dc "$BASE_IMAGE_GZ" > "$RAW_IMAGE".tmp
    status=$?
    set -e
    if [[ $status -ne 0 && $status -ne 2 ]]; then
	echo "ERROR: gzip failed (exit $status)" >&2
        rm -f "$RAW_IMAGE".tmp
        exit $status
    fi
    mv "$RAW_IMAGE".tmp "$RAW_IMAGE"
    # Force overlay recreation if base changed
    RECREATE_OVERLAYS=1
  fi

  local RAW_ABS
  RAW_ABS="$(realpath "$RAW_IMAGE")"

  # Create/recreate overlays
  if [[ "$RECREATE_OVERLAYS" == "1" && -f "$VM1_IMAGE" ]]; then rm -f "$VM1_IMAGE"; fi
  if [[ "$RECREATE_OVERLAYS" == "1" && -f "$VM2_IMAGE" ]]; then rm -f "$VM2_IMAGE"; fi
  if [[ "$RECREATE_OVERLAYS" == "1" && -f "$VM3_IMAGE" ]]; then rm -f "$VM3_IMAGE"; fi
  if [[ "$RECREATE_OVERLAYS" == "1" && -f "$VM_TEST" ]]; then rm -f "$VM_TEST"; fi

  if [[ ! -f "$VM1_IMAGE" ]]; then
    echo "[+] Creating overlay $VM1_IMAGE"
    "$QEMU_IMG" create -f qcow2 -F raw -b "$RAW_ABS" "$VM1_IMAGE" >/dev/null
  fi
  if [[ ! -f "$VM2_IMAGE" ]]; then
    echo "[+] Creating overlay $VM2_IMAGE"
    "$QEMU_IMG" create -f qcow2 -F raw -b "$RAW_ABS" "$VM2_IMAGE" >/dev/null
  fi
  if [[ ! -f "$VM3_IMAGE" ]]; then
    echo "[+] Creating overlay $VM3_IMAGE"
    "$QEMU_IMG" create -f qcow2 -F raw -b "$RAW_ABS" "$VM3_IMAGE" >/dev/null
  fi
  if [[ ! -f "$VM_TEST" ]]; then
    echo "[+] Creating overlay $VM_TEST"
    "$QEMU_IMG" create -f qcow2 -F raw -b "$RAW_ABS" "$VM_TEST" >/dev/null
  fi
}

start_tmux_env() {
  require tmux
  if [[ -n "${TMUX:-}" ]]; then
      # We are already inside tmux, so create a brand‑new window
      CUR_SESSION="$(tmux display-message -p '#S')"
  
      # -a  → automatically pick the lowest unused window index
      # -P  → print the new window's target
      # -F  → choose what is printed; we want "session:window_index"
      TARGET="$(tmux new-window -a -P -F '#{session_name}:#{window_index}' \
                                -n "$WINDOW" -c "$PWD" -t "$CUR_SESSION")"
  else
      # ---------- outside‑tmux path ----------
      tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"
      tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$PWD"
      TARGET="$SESSION:0"
  fi
  # Enable mouse (click to select pane, drag to resize, scroll)
  tmux set-option -t "$TARGET" -g mouse on
}


pane() { echo "$TARGET.$1"; }

send() {
  local pane_id="$1"; shift
  tmux send-keys -t "$pane_id" "$@" C-m
}

qemu_cmd() {
  local image="$1" mac="$2" ssh_port="$3" last_octet="$4"
  echo "$QEMU_BIN ${QEMU_COMMON[*]}" \
    "-drive file=$image,if=virtio,format=qcow2" \
    "-device virtio-net-pci,mac=$mac,netdev=mesh0" \
    "-netdev user,id=mesh0,net=10.13.0.0/16,hostfwd=tcp::${ssh_port}-10.13.0.1:22" \
    "-device virtio-net-pci,netdev=wan0" \
    "-netdev user,id=wan0"
}

launch() {
  require "$QEMU_BIN"

  # Pane 0: vwifi-server (or warn)
  send "$(pane 0)" "command -v ${VWIFI_CMD%% *} >/dev/null && $VWIFI_CMD || echo 'vwifi-server not found; skipping'"

  # Create other panes and layout
  tmux split-window -h -t "$TARGET"          # pane 1 (right)
  tmux split-window -v -t "$(pane 1)"        # pane 2 (below pane 1)
  tmux split-window -v -t "$(pane 0)"        # pane 3 (below pane 0)
  tmux select-layout -t "$TARGET" tiled

  # Pane 1: VM1
  send "$(pane 1)" "$(qemu_cmd "$VM1_IMAGE" 52:54:00:00:00:01 $VM1_SSH_PORT 1)"

  # Pane 2: VM2
  send "$(pane 2)" "$(qemu_cmd "$VM2_IMAGE" 52:54:00:00:00:02 $VM2_SSH_PORT 2)"

  # Pane 3: VM3
  send "$(pane 3)" "$(qemu_cmd "$VM3_IMAGE" 52:54:00:00:00:03 $VM3_SSH_PORT 3)"
}

wait_for_ssh() {
  local port=$1
  echo "Waiting for SSH on port $port"
  until ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$port" root@127.0.0.1 true 2>/dev/null; do
  sleep 1
  done
  echo "SSH is up on $port"
}

setup_ssh() {
  wait_for_ssh $1
  echo "$SETUP_VM_CMD $1"
  "$SETUP_VM_CMD" $1
}

# Open the tmux session in a new X terminal so the calling terminal stays
# free to show setup_ssh progress (set -x output).
open_tmux_window() {
  if [[ -n "${TMUX:-}" ]]; then
    # Already inside tmux: just switch to the new window
    tmux select-window -t "$TARGET"
    return
  fi
  # Outside tmux: spawn a new terminal with the session attached
  local cmd="tmux attach -t $SESSION"
  if   command -v gnome-terminal  &>/dev/null; then
    gnome-terminal -- bash -c "$cmd; exec bash" &
  elif command -v xterm           &>/dev/null; then
    xterm -e "$cmd" &
  elif command -v konsole         &>/dev/null; then
    konsole -e "$cmd" &
  elif command -v xfce4-terminal  &>/dev/null; then
    xfce4-terminal -e "$cmd" &
  else
    echo "[!] No X terminal found. Attach manually: tmux attach -t $SESSION"
  fi
}

# ========= cssh mode helpers =========

launch_background() {
  require "$QEMU_BIN"
  local logdir="$LIBREMESH_DIR/logs"
  mkdir -p "$logdir"

  # Start vwifi-server in background if available
  if command -v "${VWIFI_CMD%% *}" >/dev/null 2>&1; then
    echo "[+] Starting vwifi-server"
    $VWIFI_CMD >"$logdir/vwifi.log" 2>&1 &
    echo $! >"$logdir/vwifi.pid"
  else
    echo "[!] vwifi-server not found; skipping"
  fi

  echo "[+] Starting VM1 in background (log: $logdir/vm1.log)"
  bash -c "$(qemu_cmd "$VM1_IMAGE" 52:54:00:00:00:01 $VM1_SSH_PORT 1)" \
    >"$logdir/vm1.log" 2>&1 &
  echo $! >"$logdir/vm1.pid"

  echo "[+] Starting VM2 in background (log: $logdir/vm2.log)"
  bash -c "$(qemu_cmd "$VM2_IMAGE" 52:54:00:00:00:02 $VM2_SSH_PORT 2)" \
    >"$logdir/vm2.log" 2>&1 &
  echo $! >"$logdir/vm2.pid"

  echo "[+] Starting VM3 in background (log: $logdir/vm3.log)"
  bash -c "$(qemu_cmd "$VM3_IMAGE" 52:54:00:00:00:03 $VM3_SSH_PORT 3)" \
    >"$logdir/vm3.log" 2>&1 &
  echo $! >"$logdir/vm3.pid"
}

# Write a temporary ssh_config so cssh can reach each VM by alias
write_ssh_config() {
  local cfg="$LIBREMESH_DIR/mesh_ssh_config"
  cat >"$cfg" <<EOF
Host vm1
    HostName 127.0.0.1
    Port $VM1_SSH_PORT
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host vm2
    HostName 127.0.0.1
    Port $VM2_SSH_PORT
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host vm3
    HostName 127.0.0.1
    Port $VM3_SSH_PORT
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
  echo "$cfg"
}

# ========= Entry points =========

main_tmux() {
  prepare_images
  start_tmux_env
  launch

  # Open the 4-pane tmux window in a NEW X terminal so this terminal
  # stays open and shows set -x / setup_ssh progress.
  open_tmux_window

  # Run setup in parallel background jobs — output (and set -x trace)
  # all appears here in the calling terminal.
  setup_ssh $VM1_SSH_PORT &
  PID1=$!
  setup_ssh $VM2_SSH_PORT &
  PID2=$!
  setup_ssh $VM3_SSH_PORT &
  PID3=$!

  RC=0
  wait $PID1 || { echo "ERROR: setup_ssh $VM1_SSH_PORT failed"; RC=1; }
  wait $PID2 || { echo "ERROR: setup_ssh $VM2_SSH_PORT failed"; RC=1; }
  wait $PID3 || { echo "ERROR: setup_ssh $VM3_SSH_PORT failed"; RC=1; }
  [[ $RC -eq 0 ]] || exit $RC
  echo "[+] All VMs configured successfully."
}

main_cssh() {
  require cssh
  prepare_images
  launch_background

  echo "[+] Waiting for all VMs to become reachable..."
  setup_ssh $VM1_SSH_PORT &
  PID1=$!
  setup_ssh $VM2_SSH_PORT &
  PID2=$!
  setup_ssh $VM3_SSH_PORT &
  PID3=$!

  RC=0
  wait $PID1 || { echo "ERROR: setup_ssh $VM1_SSH_PORT failed"; RC=1; }
  wait $PID2 || { echo "ERROR: setup_ssh $VM2_SSH_PORT failed"; RC=1; }
  wait $PID3 || { echo "ERROR: setup_ssh $VM3_SSH_PORT failed"; RC=1; }
  [[ $RC -eq 0 ]] || exit $RC

  local cfg
  cfg="$(write_ssh_config)"
  echo "[+] Launching cssh (config: $cfg)"
  cssh -o "-F $cfg" vm1 vm2 vm3
}

usage() {
  echo "Usage: $0 [--cssh]"
  echo "  (default)  Launch VMs in a tmux session with 4 panes."
  echo "  --cssh     Launch VMs in the background and open cssh for all three."
}

# ---- dispatch ----
MODE=tmux
for arg in "$@"; do
  case "$arg" in
    --cssh)   MODE=cssh ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; usage; exit 1 ;;
  esac
done

case "$MODE" in
  tmux) main_tmux ;;
  cssh) main_cssh ;;
esac
