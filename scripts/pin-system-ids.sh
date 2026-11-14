#!/usr/bin/env bash
# Gives the system users and groups of an image root the IDs in system-ids.conf: entries
# in /etc/passwd and /etc/group, and the ownership of their files. A user or group that is
# not listed keeps its ID unless another name reserves it (then it gets a free one), and
# is reported, so it can be added.
#   pin-system-ids.sh <root> <system-ids.conf>
set -euo pipefail
ROOT=${1:?root}; IDS=${2:?system-ids.conf}

declare -A PIN_U=() PIN_G=() RES_U=() RES_G=()
while read -r kind name id _; do
  [[ $id =~ ^[0-9]+$ ]] || { echo "system-ids.conf: bad line: $kind $name $id" >&2; exit 1; }
  case $kind in
    u) PIN_U[$name]=$id; RES_U[$id]=$name ;;
    g) PIN_G[$name]=$id; RES_G[$id]=$name ;;
    *) echo "system-ids.conf: bad kind: $kind" >&2; exit 1 ;;
  esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$IDS")

# new_ids <passwd|group> <pin array> <reserved array> <result array (name -> id)>
new_ids() {
  local file=$ROOT/etc/$1 name id n
  local -n pin=$2 res=$3 out=$4
  local -A used=()
  local -a later=()
  while IFS=: read -r name _ id _; do
    if [ -n "${pin[$name]:-}" ]; then out[$name]=${pin[$name]}
    elif [ -n "${res[$id]:-}" ] && [ "${res[$id]}" != "$name" ]; then later+=("$name")
    else
      out[$name]=$id
      [ "$id" -lt 1000 ] && [ "$id" -ge 100 ] && echo "::warning::$1: $name ($id) is not in system-ids.conf; add it, or its ID can change"
    fi
  done < "$file"
  for id in "${out[@]}"; do used[$id]=1; done
  for name in "${later[@]}"; do
    for ((n = 999; n >= 100; n--)); do
      [ -z "${used[$n]:-}" ] && [ -z "${res[$n]:-}" ] && break
    done
    [ "$n" -ge 100 ] || { echo "no free ID for $name" >&2; exit 1; }
    out[$name]=$n; used[$n]=1
    echo "::warning::$1: $name took an ID reserved in system-ids.conf, now $n; add it there"
  done
}
declare -A NEW_U=() NEW_G=() MAP_U=() MAP_G=()
new_ids passwd PIN_U RES_U NEW_U
new_ids group PIN_G RES_G NEW_G

while IFS=: read -r name _ id _; do
  [ "${NEW_U[$name]}" = "$id" ] || MAP_U[$id]=${NEW_U[$name]}
done < "$ROOT"/etc/passwd
while IFS=: read -r name _ id _; do
  [ "${NEW_G[$name]}" = "$id" ] || MAP_G[$id]=${NEW_G[$name]}
done < "$ROOT"/etc/group
if [ ${#MAP_U[@]} -eq 0 ] && [ ${#MAP_G[@]} -eq 0 ]; then
  echo "System IDs: as pinned"; exit 0
fi
for id in "${!MAP_U[@]}"; do echo "System IDs: uid $id -> ${MAP_U[$id]}"; done
for id in "${!MAP_G[@]}"; do echo "System IDs: gid $id -> ${MAP_G[$id]}"; done

# Ownership first (one pass over the files that have a changed ID), then the databases.
expr=()
for id in "${!MAP_U[@]}"; do expr+=(-o -uid "$id"); done
for id in "${!MAP_G[@]}"; do expr+=(-o -gid "$id"); done
n=0
while IFS= read -r -d '' rec; do
  u=${rec%% *}; rest=${rec#* }; g=${rest%% *}; p=${rest#* }
  chown -h "${MAP_U[$u]:-$u}:${MAP_G[$g]:-$g}" "$p"; n=$((n + 1))
done < <(find "$ROOT" -xdev \( -path "$ROOT/proc" -o -path "$ROOT/sys" -o -path "$ROOT/dev" \
           -o -path "$ROOT/run" -o -path "$ROOT/tmp" \) -prune -o \( "${expr[@]:1}" \) -printf '%U %G %p\0')
echo "System IDs: $n files re-owned"

map_file() {  # map_file <file> <awk program>; keeps mode and SELinux label (cat into it)
  local tmp; tmp=$(mktemp)
  awk -F: -v OFS=: "$2" "$1" > "$tmp" && cat "$tmp" > "$1" && rm -f "$tmp"
}
umap=$(for n in "${!NEW_U[@]}"; do printf '%s=%s ' "$n" "${NEW_U[$n]}"; done)
gmap=$(for n in "${!NEW_G[@]}"; do printf '%s=%s ' "$n" "${NEW_G[$n]}"; done)
gold=$(for id in "${!MAP_G[@]}"; do printf '%s=%s ' "$id" "${MAP_G[$id]}"; done)
map_file "$ROOT"/etc/passwd "BEGIN { split(\"$umap\", a, \" \"); for (i in a) { split(a[i], kv, \"=\"); U[kv[1]] = kv[2] }
  split(\"$gold\", b, \" \"); for (i in b) { split(b[i], kv, \"=\"); G[kv[1]] = kv[2] } }
  { if (\$1 in U) \$3 = U[\$1]; if (\$4 in G) \$4 = G[\$4]; print }"
map_file "$ROOT"/etc/group "BEGIN { split(\"$gmap\", a, \" \"); for (i in a) { split(a[i], kv, \"=\"); G[kv[1]] = kv[2] } }
  { if (\$1 in G) \$3 = G[\$1]; print }"
