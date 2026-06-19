#!/usr/bin/env bash
#
# Archive the LATEST WeChat Linux version from the official CDN.
#
#   1. Query the API for the latest x.x.x version (3-part; preliminary
#      constraint only -- the real package version is 4-part: x.x.x.x).
#   2. Download every package from the CDN (all required).
#   3. Extract & verify the version inside each package.
#   4. Rename into ./dist with the version + build SHA256 release notes.
#   5. Export version/tag/skip to $GITHUB_OUTPUT for the release step.
#
# Publishing is handled by softprops/action-gh-release in the workflow.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

API_URL="https://linux.weixin.qq.com/api/version"

get_api_version() {
  local body
  body="$(curl -fsSL --retry 3 --retry-delay 3 "${API_URL}" 2>/dev/null)" \
    || { err "Failed to query ${API_URL}"; fail_exit 1; }
  API_VERSION="$(printf '%s' "${body}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "${API_VERSION}" ] || { err "Could not parse version from API: ${body}"; fail_exit 1; }
  VERSION_HINT="${API_VERSION}"   # constrain version greps to the API prefix
  ok "API latest version (3-part): ${API_VERSION}"
}

download_all() {
  title "Downloading ${#PKG_SUFFIXES[@]} packages"
  local suffix url out
  for suffix in "${PKG_SUFFIXES[@]}"; do
    url="${CDN_BASE}/WeChatLinux_${suffix}"
    out="${DL_DIR}/WeChatLinux_${suffix}"
    info "GET ${url}"
    if ! curl -fSL --retry 4 --retry-delay 5 -o "${out}" "${url}"; then
      err "Download failed: ${url}"; fail_exit 1
    fi
    valid_magic "${out}" "${suffix}" || { err "Unexpected content for ${suffix}"; fail_exit 1; }
    ok "Saved $(basename "${out}") ($(du -h "${out}" | cut -f1))"
  done
}

main() {
  rm -rf "${WORK_DIR}"; mkdir -p "${DL_DIR}"
  install_depends
  get_api_version
  download_all
  verify_versions_list "${PKG_SUFFIXES[@]}"
  prepare_assets_list  "${PKG_SUFFIXES[@]}"
  check_already_released
  write_outputs
  clean_temp
}

# Run only when executed directly (not when sourced for testing).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
