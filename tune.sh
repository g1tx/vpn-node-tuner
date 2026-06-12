#!/usr/bin/env bash
#==============================================================================
# tune-net-merged.sh — Universal network tuning for Xray VLESS+REALITY+TCP exit
#                      nodes (Docker + Remnawave). Low VPS -> High bare-metal.
#
# = ВЕРИФИЦИРОВАННЫЙ БАЗИС (11 расхождений) +
#   5 ПОЛЕЗНЫХ БЛОКОВ из optimization.sh:
#     (1) VM/IO tuning  (2) security-hardening sysctl  (3) ARP/neigh gc_thresh
#     (4) ethtool offloads/ring/RSS  (5) Docker log rotation
#
# ОТВЕРГНУТО как cargo-cult/риск: netdev_budget=30000, established=600,
#   notsent_lowat=16384, ip_local_port_range с 1024, rp_filter strict(1).
#
# Безопасно под set -Eeuo pipefail; идемпотентно; ничего не ломает по умолчанию.
# Запуск:  sudo ./tune-net-merged.sh        Откат:  sudo ./tune-net-merged.sh --revert
#==============================================================================
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "ERROR: запускать от root (sudo)." >&2; exit 1; fi

LOG=/var/log/xray-reality-sysctl.log
SYSCTL=/etc/sysctl.d/99-xray-reality-tuning.conf
LIMITS=/etc/security/limits.d/99-xray-reality.conf
MODPROBE=/etc/modprobe.d/99-xray-conntrack.conf
RPS_SCRIPT=/usr/local/sbin/xray-reality-rps-xps.sh
RPS_UNIT=/etc/systemd/system/xray-reality-rps-xps.service
DAEMON_JSON=/etc/docker/daemon.json

log(){ printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
trap 'log "ERROR на строке $LINENO (rc=$?)"' ERR

if [[ "${1:-}" == "--revert" ]]; then
  rm -f "$SYSCTL" "$LIMITS" "$MODPROBE" "$RPS_SCRIPT" "$RPS_UNIT"
  systemctl disable --now xray-reality-rps-xps.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  log "Откат выполнен. sysctl-дефолты вернутся после перезагрузки."; exit 0
fi

#==============================================================================
# 0. Детекция железа
#==============================================================================
CPU=$(nproc)
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MB=$(( RAM_KB / 1024 )); RAM_BYTES=$(( RAM_KB * 1024 ))
PAGE=$(getconf PAGE_SIZE)

NIC="${NIC:-$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')}"
[[ -z "${NIC:-}" ]] && NIC=$(ls /sys/class/net | grep -v '^lo$' | head -n1)
DRIVER=unknown
[[ -n "$NIC" ]] && command -v ethtool >/dev/null 2>&1 && \
  DRIVER=$(ethtool -i "$NIC" 2>/dev/null | awk -F': ' '/^driver:/{print $2}' || echo unknown)
SPEED_MBIT="${BANDWIDTH_MBIT:-$(cat /sys/class/net/"$NIC"/speed 2>/dev/null || echo 1000)}"
[[ "$SPEED_MBIT" =~ ^[0-9]+$ ]] && (( SPEED_MBIT > 0 )) || SPEED_MBIT=1000
SPEED_FACTOR=$(( (SPEED_MBIT + 999) / 1000 ))
(( SPEED_FACTOR < 1 )) && SPEED_FACTOR=1; (( SPEED_FACTOR > 100 )) && SPEED_FACTOR=100

if   (( RAM_MB <= 4096 || CPU <= 2 ));  then TIER=0; TIER_NAME=Low
elif (( RAM_MB <= 32768 && CPU <= 8 )); then TIER=1; TIER_NAME=Medium
else TIER=2; TIER_NAME=High; fi

clamp(){ local v=$1 lo=$2 hi=$3; (( v<lo )) && v=$lo; (( v>hi )) && v=$hi; printf '%s' "$v"; }
GIB=$(( 1024*1024*1024 ))
log "Tier=$TIER_NAME cpu=$CPU ram=${RAM_MB}MB nic=$NIC drv=$DRIVER speed=${SPEED_MBIT}Mbit page=$PAGE"

#==============================================================================
# Формулы (верифицированный базис)
#==============================================================================
# #1 netdev_budget — cap 8000 (НЕ 30000)
NAPI_SCORE=$(( (CPU-1) * SPEED_FACTOR )); NAPI_MAX=$(( 127 * 100 )); (( NAPI_MAX<1 )) && NAPI_MAX=1
NETDEV_BUDGET=$(clamp $(( 300 + 7700 * NAPI_SCORE / NAPI_MAX )) 300 8000)
NETDEV_USECS=$(clamp $(( 2000 + 6000 * NAPI_SCORE / NAPI_MAX )) 2000 8000)
NETDEV_BACKLOG=$(clamp $(( 1000 + CPU*SPEED_FACTOR*1000 )) 1000 1000000)

NOFILE=$(clamp $(( RAM_MB * 512 )) 1048576 2097152); FILE_MAX=$(( NOFILE * 2 ))

# #2 conntrack_max — мягкий RAM*64 + mem-cap (320 B/запись)
CT_DIV=$(( TIER==2 ? 16 : 32 ))
CT_BY_RAM=$(( RAM_MB * 64 )); CT_BY_CPU=$(( CPU * SPEED_FACTOR * 8192 ))
CT_MEM_CAP=$(( RAM_BYTES / CT_DIV / 320 ))
CT_RAW=$(( CT_BY_RAM > CT_BY_CPU ? CT_BY_RAM : CT_BY_CPU ))
(( CT_RAW > CT_MEM_CAP )) && CT_RAW=$CT_MEM_CAP
NF_CONNTRACK_MAX=$(clamp "$CT_RAW" 65536 16777216)

# #3 hashsize — max/2; =max только RAM>=64GB И CT_BOTTLENECK=1
if (( RAM_MB >= 65536 )) && [[ "${CT_BOTTLENECK:-0}" == "1" ]]; then NF_HASHSIZE=$NF_CONNTRACK_MAX
else NF_HASHSIZE=$(( NF_CONNTRACK_MAX / 2 )); fi

# #4 ct_established — tiered (НЕ 600), env override
case $TIER in 0) CT_EST_DEF=3600 ;; 1) CT_EST_DEF=14400 ;; 2) CT_EST_DEF=43200 ;; esac
CT_ESTABLISHED="${CT_ESTABLISHED:-$CT_EST_DEF}"
KEEPALIVE_TIME="${KEEPALIVE_TIME:-600}"

