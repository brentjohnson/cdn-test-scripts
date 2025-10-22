#!/usr/bin/env bash
# geo_lookup.sh
# Usage:
#   ./geo_lookup.sh host1.example.com host2.example.com
#   ./geo_lookup.sh -f hosts.txt

set -euo pipefail

# Check for required dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq command is required but not found. Please install jq." >&2
  exit 1
fi

if ! command -v dig &>/dev/null; then
  echo "Error: dig command is required but not found. Please install dig (part of dnsutils)." >&2
  exit 1
fi

# Geolocation providers
declare -A GEO_PROVIDERS
GEO_PROVIDERS["ip-api"]="http://ip-api.com/json"
GEO_PROVIDERS["ipinfo"]="https://ipinfo.io"
GEO_PROVIDERS["ipapi"]="https://ipapi.co"
GEO_PROVIDERS["ipdata"]="https://api.ipdata.co"
GEO_PROVIDERS["bigdatacloud"]="https://api.bigdatacloud.net/data/ip-geolocation"

RATE_LIMIT_SLEEP=0.5
DNS_SERVER=""
GEO_PROVIDER="ipinfo"  # Default provider

print_usage() {
  cat <<EOF
Usage:
  $0 host1 host2 ...
  $0 -f hosts.txt
  $0 -d DNS_SERVER host1 host2 ...
  $0 -d DNS_SERVER -f hosts.txt
  $0 -g PROVIDER host1 host2 ...

Options:
  -d DNS_SERVER    Use specified DNS server for lookups
  -f FILE          Read hostnames from file
  -g PROVIDER      Use specified geolocation provider
                  Available providers: ip-api, ipinfo, ipapi, ipdata, bigdatacloud
                  Default: ipinfo

Examples:
  $0 -g ipinfo example.com
  $0 -d 8.8.8.8 -g ipapi host1.com host2.com
EOF
}

