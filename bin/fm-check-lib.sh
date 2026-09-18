#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

# --- Check-set fingerprint: the byte-identical short-circuit for per-record
# poll validation.
#
# Validating every armed check on a home with ~50 polls costs hundreds of
# process spawns and was measured at 25-47s under fleet load, on every watcher
# arm. Every input of that validation is a function of the bytes and stat
# identity (type, mode, owner, device, inode, link count, size, mtime) of the
# member files below, the template bytes, the state device, and the home and
# root paths the X shim is generated for. A fingerprint over exactly those
# inputs therefore decides the validation: a record whose fingerprint equals
# the one recorded after its last full successful validation is still valid,
# and its per-record work is skipped. The fingerprint is computed with one
# stat, one digest pass, and a handful of fixed helpers regardless of record
# count, so an unchanged set costs O(1) process spawns and a set with one
# moved record costs one record's validation.
#
# Members, per $state/<id>.check.sh: that check, <id>.pr-poll,
# <id>.pr-poll-registration, <id>.meta, and <id>.check-trust, each only when
# present. Any member that is not a regular non-symlink file makes the set
# unfingerprintable (return 1), so such a set always takes the full path.
#
# FINGERPRINT TEXT, printed by fm_check_set_fingerprint:
#   context=<sha256 of version, home, root, state device, template digest>
#   <id> <TAB> <sha256 of that id's member stat and digest lines>   (sorted)
# The record file state/.pr-check-set-fingerprint holds one version line
# followed by exactly that text. It is a private single-link 0600 file whose
# validation mirrors the migration markers; any defect in it is ignored, never
# trusted, and deleting it only costs one full validation.
#
# Recording is safe only across an unchanged set: a caller computes the
# fingerprint BEFORE validating, validates every id whose line is not already
# certified, recomputes AFTER, and records only when both agree, so a record
# that moved during validation is never certified. FM_CHECK_SET_FINGERPRINT_VERSION
# must change whenever the per-record validation rules change, so an older
# record cannot certify a set under rules it never passed.
FM_CHECK_SET_FINGERPRINT_VERSION=fm-check-set-fingerprint-v1

fm_check_set_fingerprint_path() {
  printf '%s/.pr-check-set-fingerprint\n' "$1"
}