# #5 notsent_lowat — tiered (НЕ 16384)
case $TIER in 0) NOTSENT_LOWAT=131072 ;; 1) NOTSENT_LOWAT=262144 ;; 2) NOTSENT_LOWAT=524288 ;; esac

# #6/#7 BDP(100ms) + sock_max
BDP_RTT_MS="${BDP_RTT_MS:-100}"
BDP=$(( SPEED_MBIT * 1000000 / 8 * BDP_RTT_MS / 1000 ))
case $TIER in 0) TIER_CAP=$((16*1024*1024)) ;; 1) TIER_CAP=$((64*1024*1024)) ;; 2) TIER_CAP=$((256*1024*1024)) ;; esac
RAM_FRAC32=$(( RAM_BYTES / 32 )); SOCK_MAX=$(( 2 * BDP ))
(( SOCK_MAX > TIER_CAP ))   && SOCK_MAX=$TIER_CAP
(( SOCK_MAX > RAM_FRAC32 )) && SOCK_MAX=$RAM_FRAC32
SOCK_MAX=$(clamp "$SOCK_MAX" $((8*1024*1024)) $((256*1024*1024)))

TW_BUCKETS=$(clamp $(( RAM_MB * 64 )) 131072 4194304)
MAX_ORPHANS=$(clamp $(( RAM_MB * 16 )) 32768 1048576)

