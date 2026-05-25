#!/usr/bin/env bash
# cam-record.sh — resilient RTSP chunk recorder
# Reads config JSON, records boundary-aligned chunks per camera.
# Supports per-camera transcode_audio flag for incompatible audio codecs.

set -uo pipefail

CONFIG="${1:-/home/lawl/camara/config.json}"

if ! command -v ffmpeg &>/dev/null; then
  echo "ERROR: ffmpeg not found. Install with: apt install ffmpeg" >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install with: apt install jq" >&2
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

secs_until_next_quarter() {
  local now
  now=$(date +%s)
  local quarter=900
  echo $(( quarter - (now % quarter) ))
}

now_timestamp() {
  date '+%Y-%m-%dT%H-%M-%S'
}

record_camera() {
  local name="$1"
  local url="$2"
  local outdir="$3"
  local transcode_audio="$4"

  mkdir -p "$outdir"
  log "[${name}] Starting recorder → ${outdir}"

  # Build audio flags once
  local audio_flags
  if [[ "$transcode_audio" == "true" ]]; then
    audio_flags="-c:v copy -c:a aac -b:a 64k"
    log "[${name}] Audio mode: transcode to AAC"
  else
    audio_flags="-c copy"
    log "[${name}] Audio mode: stream copy"
  fi

  while true; do
    local duration
    duration=$(secs_until_next_quarter)

    if [[ $duration -lt 5 ]]; then
      log "[${name}] Too close to boundary (${duration}s), sleeping…"
      sleep "$duration"
      continue
    fi

    local ts
    ts=$(now_timestamp)
    local outfile="${outdir}/${ts}.mp4"

    log "[${name}] Recording ${duration}s chunk → ${outfile}"

    local errfile
    errfile=$(mktemp /tmp/camrecord-XXXXXX)

    # shellcheck disable=SC2086
    ffmpeg \
      -loglevel error \
      -rtsp_transport tcp \
      -i "$url" \
      $audio_flags \
      -t "$duration" \
      -movflags +frag_keyframe+empty_moov+default_base_moof \
      -avoid_negative_ts make_zero \
      -y \
      "$outfile" \
      2>"$errfile"
    local exit_code=$?

    # Log any ffmpeg stderr output
    if [[ -s "$errfile" ]]; then
      while IFS= read -r line; do log "[${name}] ffmpeg: $line"; done < "$errfile"
    fi
    rm -f "$errfile"

    if [[ $exit_code -ne 0 ]]; then
      log "[${name}] ffmpeg exited with code ${exit_code}. Reconnecting in 5s…"
      sleep 5
    else
      log "[${name}] Chunk done: ${outfile}"
    fi
  done
}

log "Loading config: ${CONFIG}"

output_base=$(jq -r '.output_base' "$CONFIG")
mapfile -t names            < <(jq -r '.cameras[].name' "$CONFIG")
mapfile -t urls             < <(jq -r '.cameras[].url'  "$CONFIG")
mapfile -t transcode_audios < <(jq -r '.cameras[] | .transcode_audio // false' "$CONFIG")

declare -a pids
declare -a cam_names
declare -a cam_urls
declare -a cam_audios
declare -a cam_dirs

for i in "${!names[@]}"; do
  cam_names[$i]="${names[$i]}"
  cam_urls[$i]="${urls[$i]}"
  cam_audios[$i]="${transcode_audios[$i]}"
  cam_dirs[$i]="${output_base}/$(echo "${names[$i]}" | tr '[:upper:]' '[:lower:]')"
  pids[$i]=0
done

spawn() {
  local i=$1
  mkdir -p "${cam_dirs[$i]}"
  record_camera "${cam_names[$i]}" "${cam_urls[$i]}" "${cam_dirs[$i]}" "${cam_audios[$i]}" &
  pids[$i]=$!
  log "Spawned recorder for [${cam_names[$i]}] (pid ${pids[$i]})"
}

# Initial spawn
for i in "${!cam_names[@]}"; do
  spawn "$i"
done

cleanup() {
  log "Shutting down — killing child recorders…"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait
  log "All recorders stopped."
  exit 0
}
trap cleanup SIGTERM SIGINT

# Watchdog loop — checks every 30s if any camera process died and respawns it
while true; do
  sleep 30
  for i in "${!cam_names[@]}"; do
    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
      log "WATCHDOG: [${cam_names[$i]}] (pid ${pids[$i]}) is dead — respawning…"
      spawn "$i"
    fi
  done
done
