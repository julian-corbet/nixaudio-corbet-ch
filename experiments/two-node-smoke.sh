#!/usr/bin/env bash
set -euo pipefail

# Exercise the real PipeWire -> JackTrip -> UDP -> JackTrip -> PipeWire path on one Linux host.
# Network namespaces give both peers independent network stacks, so this uses the same bind/peer
# port on both sides exactly as two physical hosts do. PipeWire exposes and connects the endpoint
# graphs; it is not the network transport.

if [[ ${EUID} -ne 0 ]]; then
  echo "two-node-smoke.sh must run as root (network namespaces are required)" >&2
  exit 2
fi

audio_user=${NIXAUDIO_TEST_USER:-richc}
audio_uid=$(id -u "$audio_user")
runtime_dir=${NIXAUDIO_TEST_RUNTIME_DIR:-/run/user/$audio_uid}
test_tag=$$
namespace_a="nxaudio-a-$test_tag"
namespace_b="nxaudio-b-$test_tag"
veth_a="nxa${test_tag}a"
veth_b="nxa${test_tag}b"
work_dir=$(mktemp -d -t nixaudio-e2e.XXXXXX)
chown "$audio_user" "$work_dir"
server_pid=
client_pid=
capture_pid=
playback_pid=

cleanup() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    for log in "$work_dir"/*.log; do
      [[ -e $log ]] || continue
      echo "--- $(basename "$log") ---" >&2
      sed -n '1,160p' "$log" >&2
    done
  fi
  for pid in "$playback_pid" "$capture_pid" "$client_pid" "$server_pid"; do
    if [[ -n $pid ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  ip netns delete "$namespace_a" 2>/dev/null || true
  ip netns delete "$namespace_b" 2>/dev/null || true
  case $work_dir in
    /tmp/nixaudio-e2e.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT INT TERM

for command in ffmpeg ip jacktrip pw-cat pw-jack pw-link runuser timeout; do
  command -v "$command" >/dev/null || {
    echo "missing command: $command" >&2
    exit 2
  }
done
[[ -S $runtime_dir/pipewire-0 ]] || {
  echo "no PipeWire socket at $runtime_dir/pipewire-0" >&2
  exit 2
}

as_audio_user() {
  runuser -u "$audio_user" -- env \
    PATH="$PATH" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    PIPEWIRE_LATENCY=128/48000 \
    "$@"
}

in_namespace() {
  local namespace=$1
  shift
  ip netns exec "$namespace" runuser -u "$audio_user" -- env \
    PATH="$PATH" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    PIPEWIRE_LATENCY=128/48000 \
    "$@"
}

wait_for_port() {
  local direction=$1
  local wanted=$2
  local line
  for _ in {1..100}; do
    while IFS= read -r line; do
      [[ $line == "$wanted" ]] && return 0
    done < <(as_audio_user pw-link "$direction")
    sleep 0.05
  done
  echo "PipeWire port did not appear: $wanted" >&2
  return 1
}

ip netns add "$namespace_a"
ip netns add "$namespace_b"
ip link add "$veth_a" type veth peer name "$veth_b"
ip link set "$veth_a" netns "$namespace_a"
ip link set "$veth_b" netns "$namespace_b"
ip -n "$namespace_a" address add 10.254.77.1/30 dev "$veth_a"
ip -n "$namespace_b" address add 10.254.77.2/30 dev "$veth_b"
ip -n "$namespace_a" link set lo up
ip -n "$namespace_b" link set lo up
ip -n "$namespace_a" link set "$veth_a" up
ip -n "$namespace_b" link set "$veth_b" up

common_args=(
  --bindport 46321
  --peerport 46321
  --nojackportsconnect
  --srate 48000
  --bufsize 128
  --bitres 16
  --queue 4
  --redundancy 1
  --zerounderrun
  --bufstrategy 3
  --timeout
)

in_namespace "$namespace_a" pw-jack jacktrip \
  --server \
  --sendchannels 3 \
  --receivechannels 5 \
  --clientname NixAudioE2EAlpha \
  "${common_args[@]}" >"$work_dir/server.log" 2>&1 &
server_pid=$!

in_namespace "$namespace_b" pw-jack jacktrip \
  --client 10.254.77.1 \
  --sendchannels 5 \
  --receivechannels 3 \
  --clientname NixAudioE2EBeta \
  "${common_args[@]}" >"$work_dir/client.log" 2>&1 &
client_pid=$!

wait_for_port -i NixAudioE2EAlpha:send_2
wait_for_port -o NixAudioE2EBeta:receive_2

as_audio_user timeout 15s pw-cat \
  --record \
  --target=0 \
  --rate=48000 \
  --channels=1 \
  --channel-map=MONO \
  --format=s16 \
  --raw \
  --sample-count=144000 \
  --properties='{"node.name":"nixaudio_e2e_capture"}' \
  "$work_dir/captured.raw" >"$work_dir/capture.log" 2>&1 &
capture_pid=$!
wait_for_port -i nixaudio_e2e_capture:input_MONO
as_audio_user pw-link NixAudioE2EBeta:receive_2 nixaudio_e2e_capture:input_MONO

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=997:sample_rate=48000:duration=4' \
  -f s16le -ac 1 "$work_dir/tone.raw"
as_audio_user timeout 10s pw-cat \
  --playback \
  --target=0 \
  --rate=48000 \
  --channels=1 \
  --channel-map=MONO \
  --format=s16 \
  --raw \
  --properties='{"node.name":"nixaudio_e2e_source"}' \
  "$work_dir/tone.raw" >"$work_dir/playback.log" 2>&1 &
playback_pid=$!
wait_for_port -o nixaudio_e2e_source:output_MONO
as_audio_user pw-link nixaudio_e2e_source:output_MONO NixAudioE2EAlpha:send_2

wait "$capture_pid" || true
capture_pid=
wait "$playback_pid" || true
playback_pid=
[[ -s $work_dir/captured.raw ]] || {
  echo "capture produced no audio data" >&2
  exit 1
}

peak=$(
  ffmpeg -hide_banner -nostats \
    -f s16le -ar 48000 -ac 1 -i "$work_dir/captured.raw" \
    -af volumedetect -f null - 2>&1 \
    | sed -n 's/.*max_volume: \([-0-9.]*\) dB.*/\1/p'
)
[[ -n $peak ]] || {
  echo "could not measure received signal" >&2
  exit 1
}
awk -v peak="$peak" 'BEGIN { exit !(peak > -30.0) }' || {
  echo "received signal is too quiet: ${peak} dB" >&2
  exit 1
}

echo "PASS: 997 Hz crossed PipeWire -> JackTrip -> UDP -> JackTrip -> PipeWire (peak ${peak} dB)"
