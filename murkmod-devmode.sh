#!/bin/bash

CURRENT_MAJOR=6
CURRENT_MINOR=0
CURRENT_VERSION=0
show_logo() { #Using ASCII font Collasal
    clear
    echo -e "
    888     888 88888888888 888    d8P  
    888     888     888     888   d8P   
    888     888     888     888  d8P    
    888     888     888     888d88K     
    888     888     888     8888888b    
    888     888     888     888  Y88b   
    Y88b. .d88P     888     888   Y88b  
      Y88888P       888     888    Y88b "
    echo "The UTK plugin manager - v$CURRENT_MAJOR.$CURRENT_MINOR.$CURRENT_VERSION - Developer mode installer"
}

show_logo_recovery() { #Using ASCII font Collasal
        clear
    echo -e "
    888     888 88888888888 888    d8P        8888888b.  8888888888  .d8888b.   .d88888b.  888     888 8888888888 8888888b. Y88b   d88P 
    888     888     888     888   d8P         888   Y88b 888        d88P  Y88b d88P   Y88b 888     888 888        888   Y88b Y88b d88P  
    888     888     888     888  d8P          888    888 888        888    888 888     888 888     888 888        888    888  Y88o88P   
    888     888     888     888d88K           888   d88P 8888888    888        888     888 Y88b   d88P 8888888    888   d88P   Y888P    
    888     888     888     8888888b          8888888P   888        888        888     888  Y88b d88P  888        8888888P      888     
    888     888     888     888  Y88b         888 T88b   888        888    888 888     888   Y88o88P   888        888 T88b      888     
    Y88b. .d88P     888     888   Y88b        888  T88b  888        Y88b  d88P Y88b. .d88P    Y888P    888        888  T88b     888     
      Y88888P       888     888    Y88b       888   T88b 8888888888   Y8888P     Y88888P       Y8P     8888888888 888   T88b    888     
                                                                                                                                    
                                                                                                                                    
                                                                                                                                    "
    echo "The UTK Recovery Manager - v$CURRENT_MAJOR.$CURRENT_MINOR.$CURRENT_VERSION - Chrome OS Installer"
}

lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"

  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
    return 1
  fi

  sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::
      s:[[:space:]]+$::
      p
    }" "${lsbfile}"
}

get_asset() {
    curl -s -f "https://api.github.com/repos/RMA-Organization/Unenrollment-Toolkit/contents/$1" | jq -r ".content" | base64 -d
# curl -s -f "https://api.github.com/repos/rainestorme/murkmod/contents/$1" Replace this when we go public
}

install() {
    TMP=$(mktemp)
    get_asset "$1" >"$TMP"
    if [ "$?" == "0" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "Failed to install $1 to $2 $?"
    # Don't mv, that would break permissions
    cat "$TMP" >"$2"
    rm -f "$TMP"
    fi
}

get_largest_nvme_namespace() {
    # this function doesn't exist if the version is old enough, so we redefine it
    local largest size tmp_size dev
    size=0
    dev=$(basename "$1")

    for nvme in /sys/block/"${dev%n*}"*; do
        tmp_size=$(cat "${nvme}"/size)
        if [ "${tmp_size}" -gt "${size}" ]; then
            largest="${nvme##*/}"
            size="${tmp_size}"
        fi
    done
    echo "${largest}"
}

get_booted_kernnum() {
    if (($(cgpt show -n "$dst" -i 2 -P) > $(cgpt show -n "$dst" -i 4 -P))); then
        echo -n 2
    else
        echo -n 4
    fi
}

opposite_num() {
    if [ "$1" == "2" ]; then
        echo -n 4
    elif [ "$1" == "4" ]; then
        echo -n 2
    elif [ "$1" == "3" ]; then
        echo -n 5
    elif [ "$1" == "5" ]; then
        echo -n 3
    else
        return 1
    fi
}

defog() {
    echo "Defogging..."
    futility gbb --set --flash --flags=0x8091 # we use futility here instead of the commented out command below because we expect newer chromeos versions and don't want to wait 30 seconds
    # /usr/share/vboot/bin/set_gbb_flags.sh 0x8091
    crossystem block_devmode=0
    vpd -i RW_VPD -s block_devmode=0
    vpd -i RW_VPD -s check_enrollment=1
}

recoverity() {
    show_logo_recovery
    echo ""
    rm -rf recoverity1
    echo "What version of Chrome OS do you want to install?"
    echo "This allows for Recovering without having to actually recover via usb"
    echo " 1) og      (chromeOS v105)"
    echo " 2) mercury (chromeOS v107)"
    echo " 3) john    (chromeOS v117)"
    echo " 4) pheonix (chromeOS v118)"
    echo " 5) latest version"
    echo " 6) custom milestone"
    echo " 7) Default Mode"
    read -p "(1-7) > " choice

    case $choice in
        1) VERSION="105" ;;
        2) VERSION="107" ;;
        3) VERSION="117" ;;
        4) VERSION="118" ;;
        5) VERSION="latest" ;;
        6) read -p "Enter milestone to target (e.g. 105, 107, 117, 118): " VERSION ;;
        7) murkmod ;;
        *) echo "Invalid choice, exiting." && exit ;;
    esac
}

