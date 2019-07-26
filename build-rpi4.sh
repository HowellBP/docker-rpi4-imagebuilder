#!/bin/bash -e

# This script is executed within the container as root.  It assumes
# that source code with debian packaging files can be found at
# /source-ro and that resulting packages are written to /output after
# succesful build.  These directories are mounted as docker volumes to
# allow files to be exchanged between the host and the container.

#TMPLOG=`mktemp /tmp/XXXXX`
TMPLOG=/tmp/build.log
#rm $TMPLOG && touch $TMPLOG
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1

# Install extra dependencies that were provided for the build (if any)
#   Note: dpkg can fail due to dependencies, ignore errors, and use
#   apt-get to install those afterwards
[[ -d /dependencies ]] && dpkg -i /dependencies/*.deb || apt-get -f install -y --no-install-recommends

#Time Stamp
now=`date +"%m_%d_%Y_%H%M"`

export PATH=/usr/lib/ccache:$PATH
# Make read-write copy of source code
mkdir -p /build
cp -a /source-ro /build/source
cd /build/source

# Install build dependencies
#mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends"

# Build packages
#debuild -b -uc -us

if [ ! -f /eoan-preinstalled-server-arm64+raspi3.img.xz ]; then
    echo "Downloading daily-preinstalled eoan ubuntu-server raspi3 image."
    wget http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/eoan-preinstalled-server-arm64+raspi3.img.xz
    echo "Extracting image."
    xzcat eoan-preinstalled-server-arm64+raspi3.img.xz > eoan-preinstalled-server-arm64+raspi4.img
else
    echo "Extracting image."
    xzcat /eoan-preinstalled-server-arm64+raspi3.img.xz > eoan-preinstalled-server-arm64+raspi4.img
fi

echo "Mounting image."
kpartx -av eoan-preinstalled-server-arm64+raspi4.img
mount /dev/mapper/loop0p2 /mnt
mount /dev/mapper/loop0p1 /mnt/boot/firmware

echo "Downloading current RPI firmware."
git clone --depth=1 https://github.com/Hexxeh/rpi-firmware
cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
cp rpi-firmware/*.elf /mnt/boot/firmware/
cp rpi-firmware/*.dat /mnt/boot/firmware/
cp rpi-firmware/*.dat /mnt/boot/firmware/
cp rpi-firmware/*.dtb /mnt/boot/firmware/
cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/

branch=rpi-4.19.y
echo "Downloading $branch RPI kernel source."
git clone --depth=1 -b $branch https://github.com/raspberrypi/linux.git rpi-linux
cd rpi-linux
#git checkout origin/rpi-4.19.y # change the branch name for newer versions
mkdir kernel-build

make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-  bcm2711_defconfig
cd kernel-build
/build/source/conform_config.sh
make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-  olddefconfig
cd ..

make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KERNEL_VERSION=`cat ./kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'` 
sudo make -j4 O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- DEPMOD=echo  INSTALL_MOD_PATH=./kernel-install/ modules_install
cd ..

echo "Copying compiled ${KERNEL_VERSION} kernel to image."
cp rpi-linux/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
cp rpi-linux/kernel-build/arch/arm64/boot/Image.gz /mnt/boot/vmlinuz-${KERNEL_VERSION}
cp rpi-linux/kernel-build/.config /mnt/boot/config-${KERNEL_VERSION}

echo "Copying compiled ${KERNEL_VERSION} modules to image."
cp -avr rpi-linux/kernel-build/kernel-install/lib/modules/${KERNEL_VERSION} /mnt/usr/lib/modules/
rm  -rf /mnt/usr/lib/modules/${KERNEL_VERSION}/build 
mv -f rpi-linux/kernel-build/kernel-install/lib/modules/${KERNEL_VERSION}/build /mnt/usr/src/linux-headers-${KERNEL_VERSION}
cd /mnt/usr/src
ln -s ../lib/modules/${KERNEL_VERSION} linux-headers-${KERNEL_VERSION}
cd /mnt/usr/lib/modules/${KERNEL_VERSION}/
ln -s ../../../linux-headers-${KERNEL_VERSION} build

cd /build/source
cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/
cp rpi-linux/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo /mnt/boot/firmware/overlays/
cp rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/etc/flash-kernel/dtbs/
sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt

echo "Downloading RPI4 armstub8-gic source"
git clone --depth=1 https://github.com/raspberrypi/tools.git rpi-tools
cd rpi-tools/armstubs
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- armstub8-gic.bin
cd ../..

cp rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin

echo "Downloading non-free firmware.."
git clone --depth=1 https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree
cp -avf firmware-nonfree/* /mnt/usr/lib/firmware

echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt ; then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt ; fi

echo "Downloading Raspberry Pi userland source."
git clone --depth=1 https://github.com/raspberrypi/userland
mkdir -p /mnt/opt/vc
cd userland/ ; CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt
echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
mkdir -p /mnt/etc/environment.d
echo -e '# /etc/env.d/00vcgencmd\n# Do not edit this file\n\nPATH="/opt/vc/bin:/opt/vc/sbin"\nROOTPATH="/opt/vc/bin:/opt/vc/sbin"\nLDPATH="/opt/vc/lib"' > /mnt/etc/environment.d/10-vcgencmd.conf
cd ..


echo "Modifying wireless firmware."
# as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
if ! grep -qs 'boardflags3=0x44200100' /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt ; then sed -i -r 's/0x48200100/0x44200100/' /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt ; fi

echo "Creating first start cleanup script"
echo -e '#!/bin/sh -e\n# 1st Boot Cleanup Script\n#\n# Print the IP address\n_IP=$(hostname -I) || true\nif [ "$_IP" ]; then\n  printf "My IP address is %s\n" "$_IP"\nfi\n#\nsleep 30; /usr/bin/apt update && /usr/bin/apt remove linux-image-raspi2 linux-raspi2 flash-kernel initramfs-tools -y\n/usr/bin/apt install wireless-tools wireless-regdb crda -y\nrm /etc/rc.local\n\nexit 0' > /mnt/etc/rc.local
chmod +x /mnt/etc/rc.local

#echo "Copying Build Log to image"
#cp $TMPLOG /mnt/boot/firmware/image-build-${now}.log


echo "unmounting modified image"
umount /mnt/boot/firmware
umount /mnt
kpartx -dv eoan-preinstalled-server-arm64+raspi4.img
echo "Compressing image quickly with lz4."
lz4 eoan-preinstalled-server-arm64+raspi4.img eoan-preinstalled-server-arm64+raspi4-${KERNEL_VERSION}_${now}.img.lz4
pwd

# Copy packages to output dir with user's permissions
chown -R $USER:$GROUP /build
echo "Copying image out of container."
cp -a /build/source/*.lz4 /output/
cp $TMPLOG /output/build-log-${KERNEL_VERSION}_${now}.log
ls -l /output
#read -p "Press [Enter] key to quit and delete container"
