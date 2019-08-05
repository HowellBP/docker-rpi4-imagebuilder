#!/bin/bash -e

# This script is executed within the container as root. The resulting image &
# logs are written to /output after a succesful build.  These directories are 
# mounted as docker volumes to allow files to be exchanged between the host and 
# the container.

#kernel_branch=rpi-4.19.y
#kernelgitrepo="https://github.com/raspberrypi/linux.git"
#branch=bcm2711-initial-v5.2
#kernelgitrepo="https://github.com/lategoodbye/rpi-zero.git"
# This should be the image we want to modify.
#base_url="http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/"
#base_image="eoan-preinstalled-server-arm64+raspi3.img.xz"
base_image_url="${base_url}/${base_image}"
# This is the base name of the image we are creating.
new_image="eoan-preinstalled-server-arm64+raspi4"
# Comment out the following if apt is throwing errors silently.
# Note that these only work for the chroot commands.
silence_apt_flags="-o Dpkg::Use-Pty=0 -qq < /dev/null > /dev/null "
silence_apt_update_flags="-o Dpkg::Use-Pty=0 < /dev/null > /dev/null "
image_compressors=("lz4" "xz")
[[ $NOXZ ]] && image_compressors=("lz4")

# Let's see if the inotify issues go away by moving function status
#  files onto /build.
mkdir /flag

#DEBUG=1
GIT_DISCOVERY_ACROSS_FILESYSTEM=1

# Needed for display
shopt -s checkwinsize 
#size=$(stty size) 
#lines=${size% *}
#columns=${size#* }
#echo "COLS: $COLS COLUMNS: $COLUMNS" > /tmp/columns
#env > /tmp/env
COLUMNS="${COLS:-80}"



# Set Time Stamp
now=`date +"%m_%d_%Y_%H%M%Z"`

# Create debug output folder.
[[ $DEBUG ]] && ( mkdir -p /output/$now/ ; chown $USER:$GROUP /output/$now/ )
#[[ $DEBUG ]] && chown $USER:$GROUP /output/$now/

# Logging Setup
TMPLOG=/tmp/build.log
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1

# Use ccache.
PATH=/usr/lib/ccache:$PATH
CCACHE_DIR=/cache/ccache
mkdir -p $CCACHE_DIR
# Change these settings if you need them to be different.
ccache -M 0 > /dev/null
ccache -F 0 > /dev/null
# Show ccache stats.
echo "Build ccache stats:"
ccache -s


# Create work directory.
workdir=/build/source
mkdir -p $workdir
#cp -a /source-ro/ $workdir

# Source cache is on the cache volume.
src_cache=/cache/src_cache
mkdir -p $src_cache

# Apt cache is on the cache volume.
apt_cache=/cache/apt_cache
# This is needed or apt has issues.
mkdir -p $apt_cache/partial 

#env >> /output/environment

# Make sure inotify-tools is installed.
apt-get -o dir::cache::archives=$apt_cache install inotify-tools lsof xdelta3 vim \
e2fsprogs qemu-user-static \
libc6-arm64-cross pv -qq 2>/dev/null

# Utility script
# Apt concurrency manager wrapper via
# https://askubuntu.com/posts/375031/revisions
cat <<'EOF'> /usr/bin/chroot-apt-wrapper
#!/bin/bash

i=0
tput sc
while fuser /mnt/var/lib/dpkg/lock >/dev/null 2>&1 ; do
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    echo -en "\r[$j] Waiting for other apt instances to finish..." 
    sleep 0.5
    ((i=i+1))
done 

/usr/bin/apt-get "$@"
EOF
chmod +x /usr/bin/chroot-apt-wrapper

cat <<'EOF'> /usr/bin/chroot-dpkg-wrapper
#!/bin/bash

i=0
tput sc
while fuser /mnt/var/lib/dpkg/lock >/dev/null 2>&1 ; do
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    echo -en "\r[$j] Waiting for other dpkg instances to finish..." 
    sleep 0.5
    ((i=i+1))
done 

/usr/bin/dpkg "$@"
EOF
chmod +x /usr/bin/chroot-dpkg-wrapper



# Utility Functions

function abspath {
    echo $(cd "$1" && pwd)
}

# Via https://superuser.com/a/917073
wait_file() {
  local file="$1"; shift
  local wait_seconds="${1:-10}"; shift # 10 seconds as default timeout

  until test $((wait_seconds--)) -eq 0 -o -f "$file" ; do sleep 1; done

  ((++wait_seconds))
}


