#title           : rmm_nc_mac_deploy.sh
#description     : This script is meant to simplify 3rd Party RMM mac agent deployment by combining the two required deployment items into a single script 
#                  This script will download both the required DMG and the silent install script for the N-central agent and install it with the submitted
#                  params
#author		     : theonlytruebigmac
#date            : 2023-08-10
#version         : 1.0.1
#usage		     : sudo ./rmm_nc_mac_deploy.sh -s SERVERURL -u APIUSR -j JWT -c CUSTOMERID #OPTIONAL:(-d MACDMGVER -i MACSHVER)

## SoftwareIDs for URL
## Customer/Site Specific Agent/Probe
# URL = https://$SERVERURL/dms/FileDownload?customerID=$CUSTOMERID&softwareID=$SOFTWAREID
#
##SOFTWARE IDs
# 101 - Windows Agent
# 103 - Windows Probe
# 113 - CentOS/RedHat 7 x64 Agent
# 128 - MacOS Agent
# 137 - CentOS/RedHat 8 x64 Agent
# 144 - Ubuntu 16/18 LTS x64 Agent
# 145 - Ubuntu 20 LTS x64 Agent
# 146 - Ubuntu 22 LTS x64 Agent
#
## System Agent/Probe
# Windows Agent - https://$SERVERURL/download/$NCVERSION/winnt/N-central/WindowsAgentSetup.exe
# Windows Probe - https://$SERVERURL/download/$NCVERSION/winnt/N-central/WindowsProbeSetup.exe
# Group Policy Deployment Script - https://$SERVERURL/download/$NCVERSION/winnt/N-central/installNableAgent.bat
# CentOS/RedHat 7 x64 Agent - https://$SERVERURL/download/$NCVERSION/rhel7_64/N-central/nagent-rhel7_64.tar.gz
# CentOS/RedHat 8 x64 Agent - https://$SERVERURL/download/$NCVERSION/rhel8_64/N-central/nagent-rhel8_64.tar.gz
# Ubuntu 16/18 LTS x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu16_18_64/N-central/nagent-ubuntu16_18_64.tar.gz
# Ubuntu 20 LTS x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu20_64/N-central/nagent-ubuntu20_64.tar.gz
# Ubuntu 22 LTS x64 Agent - https://$SERVERURL/download/$NCVERSION/ubuntu22_64/N-central/nagent-ubuntu22_64.tar.gz
# MacOS DMG Installation Script - https://$SERVERURL/download/$MACSHVER/macosx/N-central/silent_install.sh
# MacOS Agent - https://$SERVERURL/download/$MACDMGVER/macosx/N-central/Install_N-central_Agent_v$MACDMGVER.dmg

#==============================================================================

today=$(date +%Y%m%d)
div=======================================

