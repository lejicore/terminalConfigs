#!/bin/bash
#
# This script is made to launch a virtual machine from CLI using QEMU on kvm while enabling VFIO passthrough
#
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 -hda /run/media/oxhart/BigData/images/win.qcow2 -device vfio-pci,host=05:00.0,multifunction=on -device vfio-pci,host=05:00.1 -boot -cdrom /home/oxhart/Downloads/Win11_22H2_French_x64.iso