inotify_touch_events () {
    # Since inotifywait seems to need help in docker. :/
    while [ ! -f "/flag/done.export_log" ]
    do
        touch /flag/*
        sleep 1
    done
}

spinnerwaitfor () {
    local waitforit
    local i=0
    tput sc
    # waitforit file is written in the function "endfunc"
    touch /flag/wait.${FUNCNAME[1]}_for_${1}
    #printf "%${COLUMNS}s\n" "${FUNCNAME[1]} waits for: ${1}    "
    printf "%${COLUMNS}s\r\n\n\r" "${FUNCNAME[1]} waits for: ${1} [$j] "
    while read waitforit; do 
    if [ "$waitforit" = done.${1} ]; 
        then break; \
    fi; 
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    printf "%${COLUMNS}s\r" "${FUNCNAME[1]} waits for: ${1} [$j] "
    sleep 1
    ((i=i+1))
    done \
   < <(inotifywait  -e create,open,access --format '%f' --quiet /flag --monitor)
    printf "%${COLUMNS}s\r" "${FUNCNAME[1]} noticed: ${1} [X] " && rm -f /flag/wait.${FUNCNAME[1]}_for_${1}
}

spinnerwait () {
        local start_timeout=10000
        if [[ -f "/flag/start.spinnerwait" ]]
        then
            echo "${1} waiting" >> /tmp/spinnerwait
            wait_file "/flag/done.spinnerwait" $start_timeout
            echo "${1} done waiting" >> /tmp/spinnerwait
            rm -f "/flag/done.spinnerwait"
        fi
startfunc
        echo "start.${1}" >> /tmp/spinnerwait
        wait_file "/flag/start.${1}" $start_timeout || \
        echo "${1} didn't start."
        echo "Starting ${1}" >> /tmp/spinnerwait
        local job_id=`cat /flag/start.${1}`
        echo "Waiting for ${job_id} to end." >> /tmp/spinnerwait
        tput sc
        while (pgrep -cxP ${job_id} &>/dev/null)
        do for s in / - \\ \|
            do 
            tput rc
            printf "%${COLUMNS}s\r" "${1} .$s"
            sleep .1
            done
        done
        echo "${job_id} done." >> /tmp/spinnerwait
endfunc
}


waitfor () {
    local waitforit
    # waitforit file is written in the function "endfunc"
    touch /flag/wait.${FUNCNAME[1]}_for_${1}
    printf "%${COLUMNS}s\r\n\r" "${FUNCNAME[1]} waits for: ${1} [/] "
    local start_timeout=10000
    wait_file "/flag/done.${1}" $start_timeout
    printf "%${COLUMNS}s\r\n\r" "${FUNCNAME[1]} noticed: ${1} [X] " && \
    rm -f /flag/wait.${FUNCNAME[1]}_for_${1}
}

waitforstart () {
    local waitforit
    while read waitforit; do 
    if [ "$waitforit" = start.${1} ]; 
        then break; \
    fi; 
    done \
   < <(inotifywait  -e create,open,access --format '%f' --quiet /flag --monitor)
}


startfunc () {
    echo $BASHPID > /flag/start.${FUNCNAME[1]}
    printf "%${COLUMNS}s\n" "Started: ${FUNCNAME[1]} [ ] "
}

endfunc () {
    [[ -f /tmp/${FUNCNAME[1]}.compile.log ]] && rm /tmp/${FUNCNAME[1]}.compile.log || true
    [[ -f /tmp/${FUNCNAME[1]}.compile.log ]] && rm /tmp/${FUNCNAME[1]}.install.log || true
    mv -f /flag/start.${FUNCNAME[1]} /flag/done.${FUNCNAME[1]}
    printf "%${COLUMNS}s\n" "Done: ${FUNCNAME[1]} [X] "
}


git_check () {
    local git_base="$1"
    local git_branch="$2"
    [ ! -z "$2" ] || git_branch="master"
    local git_output=`git ls-remote ${git_base} refs/heads/${git_branch}`
    local git_hash
    local discard 
    read git_hash discard< <(echo "$git_output")
    echo $git_hash
}

local_check () {
    local git_path="$1"
    local git_branch="$2"
    [ ! -z "$2" ] || git_branch="HEAD"
    local git_output=`git -C $git_path rev-parse ${git_branch} 2>/dev/null`
    echo $git_output
}


arbitrary_wait () {
    # To stop here "rm /flag/done.ok_to_continue_after_here".
    # Arbitrary build pause for debugging
    if [ ! -f /flag/done.ok_to_continue_after_here ]; then
        echo "** Build Paused. **"
        echo 'Type in "touch /flag/done.ok_to_continue_after_here"'
        echo "in a shell into this container to continue."
    fi 
    waitfor "ok_to_continue_after_here"
}


# Standalone get with git function
# get_software_src () {
# startfunc
# 
#     git_get "gitrepo" "local_path" "git_branch"
# 
# endfunc
# }

git_get () {
    local git_repo="$1"
    local local_path="$2"
    local git_branch="$3"
    [ ! -z "$3" ] || git_branch="master"
    mkdir -p $src_cache/$local_path
    mkdir -p $workdir/$local_path
    
    local remote_git=$(git_check "$git_repo" "$git_branch")
    local local_git=$(local_check "$src_cache/$local_path" "$git_branch")
    
    [ -z $git_branch ] && git_extra_flags= || git_extra_flags=" -b $git_branch "
    local git_flags=" --quiet --depth=1 "
    local clone_flags=" $git_repo $git_extra_flags "
    local pull_flags="origin/$git_branch"
    echo -e "${FUNCNAME[1]}\nremote hash: $remote_git\nlocal hash: $local_git"
      
    if [ ! "$remote_git" = "$local_git" ]
        then
            printf "%${COLUMNS}s\n"  "${FUNCNAME[1]} refreshing cache files from git."
            # Does the local repo even exist?
            if [ ! -d "$src_cache/$local_path/.git" ] 
                then
                    recreate_git $git_repo $local_path $git_branch
            fi
            # Is the requested branch the same as the local saved branch?
            local local_branch=`git -C $src_cache/$local_path rev-parse \
            --abbrev-ref HEAD` || local_branch=
            # Set HEAD = master
            [[ "$local_branch" = "HEAD" ]] && local_branch="master"
            if [[ "$local_branch" != "$git_branch" ]]
                then 
                    echo "Branch mismatch!"
                    # Be safe.
                    recreate_git $git_repo $local_path $git_branch
            fi
            # sync to local branch
            cd $src_cache/$local_path
            git fetch --all $git_flags &>> /tmp/${FUNCNAME[1]}.git.log || true
            git reset --hard $pull_flags $git_flags 2>> /tmp/${FUNCNAME[1]}.git.log
        else
            echo -e "${FUNCNAME[1]} getting files from cache volume. 😎\n"
    fi
    cd $src_cache/$local_path 
    last_commit=`git log --graph \
    --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) \
    %C(bold blue)<%an>%Creset' --abbrev-commit -2 \
    --quiet 2> /dev/null`
    echo -e "*${FUNCNAME[1]} Last Commits:\n$last_commit\n"
    rsync -a $src_cache/$local_path $workdir/
#                     
#         
#         cd $src_cache
#         [ ! -d "$src_cache/$local_path/.git" ] && rm -rf $src_cache/$local_path
#         
#         git clone $git_flags $clone_flags $local_path &>> /tmp/${FUNCNAME[1]}.git.log || true
#         cd $src_cache/$local_path
#         git fetch --all $git_flags &>> /tmp/${FUNCNAME[1]}.git.log || true
#         git reset --hard $pull_flags $git_flags 2>> /tmp/${FUNCNAME[1]}.git.log || \
#         ( rm -rf $src_cache/$local_path ; cd $src_cache ; git clone $git_flags $clone_flags $local_path ) 2>> /tmp/${FUNCNAME[1]}.git.log
#         else
#         
#     fi
#     
#     cd $src_cache/$local_path 
#     last_commit=`git log --graph \
#     --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) \
#     %C(bold blue)<%an>%Creset' --abbrev-commit -2 \
#     --quiet 2> /dev/null`
#     echo -e "*${FUNCNAME[1]} Last Commits:\n$last_commit\n"
#     rsync -a $src_cache/$local_path $workdir/
}

recreate_git () {
    local git_repo="$1"
    local local_path="$2"
    local git_branch="$3"
    local git_flags=" --quiet --depth=1 "
    local git_extra_flags=" -b $git_branch "
    local clone_flags=" $git_repo $git_extra_flags "
    rm -rf $src_cache/$local_path
    cd $src_cache
    git clone $git_flags $clone_flags $local_path \
    &>> /tmp/${FUNCNAME[2]}.git.log || true
}



# Main functions

download_base_image () {
startfunc
    echo "* Downloading ${base_image} ."
    wget_fail=0
    wget -nv ${base_image_url} -O ${base_image} || wget_fail=1
endfunc
}

base_image_check () {
startfunc
    echo "* Checking for downloaded ${base_image} ."
    cd $workdir
    if [ ! -f /${base_image} ]; then
        download_base_image
    else
        echo "* Downloaded ${base_image} exists."
    fi
    # Symlink existing image
    if [ ! -f $workdir/${base_image} ]; then 
        ln -s /$base_image $workdir/
    fi   
endfunc
}

image_extract_and_mount () {
    waitfor "base_image_check"
startfunc 
    if [[ -f "/source-ro/${base_image%.xz}" ]] 
    then
    cp "/source-ro/${base_image%.xz}" $workdir/$new_image.img
    [[ $DELTA ]] && (ln -s "/source-ro/${base_image%.xz}" $workdir/old_image.img &)
    else
    local size
    local filename   
    echo "* Extracting: ${base_image} to ${new_image}.img"
    read size filename < <(ls -sH ${workdir}/${base_image})
    #echo $size
    #size="620M"
    #echo "pv -cfpterb -s ${size} -N "xzcat:${base_image}" $workdir/$base_image"
    pvcmd="pv -s ${size} -cfperb -N "xzcat:${base_image}" $workdir/$base_image"
    echo $pvcmd
    $pvcmd | xzcat > $workdir/$new_image.img
    [[ $DELTA ]] && (cp $workdir/$new_image.img $workdir/old_image.img &)
    fi
    [[ -f "/output/loop_device" ]] && ( old_loop_device=`cat /output/loop_device` ; \
    dmsetup remove -f /dev/mapper/${old_loop_device}p2 &> /dev/null || true; \
    dmsetup remove -f /dev/mapper/${old_loop_device}p1 &> /dev/null || true; \
    losetup -d /dev/${old_loop_device} &> /dev/null || true)
    #echo "* Increasing image size by 200M"
    #dd if=/dev/zero bs=1M count=200 >> $workdir/$new_image.img
    echo "* Clearing existing loopback mounts."
    # This is dangerous as this may not be the relevant loop device.
    #losetup -d /dev/loop0 &>/dev/null || true
    #dmsetup remove_all
    dmsetup info
    losetup -a
    cd $workdir
    echo "* Mounting: ${new_image}.img"
    
    loop_device=$(kpartx -avs ${new_image}.img \
    | sed -n 's/\(^.*map\ \)// ; s/p1\ (.*//p')
    echo $loop_device >> /tmp/loop_device
    echo $loop_device > /output/loop_device
    #e2fsck -f /dev/loop0p2
    #resize2fs /dev/loop0p2
    
    # To stop here "rm /flag/done.ok_to_continue_after_mount_image".
    if [ ! -f /flag/done.ok_to_continue_after_mount_image ]; then
        echo "** Image mount done & container paused. **"
        echo 'Type in "/flag/done.ok_to_continue_after_mount_image"'
        echo "in a shell into this container to continue."
    fi 
    waitfor "ok_to_continue_after_mount_image"
    
    mount /dev/mapper/${loop_device}p2 /mnt
    mount /dev/mapper/${loop_device}p1 /mnt/boot/firmware
    # Guestmount is at least an order of magnitude slower than using loopback device.
    #guestmount -a ${new_image}.img -m /dev/sda2 -m /dev/sda1:/boot/firmware --rw /mnt -o dev
    
endfunc
}

