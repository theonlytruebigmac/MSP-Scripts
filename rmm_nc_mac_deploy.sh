#!/bin/bash

#title           : rmm_nc_mac_deploy.sh
#description     : This script simplifies 3rd Party RMM mac agent deployment by combining the required DMG and the silent install script for the N-central agent and installing them with the provided parameters.
#author          : theonlytruebigmac
#date            : 2023-08-10
#version         : 1.0.1
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

# Create temporary download directory
if [ ! -d "/tmp/NCENTRAL/" ]; then
    echo "Creating temp download directory."
    mkdir "/tmp/NCENTRAL/"
fi

# Get XML data from the SIS URL
SISURL="http://sis.n-able.com/GenericFiles.xml"
curl -s $SISURL > /tmp/NCENTRAL/GenericFiles.xml

# Parse the XML content directly from curl for the most recent Mac DMG and Silent Installer URLs, ensuring correct filters
MACDMGURL=$(curl -s $SISURL | awk -F'"' '/Install_N-central_Agent/ && /.dmg/ {print $2, $4}' | sort -V -k2 | tail -n 1 | awk '{print $1}')
MACSHURL=$(curl -s $SISURL | awk -F'"' '/silent_install.sh/ {print $2, $4}' | sort -V -k2 | tail -n 1 | awk '{print $1}')

echo "MAC DMG URL: $MACDMGURL"
echo "MAC SILENT INSTALLER URL: $MACSHURL"

# Download the DMG if it does not exist
if [ ! -f "/tmp/NCENTRAL/Install_N-central_Agent.dmg" ]; then 
    echo "Downloading DMG"
    curl -L --fail -o "/tmp/NCENTRAL/Install_N-central_Agent.dmg" -s $MACDMGURL
    if [ $? -gt 0 ]; then
        echo "ERROR DOWNLOADING $MACDMGURL"
        exit 1
    fi
fi

# Download the silent install script if it does not exist
if [ ! -f "/tmp/NCENTRAL/silent_install.sh" ]; then
    echo "Downloading silent install script"
    curl -L --fail -o "/tmp/NCENTRAL/silent_install.sh" -s $MACSHURL
    if [ $? -gt 0 ]; then
        echo "ERROR DOWNLOADING $MACSHURL"
        exit 1
    fi
fi

# Clean up server address if necessary
SERVERURL=$(echo "${SERVERURL}" | awk -F "://" '{if($2) print $2; else print $1;}' | sed 's|/$||')
echo "SERVER URL: $SERVERURL"

# Generate URL for API access
APIURL="https://$SERVERURL/dms2/services2/ServerEI2"
echo "API URL: $APIURL"

# Get N-central version
NCVERSION=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><versionInfoGet xmlns="http://ei2.nobj.nable.com/"><credentials><password>'$JWT'</password></credentials></versionInfoGet></Body></Envelope>' $APIURL | sed 's,</value>,\n,g' | grep -m1 -i "Installation: UI Product Version" | awk -F'</key><value>' '{print $2}')
echo "N-CENTRAL VERSION: $NCVERSION"

# Fetch the registration token and customer name for the specified customer ID
RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><customerList xmlns="http://ei2.nobj.nable.com/"><username>'$APIUSR'</username><password>'$JWT'</password><settings><key>listSOs</key><value>false</value></settings></customerList></Body></Envelope>' $APIURL | sed s/\<return\>/\\n\<return\>/g | grep customerid\</key\>\<value\>$CUSTOMERID\<)
CUSTOMERNAME=$(echo $RESPONSE | sed s/\>customer/\\n/g | grep -m1 customername | cut -d \> -f 3 | cut -d \< -f 1)
TOKEN=$(echo $RESPONSE | sed s/customer./\\n/g | grep -m1 registrationtoken | cut -d \> -f 3 | cut -d \< -f 1)

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
