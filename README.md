# Things to Fix in chronological order. Top to bottom
- mush doesn't install. 
- mush doesn't launch.
- we will start croshunblocker when chrome starts by spoofing chrome like we did with tpmc.


# Things to do going in chronological order. Top to Bottom.
- ~Fork Murkmod to this repo because I'm a dumbass and didn't do it~
- ~Upload base grunt with murkmod for reference (Doesn't have everything but it's a rough starting point)~ (Uploaded partial rootfs read restofrootfs.md for reason)
- Spoof TPM with fake tpm (Almost done need tpmc command to find out dev mode)
- ~implement Murkmod within RMA shim~ (Murkmod already did this)
- ~Put Logo in boot via frecon over Chrome OS logo~ (Murkmod solved this for us)
- ~Design UTK logo~
- ~Add cryptosmite/Sh1mmer both to RMA shim and crosh~ (It's probably in crosmidi)
- ~Add enrollment to Cryptosmite~ (TESTING REQUIRED)
- ~Add access crosh via special shortcut other crosh is blocked by policy. (Safety)~ (TESTING REQUIRED)
- Design frecon UTK RMA shim images
- Implement UTK images into RMA shim
- Spoof tpm_manager_client (Different from tpmc)
- Change murkmod logo to UTK logo.
- implement Crosmidi within RMA shim (Let's wait on implementing crosmidi until we are done adding checks and testing generally making sure stuff works until we ask crossystem)
- Implement Crosmidi into UTK
- Implement Crosmidi to be accesible via crosh
- implement install via crosh shell
- Implement website to build Unenrollment Toolkit
- Compile Prebuilt Images
- Finalize docs and README.md
- PUBLISH!!!