fm_check_set_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# fm_check_set_fingerprint <state> <template> <home> <root>
# Prints the fingerprint text of the current check set on stdout.
fm_check_set_fingerprint() {
  local state=$1 template=$2 home=$3 root=$4 kernel check id member state_device
  local context template_digest scratch line digest name text i
  local -a members=() ids=() lines=()
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  kernel=$(uname)
  if [ "$kernel" = Darwin ]; then
    state_device=$(stat -f %d "$state" 2>/dev/null) || return 1
  else
    state_device=$(stat -c %d "$state" 2>/dev/null) || return 1
  fi
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    fm_pr_task_id_valid "$id" || return 1
    ids+=("$id")
    for member in "$check" "$state/$id.pr-poll" "$state/$id.pr-poll-registration" \
      "$state/$id.meta" "$state/$id.check-trust"; do
      [ -e "$member" ] || [ -L "$member" ] || continue
      [ -f "$member" ] && [ ! -L "$member" ] || return 1
      members+=("$member")
    done
  done
  template_digest=$(fm_pr_sha256 "$template") || return 1
  [[ "$template_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  context=$(printf 'version=%s\nhome=%s\nroot=%s\nstate_device=%s\ntemplate=%s\n' \
    "$FM_CHECK_SET_FINGERPRINT_VERSION" "$home" "$root" "$state_device" "$template_digest" \
    | fm_check_set_sha256_stdin)
  [[ "$context" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'context=%s\n' "$context"
  [ "${#ids[@]}" -gt 0 ] || return 0
  # One stat pass and one digest pass over every member, read back
  # positionally so no path parsing is needed, then each id's lines are
  # gathered into a scratch file so a single digest pass names every id.
  scratch=$(mktemp -d "$state/.fm-check-set-fingerprint.XXXXXX") || return 1
  chmod 0700 "$scratch" 2>/dev/null || { rm -rf -- "$scratch"; return 1; }
  text=$(
    if [ "$kernel" = Darwin ]; then
      stat -f '%HT %Lp %u %d %i %l %z %m' "${members[@]}" || exit 1
    else
      stat -c '%F %a %u %d %i %h %s %Y' "${members[@]}" || exit 1
    fi
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "${members[@]}" || exit 1
    else
      sha256sum "${members[@]}" || exit 1
    fi
  ) || { rm -rf -- "$scratch"; return 1; }
  mapfile -t lines <<< "$text"
  [ "${#lines[@]}" -eq $(( 2 * ${#members[@]} )) ] || { rm -rf -- "$scratch"; return 1; }
  i=0
  while [ "$i" -lt "${#members[@]}" ]; do
    name=${members[$i]##*/}
    case "$name" in
      *.check.sh) id=${name%.check.sh} ;;
      *.pr-poll-registration) id=${name%.pr-poll-registration} ;;
      *.pr-poll) id=${name%.pr-poll} ;;
      *.meta) id=${name%.meta} ;;
      *.check-trust) id=${name%.check-trust} ;;
      *) rm -rf -- "$scratch"; return 1 ;;
    esac
    digest=${lines[$(( ${#members[@]} + i ))]%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { rm -rf -- "$scratch"; return 1; }
    printf '%s %s %s\n' "$name" "${lines[$i]}" "$digest" >> "$scratch/$id" \
      || { rm -rf -- "$scratch"; return 1; }
    i=$((i + 1))
  done
  for id in "${ids[@]}"; do
    [ -s "$scratch/$id" ] || { rm -rf -- "$scratch"; return 1; }
  done
  if command -v shasum >/dev/null 2>&1; then
    text=$(cd "$scratch" && shasum -a 256 -- *) || { rm -rf -- "$scratch"; return 1; }
  else
    text=$(cd "$scratch" && sha256sum -- *) || { rm -rf -- "$scratch"; return 1; }
  fi
  rm -rf -- "$scratch"
  while IFS= read -r line; do
    digest=${line%% *}
    id=${line##*  }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    fm_pr_task_id_valid "$id" || return 1
    printf '%s\t%s\n' "$id" "$digest"
  done <<< "$text"
}

# fm_check_set_fingerprint_read <state>
# Prints the fingerprint text a valid private record certifies, or nothing.
fm_check_set_fingerprint_read() {
  local state=$1 record state_device line first=1
  record=$(fm_check_set_fingerprint_path "$state")
  [ -e "$record" ] || [ -L "$record" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$record" 600 "$state_device" || return 1
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "$FM_CHECK_SET_FINGERPRINT_VERSION" ] || return 1
      continue
    fi
    printf '%s\n' "$line"
  done < "$record"
  [ "$first" -eq 0 ]
}

# fm_check_set_fingerprint_certified_ids <current-text> <recorded-text>
# Prints every id whose line in the current fingerprint text is certified by
# the recorded text under the same context, one per line.
fm_check_set_fingerprint_certified_ids() {
  local current=$1 recorded=$2 context line
  [ -n "$current" ] && [ -n "$recorded" ] || return 0
  context=${current%%$'\n'*}
  case "$context" in context=*) ;; *) return 0 ;; esac
  [ "${recorded%%$'\n'*}" = "$context" ] || return 0
  while IFS= read -r line; do
    case "$line" in context=*|'') continue ;; esac
    case "$recorded" in
      *$'\n'"$line"$'\n'*|*$'\n'"$line") printf '%s\n' "${line%%$'\t'*}" ;;
    esac
  done <<< "$current"
}

# fm_check_set_fingerprint_record <state> <text>
# Atomically publishes the record; a failure leaves no partial file behind.
fm_check_set_fingerprint_record() {
  local state=$1 text=$2 record tmp state_device
  record=$(fm_check_set_fingerprint_path "$state")
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" || return 1
  tmp=$(mktemp "$state/.fm-check-set-fingerprint.XXXXXX") || return 1
  if ! { chmod 0600 "$tmp" \
    && printf '%s\n%s\n' "$FM_CHECK_SET_FINGERPRINT_VERSION" "$text" > "$tmp" \
    && fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    && mv -f -- "$tmp" "$record"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}
