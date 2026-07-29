#!/usr/bin/env bash
#
# What needs updating, in one place.
#
# Diun knows which images have newer releases, but its own `diun image
# list` only reports the newest tag it has seen per image. It says nothing
# about what is actually running, so it cannot answer "do I need to do
# anything". This joins the two: Diun's view of the registry against the
# containers running right now.
#
# Comparison is by DIGEST, not tag. Most services here run :latest, so
# comparing tag strings would report "latest vs latest" forever and miss
# every update. The running image's RepoDigests are what actually pin what
# you have.
#
# Note RepoDigests is a LIST, not a single value. An image pulled more than
# once accumulates an entry per manifest it has been resolved under, and
# the current one is not necessarily first. Taking element 0 reports
# up-to-date images as needing updates, so this tests membership of the
# whole list.
#
# Usage:
#   ./scripts/check-updates.sh          print a table
#   ./scripts/check-updates.sh --json   also write web/lab.lan/updates.json
#
# Exits non-zero only on real errors. Having updates available is the
# normal case, not a failure, so a systemd timer running this will not
# report a fault for doing its job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIUN_CONTAINER="${DIUN_CONTAINER:-diun}"
JSON_OUT="$REPO_ROOT/web/lab.lan/updates.json"

write_json=false
case "${1:-}" in
  --json) write_json=true ;;
  -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

for cmd in docker jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required but not installed" >&2; exit 1; }
done

if ! docker inspect "$DIUN_CONTAINER" >/dev/null 2>&1; then
  echo "container '$DIUN_CONTAINER' not found. Is the stack up?" >&2
  exit 1
fi

# Diun's database. Empty until the first scheduled check has run.
diun_raw="$(docker exec "$DIUN_CONTAINER" diun image list --raw 2>/dev/null || echo '{}')"
if [ "$(jq -r '(.images // []) | length' <<<"$diun_raw")" = "0" ]; then
  echo "Diun has no images recorded yet. It checks on DIUN_SCHEDULE" >&2
  echo "(six-hourly by default); the first run populates the database." >&2
fi

# Running containers, with the digest of the image each one was started
# from. A container built locally has no RepoDigest at all, which is how
# we spot mealie.
rows=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  ref="$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || echo "")"
  label="$(docker inspect -f '{{index .Config.Labels "diun.enable"}}' "$name" 2>/dev/null || echo "")"
  # Locally built images have no upstream to look up. homelab.watch-image
  # names the registry image they are derived from, so mealie can still
  # show "running v3.19.2, available v3.22.0" instead of a blank row.
  watch_as="$(docker inspect -f '{{index .Config.Labels "homelab.watch-image"}}' "$name" 2>/dev/null || echo "")"
  [ "$watch_as" = "<no value>" ] && watch_as=""
  img_id="$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || echo "")"
  digest=""
  if [ -n "$img_id" ]; then
    # Every digest this image is known by, comma separated, repo stripped.
    digest="$(docker image inspect -f '{{range .RepoDigests}}{{.}},{{end}}' "$img_id" 2>/dev/null \
              | tr ',' '\n' | sed -n 's/.*@//p' | paste -sd, -)"
  fi
  rows+="${name}"$'\t'"${ref}"$'\t'"${digest}"$'\t'"${label}"$'\t'"${watch_as}"$'\n'
done < <(docker ps --format '{{.Names}}' | sort)

report="$(
  jq -n \
    --arg rows "$rows" \
    --argjson diun "$diun_raw" \
    --arg generated "$(date -Iseconds)" '
    # Registry-qualify an image reference the way Diun stores it, so the
    # two sides can be joined: bare names get docker.io/, and official
    # images additionally get library/.
    def norm(ref):
      (ref | sub("@sha256:.*$"; "") | sub(":[^:/]+$"; "")) as $repo
      | ($repo | split("/")) as $parts
      | if ($parts | length) == 1 then "docker.io/library/" + $repo
        elif ($parts[0] | test("[.:]")) or ($parts[0] == "localhost") then $repo
        else "docker.io/" + $repo
        end;

    def tagof(ref):
      (ref | sub("@sha256:.*$"; "")) as $r
      | ($r | split("/") | last) as $last
      | if ($last | test(":")) then ($last | split(":") | last) else "latest" end;

    ($diun.images // []) as $images
    | ($images | map({key: .name, value: .latest}) | from_entries) as $known
    | ($rows | split("\n") | map(select(length > 0)) | map(split("\t"))
       | map({
           container: .[0],
           ref:       .[1],
           digests:   ((.[2] // "") | split(",") | map(select(length > 0))),
           optout:    (.[3] == "false"),
           watch_as:  (.[4] // "")
         })) as $running
    | $running
    | map(
        . as $c
        # A locally built image is looked up under the upstream it was
        # derived from, when the container declares one.
        | (if $c.watch_as != "" then norm($c.watch_as) else norm($c.ref) end) as $name
        | ($known[$name] // null) as $latest
        | {
            name:      $c.container,
            image:     $name,
            running:   tagof($c.ref),
            available: ($latest.tag // null),
            status: (
              if $c.optout then "pinned"
              elif (($c.digests | length) == 0) then "local"
              elif ($latest == null) then "unwatched"
              # Membership, not equality: see the RepoDigests note above.
              elif ($c.digests | index($latest.digest)) then "current"
              else "UPDATE"
              end
            )
          }
      )
    | {
        generated: $generated,
        count: (map(select(.status == "UPDATE")) | length),
        services: .
      }
  '
)"

# Human-readable table.
printf '\n'
printf '%-22s %-14s %-14s %s\n' "SERVICE" "RUNNING" "AVAILABLE" "STATUS"
jq -r '.services[]
  | [ .name,
      (.running // "-"),
      (.available // "-"),
      (if .status == "pinned" then "pinned (manual)"
       elif .status == "local" then "local build"
       else .status end)
    ] | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r name running available status; do
      printf '%-22s %-14s %-14s %s\n' "$name" "$running" "$available" "$status"
    done

count="$(jq -r '.count' <<<"$report")"
total="$(jq -r '.services | length' <<<"$report")"
printf '\n%s of %s services have updates available.\n' "$count" "$total"
if [ "$count" != "0" ]; then
  printf 'Apply with ./scripts/update.sh (mealie is built by hand, see services/diun.md).\n'
fi
printf '\n'

if [ "$write_json" = true ]; then
  # Written into the directory Caddy serves at https://lab.lan. The mount
  # is read-only inside the container; this writes on the host side.
  printf '%s\n' "$report" > "$JSON_OUT"
  echo "wrote $JSON_OUT"
fi
