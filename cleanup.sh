RETAIN_DAYS="${1:-10}"
OUTPUT_BASE="/bigboi/camara"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

log "Cleanup started — deleting recordings older than ${RETAIN_DAYS} days"

deleted=0
while IFS= read -r f; do
  rm -f "$f"
  deleted=$((deleted + 1))
done < <(find "$OUTPUT_BASE" -name '*.mp4' -mtime "+${RETAIN_DAYS}")

log "Done. Deleted ${deleted} file(s)."
log "Disk now at: $(df -h "$OUTPUT_BASE" | awk 'NR==2 {print $5}')"
