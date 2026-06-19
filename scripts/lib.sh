#!/usr/bin/env bash
#
# Shared helpers for the WeChat Linux archive scripts.
# Sourced by archive-latest.sh (live CDN) and archive-history.sh (web.archive.org).
#
# Globals an entry script may set BEFORE sourcing:
#   CDN_BASE      original download base (default: official CDN)
#   WORK_DIR      temp dir (default: ./.wechat-archive)
#   DIST_DIR      output dir for renamed assets (default: ./dist)
#   VERSION_HINT  3/4-part prefix used to constrain version greps (optional)

# --------------------------------------------------------------------------- #
# Configuration (overridable via env before sourcing)
# --------------------------------------------------------------------------- #
: "${CDN_BASE:=https://dldir1v6.qq.com/weixin/Universal/Linux}"
: "${WORK_DIR:=$(pwd)/.wechat-archive}"
: "${DIST_DIR:=$(pwd)/dist}"
: "${VERSION_HINT:=}"
DL_DIR="${WORK_DIR}/downloads"

# All known package suffixes (downloaded as WeChatLinux_<suffix>).
PKG_SUFFIXES=(
  "x86_64.deb"
  "x86_64.rpm"
  "x86_64.AppImage"
  "arm64.deb"
  "arm64.rpm"
  "arm64.AppImage"
  "LoongArch.deb"
)

# NOTE: kept compatible with bash 3.2 (macOS system bash) -- no associative
# arrays, no `declare -g`. Per-suffix versions are passed via parallel arrays.

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
_hr()   { printf '#%.0s' {1..60}; echo; }
title() { _hr; echo -e "## \033[1;33m$*\033[0m"; _hr; }
info()  { echo -e "\033[1;36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;35m[WARN]\033[0m  $*" >&2; }
err()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; }

# --------------------------------------------------------------------------- #
# Cleanup (temp only; DIST_DIR must survive for the release step)
# --------------------------------------------------------------------------- #
clean_temp() { rm -rf "${WORK_DIR}"; }
fail_exit()  { local code="${1:-1}"; clean_temp; exit "${code}"; }

# --------------------------------------------------------------------------- #
# Dependencies
# --------------------------------------------------------------------------- #
install_depends() {
  title "Installing dependencies"
  #   libarchive-tools -> bsdtar       (read deb/rpm)
  #   rpm              -> rpm header   (rpm version)
  #   squashfs-tools   -> unsquashfs   (AppImage payload)
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y -qq || apt-get update -y -qq || true
    sudo apt-get install -y -qq libarchive-tools rpm squashfs-tools curl coreutils \
      || apt-get install -y -qq libarchive-tools rpm squashfs-tools curl coreutils \
      || warn "apt-get install failed; will rely on fallbacks"
  else
    warn "apt-get not found; assuming required tools are present"
  fi
  for t in curl dpkg-deb; do
    command -v "$t" >/dev/null 2>&1 || warn "missing tool: $t"
  done
}

# Portable SHA256 (sha256sum on Linux, shasum on macOS).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

# --------------------------------------------------------------------------- #
# Validate a downloaded file really is the expected package (magic bytes).
# Guards against archive/HTML error pages served with HTTP 200.
# --------------------------------------------------------------------------- #
valid_magic() {
  local f="$1" suffix="$2" sig
  [ -s "$f" ] || return 1
  case "$suffix" in
    *.deb)      head -c 8 "$f" | grep -q '!<arch>' ;;          # ar archive
    *.rpm)      sig="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"; [ "$sig" = "edabeedb" ] ;;
    *.AppImage) sig="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"; [ "$sig" = "7f454c46" ] ;;  # ELF
    *)          return 0 ;;
  esac
}

# --------------------------------------------------------------------------- #
# Version extraction
# --------------------------------------------------------------------------- #

