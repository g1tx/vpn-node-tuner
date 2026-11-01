#!/usr/bin/env bash
# Conservative TCP tuning. Bash 5+, iproute2, procps, util-linux, systemd.
set -Eeuo pipefail
umask 077
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: sudo ./tune.sh [--apply] [--migrate-legacy]
       ./tune.sh --dry-run | --diagnose | --help
       sudo ./tune.sh --revert

Environment: PROFILE=balanced (default, preserve current CC and supported queues)
or PROFILE=bbr (explicit BBR + fq). NIC (default-route interface), BANDWIDTH_MBIT (1..100000, default
1000 assumed, not NIC speed), BDP_RTT_MS (1..2000, default 100), NOFILE
(65536..131072, default 65536). Socket target: min(2*BDP, RAM/32, 16MiB).
Existing larger socket maxima and TCP minimum/initial sizes are preserved.
Dry-run and diagnose never create files, locks, services or load modules.
Apply stores the original state; repeated apply keeps that original for revert.
No packages are installed. No Docker or native Xray service is restarted.
Legacy migration removes legacy persistent tuning, not inherited runtime
changes or Docker configuration. Reboot to a reviewed baseline separately.
EOF
}
MODE=apply MIGRATE=0
for arg in "$@"; do
    case "$arg" in
        --apply|--dry-run|--diagnose|--revert)
            [[ $MODE == apply && ${mode_set:-0} == 0 ]] || die 'choose one mode'
            MODE=${arg#--}; mode_set=1 ;;
        --migrate-legacy) MIGRATE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done
(( BASH_VERSINFO[0] >= 5 )) || die 'Bash 5 or newer is required'
[[ $MODE == apply || $MIGRATE == 0 ]] || die '--migrate-legacy requires --apply'
PROFILE=${PROFILE-balanced}
[[ $PROFILE == balanced || $PROFILE == bbr ]] || die 'PROFILE must be balanced or bbr'
RESERVED_QDISC_HANDLES=''

# Only integration tests use a filesystem fixture; their PATH supplies fake
# kernel commands. A fixture must never be used to tune the real host.
ROOT=${EXIT_NODE_TEST_ROOT:-}
if [[ -n $ROOT ]]; then
    [[ ${EXIT_NODE_TESTING:-} == 1 && $ROOT == /* && $ROOT != / && -f $ROOT/.exit-node-test-root ]] || die 'invalid test fixture'
fi
STATE=$ROOT/var/lib/exit-node-optimizer
SYSCTL=$ROOT/etc/sysctl.d/90-exit-node-optimizer.conf
HELPER=$ROOT/usr/local/sbin/exit-node-optimizer-fq
UNIT=$ROOT/etc/systemd/system/exit-node-optimizer-fq.service
SERVICE=exit-node-optimizer-fq.service
LEGACY_SERVICE=xray-reality-rps-xps.service
LEGACY=(
    /etc/sysctl.d/99-xray-reality-tuning.conf
    /etc/security/limits.d/99-xray-reality.conf
    /etc/modprobe.d/99-xray-conntrack.conf
    /usr/local/sbin/xray-reality-rps-xps.sh
    /etc/systemd/system/xray-reality-rps-xps.service
    /etc/systemd/system/xray.d/99-xray-reality-limits.conf
    /etc/systemd/system/xray-core.d/99-xray-reality-limits.conf
    /etc/systemd/system/docker.d/99-xray-reality-limits.conf
    /etc/systemd/system/xray.service.d/99-xray-reality-limits.conf
    /etc/systemd/system/xray-core.service.d/99-xray-reality-limits.conf
    /etc/systemd/system/docker.service.d/99-xray-reality-limits.conf
)
FILES=( "$SYSCTL" "$HELPER" "$UNIT" )
XRAY_UNITS=(xray.service xray-core.service xray@.service xray-core@.service)
for unit in "${XRAY_UNITS[@]}"; do FILES+=( "$ROOT/etc/systemd/system/$unit.d/90-exit-node-optimizer.conf" ); done
for path in "${LEGACY[@]}"; do FILES+=( "$ROOT$path" ); done
KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control
    net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing
    net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem)
declare -A CURRENT=() TARGET=()
need() { command -v "$1" >/dev/null 2>&1 || die "required command missing: $1 (install it manually)"; }
number() {
    local name=$1 value=$2 low=$3 high=$4
    [[ $value =~ ^[0-9]{1,10}$ ]] || die "$name must be an integer in $low..$high"
    value=$((10#$value))
    (( value >= low && value <= high )) || die "$name must be in $low..$high"
    printf '%s' "$value"
}
valid_nic() { [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.:-]{0,14}$ && -d $ROOT/sys/class/net/$1 ]] || die "invalid or missing NIC: $1"; }
native_unit_exists() {
    if [[ $1 == *@.service ]]; then systemctl cat "$1" --no-pager >/dev/null 2>&1
    else [[ $(systemctl show "$1" -p LoadState --value 2>/dev/null) == loaded ]]; fi
}
native_nofile() {
    local unit=$1 value property
    LIMIT_SOFT=$NOFILE LIMIT_HARD=$NOFILE
    for property in LimitNOFILESoft LimitNOFILE; do
        value=$(systemctl show "$unit" -p "$property" --value)
        if [[ $value == infinity || $value == 18446744073709551615 ]]; then value=infinity
        else
            value=$(number "$unit $property" "$value" 0 2147483647)
            (( value >= NOFILE )) || value=$NOFILE
        fi
        if [[ $property == LimitNOFILESoft ]]; then LIMIT_SOFT=$value; else LIMIT_HARD=$value; fi
    done
}
verify_persistent_sysctls() {
    local config line key value origin='unknown source'
    local -A final=() sources=()
    config=$(systemd-analyze cat-config sysctl.d) || die 'cannot read native sysctl.d configuration precedence'
    while IFS= read -r line; do
        if [[ $line =~ ^#[[:space:]]+(/.*)$ ]]; then
            origin=${BASH_REMATCH[1]}
            continue
        fi
        [[ $line == *=* && ! $line =~ ^[[:space:]]*[#\;] ]] || continue
        key=$(awk '{
            $1=$1
            sub(/^-[[:space:]]*/, "")
            gsub(/\//, ".")
            gsub(/[.]+/, ".")
            sub(/^[.]+/, "")
            sub(/[.]+$/, "")
            print
        }' <<< "${line%%=*}")
        # Explicit assignments are excluded from sysctl.d glob matches. Only
        # exact managed names participate; unrelated settings stay untouched.
        [[ " ${KEYS[*]} " == *" $key "* ]] || continue
        value=$(awk '{$1=$1;print}' <<< "${line#*=}")
        final[$key]=$value
        sources[$key]=$origin
    done <<< "$config"
    for key in "${KEYS[@]}"; do
        [[ ${final[$key]:-} == "${TARGET[$key]}" ]] || die "persistent sysctl conflict: $key = ${final[$key]:-(missing)} from ${sources[$key]:-unknown source}; expected ${TARGET[$key]}"
    done
}