TCP_FRAC=$(( RAM_MB <= 4096 ? 16 : 8 ))
TCP_MAX_BYTES=$(( RAM_BYTES / TCP_FRAC )); (( TCP_MAX_BYTES > 32*GIB )) && TCP_MAX_BYTES=$(( 32*GIB ))
TCP_MEM_MAX=$(( TCP_MAX_BYTES / PAGE )); TCP_MEM_PRESSURE=$(( TCP_MEM_MAX*7/8 )); TCP_MEM_MIN=$(( TCP_MEM_MAX*3/4 ))
UDP_MAX_BYTES=$(( RAM_BYTES / 32 ))
(( UDP_MAX_BYTES < 16*1024*1024 )) && UDP_MAX_BYTES=$(( 16*1024*1024 ))
(( UDP_MAX_BYTES > 8*GIB )) && UDP_MAX_BYTES=$(( 8*GIB ))
UDP_MEM_MAX=$(( UDP_MAX_BYTES / PAGE )); UDP_MEM_PRESSURE=$(( UDP_MEM_MAX*7/8 )); UDP_MEM_MIN=$(( UDP_MEM_MAX*3/4 ))

# #8 somaxconn / syn_backlog
SOMAXCONN=$(clamp $(( 1024 + CPU*SPEED_FACTOR*256 )) 4096 65535)
SYN_BACKLOG=$(clamp $(( 2*SOMAXCONN )) 8192 262144)

# #11 src_valid_mark — НЕ ставим
RP_FILTER_MODE="${RP_FILTER_MODE:-2}"   # loose (НЕ strict)
TCP_FASTOPEN="${TCP_FASTOPEN:-3}"
PORT_RANGE_LOW="${PORT_RANGE_LOW:-10000}"   # НЕ 1024
RESERVED_PORTS="${RESERVED_PORTS:-}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
OPTMEM_MAX=1048576

# --- БЛОК 3 (из optimization.sh): ARP/neigh gc_thresh, tier-scaled ---
case $TIER in
  0) GC1=1024; GC2=4096;  GC3=8192  ;;
  1) GC1=2048; GC2=8192;  GC3=16384 ;;
  2) GC1=4096; GC2=16384; GC3=32768 ;;
esac

