#!/bin/bash -e

# This script is executed within the container as root.  It assumes
# that source code with debian packaging files can be found at
# /source-ro and that resulting packages are written to /output after
# succesful build.  These directories are mounted as docker volumes to
# allow files to be exchanged between the host and the container.

# Install extra dependencies that were provided for the build (if any)
#   Note: dpkg can fail due to dependencies, ignore errors, and use
#   apt-get to install those afterwards
[[ -d /dependencies ]] && dpkg -i /dependencies/*.deb || apt-get -f install -y --no-install-recommends

# Make read-write copy of source code
mkdir -p /build
cp -a /source-ro /build/source
cd /build/source

# Install build dependencies
mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends"

# Build packages
#debuild -b -uc -us

wget http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/eoan-preinstalled-server-arm64+raspi3.img.xz
xzcat eoan-preinstalled-server-arm64+raspi3.img.xz > eoan-preinstalled-server-arm64+raspi4.img
kpartx -av eoan-preinstalled-server-arm64+raspi4.img
mount /dev/mapper/loop0p2 /mnt
mount /dev/mapper/loop0p1 /mnt/boot/firmware

git clone --depth=1 https://github.com/Hexxeh/rpi-firmware
cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
cp rpi-firmware/*.elf /mnt/boot/firmware/
cp rpi-firmware/*.dat /mnt/boot/firmware/
cp rpi-firmware/*.dat /mnt/boot/firmware/
cp rpi-firmware/*.dtb /mnt/boot/firmware/
cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/


git clone --depth=1 -b rpi-4.19.y https://github.com/raspberrypi/linux.git rpi-linux
cd rpi-linux
#git checkout origin/rpi-4.19.y # change the branch name for newer versions
mkdir kernel-build
make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-  bcm2711_defconfig
make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KERNEL_VERSION=`cat ./kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'` 
make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- DEPMOD=echo MODLIB=./kernel-install/lib/modules/${KERNEL_VERSION} INSTALL_FW_PATH=./kernel-install/lib/firmware modules_install
cd ..

cp rpi-linux/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
cp rpi-linux/kernel-build/arch/arm64/boot/Image.gz /mnt/boot/vmlinuz-${KERNEL_VERSION}
cp -avf rpi-linux/kernel-build/kernel-install/lib/modules/${KERNEL_VERSION} /mnt/usr/lib/modules/
cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/
cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/etc/flash-kernel/dtbs
sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt


git clone --depth=1 https://github.com/raspberrypi/tools.git rpi-tools
cd rpi-tools/armstubs
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- armstub8-gic.bin
cd ../..

cp rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin


git clone --depth=1 https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree
cp -avf firmware-nonfree/* /mnt/usr/lib/firmware

echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt ; then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt ; fi

git clone --depth=1 https://github.com/raspberrypi/userland
mkdir -p /mnt/opt/vc
cd userland/ ; CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt/opt/vc/
echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
echo -e '# /etc/env.d/00vcgencmd\n# Do not edit this file\n\nPATH="/opt/vc/bin:/opt/vc/sbin"\nROOTPATH="/opt/vc/bin:/opt/vc/sbin"\nLDPATH="/opt/vc/lib"' > /etc/env.d/00vcgencmd
cd ..

# as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
if ! grep -qs 'boardflags3=0x44200100' /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt ; then sed -i -r 's/0x48200100/0x44200100/' /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt ; fi



umount /mnt/boot/firmware
umount /mnt
kpartx -dv eoan-preinstalled-server-arm64+raspi4.img
lz4 eoan-preinstalled-server-arm64+raspi4.img

# Copy packages to output dir with user's permissions
chown -R $USER:$GROUP /build
cp -a /build/*.lz4 /output/
ls -l /output