# First 4-part (preferred) or 3-part version number in a string.
norm_ver() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# Most frequent version string inside a raw file. Constrained to VERSION_HINT
# when set, otherwise any 4-part version.
grep_version_in_file() {
  local f="$1" pat
  if [ -n "${VERSION_HINT}" ]; then pat="${VERSION_HINT//./\\.}\.[0-9]+"
  else pat='[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; fi
  LC_ALL=C grep -aoE "$pat" "$f" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

# Read an unsigned little-endian integer (portable: GNU & BSD od).
#   $1 file   $2 byte offset   $3 number of bytes
le_uint() {
  local b val=0 i=0
  for b in $(od -An -tu1 -j "$2" -N "$3" "$1" 2>/dev/null); do
    val=$(( val + (b << (8 * i)) )); i=$(( i + 1 ))
  done
  printf '%s' "$val"
}

# Squashfs offset of a type-2 AppImage from its ELF64 header:
#   offset = e_shoff + e_shentsize * e_shnum
appimage_offset() {
  local f="$1" cls shoff shentsize shnum
  cls="$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')"   # EI_CLASS: 2 = ELF64
  [ "$cls" = "2" ] || { printf ''; return; }
  shoff="$(le_uint "$f" 40 8)"; shentsize="$(le_uint "$f" 58 2)"; shnum="$(le_uint "$f" 60 2)"
  if [ -n "$shoff" ] && [ -n "$shentsize" ] && [ -n "$shnum" ] && [ "$shoff" -gt 0 ]; then
    printf '%s' "$(( shoff + shentsize * shnum ))"
  fi
}

find_version_in_tree() {
  local d="$1" v=""
  if [ -n "${VERSION_HINT}" ]; then
    v="$(grep -raohE "${VERSION_HINT//./\\.}\.[0-9]+" "$d" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  fi
  [ -z "$v" ] && v="$(grep -raohE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$d" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  printf '%s' "$v"
}

version_from_deb() {
  local f="$1" v=""
  command -v dpkg-deb >/dev/null 2>&1 && v="$(dpkg-deb -f "$f" Version 2>/dev/null)"
  if [ -z "$v" ] && command -v bsdtar >/dev/null 2>&1; then
    v="$(bsdtar -xOf "$f" 'control.tar*' 2>/dev/null | bsdtar -xOf - ./control 2>/dev/null \
         | awk -F': *' '/^Version:/{print $2; exit}')"
  fi
  v="${v#*:}"; v="${v%%-*}"            # strip epoch + debian revision
  v="$(norm_ver "$v")"
  [ -z "$v" ] && v="$(grep_version_in_file "$f")"
  printf '%s' "$v"
}

version_from_rpm() {
  local f="$1" v=""
  if command -v rpm >/dev/null 2>&1; then
    v="$(rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null)"
    if [ "$(printf '%s' "$v" | grep -oE '[0-9]+' | wc -l)" -lt 4 ]; then
      local vr; vr="$(rpm -qp --qf '%{VERSION}.%{RELEASE}' "$f" 2>/dev/null)"
      [ -n "$(norm_ver "$vr")" ] && v="$vr"
    fi
  fi
  v="$(norm_ver "$v")"
  [ -z "$v" ] && v="$(grep_version_in_file "$f")"
  printf '%s' "$v"
}

version_from_appimage() {
  # ELF runtime + appended squashfs. Cannot exec a foreign-arch binary and
  # bsdtar cannot read squashfs, so unsquashfs at the ELF-computed offset.
  local f="$1" v="" off out
  if command -v unsquashfs >/dev/null 2>&1; then
    off="$(appimage_offset "$f")"
    [ -z "$off" ] && off="$(LC_ALL=C grep -aboE 'hsqs' "$f" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [ -n "$off" ]; then
      out="$(mktemp -d)"
      if unsquashfs -o "$off" -n -d "${out}/x" "$f" >/dev/null 2>&1; then
        v="$(find_version_in_tree "${out}/x")"
      else
        warn "$(basename "$f"): unsquashfs failed at offset ${off}"
      fi
      rm -rf "$out"
    fi
  fi
  [ -z "$v" ] && v="$(grep_version_in_file "$f")"
  printf '%s' "$v"
}

extract_version() {
  local f="$1"
  case "$f" in
    *.deb)      version_from_deb "$f" ;;
    *.rpm)      version_from_rpm "$f" ;;
    *.AppImage) version_from_appimage "$f" ;;
    *)          grep_version_in_file "$f" ;;
  esac
}