#==============================================================================
# 1. sysctl drop-in
#==============================================================================
{
  echo "# Auto-generated $(date -Is) — tier=$TIER_NAME cpu=$CPU ram=${RAM_MB}MB nic=$NIC@${SPEED_MBIT}Mbit drv=$DRIVER"
  echo "# === RX/softirq (#1) ==="
  echo "net.core.netdev_budget = $NETDEV_BUDGET"
  echo "net.core.netdev_budget_usecs = $NETDEV_USECS"
  echo "net.core.netdev_max_backlog = $NETDEV_BACKLOG"
  echo "net.core.dev_weight = 64"
  echo "# === conntrack (#2,#4) ==="
  echo "net.netfilter.nf_conntrack_max = $NF_CONNTRACK_MAX"
  echo "net.netfilter.nf_conntrack_tcp_timeout_established = $CT_ESTABLISHED"
  echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60"
  echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30"
  echo "net.netfilter.nf_conntrack_udp_timeout = 30"
  echo "net.netfilter.nf_conntrack_udp_timeout_stream = 60"
  echo "# === TCP memory / buffers (#5,#6,#7) ==="
  echo "net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
  echo "net.ipv4.udp_mem = $UDP_MEM_MIN $UDP_MEM_PRESSURE $UDP_MEM_MAX"
  echo "net.core.rmem_default = 1048576"
  echo "net.core.wmem_default = 1048576"
  echo "net.core.rmem_max = $SOCK_MAX"
  echo "net.core.wmem_max = $SOCK_MAX"
  echo "net.core.optmem_max = $OPTMEM_MAX"
  echo "net.ipv4.tcp_rmem = 4096 131072 $SOCK_MAX"
  echo "net.ipv4.tcp_wmem = 4096 16384 $SOCK_MAX"
  echo "net.ipv4.tcp_moderate_rcvbuf = 1"
  echo "net.ipv4.tcp_notsent_lowat = $NOTSENT_LOWAT"
  echo "net.ipv4.tcp_max_tw_buckets = $TW_BUCKETS"
  echo "net.ipv4.tcp_max_orphans = $MAX_ORPHANS"
  echo "# === Accept/SYN queues (#8) ==="
  echo "net.core.somaxconn = $SOMAXCONN"
  echo "net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG"
  echo "net.ipv4.tcp_syncookies = 1"
  echo "# === keepalive / timeouts ==="
  echo "net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME"
  echo "net.ipv4.tcp_keepalive_intvl = 30"
  echo "net.ipv4.tcp_keepalive_probes = 5"
  echo "net.ipv4.tcp_fin_timeout = 15"
  echo "net.ipv4.tcp_tw_reuse = 1"
  echo "# === throughput / latency ==="
  echo "net.core.default_qdisc = fq"
  echo "net.ipv4.tcp_congestion_control = bbr"
  echo "net.ipv4.tcp_fastopen = $TCP_FASTOPEN"
  echo "net.ipv4.tcp_mtu_probing = 1"
  echo "net.ipv4.tcp_slow_start_after_idle = 0"
  echo "net.ipv4.tcp_window_scaling = 1"
  echo "net.ipv4.tcp_sack = 1"
  echo "net.ipv4.tcp_timestamps = 1"
  echo "net.ipv4.tcp_ecn = 0"
  echo "# === forwarding / RPF (#11: src_valid_mark НЕ ставим; rp_filter=loose) ==="
  echo "net.ipv4.ip_forward = 1"
  echo "net.ipv4.conf.all.forwarding = 1"
  echo "net.ipv4.conf.all.rp_filter = $RP_FILTER_MODE"
  echo "net.ipv4.conf.default.rp_filter = $RP_FILTER_MODE"
  echo "net.ipv4.ip_local_port_range = $PORT_RANGE_LOW 65535"
  [[ -n "$RESERVED_PORTS" ]] && echo "net.ipv4.ip_local_reserved_ports = $RESERVED_PORTS"
  echo "fs.nr_open = $NOFILE"
  echo "fs.file-max = $FILE_MAX"
  echo "# === [БЛОК 1] VM / I/O tuning ==="
  echo "vm.swappiness = 10"
  echo "vm.dirty_ratio = 20"
  echo "vm.dirty_background_ratio = 5"
  echo "vm.dirty_expire_centisecs = 500"
  echo "vm.overcommit_memory = 0"
  echo "# === [БЛОК 1] kernel limits ==="
  echo "kernel.pid_max = 4194304"
  echo "kernel.threads-max = $(clamp $(( RAM_MB * 64 )) 65536 4194304)"
  echo "# === [БЛОК 2] security hardening ==="
  echo "net.ipv4.conf.all.send_redirects = 0"
  echo "net.ipv4.conf.default.send_redirects = 0"
  echo "net.ipv4.conf.all.accept_redirects = 0"
  echo "net.ipv4.conf.default.accept_redirects = 0"
  echo "net.ipv4.conf.all.accept_source_route = 0"
  echo "net.ipv4.conf.default.accept_source_route = 0"
  echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"
  echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"
  echo "# === [БЛОК 3] ARP / neigh table scaling ==="
  echo "net.ipv4.neigh.default.gc_thresh1 = $GC1"
  echo "net.ipv4.neigh.default.gc_thresh2 = $GC2"
  echo "net.ipv4.neigh.default.gc_thresh3 = $GC3"
  if [[ "$DISABLE_IPV6" == "1" ]]; then
    echo "# === IPv6 policy: disabled ==="
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
  else
    echo "net.ipv6.conf.all.forwarding = 1"
  fi
} > "$SYSCTL"

sysctl -p "$SYSCTL" >/dev/null && log "sysctl применён: $SYSCTL"

#==============================================================================
# 2. conntrack hashsize (#3) + persist
#==============================================================================
if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
  echo "$NF_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize || true
fi
echo "options nf_conntrack hashsize=$NF_HASHSIZE" > "$MODPROBE"
log "conntrack hashsize=$NF_HASHSIZE (max=$NF_CONNTRACK_MAX)"

#==============================================================================
# 3. limits.d
#==============================================================================
cat > "$LIMITS" <<EOF
# Auto-generated $(date -Is)
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF
log "limits.d записан: NOFILE=$NOFILE"

#==============================================================================
# 4. Персистентный NIC-скрипт: ethtool offloads/ring/RSS [БЛОК 4]
#    + RPS/XPS grouped, NUMA-aware
#==============================================================================
cat > "$RPS_SCRIPT" <<'RPSEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
NIC="${1:?usage: rps-xps.sh <nic>}"
DRIVER=$(ethtool -i "$NIC" 2>/dev/null | awk -F': ' '/^driver:/{print $2}' || echo unknown)
TOTAL_CPU=$(nproc)

