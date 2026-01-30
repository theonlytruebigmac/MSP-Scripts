#!/bin/bash

#title           : rmm_nc_mac_deploy.sh
#description     : This script simplifies 3rd Party RMM mac agent deployment by combining the required DMG and the silent install script for the N-central agent and installing them with the provided parameters.
#author          : theonlytruebigmac
#date            : 2026-01-30
#version         : 1.4
#usage           : sudo ./rmm_nc_mac_deploy.sh -s SERVERURL -u APIUSR -j JWT -c CUSTOMERID [-d MACDMGVER -i MACSHVER]

# Define the parameters
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -h, --help           Show this help message and exit"
            echo "  -s, --serverurl      Set the server URL (e.g., https://ncentral.domain.com)"
            echo "  -u, --apiusr         Set the API User (e.g., api@domain.com)"
            echo "  -j, --jwt            Set the JSON Web Token from the N-central API User"
            echo "  -c, --customerid     Set the Customer ID to deploy the agent to"
            echo "  -d, --macdmgver      Set the Mac DMG version (optional)"
            echo "  -i, --macshver       Set the Mac Silent Installer version (optional)"
            exit 0
            ;;
        -s|--serverurl)
            SERVERURL="$2"
            shift
            shift
            ;;
        -u|--apiusr)
            APIUSR="$2"
            shift
            shift
            ;;
        -j|--jwt)
            JWT="$2"
            shift
            shift
            ;;
        -c|--customerid)
            CUSTOMERID="$2"
            shift
            shift
            ;;
        -d|--macdmgver)
            MACDMGVER="$2"
            shift
            shift
            ;;
        -i|--macshver)
            MACSHVER="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for root privileges
if [ "$(whoami)" != "root" ]; then
    echo "This script must be run with root/sudo privileges."
    exit 1
fi

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

# Create temporary download directory (always start fresh)
if [ -d "/tmp/NCENTRAL/" ]; then
    echo "Removing existing temp directory for fresh download..."
    rm -rf "/tmp/NCENTRAL/"
fi
echo "Creating temp download directory."
mkdir "/tmp/NCENTRAL/"

# Get XML data from the SIS URL
SISURL="http://sis.n-able.com/GenericFiles.xml"
curl -s $SISURL > /tmp/NCENTRAL/GenericFiles.xml

# Clean up server address if necessary (moved earlier in script)
SERVERURL=$(echo "${SERVERURL}" | awk -F "://" '{if($2) print $2; else print $1;}' | sed 's|/$||')
echo "SERVER URL: $SERVERURL"

# Generate URL for API access
APIURL="https://$SERVERURL/dms2/services2/ServerEI2"
echo "API URL: $APIURL"

# Get N-central version
NCVERSION=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><versionInfoGet xmlns="http://ei2.nobj.nable.com/"><credentials><password>'$JWT'</password></credentials></versionInfoGet></Body></Envelope>' $APIURL | sed 's,</value>,\n,g' | grep -m1 -i "Installation: UI Product Version" | awk -F'</key><value>' '{print $2}')
echo "N-CENTRAL VERSION: $NCVERSION"

if [ -z "$NCVERSION" ]; then
    echo "ERROR: Could not retrieve N-central version. Check your server URL and JWT."
    exit 1
fi

## Function: version_compare
## Purpose: Compare two version strings (dot-separated)
## Returns: 0 if v1 >= min AND v1 <= max, 1 otherwise
version_in_range() {
    local version="$1"
    local min_version="$2"
    local max_version="$3"
    
    # Convert versions to comparable format (pad each segment to 10 digits)
    normalize_version() {
        echo "$1" | awk -F'.' '{printf "%010d%010d%010d%010d\n", $1+0, $2+0, $3+0, $4+0}'
    }
    
    local v=$(normalize_version "$version")
    local min_v=$(normalize_version "$min_version")
    local max_v=$(normalize_version "$max_version")
    
    # Check if version is >= min and <= max
    if [[ "$v" > "$min_v" || "$v" == "$min_v" ]] && [[ "$v" < "$max_v" || "$v" == "$max_v" ]]; then
        return 0
    else
        return 1
    fi
}

# Parse the XML to find the correct Range based on NCVERSION and extract URLs
echo "Finding correct software version range for N-central $NCVERSION..."

