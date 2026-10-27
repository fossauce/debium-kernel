#!/usr/bin/env bash
# Builds Debian's backports kernel with options.config and patches/<series>/.
set -euo pipefail
trap 'printf "error: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

NAME=debium
MAINTAINER_NAME=debium
MAINTAINER_EMAIL=hmwassim95@gmail.com
BUILD_PACKAGES="bc bindgen bison build-essential cpio debhelper dpkg-dev dwarves fakeroot flex \
kmod libdw-dev libelf-dev libssl-dev patch python3 rsync rust-src rustc rustfmt xz-utils zstd"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIONS="$ROOT/options.config"
CACHE="$ROOT/cache"
BUILD="$ROOT/build"
SRC="$BUILD/linux"
LOG="$BUILD/build.log"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ./build.sh [-r REVISION] [-s SERIES] [--configure]

  -r REVISION   debium revision for this Debian version (default 1)
  -s SERIES     kernel series, e.g. 7.2 (default: newest in backports)
  --configure   stop after the verified .config
EOF
}

parse_args() {
    REVISION=1 SERIES="" CONFIGURE_ONLY=no
    while [ $# -gt 0 ]; do
        case $1 in
            -r) [ $# -ge 2 ] || die "-r needs a value"; REVISION=$2; shift ;;
            -s) [ $# -ge 2 ] || die "-s needs a value"; SERIES=$2; shift ;;
            --configure) CONFIGURE_ONLY=yes ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; exit 1 ;;
        esac
        shift
    done
    [[ $REVISION =~ ^[1-9][0-9]*$ ]] || die "revision must be a positive integer"
    [ "$(id -u)" != 0 ] || die "run as a normal user"
}