# --------------------------------------------------------------------------- #
# Verify versions over a given list of suffixes (subset allowed). Sets
# DEST_VERSION. Uses parallel indexed arrays (bash 3.2 compatible).
# --------------------------------------------------------------------------- #
verify_versions_list() {
  title "Extracting & verifying package versions"
  local suffixes=("$@") mismatch=0 full=() vers=() s f v i

  i=0
  for s in "${suffixes[@]}"; do
    f="${DL_DIR}/WeChatLinux_${s}"
    v="$(extract_version "$f")"
    vers[$i]="$v"; i=$(( i + 1 ))
    if [ -z "$v" ]; then err "Could not determine version of WeChatLinux_${s}"; mismatch=1; continue; fi
    info "$(printf '%-22s' "$s") -> ${v}"
    if [ -n "${VERSION_HINT}" ]; then
      case "$v" in "${VERSION_HINT}"|"${VERSION_HINT}."*) : ;;
        *) warn "${s}: version ${v} does not match hint ${VERSION_HINT}" ;; esac
    fi
    printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && full+=("$v")
  done

  [ "$mismatch" -eq 0 ] || { err "Version extraction failed for one or more files."; fail_exit 1; }
  [ "${#full[@]}" -gt 0 ] || { err "No 4-part version could be extracted."; fail_exit 1; }

  local uniq_full; uniq_full="$(printf '%s\n' "${full[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$uniq_full" | wc -l)" -ne 1 ]; then
    err "Inconsistent versions across packages:"; printf '%s\n' "$uniq_full" >&2; fail_exit 1
  fi
  DEST_VERSION="$uniq_full"

  i=0
  for s in "${suffixes[@]}"; do
    v="${vers[$i]}"; i=$(( i + 1 ))
    case "${DEST_VERSION}" in "${v}"|"${v}."*) : ;;
      *) err "${s} version ${v} inconsistent with ${DEST_VERSION}"; fail_exit 1 ;; esac
  done
  ok "All packages consistent: ${DEST_VERSION}"
}

# --------------------------------------------------------------------------- #
# Rename present packages into DIST_DIR with the version; build SHA256 notes.
# --------------------------------------------------------------------------- #
prepare_assets_list() {
  title "Preparing release assets in ${DIST_DIR}"
  local suffixes=("$@") s src dst
  rm -rf "${DIST_DIR}"; mkdir -p "${DIST_DIR}"
  for s in "${suffixes[@]}"; do
    src="${DL_DIR}/WeChatLinux_${s}"
    dst="${DIST_DIR}/WeChatLinux_${DEST_VERSION}_${s}"   # e.g. WeChatLinux_4.1.1.9_x86_64.deb
    mv "${src}" "${dst}"
    ok "$(basename "${dst}")"
  done
  # Checksums ordered by filename, case-insensitive & locale-independent, to
  # match how GitHub lists the release assets. Not uploaded as an asset.
  local sums; sums="$( cd "${DIST_DIR}" && sha256_of WeChatLinux_* | LC_ALL=C sort -f -k2 )"
  { echo "### SHA256"; echo; echo '```'; echo "${sums}"; echo '```'; } > "${DIST_DIR}/RELEASE_NOTES.md"
  ok "Wrote RELEASE_NOTES.md (SHA256 only)"
}

# --------------------------------------------------------------------------- #
# Has this version already been released?
# --------------------------------------------------------------------------- #
check_already_released() {
  local tag="v${DEST_VERSION}"
  SKIP="false"
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    if gh release view "${tag}" >/dev/null 2>&1; then
      SKIP="true"; ok "Release ${tag} already exists -> skip publishing."
    else
      info "Release ${tag} not found -> will publish."
    fi
  else
    info "gh/token unavailable; leaving skip=false (release step decides)."
  fi
}

# --------------------------------------------------------------------------- #
# Emit outputs + job summary.
# --------------------------------------------------------------------------- #
write_outputs() {
  local tag="v${DEST_VERSION}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "version=${DEST_VERSION}"
      echo "tag=${tag}"
      echo "skip=${SKIP}"
      echo "dist_dir=${DIST_DIR}"
    } >> "${GITHUB_OUTPUT}"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### WeChat Linux ${DEST_VERSION}"
      echo "- tag: \`${tag}\` (skip=${SKIP})"
      echo "- assets: $(ls -1 "${DIST_DIR}"/WeChatLinux_* 2>/dev/null | wc -l)"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  ok "version=${DEST_VERSION} tag=${tag} skip=${SKIP}"
}
