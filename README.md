# ALSO FUCKING REMEMBER TO REMOVE BEFORE PUBLISH API KEY FOR TESTING "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" Created testing account and api key for org and to test without having to public it
# Things to Fix in chronological order. Top to bottom
- ~murkmod-devmode.sh doesn't work cause image-patcher.sh doesn't work cause for some reason recovery image was like fuck this and dissapeared. Almost done fixing need to TEST to confirm~ WORKS
Currently trying to speed up test time with recovery-download function.  continue debugging soon.
- mush doesn't install and doesn't launch. (Obvious)
- ~we will start croshunblocker when chrome starts by spoofing chrome like we did with tpmc.~ NO do this with an extension. Murkmod already solved it. We're idiots.
- Remember to put info for skids at the bottom of the inevitable faq
- ~Fix when powerwash "my chwomebook did a fucky a wucky"~ Add an option to the installation script to add the boot messages or not
- ~Chromebook also bootloops and is not recoverable~ WP has to be disabled for this and chromebook powerwashed while utk is installed. 
# Things to do going in chronological order. Top to Bottom. 
- ~Fork Murkmod to this repo because I'm a dumbass and didn't do it~
- ~Upload base grunt with murkmod for reference (Doesn't have everything but it's a rough starting point)~ (Uploaded partial rootfs we don't need the whole rootfs)
- ~Spoof TPM with fake tpm (Almost done need tpmc command to find out dev mode)~ 
- ~implement Murkmod within RMA shim~ (Murkmod already did this)
- ~Put Logo in boot via frecon over Chrome OS logo~ (Murkmod solved this for us)
- ~Design UTK logo~
- ~Add cryptosmite/Sh1mmer both to RMA shim and crosh~ (It's probably in crosmidi)
- ~Add enrollment to Cryptosmite~ (TESTING REQUIRED)
- ~Add access crosh via special shortcut other crosh is blocked by policy. (Safety)~ (TESTING REQUIRED)
- ADD RECOVERY OPTION TO UTK VERSION INPUT IN MURKMOD-DEVMODE.SH CURRENTLY WORKING ON IT -PEAP
- Add more options to mush
- ~Change chromeos firmware bitmaps for oops UwU i did a little fucky wucky and your system is trying to repair itself~ it's not firmware bitmaps cuase were dumb also we already did it sorry OwO
- Design Extension to cover up crosh unless under special circumstances aka some shortcuts. idk why I didn't think of this earlier. thanks rainstorm VERY COOL
- Design frecon UTK RMA shim images
- Implement UTK images into RMA shim
- ~Spoof tpm_manager_client (Different from tpmc)~ NO do this with an extension
- ~Change murkmod logo to UTK logo.~
- implement Crosmidi within RMA shim (Let's wait on implementing crosmidi until we are done adding checks and testing generally making sure stuff works until we ask crossystem)
- Implement Crosmidi into UTK
- Implement Crosmidi to be accesible via crosh
- implement install via crosh shell
- Implement website to build Unenrollment Toolkit
- Compile Prebuilt Images
- Finalize docs and README.md
- PUBLISH!!! REMEMBER TO FUCKING EXPIRE API KEY 

