 revert() {
    echo "This option will re-enroll your chromebook and restore it to its exact state before UTK was run. This is useful if you need to quickly go back to normal."
    echo "This is *permanent*. You will not be able to UTK again unless you re-run everything from the beginning."
    echo "Are you sure - 100% sure - that you want to continue? (press enter to continue, ctrl-c to cancel)"
    swallow_stdin
    read -r
    
    printf "Setting kernel priority in 3 (this is your last chance to cancel)..."
    sleep 1
    printf "2..."
    sleep 1
    echo "1..."
    sleep 1
    
    echo "Setting kernel priority"

    DST=/dev/$(get_largest_nvme_namespace)

    if doas "((\$(cgpt show -n \"$DST\" -i 2 -P) > \$(cgpt show -n \"$DST\" -i 4 -P)))"; then
        doas cgpt add "$DST" -i 2 -P 0
        doas cgpt add "$DST" -i 4 -P 1
    else
        doas cgpt add "$DST" -i 4 -P 0
        doas cgpt add "$DST" -i 2 -P 1
    fi
    
    echo "Setting vpd..."
    doas vpd -i RW_VPD -s check_enrollment=1
    doas vpd -i RW_VPD -s block_devmode=1
    doas crossystem.old block_devmode=1
    
    echo "Setting stateful unfuck flag..."
    rm -f /stateful_unfucked

    echo "Done. Press enter to reboot"
    swallow_stdin
    read -r
    echo "Bye!"
    sleep 2
    doas reboot
    sleep 1000
    echo "Your chromebook should have rebooted by now. If your chromebook doesn't reboot in the next couple of seconds, press Esc+Refresh to do it manually."
}
revert