# Define the parameters
while [[ $# -gt 0 ]]
do
key="$1"

    case $key in
        -h|--help)
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
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# These are optional variables, only if you want to set static entries, just uncomment and update INSERTHERE with the value
# make sure that MACDMGVER and MACSHVER are on the correct version if you use them
#SERVERURL="${SERVERURL:-INSERTHERE}"
#APIUSR="${APIUSR:-INSERTHERE}"
#JWT="${JWT:-INSERTHERE}"
#CUSTOMERID="${CUSTOMERID:-INSERTHERE}"

# Check your privilege
if [ $(whoami) != "root" ]; then
    echo "This script must be run with root/sudo privileges."
    exit 1
fi

if [ ! -d "/tmp/NCENTRAL/" ] ;
then
	echo "Creating temp download directory."
	mkdir "/tmp/NCENTRAL/"
fi

# get xml data from "http://sis.n-able.com/GenericFiles.xml" and store xml in file at /tmp/NCENTRAL/GenericFiles.xml
SISURL="http://sis.n-able.com/GenericFiles.xml"
curl -s $SISURL > /tmp/NCENTRAL/GenericFiles.xml

# parse GenericFiles.xml for the latest Mac DMG version
MACDMGVER=$(cat /tmp/NCENTRAL/GenericFiles.xml | grep -m1 -i "N-central Mac Agent" | awk -F'"' '{print $4}')
echo "MAC DMG VERSION: $MACDMGVER"

# parse GenericFiles.xml for the latest Mac Silent Installer version
MACSHVER=$(cat /tmp/NCENTRAL/GenericFiles.xml | grep -m1 -i "N-central Mac Agent installation script" | awk -F'"' '{print $4}')
echo "MAC SILENT INSTALLER VERSION: $MACSHVER"

# clean up server address if necessary
SERVERURL=$( echo "${SERVERURL}" | awk -F "://" '{if($2) print $2; else print $1;}' )
SERVERURL=${SERVERURL%/} 	# strip trailing slash
echo "SERVER URL: $SERVERURL"

# generate URL for API access
APIURL="https://$SERVERURL/dms2/services2/ServerEI2"
echo "API URL $APIURL"

# build the URL for the DMG and install script
NCVERSION=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><versionInfoGet xmlns="http://ei2.nobj.nable.com/"><credentials><password>'$JWT'</password></credentials></versionInfoGet></Body></Envelope>' $APIURL | sed 's,</value>,\n,g' | grep -m1 -i "Installation: UI Product Version" | awk -F'</key><value>' '{print $2}')
echo "N-CENTRAL VERSION: $NCVERSION"

URI="https://$SERVERURL/dms/FileDownload?customerID=$CUSTOMERID&softwareID=101"
RES=$(curl -sS -u "$APIUSR:$JWT" "$URI" > /dev/null)
echo "Updating Registration token..."

SCRIPTURL=$(printf "https://%s/download/$MACSHVER/macosx/N-central/silent_install.sh" "$SERVERURL")
echo "SCRIPT URL: $SCRIPTURL"

DMGURL=$(printf "https://%s/download/$MACDMGVER/macosx/N-central/Install_N-central_Agent_v$MACDMGVER.dmg" "$SERVERURL")
echo "DMG URL: $DMGURL"


# fetch the registration token and customer name for the specified customer ID
RESPONSE=$(curl -s --header 'Content-Type: application/soap+xml; charset="utf-8"' --header 'SOAPAction:POST' --data '<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope"><Body><customerList xmlns="http://ei2.nobj.nable.com/"><username>'$APIUSR'</username><password>'$JWT'</password><settings><key>listSOs</key><value>false</value></settings></customerList></Body></Envelope>' $APIURL | sed s/\<return\>/\\n\<return\>/g | grep customerid\</key\>\<value\>$CUSTOMERID\<)
echo "RESPONSE: $RESPONSE"

CUSTOMERNAME=$(echo $RESPONSE | sed s/\>customer/\\n/g | grep -m1 customername | cut -d \> -f 3 | cut -d \< -f 1)
echo "CUSTOMER NAME: "$CUSTOMERNAME""

TOKEN=$(echo $RESPONSE | sed s/customer./\\n/g | grep -m1 registrationtoken | cut -d \> -f 3 | cut -d \< -f 1)
echo "REGISTRATION TOKEN: $TOKEN"

	
# get the installer pieces
if [ ! -f "/tmp/NCENTRAL/Install_N-central_Agent_v$MACDMGVER.dmg" ];
then 
	echo "Downloading DMG"
	curl -o "/tmp/NCENTRAL/Install_N-central_Agent_v$MACDMGVER.dmg" -s $DMGURL
	if [ $? -gt 0 ]
	then
		echo "ERROR DOWNLOADING $DMGURL"
		exit 1
	fi
fi

if [ ! -f  "/tmp/NCENTRAL/silent_install.sh" ];
then
	echo "Downloading install script"
	curl -o "/tmp/NCENTRAL/silent_install.sh" -s $SCRIPTURL
	if [ $? -gt 0 ]
	then
		echo "ERROR DOWNLOADING $SCRIPTURL"
		exit 1
	fi
fi

# run the installer script
cd /tmp/NCENTRAL/ || return

echo "Starting silent install bash..."
sudo bash silent_install.sh -s "$SERVERURL" -i "$CUSTOMERID" -c "$CUSTOMERNAME" -t "$TOKEN" -I "./Install_N-central_Agent_v$MACDMGVER.dmg"