arm64_chroot_setup () {
    waitfor "image_extract_and_mount"
startfunc    
    echo "* Setup ARM64 chroot"
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin
    

    mount -t proc proc     /mnt/proc/
#    mount -t sysfs sys     /mnt/sys/
#    mount -o bind /dev     /mnt/dev/
    mount -o bind /dev/pts /mnt/dev/pts
    mount --bind $apt_cache /mnt/var/cache/apt
 #   chmod -R 777 /mnt/var/lib/apt/
 #   setfacl -R -m u:_apt:rwx /mnt/var/lib/apt/ 
    mkdir -p /mnt/ccache || ls -aFl /mnt
    mount --bind $CCACHE_DIR /mnt/ccache
    mount --bind /run /mnt/run
    mkdir -p /run/systemd/resolve
    cp /etc/resolv.conf /run/systemd/resolve/stub-resolv.conf
    rsync -avh --devices --specials /run/systemd/resolve /mnt/run/systemd > /dev/null
    
    
    # Apt concurrency manager wrapper via
    # https://askubuntu.com/posts/375031/revisions
    mkdir -p /mnt/usr/local/bin
    cat <<'EOF'> /mnt/usr/local/bin/chroot-apt-wrapper
#!/bin/bash

i=0
tput sc
while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    echo -en "\r[$j] Waiting for other apt instances to finish..." 
    sleep 0.5
    ((i=i+1))
done 

/usr/bin/apt-get "$@"
EOF
    chmod +x /mnt/usr/local/bin/chroot-apt-wrapper

cat <<'EOF'> /mnt/usr/local/bin/chroot-dpkg-wrapper
#!/bin/bash

i=0
tput sc
while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    echo -en "\r[$j] Waiting for other dpkg instances to finish..." 
    sleep 0.5
    ((i=i+1))
done 

/usr/bin/dpkg "$@"
EOF
chmod +x /mnt/usr/local/bin/chroot-dpkg-wrapper



    mkdir -p /mnt/build
    mount -o bind /build /mnt/build
    echo "* ARM64 chroot setup is complete."  
endfunc
}

image_apt_installs () {
        waitfor "arm64_chroot_setup"
startfunc    
    echo "* Remove man-db."
    #Otherwise this wreaks havoc later. Something with qemu maybe?
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper \
     remove -qq --purge man-db" &>> /tmp/${FUNCNAME[0]}.install.log
     
    echo "* Starting apt update."
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    update &>> /tmp/${FUNCNAME[0]}.install.log | grep packages | cut -d '.' -f 1  || true
    echo "* Apt update done."
    echo "* Downloading software for apt upgrade."
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    upgrade -d -y &>> /tmp/${FUNCNAME[0]}.install.log || true
    echo "* Apt upgrade download done."
    echo "* Downloading wifi & networking tools."
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    -d install wireless-tools wireless-regdb crda \
    net-tools network-manager -qq &>> /tmp/${FUNCNAME[0]}.install.log || true
    # This setup is to see if we can get around the issues with kernel
    # module support binaries built in amd64 instead of arm64.
    #echo "* Downloading qemu-user-static"
    # qemu-user-binfmt needs to be installed after reboot though otherwise there 
    # are container problems.
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    -d install  \
    qemu-user qemu libc6-amd64-cross -qq &>> /tmp/${FUNCNAME[0]}.install.log || true
    
# endfunc
# }
# 
# image_apt_upgrade () {
#         waitfor "image_apt_download"
# startfunc 
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper install -qq \
    --no-install-recommends \
    qemu-user qemu libc6-amd64-cross" &>> /tmp/${FUNCNAME[0]}.install.log || true
                          
    echo "* Apt upgrading image in chroot."
    #echo "* There may be some errors here due to" 
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper upgrade -qq || (/usr/local/bin/chroot-dpkg-wrapper --configure -a ; /usr/local/bin/chroot-apt-wrapper upgrade -qq)" || true &>> /tmp/${FUNCNAME[0]}.install.log || true
    echo "* Image apt upgrade done."
    
# endfunc
# }
# 
# image_apt_install () {
#         waitfor "image_apt_upgrade"
# startfunc
  echo "* Installing wifi & networking tools to image."
    #chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper \
    #install wireless-tools wireless-regdb crda \
    #net-tools network-manager -y $silence_apt_flags" &>> /tmp/${FUNCNAME[0]}.install.log
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper \
    install wireless-tools wireless-regdb crda \
    net-tools network-manager -qq " &>> /tmp/${FUNCNAME[0]}.install.log || true
    echo "* Wifi & networking tools installed." 
    #chroot /mnt /bin/bash -c "lsinitramfs /boot/firmware/initrd.img" &>> /output/initramfs.log

endfunc
}

