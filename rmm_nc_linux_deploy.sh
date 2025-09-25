#!/usr/bin/env bash

#title           : rmm_nc_linux_deploy.sh
#description     : This script will download linux installer for the N-central agent and install it
#author          : Zach.Frazier
#date            : 2025-09-26
#version         : 1.6.0
#usage           : sudo bash rmm_nc_linux_deploy.sh -s SERVERURL -u APIUSR -j JWT -c CUSTOMERID

## SoftwareIDs for URL
#
## Customer/Site Specific Agent/Probe
# URL = https://$SERVERURL/dms/FileDownload?customerID=$CUSTOMERID&softwareID=$SOFTWAREID
#
# 113 - CentOS/RedHat 7 x64 Agent
# 137 - CentOS/RedHat 8 x64 Agent
# 138 - CentOS/RedHat/AlmaLinux 9 x64 Agent
# 144 - Ubuntu 16/18 LTS x64 Agent
# 145 - Ubuntu 20 LTS x64 Agent
# 146 - Ubuntu 22 LTS x64 Agent
# 147 - Ubuntu 24 LTS x64 Agent
#
## System Agent/Probe
#
# Group Policy Deployment Script - https://$SERVERURL/download/$NCVERSION/winnt/N-central/installNableAgent.bat
# CentOS/RedHat 7 x64 Agent - https://$SERVERURL/download/$NCVERSION/rhel7_64/N-central/nagent-rhel7_64.tar.gz
# CentOS/RedHat 8 x64 Agent - https://$SERVERURL/download/$NCVERSION/rhel8_64/N-central/nagent-rhel8_64.tar.gz
# CentOS/RedHat/AlmaLinux 9 x64 Agent - https://$SERVERURL/download/2025.3.1.9/rhel9_64/N-central/nagent-rhel9_64.tar.gz
# Ubuntu 16/18 LTS x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu16_18_64/N-central/nagent-ubuntu16_18_64.tar.gz
# Ubuntu 20 LTS/Debian 11 x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu20_64/N-central/nagent-ubuntu20_64.tar.gz
# Ubuntu 22 LTS/Debian 12 x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu22_64/N-central/nagent-ubuntu22_64.tar.gz
# Ubuntu 24 LTS x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu24_64/N-central/nagent-ubuntu24_64.tar.gz

#==============================================================================

today=$(date +%Y%m%d)

# Define the parameters
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -h | --help)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  -h, --help           Show this help message and exit"
        echo "  -s, --serverurl      Set the server URL (e.g. https://ncentral.domain.com)"
        echo "  -u, --apiusr         Set the API User (e.g. api@domain.com)"
        echo "  -j, --jwt            Set the JSON Web Token from the N-central API User"
        echo "  -c, --customerid     Set the Customer ID to deploy the agent to"
        exit 0
        ;;
    -s | --serverurl)
        SERVERURL="$2"
        shift
        shift
        ;;
    -u | --apiusr)
        APIUSR="$2"
        shift
        shift
        ;;
    -j | --jwt)
        JWT="$2"
        shift
        shift
        ;;
    -c | --customerid)
        CUSTOMERID="$2"
        shift
        shift
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

# These are optional variables, only if you want to set static entries, just uncomment and update INSERTHERE with the value
# make sure that MACDMGVER and MACSHVER are on the correct version if you use them
# SERVERURL="sedemo.focusmsp.net"
# APIUSR="api@chimpsec.com"
# JWT="eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJTb2xhcndpbmRzIE1TUCBOLWNlbnRyYWwiLCJ1c2VyaWQiOjEwNDMxMDA0MTMsImlhdCI6MTc1ODgzMTI0OH0.LKdJxMs415zEa88ASIQZxDfezI26KmvGLmRNPEopFcc"
# CUSTOMERID="666"

# Check your privilege
if [ $(whoami) != "root" ]; then
    echo "This script must be run with root/sudo privileges."
    exit 1
fi

