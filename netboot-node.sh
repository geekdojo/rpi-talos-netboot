#! /bin/bash

piSerials=("fd6f8425" "9ffe8c84" "5712c92d" "106663d7" "3a671b4e" "70408f6c" "3975a78a" "0f3b47a1" "509f8ed8" "99b56890")

tftpRoot="/tftp"
tftpBaseline="$tftpRoot/baseline"
tftpIp=$(hostname -I | xargs)

talosVersion="0.14.3"
talosClusterName="dk8s"
talosClusterIp="192.168.197.200"
apacheRoot="/var/www/html"
talosBaselineDir="${apacheRoot}/talosBaseline"

# upgrade everything
apt update && apt upgrade -y

# install required apps
apt install dnsmasq apache2 -y

# ---- TFTP BOOT BEGIN ----

# configure dnsmasq

rm /etc/dnsmasq.conf

cat <<EOT >> /etc/dnsmasq.conf
interface=eth0
no-hosts
dhcp-range=$tftpIp,proxy
log-dhcp
enable-tftp
tftp-root=$tftpRoot
pxe-service=0,"Raspberry Pi Boot"
EOT

# configure tftp boot dir
rm -rf $tftpRoot

mkdir -p $tftpRoot
chmod 777 $tftpRoot
mkdir $tftpBaseline

# create boot baseline
wget -O $tftpBaseline/RPi4_UEFI-Firmware.zip https://github.com/pftf/RPi4/releases/download/v1.32/RPi4_UEFI_Firmware_v1.32.zip
unzip $tftpBaseline/RPi4_UEFI-Firmware.zip -d $tftpBaseline
rm $tftpBaseline/RPi4_UEFI-Firmware.zip
rm $tftpBaseline/RPI_EFI.fd
rm $tftpBaseline/config.txt

wget -O $tftpBaseline/initramfs-arm64.xz https://github.com/talos-systems/talos/releases/download/v$talosVersion/initramfs-arm64.xz
wget -O $tftpBaseline/vmlinuz-arm64 https://github.com/talos-systems/talos/releases/download/v$talosVersion/vmlinuz-arm64

# configure the pi boot to use the Talos kernel and initrd boot
cat <<EOT >> $tftpBaseline/config.txt
arm_64bit=1
arm_boost=1
enable_uart=1
uart_2ndstage=1
enable_gic=1
disable_commandline_tags=1
disable_overscan=1
kernel=vmlinuz-arm64
initramfs initramfs-arm64.xz followkernel
EOT

# create the talos specific cmdline.txt (i.e. kernel params)
cat <<EOT >> $tftpBaseline/cmdline.txt
talos.config=http://$tftpIp/ talos.platform=metal talos.board=rpi_4 panic=0
EOT

# symlink a directory for each pi to the baseline
for i in ${piSerials[@]}; do
    ln -s $tftpBaseline $tftpRoot/${i}
done

# ---- TFTP BOOT END ----

# ---- TALOS WEB BEGIN ----

# TODO config Apache to only respond to the PI's CIDR

rm /var/www/html/index.html

# install TalosCtl
rm /usr/local/bin/talosctl

curl -Lo /usr/local/bin/talosctl https://github.com/talos-systems/talos/releases/download/v$talosVersion/talosctl-linux-arm64
chmod +x /usr/local/bin/talosctl

# generate configs
rm -rf $talosBaselineDir

mkdir $talosBaselineDir
talosctl gen config $talosClusterName "https://${talosClusterIp}:6443" --output-dir $talosBaselineDir

talosConfigFiles=("${talosBaselineDir}/controlplane.yaml" "${talosBaselineDir}/worker.yaml")

for i in ${talosConfigFiles[@]}; do
    sed -i 's|/dev/sda|/dev/mmcblk0|g' $i
    sed -i 's|# sysctls:|sysctls:|g' $i
    sed -i 's|#     net.ipv4.ip_forward: "0"|    net.ipv4.ip_forward: "1"|g' $i

    sed -i 's|# interfaces:|  interfaces:|g' $i
    sed -i 's|#     - interface: eth0|    - interface: eth0|g' $i
    sed -i 's|#       # dhcp: true|      dhcp: true|g' $i

    if [[ $i == "${talosBaselineDir}/controlplane.yaml" ]]
    then
        #controlplane so let's add the VIP
        sed -i 's|#       # vip:|      vip:|g' $i
        sed -i "s|#       #     ip: 172.16.199.55|          ip: $talosClusterIp|g" $i
    fi
done

# determine number of controlplanes and workers
numberOfNodes=${#piSerials[@]}
numberOfControlPlanes=1
untaintControlPlanes=false # used later to allow scheduling on the controlplanes for small clusters
if [[ $numberOfNodes -gt 3 ]]
then
    ((numberOfControlPlanes=3))
else
    ((untaintControlPlanes=true))
fi

# now loop through all the PIs and create a directory for each in apache
let z=numberOfControlPlanes-1 #zero based array
for i in ${!piSerials[@]}; do
    newDir="${apacheRoot}/${piSerials[$i]}"

    rm -rf $newDir
    mkdir $newDir    

    if [[ $i -le $z ]]
    then
        #controlplane node
        if [[ $i == 0 ]]
        then
            # make first one init node
            cp "${talosBaselineDir}/controlplane.yaml" "${newDir}/controlplane.yaml"
            sed -i 's|type: controlplane|type: init|g' "${newDir}/controlplane.yaml"
            echo "WARNING WARNING: After bootstrap occurs you MUST change the type on ${newDir}/controlplane.yaml to 'controlplane' (from init) or risk a split head situation."
        else
            ln -s "${talosBaselineDir}/controlplane.yaml" "${newDir}/controlplane.yaml"
        fi
    else
        #worker node
        ln -s "${talosBaselineDir}/worker.yaml" "${newDir}/worker.yaml"
    fi
done

# ---- TALOS WEB END ----

# enable and start dnsmasq
#sudo systemctl enable dnsmasq.service
#sudo systemctl restart dnsmasq.service