murkmod() {
    clear
    show_logo
    mkdir recoverity1
    if [ -f /sbin/fakemurk-daemon.sh ]; then
        echo "!!! Your system already has a fakemurk installation! Continuing anyway, but emergency revert will not work correctly. !!!"
    fi
    if [ -f /sbin/murkmod-daemon.sh ]; then
        echo "!!! Your system already has a murkmod installation! Continuing anyway, but emergency revert will not work correctly. !!!"
    fi
    echo "What version of UTK do you want to install?"
    echo "If you're not sure, choose pheonix (v118) or the latest version. If you know what your original enterprise version was, specify that manually."
    echo " 1) og      (chromeOS v105)"
    echo " 2) mercury (chromeOS v107)"
    echo " 3) john    (chromeOS v117)"
    echo " 4) pheonix (chromeOS v118)"
    echo " 5) latest version"
    echo " 6) custom milestone"
    echo " 7) Recoverity Mode"
    read -p "(1-7) > " choice

    case $choice in
        1) VERSION="105" ;;
        2) VERSION="107" ;;
        3) VERSION="117" ;;
        4) VERSION="118" ;;
        5) VERSION="latest" ;;
        6) read -p "Enter milestone to target (e.g. 105, 107, 117, 118): " VERSION ;;
        7) recoverity ;;
        *) echo "Invalid choice, exiting." && exit ;;
    esac
    if [ -f recoverity1 ]; then
        show_logo_recovery
    else
        show_logo
    echo "Finding latest Chrome100 build ID..."
    local build_id=$(curl -s "https://chrome100.dev" | grep -o '"buildId":"[^"]*"' | cut -d':' -f2 | tr -d '"')
    echo "Finding recovery image..."
    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    #local release_board="hatch"
    local board=${release_board%%-*}
    if [ $VERSION == "latest" ]; then
        local builds=$(curl -ks "https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS\\")
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}
        local milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
        local VERSION=$(echo "$milestones" | tail -n 1 | tr -d '"')
        echo "Latest version is $VERSION"
    fi
    local url="https://chrome100.dev/_next/data/$build_id/board/$board.json"
    local json=$(curl -ks "$url")
    chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')
    echo "Found $(echo "$chrome_versions" | wc -l) versions of chromeOS for your board on chrome100."
    echo "Searching for a match..."
    MATCH_FOUND=0
    for cros_version in $chrome_versions; do
        platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
        channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
        mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
        mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
        last_modified=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .last_modified')
        # if $cros_version starts with $VERSION, then we have a match
        if [[ $cros_version == $VERSION* ]]; then
            echo "Found a $VERSION match on platform $platform from $last_modified."
            MATCH_FOUND=1
            #https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_15117.112.0_hatch_recovery_stable-channel_mp-v6.bin.zip
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            echo $FINAL_URL
            echo "DEBUG REMOVE THIS"
            break
        fi
    done
    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Falling back to Chromium Dash."
        local builds=$(curl -ks "https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS\\")
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}

        # Get all milestones for the specified hwid
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")

        # Loop through all milestones
        echo "Searching for a match..."
        for milestone in $milestones; do
            milestone=$(echo "$milestone" | tr -d '"')
            if [[ $milestone == $VERSION* ]]; then
                MATCH_FOUND=1
                FINAL_URL=$(jq -r ".builds.$board[].$hwid.pushRecoveries[\"$milestone\"]" <<<"$builds")
                echo "Found a match!"
                echo $FINAL_URL
                echo "DEBUG REMOVE THIS"
                break
            fi
        done
    fi

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No recovery image found for your board and target version. Exiting."
        exit
    fi

    echo "Installing unzip (this may take up to 2 minutes)..."
    dev_install <<EOF > /dev/null