HOSTS=()
if [[ $# -eq 0 ]]; then
  print_usage
  exit 1
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -d)
      if [[ $# -lt 2 ]]; then
        echo "Error: -d requires a DNS server argument" >&2
        print_usage
        exit 1
      fi
      DNS_SERVER="$2"
      shift 2
      ;;
    -g)
      if [[ $# -lt 2 ]]; then
        echo "Error: -g requires a provider argument" >&2
        print_usage
        exit 1
      fi
      if [[ -z "${GEO_PROVIDERS[$2]:-}" ]]; then
        echo "Error: Unknown geolocation provider '$2'" >&2
        echo "Available providers: ${!GEO_PROVIDERS[*]}" >&2
        exit 1
      fi
      GEO_PROVIDER="$2"
      shift 2
      ;;
    -f)
      if [[ $# -lt 2 ]]; then
        echo "Error: -f requires a filename argument" >&2
        print_usage
        exit 1
      fi
      file="$2"
      if [[ ! -f "$file" ]]; then
        echo "File not found: $file" >&2
        exit 2
      fi
      while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue
        HOSTS+=("$line")
      done < "$file"
      shift 2
      ;;
    -*)
      echo "Error: Unknown option $1" >&2
      print_usage
      exit 1
      ;;
    *)
      HOSTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "Error: No hostnames provided" >&2
  print_usage
  exit 1
fi

# --- Always return numeric IP address (IPv4 or IPv6) ---
resolve_ip() {
  local host="$1"
  local ip=""
  local dig_cmd="dig +short"

  # Add DNS server if specified
  if [[ -n "$DNS_SERVER" ]]; then
    dig_cmd="$dig_cmd @$DNS_SERVER"
  fi

  ip="$($dig_cmd A "$host" | grep -E '^[0-9.]+$' | head -n1)"
  if [[ -z "$ip" ]]; then
    ip="$($dig_cmd AAAA "$host" | grep -E '^[0-9a-fA-F:]+$' | head -n1)"
  fi

  echo "$ip"
}

lookup_geo() {
  local ip="$1"
  if [[ -z "$ip" ]]; then
    echo "N/A"
    return
  fi

  local base_url="${GEO_PROVIDERS[$GEO_PROVIDER]}"
  local res

  case "$GEO_PROVIDER" in
    "ip-api")
      if ! res="$(curl -s --fail "${base_url}/${ip}?fields=status,message,country,regionName,city,lat,lon,isp,query")"; then
        echo "N/A"
        return
      fi
      local status
      status="$(echo "$res" | jq -r '.status')"
      if [[ "$status" != "success" ]]; then
        local msg
        msg="$(echo "$res" | jq -r '.message // "unknown error"')"
        echo "Error: $msg"
        return
      fi
      local city region country lat lon isp
      city="$(echo "$res" | jq -r '.city // ""')"
      region="$(echo "$res" | jq -r '.regionName // ""')"
      country="$(echo "$res" | jq -r '.country // ""')"
      lat="$(echo "$res" | jq -r '.lat // ""')"
      lon="$(echo "$res" | jq -r '.lon // ""')"
      isp="$(echo "$res" | jq -r '.isp // ""')"
      ;;
    "ipinfo")
      if ! res="$(curl -s --fail "${base_url}/${ip}/json")"; then
        echo "N/A"
        return
      fi
      local city region country lat lon isp
      city="$(echo "$res" | jq -r '.city // ""')"
      region="$(echo "$res" | jq -r '.region // ""')"
      country="$(echo "$res" | jq -r '.country // ""')"
      lat="$(echo "$res" | jq -r '.loc // ""' | cut -d',' -f1)"
      lon="$(echo "$res" | jq -r '.loc // ""' | cut -d',' -f2)"
      isp="$(echo "$res" | jq -r '.org // ""')"
      ;;
    "ipapi")
      if ! res="$(curl -s --fail "${base_url}/${ip}/json/")"; then
        echo "N/A"
        return
      fi
      local city region country lat lon isp
      city="$(echo "$res" | jq -r '.city // ""')"
      region="$(echo "$res" | jq -r '.region // ""')"
      country="$(echo "$res" | jq -r '.country_name // ""')"
      lat="$(echo "$res" | jq -r '.latitude // ""')"
      lon="$(echo "$res" | jq -r '.longitude // ""')"
      isp="$(echo "$res" | jq -r '.org // ""')"
      ;;
    "ipdata")
      if ! res="$(curl -s --fail "${base_url}/${ip}?api-key=test")"; then
        echo "N/A"
        return
      fi
      local city region country lat lon isp
      city="$(echo "$res" | jq -r '.city // ""')"
      region="$(echo "$res" | jq -r '.region // ""')"
      country="$(echo "$res" | jq -r '.country_name // ""')"
      lat="$(echo "$res" | jq -r '.latitude // ""')"
      lon="$(echo "$res" | jq -r '.longitude // ""')"
      isp="$(echo "$res" | jq -r '.asn.name // ""')"
      ;;
    "bigdatacloud")
      if ! res="$(curl -s --fail "${base_url}?ip=${ip}")"; then
        echo "N/A"
        return
      fi
      local city region country lat lon isp
      city="$(echo "$res" | jq -r '.location.city // ""')"
      region="$(echo "$res" | jq -r '.location.principalSubdivision // ""')"
      country="$(echo "$res" | jq -r '.location.country.name // ""')"
      lat="$(echo "$res" | jq -r '.location.latitude // ""')"
      lon="$(echo "$res" | jq -r '.location.longitude // ""')"
      isp="$(echo "$res" | jq -r '.network.organisation // ""')"
      ;;
  esac

  local loc=""
  if [[ -n "$city" ]]; then loc+="$city"; fi
  if [[ -n "$region" ]]; then
    [[ -n "$loc" ]] && loc+=", "
    loc+="$region"
  fi
  if [[ -n "$country" ]]; then
    [[ -n "$loc" ]] && loc+=", "
    loc+="$country"
  fi
  if [[ -n "$lat" && -n "$lon" ]]; then
    loc+=" (${lat},${lon})"
  fi
  if [[ -n "$isp" ]]; then
    loc+=" - $isp"
  fi

  echo "${loc:-N/A}"
}

# Get current timestamp and local IP information
echo
echo "=== Geo-location Analysis ==="
echo "Timestamp: $(TZ='America/New_York' date)"
echo "Geolocation Provider: $GEO_PROVIDER"
if [[ -n "$DNS_SERVER" ]]; then
  echo "DNS Server: $DNS_SERVER"
fi

# Get local IP using the selected provider
local_ip=""
case "$GEO_PROVIDER" in
  "ip-api")
    local_ip="$(curl -s --fail http://ip-api.com/json | jq -r '.query // "N/A"')"
    ;;
  "ipinfo")
    local_ip="$(curl -s --fail https://ipinfo.io/ip)"
    ;;
  "ipapi")
    local_ip="$(curl -s --fail https://ipapi.co/ip/)"
    ;;
  "ipdata")
    local_ip="$(curl -s --fail https://api.ipdata.co/ip)"
    ;;
  "bigdatacloud")
    local_ip="$(curl -s --fail https://api.bigdatacloud.net/data/ip)"
    ;;
esac

echo "Local IP: ${local_ip:-N/A}"
echo "Local Location: $(lookup_geo "$local_ip")"
echo ""

printf "%-30s %-25s %s\n" "HOSTNAME" "IP ADDRESS" "GEOLOCATION"
printf "%-30s %-25s %s\n" "--------" "----------" "-----------"

for host in "${HOSTS[@]}"; do
  ip="$(resolve_ip "$host" || true)"
  if [[ -z "$ip" ]]; then
    printf "%-30s %-25s %s\n" "$host" "N/A" "Could not resolve hostname"
    continue
  fi

  geo="$(lookup_geo "$ip")"
  printf "%-30s %-25s %s\n" "$host" "$ip" "$geo"

  sleep "$RATE_LIMIT_SLEEP"
done