nativebuild () {
    waitfor "arm64_chroot_setup"
startfunc
    echo "* Downloading software for building portions of kernel natively on chroot."
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    install -d -qq --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils 2>/dev/null
    echo "* Installing native kernel build software to image."
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper install -y --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils $silence_apt_flags"
    echo "* Native kernel build software installed."
endfunc
}


rpi_firmware () {
    git_get "https://github.com/Hexxeh/rpi-firmware" "rpi-firmware"
    waitfor "image_extract_and_mount"
startfunc    
    cd $workdir/rpi-firmware
    echo "* Installing current RPI firmware."
    cp bootcode.bin /mnt/boot/firmware/
    cp *.elf /mnt/boot/firmware/
    cp *.dat /mnt/boot/firmware/
    cp *.dat /mnt/boot/firmware/
    cp *.dtb /mnt/boot/firmware/
    cp *.dtb /mnt/etc/flash-kernel/dtbs/
    cp overlays/*.dtbo /mnt/boot/firmware/overlays/
endfunc
}

kernelbuild_setup () {
    git_get "$kernelgitrepo" "rpi-linux" "$kernel_branch"
    majorversion=`grep VERSION $src_cache/rpi-linux/Makefile | \
    head -1 | awk -F ' = ' '{print $2}'`
    patchlevel=`grep PATCHLEVEL $src_cache/rpi-linux/Makefile | \
    head -1 | awk -F ' = ' '{print $2}'`
    sublevel=`grep SUBLEVEL $src_cache/rpi-linux/Makefile | \
    head -1 | awk -F ' = ' '{print $2}'`
    extraversion=`grep EXTRAVERSION $src_cache/rpi-linux/Makefile | \
    head -1 | awk -F ' = ' '{print $2}'`
    extraversion_nohyphen="${extraversion//-}"
    CONFIG_LOCALVERSION=`grep CONFIG_LOCALVERSION \
    $src_cache/rpi-linux/arch/arm64/configs/bcm2711_defconfig | \
    head -1 | awk -F '=' '{print $2}' | sed 's/"//g'`
    PKGVER="$majorversion.$patchlevel.$sublevel"
    
    #echo "PKGVER: $PKGVER"
    kernelrev=`git -C $src_cache/rpi-linux rev-parse --short HEAD` > /dev/null
    KERNEL_VERS="${PKGVER}${CONFIG_LOCALVERSION}-g${kernelrev}"
    echo "KERNEL_VERS: $KERNEL_VERS" 
    echo $KERNEL_VERS > /tmp/KERNEL_VERS
startfunc    
    cd $workdir/rpi-linux
        # Get rid of dirty localversion as per https://stackoverflow.com/questions/25090803/linux-kernel-kernel-version-string-appended-with-either-or-dirty
    #touch $workdir/rpi-linux/.scmversion
    sed -i \
     "s/scripts\/package/scripts\/package\\\|Makefile\\\|scripts\/setlocalversion/g" \
     $workdir/rpi-linux/scripts/setlocalversion

    cd $workdir/rpi-linux
    git update-index --refresh &>> /tmp/${FUNCNAME[0]}.compile.log || true
    git diff-index --quiet HEAD &>> /tmp/${FUNCNAME[0]}.compile.log || true
    

    mkdir $workdir/kernel-build
    cd $workdir/rpi-linux
    
    
    [ ! -f arch/arm64/configs/bcm2711_defconfig ] && \
    wget https://raw.githubusercontent.com/raspberrypi/linux/rpi-5.2.y/arch/arm64/configs/bcm2711_defconfig \
    -O arch/arm64/configs/bcm2711_defconfig
endfunc
}
    
kernel_build () {
    waitfor "kernelbuild_setup"
startfunc
    KERNEL_VERS=`cat /tmp/KERNEL_VERS`
    cd $workdir/rpi-linux
    make \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    O=$workdir/kernel-build \
    bcm2711_defconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    
    cd $workdir/kernel-build
    # Use kernel config modification script from sakaki- found at 
    # https://github.com/sakaki-/bcm2711-kernel-bis
    # This is needed to enable squashfs - which snapd requires, since otherwise
    # login at boot fails on the ubuntu server image.
    # This also enables the BPF syscall for systemd-journald firewalling
    /source-ro/conform_config.sh
    yes "" | make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    O=$workdir/kernel-build/ \
    olddefconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    
    
    KERNEL_VERS=`cat /tmp/KERNEL_VERS`
    #make -j$(($(nproc) + 1)) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    #O=$workdir/kernel-build/ &>> /tmp/${FUNCNAME[0]}.compile.log
    
    echo "* Making $KERNEL_VERS kernel debs."
    # Enable this if we want certain kernel install files compiled in
    # arm64 chroot
    #ext_mod_build_infrastructure
    cd $workdir/rpi-linux
    debcmd="make \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    -j$(($(nproc) + 1)) O=$workdir/kernel-build \
    bindeb-pkg & job=$!"
    

    echo $debcmd
    $debcmd &>> /tmp/${FUNCNAME[0]}.compile.log
#     while kill -0 $job 2>/dev/null
#     do for s in / - \\ \|
#         do printf "Compiling Kernel Debs.\r$s"
#         sleep .1
#         done
#     done
    
        
endfunc
}

ext_mod_build_infrastructure () {
    waitfor "arm64_chroot_setup"
    waitfor "kernelbuild_setup"
startfunc

    cd $workdir/rpi-linux
    echo "* Regenerating broken cross-compile module installation infrastructure."
    nativebuild
    # Cross-compilation of kernel wreaks havoc with building out of kernel modules
    # later, due to module install files being installed into the target system in
    # the cross-compile build host architecture, so let's fix this with natively 
    # compiled module tools which have been installed into the image.
    files=("scripts/recordmcount" "scripts/mod/modpost" \
        "scripts/basic/fixdep")
        
    for i in "${files[@]}"
    do
     rm $workdir/kernel-build/$i || true
    done
    
    # This is all we can do before the image is mounted.
    waitfor "image_extract_and_mount"   
    waitfor "arm64_chroot_setup"
    
    chroot /mnt /bin/bash -c "cd $workdir/rpi-linux ; make \
    CCACHE_DIR=/ccache PATH=/usr/lib/ccache:$PATH \
    -j $(($(nproc) + 1)) O=$workdir/kernel-build \
    modules_prepare" &>> /tmp/${FUNCNAME[0]}.compile.log
    #LOCALVERSION=-${kernelrev} \

    mkdir -p $workdir/kernel-build/tmp/scripts/mod
    mkdir -p $workdir/kernel-build/tmp/scripts/basic
    for i in "${files[@]}"
    do
     cp $workdir/kernel-build/$i $workdir/kernel-build/tmp/$i
     rm $workdir/kernel-build/$i
     sed -i "/.tmp_quiet_recordmcount$/i TABTMP\$(Q)cp $workdir/kernel-build/tmp/${i} ${i}" \
     $workdir/rpi-linux/Makefile
    done
    TAB=$'\t'
    sed -i "s/TABTMP/${TAB}/g" $workdir/rpi-linux/Makefile
    
    # Now we have qemu-static & arm64 binaries installed, so we copy libraries over
    # from image to build container in case they are needed during this install.
    #cp /mnt/usr/lib/aarch64-linux-gnu/libc.so.6 /lib64/
    #cp /mnt/lib/ld-linux-aarch64.so.1 /lib/
    
    # Maybe this can all be worked around by statically compiling these files
    # so that qemu-static can just deal with them without library issues during the 
    # packaging process. This two lines may not be needed.
    aarch64-linux-gnu-gcc -static $workdir/rpi-linux/scripts/basic/fixdep.c -o \
    $workdir/kernel-build/tmp/scripts/basic/fixdep &>> /tmp/${FUNCNAME[0]}.compile.log
    
    aarch64-linux-gnu-gcc -static $workdir/rpi-linux/scripts/recordmcount.c -o \
    $workdir/kernel-build/tmp/scripts/recordmount &>> /tmp/${FUNCNAME[0]}.compile.log
    
    endfunc
    }



kernel_debs () {
    waitfor "kernelbuild_setup"
startfunc

   # Don't remake debs if they already exist in output.
   #arbitrary_wait
   KERNEL_VERS=`cat /tmp/KERNEL_VERS`
   echo -e "Looking for cached $KERNEL_VERS kernel debs."
    for f in "$apt_cache/linux-image-*${KERNEL_VERS}*"; do
     if [ -f "$f" ]
     then
        echo -e "$f on cache volume. 😎\n"
        echo 1 > /tmp/nodebs
     else
        rm -f /tmp/nodebs || true
    fi
    break
    done
    for f in "$apt_cache/linux-headers-*${KERNEL_VERS}*"; do
     if [ -f "$f" ]
     then
        echo -e "$f on cache volume. 😎\n"
        echo 1> /tmp/nodebs
     else
         rm -f /tmp/nodebs || true
     fi
     break
    done
    if [[ -e /tmp/nodebs ]]
    then
    # echo -e "Using existing $KERNEL_VERS debs from cache volume.\nNo \
    # kernel needs to be built."
    cp $apt_cache/linux-image-*${KERNEL_VERS}*arm64.deb $workdir/
    cp $apt_cache/linux-headers-*${KERNEL_VERS}*arm64.deb $workdir/
    cp $workdir/*.deb /output/ 
    chown $USER:$GROUP /output/*.deb
    else
        echo "Cached $KERNEL_VERS kernel debs not found. Building."
        kernel_build &
        spinnerwait kernel_build
        #waitfor "kernel_build"
        #arbitrary_wait

        echo "* Copying out git *${KERNEL_VERS}* kernel debs."
        rm -f $workdir/linux-libc-dev*.deb
        cp $workdir/*.deb $apt_cache/
        cp $workdir/*.deb /output/ 
        chown $USER:$GROUP /output/*.deb
    fi
    


 endfunc
}   

kernel_deb_install () {
    waitfor "kernel_debs"
    waitfor "image_extract_and_mount"
    waitfor "added_scripts"
    waitfor "image_apt_installs"
startfunc
    KERNEL_VERS=`cat /tmp/KERNEL_VERS`
    # Try installing the generated debs in chroot before we do anything else.
    cp $workdir/*.deb /mnt/tmp/
    waitfor "added_scripts"
    waitfor "arm64_chroot_setup"
    echo "* Installing $KERNEL_VERS debs to image."
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper remove \
    linux-image-raspi2 linux-image*-raspi2 linux-modules*-raspi2 -y --purge" \
    &>> /tmp/${FUNCNAME[0]}.install.log || true
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-dpkg-wrapper -i /tmp/*.deb" \
    &>> /tmp/${FUNCNAME[0]}.install.log || true
    cp /mnt/boot/initrd.img-$KERNEL_VERS /mnt/boot/firmware/initrd.img
    cp /mnt/boot/vmlinuz-$KERNEL_VERS /mnt/boot/firmware/vmlinuz
   # chroot /mnt /bin/bash -c "lsinitramfs /boot/firmware/initrd.img" \
   #&> /output/initramfs.log || true
    vmlinuz_type=`file -bn /mnt/boot/firmware/vmlinuz`
    if [ "$vmlinuz_type" == "MS-DOS executable" ]
        then
        cp /mnt/boot/firmware/vmlinuz /mnt/boot/firmware/kernel8.img.nouboot
    else
        cp /mnt/boot/firmware/vmlinuz /mnt/boot/firmware/kernel8.img.nouboot.gz
        cd /mnt/boot/firmware/ ; gunzip /mnt/boot/firmware/kernel8.img.nouboot.gz \
        &>> /tmp/${FUNCNAME[0]}.install.log
    fi
    # Make booting without uboot the default so we get the default 3Gb ram available.
    cp /mnt/boot/firmware/kernel8.img.nouboot /mnt/boot/firmware/kernel8.img

endfunc
}


armstub8-gic () {
    git_get "https://github.com/raspberrypi/tools.git" "rpi-tools"
startfunc    
    cd $workdir/rpi-tools/armstubs
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make armstub8-gic.bin &>> /tmp/${FUNCNAME[0]}.compile.log
    waitfor "image_extract_and_mount"
    cp $workdir/rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin
endfunc
}

non-free_firmware () {
    git_get "https://github.com/RPi-Distro/firmware-nonfree" "firmware-nonfree"
    waitfor "image_extract_and_mount"
startfunc    
    cp -af $workdir/firmware-nonfree/* /mnt/usr/lib/firmware
endfunc
}


rpi_config_txt_configuration () {
    waitfor "image_extract_and_mount"
startfunc    
    echo "* Making /boot/firmware/config.txt modifications."
    
    cat <<-EOF >> /mnt/boot/firmware/config.txt
	#
	# This image was built on $now using software at
	# https://github.com/satmandu/docker-rpi4-imagebuilder/
	# 
EOF
    if ! grep -qs 'armstub=armstub8-gic.bin' /mnt/boot/firmware/config.txt
        then echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'enable_gic=1' /mnt/boot/firmware/config.txt
        then echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt
        then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt
    fi
    
    if grep -qs 'kernel8.bin' /mnt/boot/firmware/config.txt
        then sed -i 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'initramfs' /mnt/boot/firmware/config.txt
        then echo "initramfs initrd.img followkernel" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'enable_uart=1' /mnt/boot/firmware/config.txt
        then echo "enable_uart=1" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'dtparam=eth_led0' /mnt/boot/firmware/config.txt
        then cat <<-EOF >> /mnt/boot/firmware/config.txt
		# Disable Ethernet LEDs
		#dtparam=eth_led0=14
		#dtparam=eth_led1=14
EOF
    fi
    
    if ! grep -qs 'dtparam=pwr_led_trigger' /mnt/boot/firmware/config.txt
        then cat <<-EOF >> /mnt/boot/firmware/config.txt
		# Disable the PWR LED
		#dtparam=pwr_led_trigger=none
		#dtparam=pwr_led_activelow=off
EOF
    fi
    
    if ! grep -qs 'dtparam=act_led_trigger' /mnt/boot/firmware/config.txt
        then cat <<-EOF >> /mnt/boot/firmware/config.txt
		# Disable the Activity LED
		#dtparam=act_led_trigger=none
		#dtparam=act_led_activelow=off
EOF
    fi
    
    
    # 3Gb limitation because USB & devices do not work currently without this.
     [ `grep -cs "total_mem=" /mnt/boot/firmware/config.txt` -gt 0 ] && \
     sed -i 's/total_mem=*$/total_mem=3072/' /mnt/boot/firmware/config.txt || \
     echo "total_mem=3072" >> /mnt/boot/firmware/config.txt

endfunc
}

rpi_cmdline_txt_configuration () {
    waitfor "image_extract_and_mount"
startfunc    
    echo "* Making /boot/firmware/cmdline.txt modifications."
    
    # Seeing possible sdcard issues, so be safe for now.
    if ! grep -qs 'fsck.repair=yes' /mnt/boot/firmware/cmdline.txt
        then sed -i 's/rootwait/rootwait fsck.repair=yes/' /mnt/boot/firmware/cmdline.txt
    fi
    
    if ! grep -qs 'fsck.mode=force' /mnt/boot/firmware/cmdline.txt
        then sed -i 's/rootwait/rootwait fsck.mode=force/' /mnt/boot/firmware/cmdline.txt
    fi
    
    # There are still DMA memory issues with >1Gb memory access so do this as per
    # https://github.com/raspberrypi/linux/issues/3032#issuecomment-511214995
    # This disables logging of the SD card DMA getting disabled, which happens
    # anyways, so hopefully this is only a temporary workaround to having logspam
    # in dmesg until this issue is actually addressed.
    if ! grep -qs 'sdhci.debug_quirks=96' /mnt/boot/firmware/cmdline.txt
        then sed -i 's/rootwait/rootwait sdhci.debug_quirks=96/' \
        /mnt/boot/firmware/cmdline.txt
    fi
    
endfunc
}


rpi_userland () {
    git_get "https://github.com/raspberrypi/userland" "rpi-userland"
    waitfor "image_extract_and_mount"
startfunc
    echo "* Installing Raspberry Pi userland source."
    cd $workdir
    mkdir -p /mnt/opt/vc
    cd $workdir/rpi-userland/
    CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt &>> /tmp/${FUNCNAME[0]}.compile.log
    
    echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
    
    mkdir -p /mnt/etc/environment.d
    cat  <<-EOF > /mnt/etc/environment.d/10-vcgencmd.conf
	# /etc/environment.d/10-vcgencmd.conf
	# Do not edit this file
	
	PATH="/opt/vc/bin:/opt/vc/sbin"
	ROOTPATH="/opt/vc/bin:/opt/vc/sbin"
	LDPATH="/opt/vc/lib"
EOF
    chmod +x /mnt/etc/environment.d/10-vcgencmd.conf
    
    cat <<-'EOF' > /mnt/etc/profile.d/98-rpi.sh 
	# /etc/profile.d/98-rpi.sh
	# Adds Raspberry Pi Foundation userland binaries to path
	export PATH="$PATH:/opt/vc/bin:/opt/vc/sbin"
EOF
    chmod +x /mnt/etc/profile.d/98-rpi.sh
       
    cat  <<-EOF > /mnt/etc/ld.so.conf.d/00-vmcs.conf
	/opt/vc/lib
EOF
    local SUDOPATH=`sed -n 's/\(^.*secure_path="\)//p' /mnt/etc/sudoers | sed s'/.$//'`
    SUDOPATH="${SUDOPATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin}"
    SUDOPATH+=":/opt/vc/bin:/opt/vc/sbin"
    # Add path to sudo
    mkdir -p /etc/sudoers.d
    echo "* Adding rpi util path to sudo."
    cat <<-EOF >> /mnt/etc/sudoers.d/rpi
	Defaults secure_path=$SUDOPATH
EOF
	chmod 0440 /mnt/etc/sudoers.d/rpi
endfunc
}

wifi_firmware_modification () {
    waitfor "image_extract_and_mount"
    waitfor "non-free_firmware"
startfunc    
    #echo "* Modifying wireless firmware if necessary."
    # as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
    if ! grep -qs 'boardflags3=0x44200100' \
    /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
        then sed -i -r 's/0x48200100/0x44200100/' \
        /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
    fi
endfunc
}

andrei_gherzan_uboot_fork () {
startfunc
    git_get "https://github.com/agherzan/u-boot.git" "u-boot" "ag/rpi4"   
    cd $workdir/u-boot
#    curl -O https://github.com/satmandu/u-boot/commit/b514f892bc3d6ecbc75f80d0096055a6a8afbf75.patch
#    patch -p1 < b514f892bc3d6ecbc75f80d0096055a6a8afbf75.patch
    echo "CONFIG_LZ4=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_GZIP=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_BZIP2=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_SYS_LONGHELP=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_REGEX=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make rpi_4_defconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j $(($(nproc) + 1)) &>> /tmp/${FUNCNAME[0]}.compile.log
    waitfor "image_extract_and_mount"
    echo "* Installing Andrei Gherzan's RPI uboot fork to image."
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/uboot.bin
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/kernel8.bin
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/kernel8.img
    mkdir -p /mnt/usr/lib/u-boot/rpi_4/
    cp $workdir/u-boot/u-boot.bin /mnt/usr/lib/u-boot/rpi_4/
    chroot /mnt /bin/bash -c "mkimage -A arm64 -O linux -T script \
    -d /etc/flash-kernel/bootscript/bootscr.rpi \
    /boot/firmware/boot.scr" &>> /tmp/${FUNCNAME[0]}.compile.log

endfunc
}

first_boot_scripts_setup () {
    waitfor "image_extract_and_mount"
startfunc    
    echo "* Creating first start cleanup script."
    cat <<-'EOF' > /mnt/etc/rc.local
	#!/bin/sh -e
	#
	# Print the IP address
	    _IP=$(hostname -I) || true
	if [ "$_IP" ]; then
	    printf "My IP address is %s\n" "$_IP"
	fi
	# Disable wifi power saving, which causes wifi instability.
	iwconfig wlan0 power off
	#
	/etc/rc.local.temp &
	exit 0
EOF
    chmod +x /mnt/etc/rc.local


    cat <<-'EOF' > /mnt/etc/rc.local.temp
	#!/bin/sh -e
	# 1st Boot Cleanup Script
	#
	/usr/bin/dpkg -i /var/cache/apt/archives/*.deb
	/usr/local/bin/chroot-apt-wrapper remove linux-image-raspi2 linux-image*-raspi2 -y --purge
	/usr/local/bin/chroot-apt-wrapper update && /usr/local/bin/chroot-apt-wrapper upgrade -y
	/usr/local/bin/chroot-apt-wrapper install qemu-user-binfmt -qq
	# man-db disabled due to v2.8.6 causing segfaults. v2.8.6.1 has the fix.
	#/usr/local/bin/chroot-apt-wrapper install man-db -qq
	/usr/sbin/update-initramfs -c -k all
	sed -i 's/\/etc\/rc.local.temp\ \&//' /etc/rc.local 
	rm -- "$0"
	exit 0
EOF
    chmod +x /mnt/etc/rc.local.temp
    
endfunc
} 

added_scripts () {
    waitfor "image_extract_and_mount"
startfunc    

    ## This script allows flash-kernel to create the uncompressed kernel file
    #  on the boot partition.
    mkdir -p /mnt/etc/kernel/postinst.d
    echo "* Creating /etc/kernel/postinst.d/zzzz_rpi4_kernel ."
    cat <<-'EOF' > /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel
	#!/bin/sh -eu
	#
	# If u-boot is not being used, this uncompresses the arm64 kernel to 
	# kernel8.img
	#
	# First exit if we aren't running an ARM64 kernel.
	#
	[ `uname -m` != aarch64 ] && exit 0
	#
	KERNEL_VERSION="$1"
	KERNEL_INSTALLED_PATH="$2"
	
	# If kernel8.img does not look like u-boot, then assume u-boot
	# is not being used.
	file /boot/firmware/kernel8.img | grep -vq "PCX" && \
	gunzip -c -f ${KERNEL_INSTALLED_PATH} > /boot/firmware/kernel8.img
	
	exit 0
EOF
    chmod +x /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel

    ## This script makes the device tree folder that a bunch of kernel debs 
    # never bother installing.

    mkdir -p /mnt/etc/kernel/preinst.d/
    echo "* Creating /etc/kernel/preinst.d/rpi4_make_device_tree_folders ."
    cat <<-'EOF' > /mnt/etc/kernel/preinst.d/rpi4_make_device_tree_folders
	#!/bin/sh -eu
	#
	# This script keeps kernel installs from complaining about a missing 
	# device tree folder in /lib/firmware/kernelversion/device-tree
	# This should go in /etc/kernel/preinst.d/
	
	KERNEL_VERSION="$1"
	KERNEL_INSTALLED_PATH="$2"
	
	mkdir -p /usr/lib/firmware/${KERNEL_VERSION}/device-tree/
	
	exit 0
EOF
    chmod +x /mnt/etc/kernel/preinst.d/rpi4_make_device_tree_folders

    # Updated flash-kernel db entry for the RPI 4B

    mkdir -p /mnt/etc/flash-kernel/
    echo "* Creating /etc/flash-kernel/db ."
    cat <<-EOF >> /mnt/etc/flash-kernel/db
	#
	# Raspberry Pi 4 Model B Rev 1.1
	Machine: Raspberry Pi 4 Model B
	Machine: Raspberry Pi 4 Model B Rev 1.1
	DTB-Id: /etc/flash-kernel/dtbs/bcm2711-rpi-4-b.dtb
	Boot-DTB-Path: /boot/firmware/bcm2711-rpi-4-b.dtb
	Boot-Kernel-Path: /boot/firmware/vmlinuz
	Boot-Initrd-Path: /boot/firmware/initrd.img
	Boot-Script-Path: /boot/firmware/boot.scr
	U-Boot-Script-Name: bootscr.rpi
	Required-Packages: u-boot-tools
	# XXX we should copy the entire overlay dtbs dir too
	# Note as of July 31, 2019 the Ubuntu u-boot-rpi does 
	# not have the required u-boot for the RPI4 yet.
EOF


endfunc
}

image_and_chroot_cleanup () {
    waitfor "rpi_firmware"
    waitfor "armstub8-gic"
    waitfor "non-free_firmware"
    waitfor "rpi_userland"
    waitfor "andrei_gherzan_uboot_fork"
    waitfor "kernel_debs"
    waitfor "rpi_config_txt_configuration"
    waitfor "rpi_cmdline_txt_configuration"
    waitfor "wifi_firmware_modification"
    waitfor "first_boot_scripts_setup"
    waitfor "added_scripts"
    waitfor "arm64_chroot_setup"
    waitfor "kernel_deb_install"
startfunc    
    echo "* Finishing image setup."
    
    echo "* Cleaning up ARM64 chroot"
    chroot /mnt /bin/bash -c "/usr/local/bin/chroot-apt-wrapper \
    autoclean -y $silence_apt_flags"
    
    # binfmt wreaks havoc with the container AND THE HOST, so let it get 
    # installed at first boot.
    umount /mnt/var/cache/apt
    echo "Installing binfmt-support files for install at first boot."
    chroot-apt-wrapper -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/mnt/var/cache/apt/archives/ \
    -d install qemu-user-binfmt -qq 2>/dev/null


    # I'm not sure where this is needed, but kernel install
    # craps out without this: /lib/firmware/`uname -r`/device-tree/
    # So we create it:
    #mkdir -p /mnt/lib/firmware/`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`/device-tree/
    # Now handled by script on image.
    
    # Copy in kernel debs generated earlier to be installed at
    # first boot.
    echo "* Copying compiled kernel debs to image for proper install"
    echo "* at first boot and also so we have a copy locally."
    cp $workdir/*.deb /mnt/var/cache/apt/archives/
    sync
    # To stop here "rm /flag/done.ok_to_unmount_image_after_build".
    #if [ ! -f /flag/done.ok_to_unmount_image_after_build ]; then
    #    echo "** Container paused before image unmount. **"
    #    echo 'Type in "touch /flag/done.ok_to_unmount_image_after_build"'
    #    echo "in a shell into this container to continue."
    #fi 
     
    waitfor "ok_to_umount_image_after_build"
    umount /mnt/build
    umount /mnt/run
    umount /mnt/ccache
    rmdir /mnt/ccache
    umount /mnt/proc
    umount /mnt/dev/pts
    #umount /mnt/sys
    # This is no longer needed.
    rm /mnt/usr/bin/qemu-aarch64-static
endfunc
}

image_unmount () {
startfunc
    echo "* Unmounting modified ${new_image}.img"
    loop_device=`cat /tmp/loop_device`
    umount -l /mnt/boot/firmware || (lsof +f -- /mnt/boot/firmware ; sleep 60 ; \
    umount -l /mnt/boot/firmware) || true
    #umount /mnt || (mount | grep /mnt)
    e4defrag /mnt >/dev/null
    umount -l /mnt || (lsof +f -- /mnt ; sleep 60 ; umount /mnt) || true
    #guestunmount /mnt

    
    kpartx -dv $workdir/${new_image}.img
    losetup -d /dev/$loop_device &>/dev/null || true
    dmsetup remove -f /dev/$loop_device &>/dev/null || true
    dmsetup info
    # To stop here "rm /flag/done.ok_to_exit_container_after_build".
    if [ ! -f /flag/done.ok_to_exit_container_after_build ]; then
        echo "** Image unmounted & container paused. **"
        echo 'Type in "touch /flag/done.ok_to_exit_container_after_build"'
        echo "in a shell into this container to continue."
    fi 
    waitfor "ok_to_exit_container_after_build"
endfunc
}

compressed_image_export () {
startfunc

    KERNEL_VERS=`cat /tmp/KERNEL_VERS`
    # Note that lz4 is much much faster than using xz.
    chown -R $USER:$GROUP /build
    cd $workdir
    for i in "${image_compressors[@]}"
    do
     echo "* Compressing ${new_image} with $i and exporting."
     compress_flags=""
     [ "$i" == "lz4" ] && compress_flags="-m"
     compresscmd="$i -v -k $compress_flags ${new_image}.img"
     echo $compresscmd
     $compresscmd
     cp "$workdir/${new_image}.img.$i" \
     "/output/${new_image}-$KERNEL_VERS_${now}.img.$i"
     #echo $cpcmd
     #$cpcmd
     chown $USER:$GROUP /output/${new_image}-$KERNEL_VERS_${now}.img.$i
     echo "${new_image}-$KERNEL_VERS_${now}.img.$i created." 
    done
endfunc
}    

xdelta3_image_export () {
startfunc
        echo "* Making xdelta3 binary diffs between today's eoan base image"
        echo "* and the new images."
        xdelta3 -e -S none -I 0 -B 1812725760 -W 16777216 -fs \
        $workdir/old_image.img $workdir/${new_image}.img \
        $workdir/patch.xdelta
        KERNEL_VERS=`cat /tmp/KERNEL_VERS`
        for i in "${image_compressors[@]}"
        do
            echo "* Compressing patch.xdelta with $i and exporting."
            compress_flags=""
            [ "$i" == "lz4" ] && compress_flags="-m"
            xdelta_patchout_compresscmd="$i -k $compress_flags \
             $workdir/patch.xdelta"
            $xdelta_patchout_compresscmd
            cp "$workdir/patch.xdelta.$i" \
     "/output/eoan-daily-preinstalled-server_$KERNEL_VERS_${now}.xdelta3.$i"
            #$xdelta_patchout_cpcmd
            chown $USER:$GROUP /output/eoan-daily-preinstalled-server_$KERNEL_VERS_${now}.xdelta3.$i
            echo "Xdelta3 file exported to:"
            echo "/output/eoan-daily-preinstalled-server_$KERNEL_VERS_${now}.xdelta3.$i"
        done
endfunc
}

export_log () {
    waitfor "compressed_image_export"
startfunc
    KERNEL_VERS=`cat /tmp/KERNEL_VERS`
    echo "* Build log at: build-log-$KERNEL_VERS_${now}.log"
    cat $TMPLOG > /output/build-log-$KERNEL_VERS_${now}.log
    chown $USER:$GROUP /output/build-log-$KERNEL_VERS_${now}.log
    
endfunc
}

# Delete this by connecting to the container using a shell if you want to 
# debug the container before the image is unmounted.
# The shell command would be something like this:
# docker exec -it `cat ~/docker-rpi4-imagebuilder/build.cid` /bin/bash
# Note that this flag is looked for in the image_and_chroot_cleanup function
touch /flag/done.ok_to_umount_image_after_build

# For debugging.
touch /flag/done.ok_to_continue_after_mount_image

# Arbitrary pause for debugging.
touch /flag/done.ok_to_continue_after_here

# Delete this by connecting to the container using a shell if you want to 
# debug the container before the container is exited.
# The shell command would be something like this:
# docker exec -it `cat ~/docker-rpi4-imagebuilder/build.cid` /bin/bash
# Note that this flag is looked for in the image_and_chroot_cleanup function
touch /flag/done.ok_to_exit_container_after_build

# inotify in docker seems to not recognize that files are being 
# created unless they are touched. Not sure where this bug is.
# So we will work around it.
inotify_touch_events &

base_image_check
image_extract_and_mount &
rpi_firmware &
armstub8-gic &
non-free_firmware & 
rpi_userland &
andrei_gherzan_uboot_fork &
kernelbuild_setup &
rpi_config_txt_configuration &
rpi_cmdline_txt_configuration &
wifi_firmware_modification &
first_boot_scripts_setup &
added_scripts &
waitforstart "kernelbuild_setup" && kernel_debs &
arm64_chroot_setup &
image_apt_installs &
# image_apt_installs & image_apt_installs_job=$!
spinnerwait image_apt_installs
# while kill -0 $image_apt_installs_job 2>/dev/null
#         do for s in / - \\ \|
#             do printf "%${COLUMNS}s\r" "Image software installs.$s"
#             sleep .1
#             done
# done
#arbitrary_wait
kernel_deb_install
# while kill -0 $kernel_deb_install_job 2>/dev/null
#         do for s in / - \\ \|
#             do printf "%${COLUMNS}s\r" "Setting up kernel install to image.$s"
#             sleep .1
#             done
# done
image_and_chroot_cleanup
image_unmount
compressed_image_export &
[[ $DELTA ]] && xdelta3_image_export
[[ $DELTA ]] && waitfor "xdelta3_image_export"
export_log
# This stops the tail process.
rm $TMPLOG
echo "**** Done."
