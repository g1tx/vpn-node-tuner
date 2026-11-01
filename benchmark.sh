#!/usr/bin/env bash
# Explicit, bounded traffic test. Use endpoints you control or may benchmark.
set -Eeuo pipefail
usage() {
  cat <<'EOF'
Usage: bash benchmark.sh --download-url URL --probe-url URL [options]
  --download-url URL  Large HTTP(S) file for sustained download
  --probe-url URL     Small HTTP(S) response, measured idle and under load
  --proxy URL         Optional curl proxy, e.g. socks5h://127.0.0.1:1080
  --seconds N         Duration of load, 5..120 (default: 20)
  --parallel N        Concurrent downloads, 1..16 (default: 4)
  --output DIR        New report directory (default: benchmark-TIMESTAMP)

Run on a VPN client with --proxy to measure the complete proxy path.
Run without --proxy to measure that machine's direct path. These differ.
Downloads can use substantial traffic. URLs/proxy credentials are not saved.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
download='' probe='' proxy='' seconds=20 parallel=4 output=''
while (($#)); do
  case $1 in
    --help|-h) usage; exit 0;;
    --download-url|--probe-url|--proxy|--seconds|--parallel|--output)
      (($# >= 2)) || die "Missing value for $1"
      case $1 in
        --download-url) download=$2;; --probe-url) probe=$2;;
        --proxy) proxy=$2;; --seconds) seconds=$2;;
        --parallel) parallel=$2;; --output) output=$2;;
      esac
      shift 2;;
    *) die "Unknown argument: $1";;
  esac
done
[[ $download =~ ^https?:// && $probe =~ ^https?:// ]] || die 'Supply HTTP(S) download and probe URLs (--help).'
if [[ ! $seconds =~ ^[1-9][0-9]{0,2}$ ]] || ((seconds < 5 || seconds > 120)); then die 'seconds must be 5..120'; fi
if [[ ! $parallel =~ ^[1-9][0-9]?$ ]] || ((parallel > 16)); then die 'parallel must be 1..16'; fi
command -v curl >/dev/null || die 'curl is required'
output=${output:-benchmark-$(date -u +%Y%m%dT%H%M%SZ)}
[[ ! -e $output ]] || die 'Output directory already exists'
mkdir -m 700 -- "$output"
args=(--silent --show-error --location --proto '=http,https' --proto-redir '=http,https' --connect-timeout 5)
[[ -z $proxy ]] || args+=(--proxy "$proxy" --noproxy '')
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'phase\ttotal_s\tfirst_byte_s\thttp_code\tcurl_exit\n' > "$output/probes.tsv"
probe_once() {
  local phase=$1 result rc=0
  result=$(curl "${args[@]}" --max-time 5 --max-filesize 1048576 --output /dev/null \
    --write-out '%{time_total}\t%{time_starttransfer}\t%{http_code}' "$probe" 2>/dev/null) || rc=$?
  printf '%s\t%s\t%s\n' "$phase" "$result" "$rc" >> "$output/probes.tsv"
}
printf 'Collecting idle responses...\n'
for ((i=0;i<10;i++)); do probe_once idle; sleep 0.2; done
printf 'Loading path with %s downloads for up to %s seconds...\n' "$parallel" "$seconds"
start=$SECONDS
for ((i=1;i<=parallel;i++)); do
  (
    rc=0
    curl_pid=''
    trap '[[ -z $curl_pid ]] || kill "$curl_pid" 2>/dev/null || true; wait 2>/dev/null || true; exit 143' TERM INT
    curl "${args[@]}" --max-time "$seconds" --output /dev/null \
      --write-out '%{time_total}\t%{size_download}\t%{speed_download}\t%{http_code}\n' "$download" \
      > "$output/download-$i.tsv" 2>/dev/null &
    curl_pid=$!
    wait "$curl_pid" || rc=$?
    curl_pid=''
    printf '%s\n' "$rc" > "$output/download-$i.exit"
  ) &
  pids+=("$!")
done
while ((SECONDS - start < seconds)); do probe_once loaded; sleep 0.2; done
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
bad_downloads=0
short_downloads=0
for ((i=1;i<=parallel;i++)); do
  rc=$(cat "$output/download-$i.exit")
  if [[ $rc != 0 && $rc != 28 ]] || ! awk -F '\t' '
    NF==4 && $2>0 && $4>=200 && $4<400 {ok=1} END {exit !ok}
  ' "$output/download-$i.tsv"; then
    bad_downloads=$((bad_downloads+1))
  elif ! awk -F '\t' -v duration="$seconds" '$1>=duration*0.9 {ok=1} END {exit !ok}' "$output/download-$i.tsv"; then
    short_downloads=$((short_downloads+1))
  fi
done
phase_stats() {
  local phase=$1
  awk -F '\t' -v phase="$phase" 'NR>1 && $1==phase && $5==0 && $4>=200 && $4<400 {print $3*1000}' \
    "$output/probes.tsv" | sort -n | awk -v phase="$phase" '
    {v[NR]=$1; sum+=$1}
    END {
      if (!NR) {printf "%s: no successful probes\n",phase; exit}
      mid=int((NR+1)/2); median=v[mid]; if(NR%2==0) median=(v[mid]+v[mid+1])/2
      p95=int(NR*0.95); if(p95<NR*0.95) p95++
      printf "%s: %d successful probes; TTFB median %.2f ms, p95 %.2f ms\n",phase,NR,median,v[p95]
    }'
}
{
  phase_stats idle
  phase_stats loaded
  printf 'Probe errors (curl failure or HTTP outside 200..399): '
  awk -F '\t' 'NR>1 && ($5!=0 || $4<200 || $4>=400) {n++} END {print n+0}' "$output/probes.tsv"
  printf 'Failed downloads: %s / %s\n' "$bad_downloads" "$parallel"
  printf 'Downloads ending before 90%% of requested duration: %s / %s\n' "$short_downloads" "$parallel"
  if ((bad_downloads==0)); then
    awk -F '\t' '{bytes+=$2; if($1>duration)duration=$1} END {
      if(duration>0) printf "Aggregate download rate over longest download: %.2f Mbit/s\n",bytes*8/duration/1000000
    }' "$output"/download-*.tsv
  fi
  printf 'Raw probe timings: probes.tsv (seconds).\n'
  printf 'Per-download fields: duration_s, bytes, bytes_per_second, HTTP code.\n'
  printf 'Download exit 28 means the requested time limit; other nonzero codes indicate failure.\n'
  printf 'If downloads finish early or fail, this is not a sustained loaded-latency test.\n'
} | tee "$output/summary.txt"
printf 'Report: %s\n' "$output"
((bad_downloads==0)) || die 'Download load failed; report retained, loaded-latency result is invalid.'
((short_downloads==0)) || die 'Downloads ended too early; choose a larger file for sustained load. Report retained.'