# Use awk to parse the XML and find URLs within the matching Range
# Note: Using BSD awk compatible syntax (no GNU-specific match with capture groups)
read -r MACDMGURL MACSHURL < <(awk -v ncver="$NCVERSION" '
# Function to extract attribute value from a line
# Usage: get_attr(line, "Name") returns the value of Name="..."
function get_attr(line, attr) {
    # Find the attribute
    if (match(line, attr "=\"[^\"]*\"")) {
        val = substr(line, RSTART, RLENGTH)
        # Remove the attribute name and quotes
        gsub(attr "=\"", "", val)
        gsub("\"", "", val)
        return val
    }
    return ""
}

function normalize_ver(ver) {
    n = split(ver, parts, ".")
    # Ensure we always have 4 parts
    for (i = n+1; i <= 4; i++) parts[i] = 0
    return sprintf("%010d%010d%010d%010d", parts[1]+0, parts[2]+0, parts[3]+0, parts[4]+0)
}

function version_in_range(v, min, max) {
    nv = normalize_ver(v)
    nmin = normalize_ver(min)
    nmax = normalize_ver(max)
    return (nv >= nmin && nv <= nmax)
}

BEGIN {
    in_range = 0
    dmg_url = ""
    sh_url = ""
}

/<Range / {
    # Extract Range attributes using get_attr function
    range_name = get_attr($0, "Name")
    range_min = get_attr($0, "Minimum")
    range_max = get_attr($0, "Maximum")
    
    if (version_in_range(ncver, range_min, range_max)) {
        in_range = 1
    } else {
        in_range = 0
    }
}

/<\/Range>/ {
    in_range = 0
}

# Look for Mac DMG URL within matching range
in_range && /N-centralMacAgent/ && /FileID="Installer"/ && /\.dmg/ && dmg_url == "" {
    dmg_url = get_attr($0, "Name")
}

# Look for silent_install.sh URL within matching range
in_range && /N-centralMacAgent/ && /FileID="InstallationScript"/ && /silent_install\.sh/ && sh_url == "" {
    sh_url = get_attr($0, "Name")
}

END {
    if (dmg_url != "" && sh_url != "") {
        print dmg_url, sh_url
    } else {
        print "ERROR", "ERROR"
    }
}
' /tmp/NCENTRAL/GenericFiles.xml)

# Check if URLs were found
if [ "$MACDMGURL" == "ERROR" ] || [ "$MACSHURL" == "ERROR" ] || [ -z "$MACDMGURL" ] || [ -z "$MACSHURL" ]; then
    echo "ERROR: Could not find Mac Agent URLs for N-central version $NCVERSION"
    echo "The GenericFiles.xml may not have an appropriate version range for your N-central version."
    exit 1
fi

echo "MAC DMG URL: $MACDMGURL"
echo "MAC SILENT INSTALLER URL: $MACSHURL"

# Download the DMG
echo "Downloading DMG..."
curl -L --fail -o "/tmp/NCENTRAL/Install_N-central_Agent.dmg" -s "$MACDMGURL"
if [ $? -gt 0 ]; then
    echo "ERROR DOWNLOADING $MACDMGURL"
    exit 1
fi

# Use local silent_install.sh if present (for debugging), otherwise download
if [ -f "./silent_install.sh" ]; then
    echo "Found local silent_install.sh, using it..."
    cp "./silent_install.sh" "/tmp/NCENTRAL/silent_install.sh"
else
    echo "Downloading silent install script..."
    curl -L --fail -o "/tmp/NCENTRAL/silent_install.sh" -s "$MACSHURL"
    if [ $? -gt 0 ]; then
        echo "ERROR DOWNLOADING $MACSHURL"
        exit 1
    fi
fi

# Fetch the registration token and customer name for the specified customer ID
RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><customerList xmlns="http://ei2.nobj.nable.com/"><username>'$APIUSR'</username><password>'$JWT'</password><settings><key>listSOs</key><value>false</value></settings></customerList></Body></Envelope>' $APIURL | sed s/\<return\>/\\n\<return\>/g | grep customerid\</key\>\<value\>$CUSTOMERID\<)
CUSTOMERNAME=$(echo "$RESPONSE" | sed s/\>customer/\\n/g | grep -m1 customername | cut -d \> -f 3 | cut -d \< -f 1)
TOKEN=$(echo "$RESPONSE" | sed s/customer./\\n/g | grep -m1 registrationtoken | cut -d \> -f 3 | cut -d \< -f 1)

# Check if token is missing and try to refresh with retries
attempts=0
max_attempts=3
while [ -z "$TOKEN" ] && [ $attempts -lt $max_attempts ]; do
    attempts=$((attempts+1))
    echo "Token missing, attempting refresh ($attempts/$max_attempts)..."
    refresh_token "$SERVERURL" "$APIUSR" "$JWT" "$CUSTOMERID"
    sleep 1
    
    # Re-fetch the registration token and customer name
    RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><customerList xmlns="http://ei2.nobj.nable.com/"><username>'$APIUSR'</username><password>'$JWT'</password><settings><key>listSOs</key><value>false</value></settings></customerList></Body></Envelope>' $APIURL | sed s/\<return\>/\\n\<return\>/g | grep customerid\</key\>\<value\>$CUSTOMERID\<)
    CUSTOMERNAME=$(echo "$RESPONSE" | sed s/\>customer/\\n/g | grep -m1 customername | cut -d \> -f 3 | cut -d \< -f 1)
    TOKEN=$(echo "$RESPONSE" | sed s/customer./\\n/g | grep -m1 registrationtoken | cut -d \> -f 3 | cut -d \< -f 1)
done

if [ -z "$TOKEN" ]; then
    echo "Warning: registration token still empty after $max_attempts attempts. Proceeding may fail."
fi

echo "CUSTOMER NAME: $CUSTOMERNAME"
echo "REGISTRATION TOKEN: $TOKEN"

# Run the installer script
cd /tmp/NCENTRAL/ || exit

echo "Running: sudo bash silent_install.sh -s "$SERVERURL" -i "$CUSTOMERID" -c "$CUSTOMERNAME" -t "$TOKEN" -I "./Install_N-central_Agent.dmg""
sudo bash silent_install.sh -s "$SERVERURL" -i "$CUSTOMERID" -c "$CUSTOMERNAME" -t "$TOKEN" -I "./Install_N-central_Agent.dmg"

# Check if the script finished successfully
if [ $? -eq 0 ]; then
    echo "Silent install completed successfully. Cleaning up..."
    rm -rf /tmp/NCENTRAL/
else
    echo "Silent install failed. No cleanup performed."
    exit 1
fi