# --- [БЛОК 4] ethtool offloads (безопасные для прокси) ---
ip link set dev "$NIC" txqueuelen 5000 2>/dev/null || true
ethtool -K "$NIC" gro on lro off tso on 2>/dev/null || true
# ring buffers и RSS-каналы — только на физических NIC (НЕ virtio_net)
if [[ "$DRIVER" != "virtio_net" && "$DRIVER" != "unknown" ]]; then
  ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null || true
  if (( TOTAL_CPU >= 4 )); then
    MAXC=$(ethtool -l "$NIC" 2>/dev/null | awk '/Pre-set maximums/{f=1} f&&/Combined:/{print $2; exit}')
    if [[ -n "${MAXC:-}" && "$MAXC" != "n/a" && "$MAXC" != "0" ]]; then
      TARGET=$(( TOTAL_CPU < MAXC ? TOTAL_CPU : MAXC ))
      ethtool -L "$NIC" combined "$TARGET" 2>/dev/null || true
    fi
  fi
fi

cpu_mask(){ local -a bits=(); local c
  for c in "$@"; do bits[$((c/32))]=$(( ${bits[$((c/32))]:-0} | (1 << (c%32)) )); done
  local out="" i
  for (( i=${#bits[@]}-1; i>=0; i-- )); do out+=$(printf '%08x' "${bits[$i]:-0}"); [[ $i -gt 0 ]] && out+=","; done
  printf '%s' "$out"; }

NODE=$(cat "/sys/class/net/$NIC/device/numa_node" 2>/dev/null || echo -1)
if [[ "$NODE" -ge 0 && -r "/sys/devices/system/node/node$NODE/cpulist" ]]; then
  mapfile -t NODE_CPUS < <(awk 'BEGIN{RS=","}{if($0~/-/){split($0,a,"-");for(i=a[1];i<=a[2];i++)print i}else print}' \
                          "/sys/devices/system/node/node$NODE/cpulist")
else NODE_CPUS=(); for ((c=0;c<TOTAL_CPU;c++)); do NODE_CPUS+=($c); done; fi
NCPUS=${#NODE_CPUS[@]}; (( NCPUS<1 )) && { NODE_CPUS=(0); NCPUS=1; }
RXQ=$(ls -d /sys/class/net/$NIC/queues/rx-* 2>/dev/null | wc -l)
TXQ=$(ls -d /sys/class/net/$NIC/queues/tx-* 2>/dev/null | wc -l)

# RPS — только если RX-очередей < CPU (иначе RSS уже распределяет)
if (( RXQ < TOTAL_CPU )); then
  RPS=$(cpu_mask "${NODE_CPUS[@]}")
  for q in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do echo "$RPS" > "$q" 2>/dev/null || true; done
  echo "RPS enabled (rxq=$RXQ < cpu=$TOTAL_CPU) mask=$RPS"
else
  for q in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do echo 0 > "$q" 2>/dev/null || true; done
  echo "RPS skipped (rxq=$RXQ >= cpu=$TOTAL_CPU)"
fi

# XPS grouped: каждой TX-очереди — disjoint подмножество CPU NUMA-узла
if (( TXQ > 1 )); then
  i=0
  for q in /sys/class/net/$NIC/queues/tx-*/xps_cpus; do
    grp=(); for ((j=0;j<NCPUS;j++)); do (( j % TXQ == i % TXQ )) && grp+=("${NODE_CPUS[$j]}"); done
    (( ${#grp[@]} == 0 )) && grp=("${NODE_CPUS[$(( i % NCPUS ))]}")
    echo "$(cpu_mask "${grp[@]}")" > "$q" 2>/dev/null || true
    i=$((i+1))
  done
  echo "XPS grouped applied (txq=$TXQ numa_node=$NODE)"
else echo "XPS skipped (single TX queue)"; fi
RPSEOF
chmod +x "$RPS_SCRIPT"

cat > "$RPS_UNIT" <<EOF
[Unit]
Description=Xray REALITY NIC offloads + RPS/XPS tuning ($NIC)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RPS_SCRIPT $NIC
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xray-reality-rps-xps.service >/dev/null 2>&1 || "$RPS_SCRIPT" "$NIC" | tee -a "$LOG"
log "NIC/RPS/XPS service установлен и запущен"

#==============================================================================
# 5. systemd TasksMax (#9 Xray=65536)
#==============================================================================
install_tasksmax(){ local unit="$1" val="$2" d="/etc/systemd/system/$1.d"
  systemctl list-unit-files "$unit.service" >/dev/null 2>&1 || { log "unit $unit не найден — пропуск TasksMax"; return 0; }
  mkdir -p "$d"
  printf '[Service]\nTasksMax=%s\nLimitNOFILE=%s\n' "$val" "$NOFILE" > "$d/99-xray-reality-limits.conf"
  log "$unit: TasksMax=$val LimitNOFILE=$NOFILE"; }
for u in xray xray-core; do install_tasksmax "$u" 65536; done
for u in docker; do install_tasksmax "$u" infinity; done
systemctl daemon-reload

#==============================================================================
# 6. Docker daemon.json — патч + log rotation [БЛОК 5] + key-aware apply (#10)
#==============================================================================
if command -v docker >/dev/null 2>&1; then
  mkdir -p /etc/docker
  OLD="$DAEMON_JSON.xray.bak.$(date +%s)"
  [[ -f "$DAEMON_JSON" ]] && cp -a "$DAEMON_JSON" "$OLD"
  IPV6_FLAG=false; IP6T_FLAG=false
  TMP=$(mktemp); EXISTING='{}'; [[ -f "$DAEMON_JSON" ]] && EXISTING=$(cat "$DAEMON_JSON")
  echo "$EXISTING" | jq \
    --argjson nofile "$NOFILE" --argjson ipv6 "$IPV6_FLAG" --argjson ip6t "$IP6T_FLAG" '
    . + {
      "live-restore": true,
      "userland-proxy": false,
      "ipv6": $ipv6,
      "ip6tables": $ip6t,
      "log-driver": "json-file",
      "log-opts": { "max-size": "10m", "max-file": "3" },
      "default-ulimits": { "nofile": { "Name": "nofile", "Soft": $nofile, "Hard": $nofile } }
    }' > "$TMP"
  CHANGED=$(jq -rn --argjson a "$EXISTING" --argjson b "$(cat "$TMP")" '
    ($b|keys[]) as $k | select(($a[$k]|tojson) != ($b[$k]|tojson)) | $k' | tr '\n' ' ')
  if dockerd --validate --config-file="$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$DAEMON_JSON"; log "daemon.json обновлён. Изменённые ключи: ${CHANGED:-нет}"
  else
    rm -f "$TMP"; log "daemon.json НЕ прошёл validate — пропуск (бэкап: ${OLD:-n/a})"; CHANGED=""
  fi
  RESTART_REQUIRED=0
  for k in $CHANGED; do
    case "$k" in
      debug|labels|insecure-registries|registry-mirrors|live-restore|max-concurrent-downloads|max-concurrent-uploads|runtimes) : ;;
      *) RESTART_REQUIRED=1 ;;
    esac
  done
  if [[ -n "$CHANGED" ]]; then
    if (( RESTART_REQUIRED )); then
      if [[ "${ALLOW_DOCKER_RESTART:-1}" == "1" ]]; then
        log "WARN: restart-required ключи ($CHANGED) → systemctl restart docker (краткий NAT-flap)"
        systemctl restart docker || log "restart docker не удался"
      else
        log "WARN: изменения требуют restart, но ALLOW_DOCKER_RESTART=0 → ОТЛОЖЕНЫ до ручного 'systemctl restart docker'"
      fi
    else
      systemctl reload docker 2>/dev/null && log "docker reload (reload-able ключи)" || systemctl restart docker
    fi
  fi
else
  log "docker не установлен — пропуск daemon.json"
fi

#==============================================================================
# 7. Итог
#==============================================================================
log "ГОТОВО. Tier=$TIER_NAME budget=$NETDEV_BUDGET conntrack=$NF_CONNTRACK_MAX hash=$NF_HASHSIZE \
ct_est=$CT_ESTABLISHED lowat=$NOTSENT_LOWAT sock_max=$SOCK_MAX somaxconn=$SOMAXCONN \
syn_backlog=$SYN_BACKLOG nofile=$NOFILE rp_filter=$RP_FILTER_MODE"
echo "OK — подробности в $LOG"
