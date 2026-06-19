#!/usr/bin/env bash
#
# Archive a HISTORICAL WeChat Linux version from web.archive.org snapshots.
#
# Usage:  archive-history.sh <snapshot-timestamp>      e.g. 20241106060201
#         (or pass it via the SNAPSHOT env var)
#
#   1. For each package suffix, download directly from
#        https://web.archive.org/web/<ts>/<original-url>
#      If the exact timestamp has no snapshot, the archive redirects to the
#      closest one (curl -L follows); if nothing was ever captured it 404s
#      (curl -f fails) and we skip that suffix.
#   2. Extract the version from each downloaded package.
#   3. If the snapshots span more than one release, keep the most common version
#      and drop the rest (a suffix whose closest snapshot is a different build).
#   4. Verify the kept files agree, rename into ./dist + build SHA256 notes.
#   5. Export version/tag/skip to $GITHUB_OUTPUT for the release step.
#
# Historical snapshots have no live API version to constrain against, so
# VERSION_HINT is left empty (version greps accept any 4-part version).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARCHIVE_BASE="https://web.archive.org/web"

download_snapshots() {
  local req_ts="$1"
  title "Fetching packages captured around ${req_ts} from web.archive.org"
  # Parallel indexed arrays (bash 3.2 compatible): got[i] <-> gotver[i]
  local suffix url out got=() gotver=() ver i

  for suffix in "${PKG_SUFFIXES[@]}"; do
    url="${ARCHIVE_BASE}/${req_ts}/${CDN_BASE}/WeChatLinux_${suffix}"
    out="${DL_DIR}/WeChatLinux_${suffix}"
    info "try ${suffix}"
    if curl -fSL --retry 3 --retry-delay 3 -o "${out}" "${url}" 2>/dev/null && valid_magic "${out}" "${suffix}"; then
      ver="$(extract_version "${out}")"
      got+=("${suffix}"); gotver+=("${ver}")
      ok "got ${suffix} -> ${ver:-?} ($(du -h "${out}" | cut -f1))"
    else
      rm -f "${out}"; warn "skip ${suffix} (no snapshot)"
    fi
  done

  [ "${#got[@]}" -gt 0 ] || { err "No packages captured for ${req_ts}."; fail_exit 1; }

  # Most snapshots are a single release; if closest snapshots span versions,
  # keep the most common version and drop the rest.
  local target
  target="$(printf '%s\n' "${gotver[@]}" | grep -vE '^$' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  [ -n "${target}" ] || { err "Could not determine a version from the snapshots."; fail_exit 1; }
  info "Target version: ${target}"

  PRESENT_SUFFIXES=()
  i=0
  for suffix in "${got[@]}"; do
    if [ "${gotver[$i]}" = "${target}" ]; then
      PRESENT_SUFFIXES+=("${suffix}")
    else
      warn "drop ${suffix}: version ${gotver[$i]:-?} != ${target}"
      rm -f "${DL_DIR}/WeChatLinux_${suffix}"
    fi
    i=$(( i + 1 ))
  done
  ok "Keeping ${#PRESENT_SUFFIXES[@]} package(s) for ${target}: ${PRESENT_SUFFIXES[*]}"
}

main() {
  local ts="${1:-${SNAPSHOT:-}}"
  ts="$(printf '%s' "${ts}" | grep -oE '[0-9]{4,14}' | head -n1)"
  if [ -z "${ts}" ]; then
    err "Usage: $(basename "$0") <snapshot-timestamp>   (e.g. 20241106060201)"
    exit 1
  fi

  VERSION_HINT=""   # historical: no live API constraint
  rm -rf "${WORK_DIR}"; mkdir -p "${DL_DIR}"

  install_depends
  download_snapshots "${ts}"
  verify_versions_list "${PRESENT_SUFFIXES[@]}"
  prepare_assets_list  "${PRESENT_SUFFIXES[@]}"
  check_already_released
  write_outputs
  clean_temp
}

# Run only when executed directly (not when sourced for testing).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
