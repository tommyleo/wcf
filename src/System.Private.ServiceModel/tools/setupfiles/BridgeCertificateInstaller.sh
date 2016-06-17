#!/usr/bin/env bash

show_banner()
{
    echo ""
    echo "WCF Core CA Certificate Installer"
}

show_usage() 
{
    echo "    Usage: $0 --service-host [service-host] --cert-file [certificate-file]"
    echo "    service-host - hostname where service is running" 
    echo "    certificate-file - Full file path where the retrieved certificate should be saved"
    echo ""
}

run_installer() 
{
    __cafile=$1

    echo "Using certificate installer at '$__installer_path'" 
    
    echo "Running installer and making a call to '$ServiceUri'"
    # echo $__corerun_exe $__installer_path $__cafile
   
    # Need to make a call as the original user as we need to write to the cert store for the current 
    # user, not as root
    echo "Making a call to the service as user '$SUDO_USER'"
    sudo -E -u $SUDO_USER $__corerun_exe $__installer_path $__cafile
    
    return $?
}

install_root_cert()
{
    __cafile=$1
    chmod a+r "$__cafile"

    # Find the command for updating the OS certificate bundle
    echo "Updating root certificates with cert from '$__cafile'"

    case ${__os} in 
        "darwin")
            # OS X SecureTransport does a direct install into the cert store without requiring copying into a location
            $__update_os_certbundle_exec -v add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${__cafile} 
            ;;
        "centos" | "rhel" | "fedora" | "opensuse")
            cp -f "${__cafile}" /etc/pki/ca-trust/source/anchors

            if [ $? -ne 0 ]; then
                return $?
            fi

            $__update_os_certbundle_exec
            ;;
        *)
            cp -f "${__cafile}" /usr/local/share/ca-certificates
        
            if [ $? -ne 0 ]; then 
                return $? 
            fi

            $__update_os_certbundle_exec
            ;;
    esac 

    if [ $? -ne 0 ]; then
        return $?
    fi

    echo "Recalculating OpenSSL certificate hashes using c_rehash"
    $__c_rehash_exec

    return $?
}

# Main execution

# Detect OS
# This is a pretty coarse detection, and we make the assumption that OSes will behave
# a certain way across versions. Hence the detection logic and placement of files will
# be assumed to be for the OS at the time of the writing of this script. We'll solve 
# the  later if there are additonal issues when we version up

if [[ "$(uname -a)" =~ ^.*(Darwin).*$ ]]; then
    # OSX
    __os="darwin"
elif [ -f /etc/os-release ]; then
    # ubuntu, debian, centos, rhel, fedora, opensuse (among others) are detected here 
    __os=`cat /etc/os-release | grep "^ID=" | sed 's/ID=//g' | sed 's/["]//g' | awk '{print $1}'`
else 
    echo "WARNING: Could not detect OS, defaulting to 'ubuntu'"
    __os="ubuntu"
fi 

# Parse arguments
while [[ $# > 0 ]]
do
    opt="$1"
    case $opt in
        -h|--help)
        show_usage
        ;;
        --service-host)
        __service_host=$2
        ;;
        --cert-file)
        __cafile=$2
        ;;
        *)
        ;;
    esac
    shift
done

show_banner
echo "    Detected OS as: ${__os}"

__scriptpath=$(cd "$(dirname "$0")"; pwd -P)
__binpath=$__scriptpath/../../../../bin
__testspath=$__binpath/tests

readonly __scriptpath
readonly __binpath
readonly __testspath
readonly __os


# Check prerequisities
if [ `id -u` -ne 0 ]; then
    show_usage
    echo "ERROR: This script must be run under sudo or as a superuser" 
    exit 1
fi

# OpenSSL rehash - applicable on all platforms

__c_rehash_exec=`which c_rehash`
if [ $? -ne 0 -o ! -f "$__c_rehash_exec" ]; then 
    echo "WARNING: Could not find 'c_rehash'. Is OpenSSL installed properly?" 
fi

# Find the command for updating the OS certificate bundle
case ${__os} in 
    "darwin")
        __update_os_certbundle_cmd="security"
        ;;
    "centos" | "rhel" | "fedora" | "opensuse") 
        __update_os_certbundle_cmd="update-ca-trust"
        ;;
    "ubuntu" | "debian")
        __update_os_certbundle_cmd="update-ca-certificates"
        ;;
    *)
        echo "ERROR: Could not detect OS certificate bundle update tool" 
        exit 1
        ;;
esac 

__update_os_certbundle_exec=`which ${__update_os_certbundle_cmd}`
if [ $? -ne 0 -o ! -f "$__update_os_certbundle_exec" ]; then 
    echo "ERROR: Could not find '${__update_os_certbundle_cmd}', which is needed to update certificates on '${__os}'" 
    exit 1
fi

# Locate any CoreRun.exe to be able to execute BridgeCertificateInstaller.exe
# Because BridgeCertificateInstaller itself is a test project, we are guaranteed
# it will contain CoreRun.exe even if no other tests have been built.
__corerun_path=$(dirname "$(find $__testspath -iname 'ScenarioTests.Common.dll' | head -1)")

if [ $? -ne 0 ]; then
    echo "Could not find 'ScenarioTests.Common.dll' under path '$__binpath'"
    echo "Try building all outerloop tests using 'build.sh -p:WithCategories=OuterLoop' from the repo root"
    exit 1
fi

__corerun_exe="$__corerun_path/corerun"

if [ ! -e "$__corerun_exe" ]; then
    echo "Could not find corerun in path $__corerun_path"
    echo "Try building all outerloop tests using 'build.sh -p:WithCategories=OuterLoop' from the repo root"
    exit 1
fi

__installer_path=$(find $__binpath -iname 'BridgeCertificateInstaller.exe' | head -1)

if [ "$__installer_path" == "" ]; then
    echo "Could not find 'BridgeCertificateInstaller.exe' under path '$__binpath'"
    echo "Try building all outerloop tests using 'build.sh -p:WithCategories=OuterLoop' from the repo root"
    exit 1
fi

# Check parameters

if [ -z "$__cafile" ]; then 
    show_usage
    exit 1
else 
    echo "Certificate Authority will be written to '$__cafile'"
fi 

if [ -n "$__service_host" ]; then 
    echo "Certificate will be obtained from ServiceHost '$__service_host'"
    if [ -n "$ServiceUri" ]; then 
        echo "WARNING: This will replace the ServiceUri specified in the environment, '$ServiceUri', for the duration of this script"
    fi 
    
    # set ServiceUri as an external env var so that this can be picked up by the certificate installer
    # this is effectively local to this run as scripts usually run inside a new shell
    export ServiceUri=$__service_host
fi 

if [ -z "$ServiceUri" ]; then
    echo "WARNING: \$ServiceUri environment variable was not specified in the environment"
    echo "         This may be caused by running under sudo; run 'sudo -E' if you want to keep the user environment"
    echo ""
    echo "         Either set the ServiceUri environment variable, or run '$0' with a --service-host parameter"
    echo ""
    echo "         The default ServiceUri is 'localhost'."
    echo "         If the test service is running on a port other than the default, also set the 'BridgePort' variable"
    echo "         so that the installer can make the call to the service correctly"
fi

# Run certificate installer 
run_installer $__cafile

# Install certificate
if [ $? -eq 0 ]; then 
    if [ -e "$__cafile" ]; then 
        install_root_cert "$__cafile"
    else 
        echo "ERROR: Certificate authority file not written to '$__cafile' as expected"
    fi  
fi 

exit 0
