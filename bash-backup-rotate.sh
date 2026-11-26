#!/usr/bin/env bash
# Create checksummed, timestamped backups and retain the newest N per source.
# Requires Bash 4+, GNU coreutils, GNU tar, and either zstd or gzip.
set -euo pipefail
umask 077
export LC_ALL=C
unset TAR_OPTIONS GZIP GLOBIGNORE
shopt -s nullglob
shopt -u failglob nocaseglob
set +f

prog=${0##*/}
ts_format='%Y%m%dT%H%M%S%NZ'
archive_re='-[0-9]{8}T[0-9]{15}Z\.tar\.(gz|zst)$'

usage() {
    printf 'Usage: %s --sources PATH [PATH ...] --dest DIR [--keep N] [--dry-run]\n' "$prog"
    printf '%s\n' \
        '  --sources   One or more files or directories; may be repeated.' \
        '              Use ./ before a relative path beginning with --.' \
        '  --dest      Directory for archives, sidecars, and backup.log.' \
        '  --keep      Positive number of archives to retain per source (default: 7).' \
        '  --dry-run   Print planned actions without writing or deleting anything.'
}

logging=0
log() {
    local stamp line
    stamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || return 1
    line="$stamp $prog: $*"
    printf '%s\n' "$line" >&2 || return 1
    if (( logging )); then
        printf '%s\n' "$line" >&3 || return 1
    fi
}
die() { log "ERROR: $*"; exit 1; }
quote() { printf '%q' "$1"; }

sources=()
dest_arg=
keep=7
dry=0
while (($#)); do
    case $1 in
        --sources)
            shift
            (($#)) && [[ $1 != --* ]] || die '--sources requires at least one path'
            while (($#)) && [[ $1 != --* ]]; do
                [[ -n $1 ]] || die 'empty source path'
                sources+=("$1")
                shift
            done
            ;;
        --dest|--keep)
            opt=$1
            (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$opt requires a value"
            if [[ $opt == --dest ]]; then dest_arg=$2; else keep=$2; fi
            shift 2
            ;;
        --dry-run) dry=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $(quote "$1")" ;;
    esac
done

((${#sources[@]})) || die 'no sources supplied'
[[ -n $dest_arg ]] || die '--dest is required'

[[ $keep =~ ^[0-9]+$ ]] || die '--keep must be a positive integer'
# Strip leading zeros; reject zero; cap at a value safely below 2^63 for arithmetic.
keep=${keep##0*}
[[ -n $keep ]] || die '--keep must be at least 1'
if ((${#keep} > 18)); then keep=999999999999999999; fi

# NUL-delimited realpath output preserves even trailing newlines in paths.
IFS= read -r -d '' dest < <(realpath -zm -- "$dest_arg") ||
    die "cannot resolve destination: $(quote "$dest_arg")"
if [[ -e $dest && ! -d $dest ]]; then
    die "destination is not a directory: $(quote "$dest")"
fi

paths=()
ids=()
declare -A seen
for arg in "${sources[@]}"; do
    IFS= read -r -d '' src < <(realpath -ze -- "$arg") ||
        die "cannot resolve source: $(quote "$arg")"
    [[ -f $src || -d $src ]] || die "not a regular file or directory: $(quote "$src")"
    if [[ $src == / || $dest == "$src" || $dest == "$src/"* ]]; then
        die "destination is equal to or inside source: $(quote "$src")"
    fi
    digest=$(printf '%s' "$src" | sha256sum) || die 'cannot compute source ID'
    id=${digest%% *}
    if [[ -n ${seen[$id]:-} ]]; then
        log "skipping duplicate source $(quote "$src")"
        continue
    fi
    seen[$id]=1
    paths+=("$src")
    ids+=("$id")
done

if command -v zstd >/dev/null 2>&1; then
    compressor=(zstd -q -c)
    ext=zst
elif command -v gzip >/dev/null 2>&1; then
    compressor=(gzip -c)
    ext=gz
else
    die 'neither zstd nor gzip is available'
fi

lock=$dest/.bash-backup-rotate.lock
locked=0
stage=
cleanup() {
    local rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n ${stage:-} ]]; then
        rm -rf -- "$stage" || { log "ERROR: cannot remove $(quote "$stage")"; rc=1; }
    fi
    if (( locked )); then
        rmdir -- "$lock" || { log "ERROR: cannot release $(quote "$lock")"; rc=1; }
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if (( dry )); then
    log "dry run: destination $(quote "$dest"); keep $keep per source; compressor .$ext"
    [[ -d $dest ]] || log "would create directory $(quote "$dest")"
else
    mkdir -p -- "$dest" || die "cannot create destination: $(quote "$dest")"
    # Serialize cooperating writers. After an unclean shutdown, verify no
    # backup is running before manually removing an abandoned lock directory.
    mkdir -- "$lock" || die "cannot acquire lock: $(quote "$lock")"
    locked=1
    logfile=$dest/backup.log
    [[ ! -L $logfile && ( ! -e $logfile || -f $logfile ) ]] ||
        die "unsafe log file: $(quote "$logfile")"
    exec 3>>"$logfile" || die "cannot open log: $(quote "$logfile")"
    logging=1
    log "starting backup in $(quote "$dest"); keep $keep per source; compressor .$ext"
    stage=$(mktemp -d -- "$dest/.backup-stage.XXXXXXXXXX") || die 'cannot create staging directory'
fi

rotate() {
    local id=$1 planned=$2 file name old sum count i j
    local -a archives=()
    # One glob gives C-locale chronological order across both compression types.
    for file in "$dest/$id-"*.tar.*; do
        name=${file##*/}
        [[ $name =~ ^${id}${archive_re}$ ]] || continue
        [[ -f $file && ! -L $file ]] || die "unexpected archive entry: $(quote "$file")"
        archives+=("$file")
    done
    if (( dry )); then
        # Insert the hypothetical new archive at its lexical position, even if
        # the clock has moved backwards since the previous backup.
        j=${#archives[@]}
        while (( j > 0 )) && [[ ${archives[j-1]} > "$planned" ]]; do
            archives[j]=${archives[j-1]}
            ((--j))
        done
        archives[j]=$planned
    fi
    count=$((${#archives[@]} - keep))
    for ((i = 0; i < count; i++)); do
        old=${archives[i]}
        sum=$old.sha256
        if (( dry )); then
            log "would delete $(quote "$old")"
            if [[ -e $sum || -L $sum || $old == "$planned" ]]; then
                log "would delete $(quote "$sum")"
            fi
        else
            if [[ -e $sum && ! -f $sum && ! -L $sum ]]; then
                die "unexpected checksum entry: $(quote "$sum")"
            fi
            log "deleting $(quote "$old")"
            rm -- "$old" || die "cannot remove $(quote "$old")"
            if [[ -e $sum || -L $sum ]]; then
                log "deleting $(quote "$sum")"
                rm -- "$sum" || die "cannot remove $(quote "$sum")"
            fi
        fi
    done
}

for i in "${!paths[@]}"; do
    src=${paths[i]}
    id=${ids[i]}
    stamp=$(date -u "+$ts_format") || die 'cannot obtain archive timestamp'
    name=$id-$stamp.tar.$ext
    final=$dest/$name
    for entry in "$final" "$final.sha256"; do
        [[ ! -e $entry && ! -L $entry ]] || die "name collision: $(quote "$entry")"
    done
    if (( dry )); then
        log "would archive $(quote "$src") to $(quote "$final")"
        log "would write checksum $(quote "$final.sha256")"
    else
        parent=${src%/*}
        log "archiving $(quote "$src") to $(quote "$final")"
        tar -c -f - -C "${parent:-/}" -- "./${src##*/}" |
            "${compressor[@]}" >"$stage/$name" || die "archive failed: $(quote "$src")"
        log "computing checksum for $(quote "$final")"
        (cd -- "$stage" && sha256sum -- "$name" >"$name.sha256") ||
            die "checksum failed: $(quote "$final")"
        # Publish without overwriting; the archive appears only after its
        # complete checksum is in place. Staging is on the same filesystem.
        ln -T -- "$stage/$name.sha256" "$final.sha256" || die 'cannot publish checksum'
        if ! ln -T -- "$stage/$name" "$final"; then
            rm -- "$final.sha256" || log 'ERROR: cannot roll back checksum'
            die "cannot publish archive: $(quote "$final")"
        fi
        rm -- "$stage/$name" "$stage/$name.sha256" || die 'cannot unlink staging files'
        log "published $(quote "$final") and $(quote "$final.sha256")"
    fi
    rotate "$id" "$final"
done
log 'finished'