EOF
    if [ $1 -eq 0 ]; then
        echo "Installed Emerge."
    else
    fi
      dev_install --reinstall <<EOF > /dev/null
EOF

    emerge unzip > /dev/null

    mkdir -p /usr/local/tmp
    pushd /mnt/stateful_partition
        set -e
        echo "Downloading recovery image from '$FINAL_URL'..."
        curl --progress-bar -k "$FINAL_URL" -o recovery.zip
        echo "Unzipping image..."
        if [ -f "recovery.zip" ]; then
                echo "Yes DEBUG REMOVE THIS"
            else
                echo "well shit DEBUG REMOVE THIS"
        fi
        unzip -o recovery.zip
        rm recovery.zip
        FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin") # 2 incase the zip format changes
        if [ -f $FILENAME ]; then
                echo "Yes DEBUG REMOVE THIS"
            else
                echo "well shit DEBUG REMOVE THIS"
        fi
        echo "Found recovery image from archive at $FILENAME"
        pushd /usr/local/tmp # /usr/local is mounted as exec, so we can run scripts from here
        if [ -f recoverity1 ]; then

            echo "Installing image_patcher.sh..."
            install "image_patcher.sh" ./image_patcher.sh
            chmod 777 ./image_patcher.sh
            echo "Installing ssd_util.sh..."
            mkdir -p ./lib
            install "ssd_util.sh" ./lib/ssd_util.sh
            chmod 777 ./lib/ssd_util.sh
            echo "Installing common_minimal.sh..."
            install "common_minimal.sh" ./lib/common_minimal.sh
            chmod 777 ./lib/common_minimal.sh
            popd
            echo "Invoking image_patcher.sh..."
            bash /usr/local/tmp/image_patcher.sh "$FILENAME"
        else
            if [ -f $FILENAME ]; then
                echo "Yes DEBUG REMOVE THIS"
            else
                echo "well shit DEBUG REMOVE THIS"
            fi
            echo ""
        fi
        popd
        if [ -f recoverity1 ]; then
            echo "Patching complete. Determining target partitions..."
        else
            echo "Determining target partitions..."
        fi
        local dst=/dev/$(get_largest_nvme_namespace)
        if [[ $dst == /dev/sd* ]]; then
            echo "WARNING: get_largest_nvme_namespace returned $dst - this doesn't seem correct!"
            echo "Press enter to view output from fdisk - find the correct drive and enter it below"
            read -r
            fdisk -l | more
            echo "Enter the target drive to use:"
            read dst
        fi
        local tgt_kern=$(opposite_num $(get_booted_kernnum))
        local tgt_root=$(( $tgt_kern + 1 ))
        local kerndev=${dst}p${tgt_kern}
        local rootdev=${dst}p${tgt_root}
        echo "Targeting $kerndev and $rootdev"
        local loop=$(losetup -f | tr -d '\r')
        losetup -P "$loop" "$FILENAME"
        echo "Press enter if nothing broke, otherwise press Ctrl+C"
        read -r
        printf "Nuking partitions in 3 (this is your last chance to cancel)..."
        sleep 1
        printf "2..."
        sleep 1
        echo "1..."
        sleep 1
        echo "Bomb has been planted! Overwriting ChromeOS..."
        echo "Installing kernel patch to ${kerndev}..."
        dd if="${loop}p4" of="$kerndev" status=progress
        echo "Installing root patch to ${rootdev}..."
        dd if="${loop}p3" of="$rootdev" status=progress
        echo "Setting kernel priority..."
        cgpt add "$dst" -i 4 -P 0
        cgpt add "$dst" -i 2 -P 0
        cgpt add "$dst" -i "$tgt_kern" -P 1
        #output = 0
        #if [[ ${#output} -eq 1 ]]; then
            #echo "Defogging... This will set GBB flags to 0x8091"
            #defog
            #fi
        echo "Cleaning up..."
        losetup -d "$loop"
        rm -rf recoverity1
        rm -f "$FILENAME"
    popd

    read -n 1 -s -r -p "Done! Press any key to continue and your system will reboot automatically."
    reboot
    echo "Bye!"
    sleep 20
    echo "Your system should have rebooted. If it didn't please perform an EC reset (Refresh+Power)."
    sleep 1d
    exit
}

if [ "$0" = "$BASH_SOURCE" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit
    fi
    murkmod
fi