# tc output is data, never shell code. Unknown options, classes, filters and
# ingress/clsact are refused instead of losing an existing custom setup.
size_bytes() {
    local value=$1
    [[ $value =~ ^[0-9]+([.][0-9]+)?([KMG]?b)?$ ]] || die "unsupported tc size: $value"
    awk -v v="$value" 'BEGIN {m=1; if(v~/Kb$/)m=1024; else if(v~/Mb$/)m=1048576; else if(v~/Gb$/)m=1073741824; printf "%.0f",v*m}'
}
qdisc_parse() {
    local text=$1 line kind handle position opt value i n bands_seen weights_seen count=0 roots=0 mq=0
    local -a words opts
    QDISC_ROWS=()
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        read -r -a words <<< "$line"
        [[ ${words[0]:-} == qdisc && ${words[2]:-} =~ ^[0-9a-fA-F]+:$ ]] || die 'unrecognized tc qdisc output'
        kind=${words[1]} handle=${words[2]} i=3
        case ${words[i]:-} in
            root) position=root; roots=$((roots+1)); i=$((i+1)) ;;
            parent)
                position=${words[i+1]:-}
                [[ $position =~ ^[0-9a-fA-F]*:[0-9a-fA-F]+$ ]] || die 'unsupported qdisc parent'
                i=$((i+2)) ;;
            *) die 'unsupported qdisc topology (including ingress/clsact)' ;;
        esac
        if [[ ${words[i]:-} == refcnt ]]; then
            [[ ${words[i+1]:-} =~ ^[0-9]+$ ]] || die 'invalid tc refcnt'
            i=$((i+2))
        fi
        if [[ $kind == mq && $position == root ]]; then
            (( i == ${#words[@]} )) || die 'unsupported mq options'
            mq=1; continue
        fi
        case $kind in
            pfifo_fast)
                value="${words[*]:i}"
                [[ -z $value || $value == 'bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' ]] || die 'custom pfifo_fast configuration is unsupported'
                opts=() ;;
            fq|fq_codel)
                opts=() bands_seen=0 weights_seen=0
                while (( i < ${#words[@]} )); do
                    opt=${words[i]}; i=$((i+1))
                    case "$kind:$opt" in
                        fq:bands)
                            [[ $bands_seen == 0 && ${words[i]:-} == 3 && ${words[i+1]:-} == priomap ]] || die 'unsupported fq bands/priomap'
                            bands_seen=1; opts+=(bands 3 priomap); i=$((i+2))
                            for ((n=0; n<16; n++)); do
                                value=${words[i]:-}; i=$((i+1))
                                [[ $value =~ ^[0-2]$ ]] || die 'fq priomap requires 16 integers in 0..2'
                                opts+=( "$value" )
                            done
                            continue ;;
                        fq:weights)
                            [[ $weights_seen == 0 ]] || die 'duplicate fq weights'
                            weights_seen=1; opts+=(weights)
                            for ((n=0; n<3; n++)); do
                                value=${words[i]:-}; i=$((i+1))
                                [[ $value =~ ^[0-9]{1,10}$ ]] || die 'fq weights require 3 integers in 16384..2147483647'
                                # tc accepts signed integers with Linux UAPI FQ_MIN_WEIGHT=16384.
                                (( 10#$value >= 16384 && 10#$value <= 2147483647 )) || die 'fq weights require 3 integers in 16384..2147483647'
                                opts+=( "$value" )
                            done
                            continue ;;
                        fq:pacing|fq:nopacing|fq:horizon_drop|fq:horizon_cap|fq_codel:ecn|fq_codel:noecn)
                            opts+=( "$opt" ); continue ;;
                        fq:limit|fq:flow_limit|fq:buckets|fq:orphan_mask|fq:quantum|fq:initial_quantum|fq:maxrate|fq:defrate|fq:low_rate_threshold|fq:refill_delay|fq:timer_slack|fq:ce_threshold|fq:horizon|fq:offload_horizon|fq_codel:limit|fq_codel:flows|fq_codel:quantum|fq_codel:target|fq_codel:interval|fq_codel:memory_limit|fq_codel:drop_batch|fq_codel:ce_threshold|fq_codel:ce_threshold_selector) ;;
                        *) die "unsupported $kind option: $opt" ;;
                    esac
                    value=${words[i]:-}; i=$((i+1))
                    [[ $value =~ ^[0-9][a-zA-Z0-9./]*$ ]] || die "unsupported tc value: $value"
                    case $opt in
                        limit|flow_limit) value=${value%p} ;;
                        quantum|initial_quantum) value=$(size_bytes "$value") ;;
                    esac
                    opts+=( "$opt" "$value" )
                done ;;
            *) die "unsupported/custom qdisc '$kind'; preserve it and configure fq manually" ;;
        esac
        QDISC_ROWS+=( "$kind|$handle|$position|${opts[*]}" )
        count=$((count+1))
    done <<< "$text"
    (( roots == 1 && count >= 1 )) || die 'expected one simple root or mq with supported leaves'
    for line in "${QDISC_ROWS[@]}"; do
        IFS='|' read -r kind handle position value <<< "$line"
        [[ ( $mq == 1 && $position != root ) || ( $mq == 0 && $position == root && $count == 1 ) ]] || die 'unsupported classful qdisc topology'
    done
}
qdisc_delete() {
    local nic=$1 position=$2
    if [[ $position == root ]]; then tc qdisc del dev "$nic" root
    else tc qdisc del dev "$nic" parent "$position"; fi
}
qdisc_replace() {
    local nic=$1 row kind handle position options existing ck ch cp co current_kind current_handle current_options
    local operation failed desired_flows current_flows i rc=0
    local -a args opts filtered current_opts requested=("${QDISC_ROWS[@]}") current
    qdisc_parse "$(tc -details qdisc show dev "$nic")"
    current=("${QDISC_ROWS[@]}")
    for row in "${requested[@]}"; do
        IFS='|' read -r kind handle position options <<< "$row"
        [[ $handle != 0: ]] || continue
        for existing in "${current[@]}"; do
            IFS='|' read -r ck ch cp co <<< "$existing"
            [[ $ch != "$handle" || $cp == "$position" ]] || { warn "qdisc handle $handle belongs to another attachment ($cp); manual review required"; return 1; }
        done
    done
    for row in "${requested[@]}"; do
        IFS='|' read -r kind handle position options <<< "$row"
        qdisc_parse "$(tc -details qdisc show dev "$nic")"
        current=("${QDISC_ROWS[@]}")
        current_kind='' current_handle='' current_options='' operation=replace failed=0
        for existing in "${current[@]}"; do
            IFS='|' read -r ck ch cp co <<< "$existing"
            if [[ $cp == "$position" ]]; then current_kind=$ck current_handle=$ch current_options=$co; fi
            # A saved handle may belong to another kind at this attachment.
            # Recreate it here; never remove a different attachment to free it.
            if [[ $handle != 0: && $ch == "$handle" && $cp != "$position" ]]; then
                warn "qdisc handle $handle moved to another attachment; manual review required"; return 1
            fi
            if [[ $handle != 0: && $ch == "$handle" && $ck != "$kind" ]]; then
                qdisc_delete "$nic" "$cp" || { failed=1; break; }
                if [[ $cp == "$position" ]]; then current_kind=''; operation=add; fi
            fi
        done
        if (( failed )); then rc=1; continue; fi
        opts=(); [[ -z $options ]] || read -r -a opts <<< "$options"
        if [[ $kind == fq_codel && $current_kind == fq_codel && ( $handle == 0: || $handle == "$current_handle" ) ]]; then
            desired_flows='' current_flows=''
            current_opts=(); [[ -z $current_options ]] || read -r -a current_opts <<< "$current_options"
            for ((i=0; i<${#opts[@]}-1; i++)); do [[ ${opts[i]} != flows ]] || desired_flows=${opts[i+1]}; done
            for ((i=0; i<${#current_opts[@]}-1; i++)); do [[ ${current_opts[i]} != flows ]] || current_flows=${current_opts[i+1]}; done
            if [[ -n $desired_flows && $desired_flows == "$current_flows" ]]; then
                # Linux rejects even an unchanged flows count on an initialized
                # fq_codel. Keep that immutable value and replay mutable options.
                filtered=()
                for ((i=0; i<${#opts[@]}; i++)); do
                    if [[ ${opts[i]} == flows ]]; then i=$((i+1)); else filtered+=( "${opts[i]}" ); fi
                done
                opts=("${filtered[@]}")
            elif [[ -n $desired_flows ]]; then
                qdisc_delete "$nic" "$position" || { rc=1; continue; }
                operation=add
            fi
        fi
        args=(qdisc "$operation" dev "$nic")
        if [[ $position == root ]]; then args+=(root); else args+=(parent "$position"); fi
        # Kernel-assigned 0: identity and packet counters cannot be recreated.
        # Restore the configuration and attachment, preserving explicit handles.
        [[ $handle == 0: ]] || args+=(handle "$handle")
        tc "${args[@]}" "$kind" "${opts[@]}" || rc=1
    done
    return "$rc"
}
qdisc_apply() {
    local nic=$1 row kind handle position options opt target text next_handle=65534
    local -a opts paced reserved
    local -A occupied=()
    [[ -z $(tc filter show dev "$nic") ]] || die 'existing egress filters are unsupported; configure fq manually'
    text=$(tc -details qdisc show dev "$nic")
    qdisc_parse "$text"
    local -a original=("${QDISC_ROWS[@]}")
    while IFS= read -r handle; do [[ -z $handle ]] || occupied[$handle]=1; done < <(awk '$1=="qdisc" {print $3}' <<< "$text")
    reserved=(); [[ -z $RESERVED_QDISC_HANDLES ]] || read -r -a reserved <<< "$RESERVED_QDISC_HANDLES"
    for handle in "${reserved[@]}"; do occupied[$handle]=1; done
    QDISC_ROWS=()
    for row in "${original[@]}"; do
        IFS='|' read -r kind handle position options <<< "$row"
        target=$FALLBACK_QDISC
        if [[ $PROFILE == balanced && ( $kind == fq || $kind == fq_codel ) ]]; then target=$kind; fi
        # Preserve supported fq_codel instances without replaying immutable init
        # parameters or disturbing their queued packets.
        [[ $PROFILE != balanced || $kind != fq_codel ]] || continue
        if [[ $kind != "$target" || $handle == 0: ]]; then
            # tc's auto allocator may reuse a freed original handle on another
            # mq leaf, including same-kind implicit queues after boot. Keep every
            # saved/current handle reserved for exact revert.
            while (( next_handle > 0 )); do
                printf -v handle '%x:' "$next_handle"; next_handle=$((next_handle-1))
                [[ -n ${occupied[$handle]:-} ]] || break
            done
            [[ -z ${occupied[$handle]:-} ]] || die 'no free qdisc handle available'
            occupied[$handle]=1
        fi
        paced=()
        if [[ $target == fq ]]; then
            paced=(pacing)
            if [[ $kind == fq && -n $options ]]; then
                read -r -a opts <<< "$options"
                for opt in "${opts[@]}"; do
                    [[ $opt == pacing || $opt == nopacing ]] || paced+=( "$opt" )
                done
            fi
        fi
        QDISC_ROWS+=( "$target|$handle|$position|${paced[*]}" )
    done
    qdisc_replace "$nic"
    qdisc_parse "$(tc -details qdisc show dev "$nic")"
    qdisc_verify_profile
}
qdisc_verify_profile() {
    local row kind
    for row in "${QDISC_ROWS[@]}"; do
        kind=${row%%|*}
        [[ $kind == fq || ( $PROFILE == balanced && $kind == fq_codel ) ]] || die "qdisc verification failed for profile=$PROFILE"
        if [[ $kind == fq ]]; then [[ " ${row##*|} " != *' nopacing '* ]] || die 'fq pacing verification failed'; fi
    done
}
qdisc_restore() {
    local nic=$1 text=$2 row actual kind handle position options ak ah ap ao found
    qdisc_parse "$text"
    local -a expected=("${QDISC_ROWS[@]}")
    qdisc_replace "$nic" || return 1
    qdisc_parse "$(tc -details qdisc show dev "$nic")"
    (( ${#expected[@]} == ${#QDISC_ROWS[@]} )) || return 1
    for row in "${expected[@]}"; do
        IFS='|' read -r kind handle position options <<< "$row"
        found=0
        for actual in "${QDISC_ROWS[@]}"; do
            IFS='|' read -r ak ah ap ao <<< "$actual"
            if [[ $kind == "$ak" && $position == "$ap" && $options == "$ao" && ( $handle == 0: || $handle == "$ah" ) ]]; then found=1; break; fi
        done
        (( found )) || { warn "qdisc restore verification failed at $position"; return 1; }
    done
}
diagnose() {
    say 'Read-only diagnostics'
    ip -brief address show
    ip route show default
    NIC=${NIC:-$(ip route show default | awk '$1=="default" {for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')}
    if [[ -n $NIC ]]; then valid_nic "$NIC"; say "Actual egress qdisc on $NIC:"; tc -details qdisc show dev "$NIC"
    else warn 'no default-route interface; set NIC to inspect its qdisc'; fi
    if [[ -r $ROOT/proc/meminfo ]]; then awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/' "$ROOT/proc/meminfo"; fi
    local key id ids
    for key in "${KEYS[@]}"; do sysctl "$key" 2>/dev/null || warn "unsupported parameter: $key"; done
    if command -v systemctl >/dev/null 2>&1; then
        for unit in "${XRAY_UNITS[@]}"; do
            if [[ $unit == *@.service ]]; then
                if native_unit_exists "$unit"; then say "$unit: installed template; inspect limits on its running instances."; fi
            else systemctl show "$unit" -p LoadState -p ActiveState -p LimitNOFILE --no-pager 2>/dev/null || true; fi
        done
    fi
    if command -v docker >/dev/null 2>&1; then
        if ids=$(docker ps -q 2>/dev/null); then
            for id in $ids; do
                docker inspect --format '{{.Name}} network={{.HostConfig.NetworkMode}} ulimits={{json .HostConfig.Ulimits}} memory={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}}' "$id" || warn "cannot inspect Docker container $id"
            done
        else warn 'Docker is installed but its daemon is unavailable'; fi
        say 'Docker limits/network settings require a reviewed Compose/container update and recreation; no Docker settings are changed.'
    fi
}
for command in ip tc sysctl awk; do need "$command"; done
if [[ $MODE == diagnose ]]; then diagnose; exit 0; fi
safe_tree() {
    local dir=$1 bad
    [[ ! -L $dir && -d $dir ]] || die "unsafe state directory: $dir"
    bad=$(find -P "$dir" \( ! -uid 0 -o -perm /022 -o -type l \) -print -quit)
    [[ -z $bad ]] || die "state must be root-owned, private and contain no symlinks: $bad"
}
validate_managed_paths() {
    local path parent bad
    for path in "${FILES[@]}"; do
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] || die "managed path must be a regular file: $path"
        if [[ -e $path ]]; then
            bad=$(find -P "$path" -maxdepth 0 \( ! -uid 0 -o -perm /022 \) -print)
            [[ -z $bad ]] || die "managed file must be root-owned and not group/world writable: $path"
        fi
        parent=${path%/*}
        while [[ $parent != / && $parent != "$ROOT" && -n $parent ]]; do
            [[ ! -L $parent ]] || die "managed parent must not be a symlink: $parent"
            if [[ -e $parent ]]; then
                [[ -d $parent ]] || die "managed parent must be a directory: $parent"
                bad=$(find -P "$parent" -maxdepth 0 \( ! -uid 0 -o -perm /022 \) -print)
                [[ -z $bad ]] || die "managed parent must be root-owned and not group/world writable: $parent"
                break
            fi
            parent=${parent%/*}
        done
    done
}
lock_state() {
    (( EUID == 0 )) || die 'apply/revert require root; use --dry-run or --diagnose without root'
    local parent=$ROOT/var/lib
    [[ ! -L $parent ]] || die 'state parent must not be a symlink'
    if [[ -e $parent ]]; then
        [[ -z $(find -P "$parent" -maxdepth 0 \( ! -uid 0 -o -perm /022 \) -print) ]] || die 'state parent must be root-owned and not group/world writable'
    fi
    if [[ -e $STATE || -L $STATE ]]; then safe_tree "$STATE"; fi
    mkdir -p "$STATE"; chmod 700 "$STATE"
    exec 9>"$STATE/lock"
    flock -n 9 || die 'another optimizer operation holds the lock'
    safe_tree "$STATE"
}
service_state() {
    local service=$1 enabled active
    enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
    active=$(systemctl is-active "$service" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$service" "${enabled:-not-found}" "${active:-inactive}"
}
snapshot() {
    local dir=$1 path index=0 key value
    mkdir -m 700 "$dir" "$dir/files"
    printf '%s\n' "$NIC" > "$dir/nic"
    tc -details qdisc show dev "$NIC" > "$dir/qdisc"
    qdisc_parse "$(cat "$dir/qdisc")"
    : > "$dir/manifest"; : > "$dir/absent-dirs"; : > "$dir/sysctl"
    for path in "${FILES[@]}"; do
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] || die "managed path must be a regular file: $path"
        if [[ -e $path ]]; then
            cp -a -- "$path" "$dir/files/$index"
            printf '%s\t%s\n' "$path" "$index" >> "$dir/manifest"
        else printf '%s\t-\n' "$path" >> "$dir/manifest"; fi
        [[ -d ${path%/*} ]] || printf '%s\n' "${path%/*}" >> "$dir/absent-dirs"
        index=$((index+1))
    done
    for key in "${KEYS[@]}"; do
        if value=$(sysctl -n "$key" 2>/dev/null); then printf '%s\t%s\n' "$key" "$value" >> "$dir/sysctl"; fi
    done
    { service_state "$SERVICE"; service_state "$LEGACY_SERVICE"; } > "$dir/services"
}
restore_snapshot() {
    local dir=$1 path index key value service enabled active nic rc=0
    nic=$(cat "$dir/nic")
    valid_nic "$nic"
    if [[ $(systemctl show "$SERVICE" -p LoadState --value) != not-found ]]; then
        systemctl disable --now "$SERVICE" >/dev/null 2>&1 || rc=1
    fi
    while IFS=$'\t' read -r path index; do
        [[ " ${FILES[*]} " == *" $path "* ]] || { warn "unknown snapshot path: $path"; return 1; }
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] || { warn "unsafe restore destination: $path"; return 1; }
        if [[ $index == - ]]; then rm -f -- "$path" || rc=1
        elif [[ $index =~ ^[0-9]+$ && -f $dir/files/$index ]]; then
            mkdir -p "${path%/*}" && cp -a -- "$dir/files/$index" "$path" || rc=1
        else warn 'invalid snapshot manifest'; return 1; fi
    done < "$dir/manifest"
    systemctl daemon-reload || rc=1
    while IFS=$'\t' read -r service enabled active; do
        [[ $service == "$SERVICE" || $service == "$LEGACY_SERVICE" ]] || return 1
        case $enabled in
            enabled) systemctl enable "$service" >/dev/null || rc=1 ;;
            enabled-runtime) systemctl enable --runtime "$service" >/dev/null || rc=1 ;;
            *) systemctl disable "$service" >/dev/null 2>&1 || true ;;
        esac
        if [[ $active == active ]]; then systemctl restart "$service" || rc=1
        elif [[ $enabled != not-found ]]; then systemctl stop "$service" || rc=1; fi
    done < "$dir/services"
    # An original helper can itself change networking when restarted. Restore
    # runtime state last so that its side effects do not overwrite the snapshot.
    while IFS=$'\t' read -r key value; do
        [[ " ${KEYS[*]} " == *" $key "* ]] || { warn 'unknown snapshot sysctl'; return 1; }
        sysctl -q -w "$key=$value" || rc=1
        [[ $(sysctl -n "$key" | awk '{$1=$1;print}') == "$(awk '{$1=$1;print}' <<< "$value")" ]] || rc=1
    done < "$dir/sysctl"
    qdisc_restore "$nic" "$(cat "$dir/qdisc")" || rc=1
    while IFS= read -r path; do rmdir --ignore-fail-on-non-empty -- "$path" 2>/dev/null || true; done < "$dir/absent-dirs"
    return "$rc"
}
if [[ $MODE == revert ]]; then
    for command in systemctl flock find stat cp chmod mkdir rm cat rmdir; do need "$command"; done
    lock_state
    [[ -d $STATE/original ]] || die 'no original snapshot exists'
    if restore_snapshot "$STATE/original"; then
        rm -rf -- "$STATE/original" "$STATE/checkpoint"
        say 'Restored original files, runtime sysctls, qdisc configuration and service state.'
    else die 'revert incomplete; snapshot retained, correct the reported failure and retry'; fi
    exit 0
fi
BANDWIDTH_MBIT=$(number BANDWIDTH_MBIT "${BANDWIDTH_MBIT:-1000}" 1 100000)
BDP_RTT_MS=$(number BDP_RTT_MS "${BDP_RTT_MS:-100}" 1 2000)
NOFILE=$(number NOFILE "${NOFILE:-65536}" 65536 131072)
NIC=${NIC:-$(ip route show default | awk '$1=="default" {for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')}
[[ -n $NIC ]] || die 'no default-route NIC; set NIC explicitly'
valid_nic "$NIC"
RAM_KB=$(awk '/^MemTotal:/ {print $2; exit}' "$ROOT/proc/meminfo")
RAM_KB=$(number MemTotal_kB "$RAM_KB" 1024 999999999)
RAM_BYTES=$((RAM_KB*1024))
BDP=$((BANDWIDTH_MBIT*125*BDP_RTT_MS))
SOCKET_TARGET=$((2*BDP))
(( SOCKET_TARGET <= RAM_BYTES/32 )) || SOCKET_TARGET=$((RAM_BYTES/32))
(( SOCKET_TARGET <= 16777216 )) || SOCKET_TARGET=16777216
for key in "${KEYS[@]}"; do
    if value=$(sysctl -n "$key" 2>/dev/null); then CURRENT[$key]=$value
    else die "unsupported required parameter: $key"; fi
done
FALLBACK_QDISC=fq_codel
[[ ${CURRENT[net.ipv4.tcp_congestion_control]} != bbr* ]] || FALLBACK_QDISC=fq
TARGET[net.ipv4.tcp_congestion_control]=${CURRENT[net.ipv4.tcp_congestion_control]}
TARGET[net.core.default_qdisc]=${CURRENT[net.core.default_qdisc]}
if [[ $PROFILE == bbr ]]; then
    FALLBACK_QDISC=fq
    TARGET[net.ipv4.tcp_congestion_control]=bbr
    TARGET[net.core.default_qdisc]=fq
elif [[ ${CURRENT[net.core.default_qdisc]} != fq && ${CURRENT[net.core.default_qdisc]} != fq_codel ]]; then
    TARGET[net.core.default_qdisc]=$FALLBACK_QDISC
fi
TARGET[net.ipv4.tcp_moderate_rcvbuf]=1
TARGET[net.ipv4.tcp_mtu_probing]=1
for key in net.core.rmem_max net.core.wmem_max; do
    value=$(number "$key" "${CURRENT[$key]}" 1 999999999)
    (( value >= SOCKET_TARGET )) || value=$SOCKET_TARGET
    TARGET[$key]=$value
done
for key in net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    read -r low initial maximum extra <<< "${CURRENT[$key]}"
    [[ -z ${extra:-} ]] || die "invalid current $key"
    low=$(number "$key minimum" "$low" 1 999999999)
    initial=$(number "$key initial" "$initial" 1 999999999)
    maximum=$(number "$key maximum" "$maximum" 1 999999999)
    (( maximum >= SOCKET_TARGET )) || maximum=$SOCKET_TARGET
    TARGET[$key]="$low $initial $maximum"
done
QDISC_TEXT=$(tc -details qdisc show dev "$NIC")
qdisc_parse "$QDISC_TEXT"
[[ -z $(tc filter show dev "$NIC") ]] || die 'existing egress filters are unsupported; configure fq manually'
LOAD_BBR=0
if [[ $PROFILE == bbr ]]; then
    AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    if [[ " $AVAILABLE " != *' bbr '* ]]; then
        need modprobe
        modprobe -n tcp_bbr >/dev/null 2>&1 || die 'BBR is unavailable and tcp_bbr cannot be loaded'
        LOAD_BBR=1
    fi
fi
LEGACY_FOUND=0
for path in "${LEGACY[@]}"; do
    if [[ -e $ROOT$path || -L $ROOT$path ]]; then warn "legacy managed file: $path"; LEGACY_FOUND=1; fi
done
if (( LEGACY_FOUND && !MIGRATE )); then die 'legacy v1 tuning detected; review its effects and use --migrate-legacy explicitly'; fi
say "profile=$PROFILE NIC=$NIC RAM=${RAM_KB}KiB bandwidth budget=${BANDWIDTH_MBIT}Mbit/s RTT=${BDP_RTT_MS}ms BDP=${BDP}B socket target=${SOCKET_TARGET}B"
say 'Bandwidth is an assumed/configured budget, never detected from advertised NIC speed.'
for key in "${KEYS[@]}"; do say "$key = ${TARGET[$key]} (was ${CURRENT[$key]})"; done
say 'Existing larger maxima are preserved; aggregate memory, initial/default allocations and txqueuelen are unchanged.'
say "Egress policy: profile=$PROFILE FIFO fallback=$FALLBACK_QDISC; preserve mq root and fq options, enable fq pacing."
[[ $PROFILE != balanced ]] || say 'Balanced preserves current congestion control and supported fq/fq_codel queues.'
if [[ $MODE == dry-run ]]; then say 'Dry-run complete: no host or state changes.'; exit 0; fi
for command in systemctl systemd-analyze flock find stat cp chmod mkdir rm cat rmdir mktemp mv; do need "$command"; done
[[ -d $ROOT/run/systemd/system ]] || die 'a running systemd host is required'
lock_state
validate_managed_paths
[[ ! -d $STATE/original || $(cat "$STATE/original/nic") == "$NIC" ]] || die 'NIC differs from original snapshot; revert before changing NIC'
[[ ! -d $STATE/checkpoint ]] || die 'unfinished transaction exists; run --revert before applying again'
FIRST=0
CHECKPOINT_CREATED=0
setup_failed() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    rm -rf -- "$STATE/checkpoint-staging" "$STATE/original-staging"
    (( CHECKPOINT_CREATED == 0 )) || rm -rf -- "$STATE/checkpoint"
    (( FIRST == 0 )) || rm -rf -- "$STATE/original"
    warn 'snapshot setup failed; staging removed, host tuning was not changed'
    exit "$rc"
}
trap setup_failed EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Staging left by a process killed before publication contains no host changes.
rm -rf -- "$STATE/checkpoint-staging" "$STATE/original-staging"
snapshot "$STATE/checkpoint-staging"
if [[ ! -d $STATE/original ]]; then
    cp -a "$STATE/checkpoint-staging" "$STATE/original-staging"
    mv -T "$STATE/original-staging" "$STATE/original"
    FIRST=1
fi
mv -T "$STATE/checkpoint-staging" "$STATE/checkpoint"
CHECKPOINT_CREATED=1
rollback() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    [[ -z ${temp:-} ]] || rm -f -- "$temp"
    warn "apply failed (status $rc); restoring this apply's checkpoint"
    if restore_snapshot "$STATE/checkpoint"; then
        rm -rf -- "$STATE/checkpoint"
        (( FIRST == 0 )) || rm -rf -- "$STATE/original"
        warn 'transaction rolled back'
    else warn 'ROLLBACK INCOMPLETE; snapshots retained; run --revert after correcting the failure'; fi
    exit "$rc"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if (( LOAD_BBR )); then
    modprobe tcp_bbr
    warn 'tcp_bbr was loaded; rollback/revert restore the default algorithm but leave the module loaded to protect live connections.'
fi
if [[ $PROFILE == bbr ]]; then
    AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    [[ " $AVAILABLE " == *' bbr '* ]] || die 'BBR did not become available'
fi
if (( MIGRATE && LEGACY_FOUND )); then
    if [[ $(systemctl show "$LEGACY_SERVICE" -p LoadState --value) != not-found ]]; then
        systemctl disable --now "$LEGACY_SERVICE"
    fi
    for path in "${LEGACY[@]}"; do rm -f -- "$ROOT$path"; done
    warn 'Legacy persistent files removed. Inherited runtime VM/IPv6/NIC/Docker changes remain; review Docker .xray.bak files manually and reboot to a reviewed baseline.'
fi
mkdir -p "${SYSCTL%/*}" "${HELPER%/*}" "${UNIT%/*}"
temp=$(mktemp "${SYSCTL}.XXXXXX")
{
    say '# Managed by exit-node-optimizer; see tune.sh --revert.'
    for key in "${KEYS[@]}"; do say "$key = ${TARGET[$key]}"; done
} > "$temp"
chmod 644 "$temp"; mv -f "$temp" "$SYSCTL"
verify_persistent_sysctls
temp=$(mktemp "${HELPER}.XXXXXX")
{
    say '#!/usr/bin/env bash'; say 'set -Eeuo pipefail'
    printf 'ROOT=%q\n' "$ROOT"
    printf 'PROFILE=%q\nFALLBACK_QDISC=%q\n' "$PROFILE" "$FALLBACK_QDISC"
    RESERVED_QDISC_HANDLES=$(awk '$1=="qdisc" {printf "%s ", $3}' "$STATE/original/qdisc")
    printf 'RESERVED_QDISC_HANDLES=%q\n' "$RESERVED_QDISC_HANDLES"
    declare -f die valid_nic size_bytes qdisc_parse qdisc_delete qdisc_replace qdisc_apply qdisc_verify_profile
    cat <<'EOF'
[[ $# == 1 ]] || die "usage: exit-node-optimizer-fq NIC"
valid_nic "$1"
qdisc_apply "$1"
EOF
} > "$temp"
chmod 755 "$temp"; mv -f "$temp" "$HELPER"
cat > "$UNIT" <<EOF
[Unit]
Description=Conservative $PROFILE egress qdisc policy for $NIC
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/exit-node-optimizer-fq $NIC
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT"
for unit in "${XRAY_UNITS[@]}"; do
    if native_unit_exists "$unit"; then
        if [[ $unit == *@.service ]]; then
            warn "$unit: uninstantiated template; limits unchanged because effective instance limits are unknown. Review the active instances manually."
            continue
        fi
        native_nofile "$unit"
        path=$ROOT/etc/systemd/system/$unit.d/90-exit-node-optimizer.conf
        mkdir -p "${path%/*}"
        printf '[Service]\nLimitNOFILE=%s:%s\n' "$LIMIT_SOFT" "$LIMIT_HARD" > "$path"; chmod 644 "$path"
        say "$unit: LimitNOFILE=$LIMIT_SOFT:$LIMIT_HARD; takes effect at its next operator-managed restart."
    fi
done
for key in "${KEYS[@]}"; do sysctl -q -w "$key=${TARGET[$key]}"; done
for key in "${KEYS[@]}"; do
    value=$(sysctl -n "$key")
    [[ $(awk '{$1=$1;print}' <<< "$value") == "${TARGET[$key]}" ]] || die "verification failed: $key"
done
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"
qdisc_parse "$(tc -details qdisc show dev "$NIC")"
qdisc_verify_profile
rm -rf -- "$STATE/checkpoint"
trap - EXIT INT TERM
say "Applied and verified profile=$PROFILE, socket settings, egress queues and persistence. Original snapshot retained for --revert."
say "Default TCP congestion control: ${TARGET[net.ipv4.tcp_congestion_control]}. Existing connections and application-selected algorithms may retain another algorithm. No application restarts were performed."
