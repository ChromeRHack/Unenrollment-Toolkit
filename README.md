
# Installation

UTK Is an exploit that spoofs crossystem. It will appear to admins as if you are in verified mode when you are in devoloper mode. You can control extensions and policies use `CTRL+ALT+T` to enter mush (The UTK shell) when you enter the exploit.

## Developer Mode Installer

> [!WARNING]
> You should have unblocked developer mode in some capacity before following the instructions below, most likely by setting your GBB flags to `0x8000`, `0x8090`, or `0x8091`.

Enter developer mode while enrolled and boot into ChromeOS. Connect to WiFi, but don't log in. Open VT2 by pressing `Ctrl+Alt+F2 (Forward)` and log in as `root`. Run the following command:

```sh
bash <(curl -SLk https://raw.githubusercontent.com/ChromeRHack/Unenrollment-Toolkit/main/murkmod-devmode.sh)
```

Select the chromeOS milestone you want to install with UTK. The script will then automatically download the correct recovery image, patch it, and install it to your device. Once the installation is complete, the system will reboot into a murkmod-patched rootfs. You may have to again wait for the Dev-Mode transtition. Continue to [Common Installation Steps](#common-installation-steps).

This command will download and install UTK to your device. Once the installation is complete, you can start using murkmod by opening mush as usual.

> [!NOTE]
> Installing (or updating) UTK will set the password for the `chronos` user to `murkmod`.

> [!WARNING]
> If you get an error about a filesystem being readonly run `fsck -f $(rootdev)` then reboot.

## Common Installation Steps

If initial enrollment after installation fails after a long wait with an error about enrollment certificates, DON'T PANIC! This is normal. Perform an EC reset (`Refresh+Power`) and press space and then enter to *disable developer mode*. As soon as the screen backlight turns off, perform another EC reset and wait for the "ChromeOS is missing or damaged" screen to appear. Enter recovery mode (`Esc+Refresh+Power`) and press Ctrl+D and enter to enable developer mode, then enroll again. This time it should succeed.