# Installs missing build packages with sudo apt-get.
install_packages() {
    local p missing=()
    for p in $BUILD_PACKAGES; do
        [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null)" == ii* ]] || missing+=("$p")
    done
    [ ${#missing[@]} -gt 0 ] || return 0
    log "installing build packages: ${missing[*]}"
    sudo apt-get install --no-install-recommends "${missing[@]}" || die "build packages not installed"
}

# version_in <package> <suite>
version_in() {
    apt-cache madison "$1" \
        | awk -F'|' -v s=" $2/" 'index($3, s) && !n++ { gsub(/ /, "", $2); print $2 }'
}

resolve() {
    local codename
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    SUITE="$codename-backports"
    if [ -z "$SERIES" ]; then
        SERIES="$(apt-cache pkgnames linux-source- | grep -E '^linux-source-[0-9]+\.[0-9]+$' \
            | while read -r p; do [ -z "$(version_in "$p" "$SUITE")" ] || echo "${p#linux-source-}"; done \
            | sort -V | tail -n 1)"
    fi
    [ -n "$SERIES" ] || die "no linux-source package in $SUITE"
    DEBIAN_VERSION="$(version_in "linux-source-$SERIES" "$SUITE")"
    [ -n "$DEBIAN_VERSION" ] || die "linux-source-$SERIES is not in $SUITE"
    UPSTREAM="${DEBIAN_VERSION%%-*}"
    KERNELRELEASE="$UPSTREAM-$NAME"
    VERSION="$DEBIAN_VERSION+$NAME$REVISION"
    TAG="$UPSTREAM-$NAME$REVISION"
    OUT="$ROOT/output/$TAG"
}

# fetch <package> <version>: cached .deb path, checked against apt's SHA-256.
# Downloads finish in a temporary folder first.
fetch() {
    local uri file size sum tmp
    read -r uri file size sum < <(apt-get download --print-uris "$1=$2" | awk 'NR == 1')
    [ -n "${file:-}" ] || die "apt cannot locate $1 $2"
    sum=${sum#SHA256:}
    if [ -f "$CACHE/$file" ] && ! printf '%s  %s\n' "$sum" "$CACHE/$file" | sha256sum -c --status; then
        rm -f -- "$CACHE/$file"
    fi
    if [ ! -f "$CACHE/$file" ]; then
        log "downloading $file" >&2
        tmp="$(mktemp -d "$CACHE/.download-XXXXXX")"
        (cd "$tmp" && apt-get download "$1=$2" >&2) || { rm -rf -- "$tmp"; die "download of $1 failed"; }
        mv -- "$tmp/$file" "$CACHE/$file"
        rmdir -- "$tmp"
    fi
    printf '%s' "$CACHE/$file"
}

prepare() {
    local source config arch p patches=()
    arch="$(dpkg --print-architecture)"
    mkdir -p "$CACHE"
    source="$(fetch "linux-source-$SERIES" "$DEBIAN_VERSION")"
    config="$(fetch "linux-config-$SERIES" "$DEBIAN_VERSION")"

    log "extracting linux-source-$SERIES $DEBIAN_VERSION"
    rm -rf -- "$BUILD"
    mkdir -p "$SRC"
    dpkg-deb --fsys-tarfile "$source" | tar -xO --wildcards '*/linux-source-*.tar.xz' \
        | xz -T0 -dc | tar -x -C "$SRC" --strip-components=1
    [ -f "$SRC/Makefile" ] || die "no kernel source in $source"

    shopt -s nullglob
    patches=("$ROOT/patches/$SERIES"/*.patch)
    shopt -u nullglob
    for p in "${patches[@]}"; do
        log "applying ${p#"$ROOT"/}"
        patch -d "$SRC" -p1 -N --no-backup-if-mismatch -i "$p" || die "${p##*/} does not apply"
    done
    [ -z "$(find "$SRC" -name '*.rej' -print -quit)" ] || die "a patch left a rejected hunk"

    log "configuring"
    dpkg-deb --fsys-tarfile "$config" | tar -xO --wildcards "*/config.${arch}_none_${arch}.xz" \
        | xz -dc >"$SRC/.config"
    [ -s "$SRC/.config" ] || die "no $arch config in $config"
    cp "$SRC/.config" "$BUILD/debian.config"
    (cd "$SRC" && ./scripts/kconfig/merge_config.sh -m .config "$OPTIONS" && make olddefconfig)
    verify_config
}

# Checks each options.config line in the final .config.
verify_config() {
    local line sym failed=0
    while IFS= read -r line; do
        if [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            sym=${BASH_REMATCH[1]}
            ! grep -q "^$sym=" "$SRC/.config" || { printf '  %s: want off, got %s\n' "$sym" \
                "$(grep "^$sym=" "$SRC/.config")" >&2; failed=1; }
        elif [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
            sym=${BASH_REMATCH[1]}
            grep -qxF "$line" "$SRC/.config" || { printf '  %s: want %s, got %s\n' "$sym" "$line" \
                "$(grep -E "^(# )?$sym[= ]" "$SRC/.config" || echo none)" >&2; failed=1; }
        elif [[ -n $line && $line != \#* ]]; then
            die "invalid line in options.config: $line"
        fi
    done <"$OPTIONS"
    [ "$failed" = 0 ] || die "options.config did not survive olddefconfig"
    diff "$BUILD/debian.config" "$SRC/.config" | grep -E '^[<>] (# )?CONFIG' >"$BUILD/config.diff" || true
    log ".config verified, diff in ${BUILD#"$ROOT"/}/config.diff"
}

compile() {
    local jobs
    jobs="$(nproc)"
    log "building $KERNELRELEASE $VERSION, $jobs jobs"
    if ! (cd "$SRC" && DEB_BUILD_PROFILES=pkg.linux-upstream.nokerneldbg \
            DEBFULLNAME="$MAINTAINER_NAME" DEBEMAIL="$MAINTAINER_EMAIL" \
            KBUILD_BUILD_USER="$NAME" KBUILD_BUILD_HOST="$NAME" \
            make -j"$jobs" bindeb-pkg LOCALVERSION="-$NAME" KDEB_PKGVERSION="$VERSION") 2>&1 | tee "$LOG"; then
        grep -E 'error|Error [0-9]' "$LOG" | tail -n 20 >&2 || true
        die "build failed, see ${LOG#"$ROOT"/}"
    fi
}

collect() {
    local f pkg arch
    rm -rf -- "$OUT"
    mkdir -p "$OUT"
    for f in "$BUILD"/*.deb; do
        pkg="$(dpkg-deb -f "$f" Package)" arch="$(dpkg-deb -f "$f" Architecture)"
        case $pkg in
            # linux-libc-dev replaces Debian's.
            linux-libc-dev | *-dbg) rm -f -- "$f"; continue ;;
        esac
        [ "$(dpkg-deb -f "$f" Version)" = "$VERSION" ] || die "$pkg has version $(dpkg-deb -f "$f" Version)"
        ! dpkg-deb -c "$f" | grep -q 'signing_key\.pem' || die "$pkg contains the module signing key"
        # No version in the name: GitHub renames '~'.
        mv -- "$f" "$OUT/${pkg}_$arch.deb"
    done
    cat >"$OUT/build-info.txt" <<EOF
kernel=$KERNELRELEASE
version=$VERSION
source=linux-source-$SERIES $DEBIAN_VERSION ($SUITE)
options_sha256=$(sha256sum "$OPTIONS" | cut -d' ' -f1)
patches=$(cd "$ROOT" && find patches/"$SERIES" -name "*.patch" -print0 | sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)
gcc=$(gcc --version | head -n 1)
rustc=$(rustc --version)
pahole=$(pahole --version)
EOF
    (cd "$OUT" && sha256sum -- *.deb >SHA256SUMS)
}

main() {
    parse_args "$@"
    mkdir -p "$CACHE"
    exec 9>"$CACHE/.lock"
    flock -n 9 || die "another build is running in $ROOT"
    rm -rf -- "$CACHE"/.download-*
    install_packages
    resolve
    log "linux-source-$SERIES $DEBIAN_VERSION from $SUITE -> $KERNELRELEASE $VERSION"
    prepare
    [ "$CONFIGURE_ONLY" = no ] || exit 0
    compile
    collect
    log "packages in ${OUT#"$ROOT"/}:"
    ls -1 "$OUT"
}

main "$@"