# clean up server address if necessary
# - trim whitespace
# - remove leading http:// or https:// (case-insensitive)
# - remove any path component after the hostname (keep host[:port])
# - remove trailing slash
SERVERURL=$(echo "${SERVERURL}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s#^https?://##I; s#/.*##; s#/$##')
if [ -z "$SERVERURL" ]; then
    echo "ERROR: server URL/host is empty. Pass with -s <host> or -s https://host" >&2
    exit 1
fi
echo "SERVER URL: $SERVERURL"

# generate URL for API access
APIURL="https://$SERVERURL/dms2/services2/ServerEI2"
echo "API URL $APIURL"

## Function: refresh_token
## Purpose: Hit the FileDownload endpoint with a HEAD to trigger/refresh a registration token
refresh_token() {
    local server="$1" apiuser="$2" jwt="$3" customer="$4"
    if [ -z "$server" ] || [ -z "$apiuser" ] || [ -z "$jwt" ] || [ -z "$customer" ]; then
        echo "refresh_token: missing arguments" >&2
        return 2
    fi
    local url="https://${server}/dms/FileDownload?customerID=${customer}&softwareID=101"
    # Use HEAD (-I). We discard body and only look at exit status.
    curl -fsS -I -u "${apiuser}:${jwt}" "$url" >/dev/null
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "refresh_token: curl returned $rc for $url" >&2
        return $rc
    fi
    echo "refresh_token: triggered for customer $customer"
    return 0
}

# Detect distribution and map to N-central platform path (rhel7_64, rhel8_64, rhel9_64, ubuntu16_18_64, ubuntu20_64, ubuntu22_64, ubuntu24_64)
# If PLATFORM is supplied externally, prefer it; otherwise auto-detect from /etc/os-release or /etc/redhat-release.
if [ -z "${PLATFORM:-}" ]; then
	if [ -r /etc/os-release ]; then
		. /etc/os-release
		ID_LIKE_LOWER=$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
		ID_LOWER=$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')
	else
		ID_LIKE_LOWER=""
		ID_LOWER=""
	fi

	if echo "$ID_LIKE_LOWER $ID_LOWER" | grep -Eqi "rhel|centos|fedora|almalinux|rocky|redhat"; then
		# try to detect major release from /etc/redhat-release
		if [ -r /etc/redhat-release ]; then
			release_major=$(sed -E 's/.* ([0-9]+)\..*/\1/' /etc/redhat-release 2>/dev/null || true)
		else
			release_major=""
		fi
		case "$release_major" in
			7) PLATFORM="rhel7_64" ;;
			8) PLATFORM="rhel8_64" ;;
			9) PLATFORM="rhel9_64" ;;
			*) PLATFORM="rhel9_64" ;;
		esac
	elif echo "$ID_LIKE_LOWER $ID_LOWER" | grep -Eqi "debian|ubuntu|mint"; then
		# try to detect Ubuntu/Debian major version
		if [ -n "${VERSION_ID:-}" ]; then
			ver_major=$(echo "$VERSION_ID" | cut -d. -f1)
		else
			ver_major=""
		fi
		case "$ver_major" in
			16|18) PLATFORM="ubuntu16_18_64" ;;
			20) PLATFORM="ubuntu20_64" ;;
			22) PLATFORM="ubuntu22_64" ;;
			24) PLATFORM="ubuntu24_64" ;;
			*) PLATFORM="ubuntu22_64" ;;
		esac
	else
		# default fallback
		PLATFORM="rhel9_64"
	fi
	echo "Detected/selected PLATFORM: $PLATFORM"
fi

# build the URL for the linux installer
read -r -d '' DATA_VERSION <<EOF
<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><versionInfoGet xmlns="http://ei2.nobj.nable.com/"><credentials><password>${JWT}</password></credentials></versionInfoGet></Body></Envelope>
EOF
NCVERSION=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data "$DATA_VERSION" "$APIURL" | sed 's@</value>@\n@g' | grep -m1 -i "Installation: UI Product Version" | awk -F'</key><value>' '{print $2}')
echo "N-CENTRAL VERSION: $NCVERSION"

# compose the download URL and archive name based on detected PLATFORM
INSTALLURL=$(printf "https://%s/download/%s/%s/N-central/nagent-%s.tar.gz" "$SERVERURL" "$NCVERSION" "$PLATFORM" "$PLATFORM")
echo "SCRIPT URL: $INSTALLURL"

# derive ARCHIVE_NAME from PLATFORM
ARCHIVE_NAME="nagent-${PLATFORM}.tar.gz"

# fetch the registration token and customer name for the specified customer ID
read -r -d '' DATA_CUSTOMER <<EOF
<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><customerList xmlns="http://ei2.nobj.nable.com/"><username>${APIUSR}</username><password>${JWT}</password><settings><key>listSOs</key><value>false</value></settings></customerList></Body></Envelope>
EOF
RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data "$DATA_CUSTOMER" "$APIURL")
echo "RESPONSE: ${RESPONSE:-<empty response>}"

# Normalize response to a single line for easier pattern matching
RESPONSE_ONE=$(echo "$RESPONSE" | tr -d '\n')

