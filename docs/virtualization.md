# KVM 虚拟机与显卡直通

> 索引：[项目说明](../README.md) · [系统基本配置](environment.md) · [安装脚本](../scripts/)

本指南假设宿主机已装好显卡驱动，见 [系统基本配置](environment.md#1-安装显卡驱动)。

## 1 安装kvm虚拟机

```bash
sudo pacman -S qemu-full virt-manager swtpm dnsmasq
sudo systemctl enable --now libvirtd
sudo usermod -a -G libvirt $(whoami)
sudo usermod -a -G kvm $(whoami)
sudo virsh net-start default
sudo virsh net-autostart default
```

嵌套虚拟化

```bash
sudo vim /etc/modprobe.d/kvm_amd.conf
```

写入

```bash
options kvm_amd nested=1
```

重新生成 initramfs

```bash
sudo mkinitcpio -P
```

打开virt-manager，在 edit -> preferences 里，确保Enable XML editing 是开启状态

## 2 安装windows虚拟机

先准备好win11的iso文件

下载VirtIO驱动镜像
<https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/>

virt-manager配置流程：
1.创建一个新的虚拟机
2.选择 Local install media，然后Forward
3.点击 Browse -> Browse Local 选择你下好的win11 iso
4.配置 RAM 和 CPU 核心
5.配置虚拟硬盘的最大容量
6.点击 Customize configuration before install，并选择一个网络

7.确保 CPUs 里的 Copy host CPU configuration   是开启状态并建议手动拓补，有需求时编辑xml
8.确保 Memory 里的 Enable shared memory 是开启状态
9.确保 Disk1 里 Disk bus 是 VirtIO
10.点击Add Hardware -> Storage 确保 Device type 是 CDROM device
，然后点击 Manage -> Browse Local 选择下好的VirtIO驱动镜像，点击 Finish
11.确保 NIC 里的 Device model 是 virtio
12.点击安装

windows安装流程：
1.进入安装介质后，在选择硬盘的阶段会找不到硬盘，这是因为VirtIO驱动还没有加载，
需要先选择 Load driver ，然后点击 OK,根据系统选择 win10 或者 win11，加载完成后，硬盘就应该会可见了
2.因为有关于网卡的驱动还没有安装，所以必须取消联网安装，按 Shfit+F10 打开命令行，输入 OOBE\BYPASSNRO   然后回车，系统重启后，就会允许选择不联网安装
3.安装完成进入系统后，安装 VirtIO ISO 里的驱动程序，
打开文件浏览器，选择 DVD Drive 找到 virtio-win-guest-tool.exe 安装

## 3 文件共享 VirtIO-FS

1.在windows虚拟机安装 WinFSP <https://winfsp.dev/rel/>，并在service面板设置服务自动开启
2.打开virt-manager，添加硬件，类型为 Filesystem，Driver 选择 virtiofs，
Source path 是你想选择共享的 linux 文件夹目录，Target path 是在windows里显示的名称

## 4 配置独显直通虚拟机

**1.配置宿主机**
本指南针对niri桌面环境进行配置，不同的桌面环境可能有不同的禁用独显渲染方案，除桌面配置外，其余流程通用
**启用IOMMU**
在 Grub 的配置文件 /etc/default/grub 中添加

```bash
# Intel CPU
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt ..."

# AMD CPU
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt ..."
```

**修改mkinitcpio**
修改文件 /etc/mkinitcpio.conf：

```bash
MODULES=(vfio_pci vfio vfio_iommu_type1 ...)
```

然后重新生成 Initramfs:

```bash
mkinitcpio -P
```

**修改niri配置文件**
先找到自己显卡的DRM文件名和PCI路径：

```bash
ls -l /sys/class/drm/card*/device/driver
ls -l /sys/class/drm/render*/device/driver
ls -l /dev/dri/by-path/
```

在niri配置文件中加入独显PCI路径忽略

```bash
debug {
    ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-card"
    ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-render"
}
```

注销重新启动niri查看是否占用niri

```bash
sudo fuser -v /dev/nvidia*
sudo fuser -v /dev/dri/card0
sudo fuser -v /dev/dri/renderD128
```

如果有其余进程可选杀死进程

```bash
sudo fuser -k -9 /dev/nvidia*
```

**显卡绑定 vfio_pci**
首先确认无进程使用 NVIDIA 后，移除所有模块

```bash
sudo rmmod nvidia_drm
sudo rmmod nvidia_modeset
sudo rmmod nvidia_uvm
sudo rmmod nvidia
```

让 VFIO 接管

```bash
# 加载 VFIO 模块
sudo modprobe vfio-pci

# 覆盖驱动为 VFIO
echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

# 重新扫描设备绑定 VFIO
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe

# 命令确认
lspci -k | grep -A 2 -i nvidia
```

在虚拟机里添加你的PCI独立显卡设备

## 5 配置 Looking-glass

1.在linux里安装 looking-glass 客户端，arch可以直接下载
aur里的 looking-glass 和 looking-glass-module-dkms
2.在windows里安装 looking-glass 服务端与 Virtual-Display-Driver，并确保服务开启
3.使用shmem进行虚拟机通信：
创建文件 /etc/tmpfiles.d/looking-glass.conf:

```bash
f /dev/shm/looking-glass 0660 用户名 kvm -
```

运行 sudo systemd-tmpfiles /etc/tmpfiles.d/looking-glass.conf --create 生效

创建文件 /etc/looking-glass-client.ini:

```bash
[app]
shmFile=/dev/shm/looking-glass
```

**编辑虚拟机的XML**
在 device 段添加

```bash
        ...
        <shmem name='looking-glass'>
          <model type='ivshmem-plain'/>
          <size unit='M'>64</size>
        </shmem>
    </device>
    ...
</domain>

```

数值的计算方法：分辨率宽x分辨率高x4x2/（1024x1024），
将计算的结果以2的n次方向上取整的整数
如显示器分辨率为 2560x1600，其结果为：

$$
\frac{2560 \times 1600 \times 4 \times 2}{1024 \times 1024} = 31.25
$$

最接近 31.25 的是 $2^6 = 64$，因此上面的值为 64

## 6 VFIO 解绑

**确认虚拟机已关闭**
解绑 VFIO

```bash
# 移除驱动覆盖
echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

# 解绑 VFIO
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
```

重新加载 NVIDIA 模块

```bash
sudo modprobe nvidia
sudo modprobe nvidia_drm
sudo modprobe nvidia_modeset
sudo modprobe nvidia_uvm
```

重新检测，激活显卡

```bash
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe
```