# If the API returned a SOAP Fault, extract the fault text and abort with a clear error
if echo "$RESPONSE_ONE" | grep -qi "<soap:Fault\|<Fault"; then
    fault_txt=$(echo "$RESPONSE_ONE" | sed -E 's/.*<soap:Text[^>]*>([^<]+)<\/soap:Text>.*/\1/')
    if [ -z "$fault_txt" ]; then
        fault_txt=$(echo "$RESPONSE_ONE" | sed -E 's/.*<Text[^>]*>([^<]+)<\/Text>.*/\1/')
    fi
    echo "ERROR: API returned SOAP Fault: ${fault_txt:-<no fault text>}" >&2
    exit 1
fi

CUSTOMERNAME=$(echo "$RESPONSE_ONE" | sed -E 's/.*<key>customer.customername<\/key><value>([^<]+)<\/value>.*/\1/')
echo "CUSTOMER NAME: $CUSTOMERNAME"

TOKEN=$(echo "$RESPONSE_ONE" | sed -E 's/.*<key>customer.registrationtoken<\/key><value>([^<]+)<\/value>.*/\1/')
echo "REGISTRATION TOKEN: $TOKEN"

# If token is missing, attempt to trigger generation and re-fetch up to max attempts
attempts=0
max_attempts=3
while [ -z "$TOKEN" ] && [ $attempts -lt $max_attempts ]; do
    attempts=$((attempts+1))
    echo "Registration token empty — attempting refresh ($attempts/$max_attempts)"
    refresh_token "$SERVERURL" "$APIUSR" "$JWT" "$CUSTOMERID" || echo "refresh_token returned non-zero (attempt $attempts)"
    sleep 1
    RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data "$DATA_CUSTOMER" "$APIURL")
    CUSTOMERNAME=$(echo "$RESPONSE" | awk -F'[><]' '/customername/ {print $3; exit}')
    TOKEN=$(echo "$RESPONSE" | awk -F'[><]' '/registrationtoken/ {print $3; exit}')
    echo "After refresh attempt $attempts: REGISTRATION TOKEN: ${TOKEN:-<empty>}"
done

if [ -z "$TOKEN" ]; then
    echo "Warning: registration token still empty after $max_attempts attempts. Proceeding may fail." >&2
fi

TMPDIR="/tmp/NCENTRAL_${today}"
if [ ! -d "$TMPDIR" ]; then
    echo "Creating temp download directory $TMPDIR."
    mkdir -p "$TMPDIR" || { echo "Failed to create $TMPDIR"; exit 1; }
fi

ARCHIVE_PATH="$TMPDIR/$ARCHIVE_NAME"
if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Downloading Install Script to $ARCHIVE_PATH"
    curl -fsS -u "$APIUSR:$JWT" "$INSTALLURL" -o "$ARCHIVE_PATH" || { echo "ERROR DOWNLOADING $INSTALLURL"; exit 1; }
fi

echo "Extracting Tar to $TMPDIR"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }
tar -xzf "$ARCHIVE_PATH" || { echo "Tar extraction failed"; exit 1; }

echo "Changing directory to extracted folder and setting execution permissions"
EXTRACTED_DIR=$(find "$TMPDIR" -maxdepth 1 -type d -name "nagent*" -print -quit)
if [ -z "$EXTRACTED_DIR" ]; then
   # fallback to the platform-based directory name
   EXTRACTED_DIR="$TMPDIR/nagent-${PLATFORM}"
fi
cd "$EXTRACTED_DIR" || { echo "Failed to cd to extracted dir: $EXTRACTED_DIR"; exit 1; }
chmod u+x install.sh

echo "Starting silent install bash..."
args=( -c "$CUSTOMERNAME" -i "$CUSTOMERID" -s "$SERVERURL" -p "https" -a "443" -t "$TOKEN" )
echo "Starting silent install bash..."
# Choose protocol argument case depending on platform family:
# - Debian/Ubuntu-family historically expects 'HTTPS' (uppercase)
# - RHEL-family expects 'https' (lowercase)
PROTO_ARG="https"
if echo "$PLATFORM" | grep -Eqi "ubuntu|debian"; then
    PROTO_ARG="HTTPS"
fi
args=( -c "$CUSTOMERNAME" -i "$CUSTOMERID" -s "$SERVERURL" -p "$PROTO_ARG" -a "443" -t "$TOKEN" )
echo "Running command: bash install.sh ${args[*]}"
bash install.sh "${args[@]}" 
