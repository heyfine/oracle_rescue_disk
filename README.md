# 一键安装脚本：
bash -c "$(https://raw.githubusercontent.com/heyfine/oracle_rescue_disk/refs/heads/main/oracle_rescue.sh)"


# 🚒 甲骨文云 ARM (Ampere) 实例打造“不死之身”：Netboot.xyz 救援模式全攻略

## 前言
甲骨文云（OCI）的 ARM 机器性能强劲，但一旦玩挂（如 SSH 失联、防火墙配置错误），重装系统非常麻烦。传统的 mfslinux 并不支持 ARM 架构。本文将教你如何利用 Netboot.xyz (ARM64) 和 **移花接木法**，给你的 ARM 实例安装一个永久的救援模式。无论系统怎么挂，都能通过云控制台救回来！

---

## 🛠️ 准备工作
- **目标机器**：一台甲骨文 ARM 实例（系统盘默认 47G）。
- **辅助机器**：同一可用区（AD）下的任意另一台机器（AMD 或 ARM 均可，推荐 AMD 免费机）。
- **胆大心细**：涉及磁盘分区操作，建议先备份重要数据。

---

## ✂️ 第一步：移花接木（挂载磁盘）
由于无法在运行的系统上修改根分区，我们需要把磁盘拆下来操作。

1. **停止实例**：在 OCI 后台停止你的 ARM 目标机。
2. **分离引导卷**：进入“引导卷” (Boot Volumes)，找到该磁盘，点击“分离” (Detach)。
3. **挂载到辅助机**：
   - 找到辅助机，向下滚动到“附加的块存储卷” (Attached block volumes)。
   - 点击“附加”，选择刚才分离的 ARM 引导卷。
   - **重点**：挂载类型选择 **半虚拟化 (Paravirtualized)**，访问类型选择 **读/写**。
4. **确认挂载**：SSH 登录辅助机，输入 `lsblk`，确认看到一个新的 47G 磁盘（假设为 `/dev/sdb`）。

---

## 🔧 第二步：重新分区（三室一厅）
我们将 47G 的大磁盘切分为：**系统盘 (15G) + 救援盘 (200M) + 数据盘 (剩余)**。

在辅助机 SSH 中执行：

```bash
# 1. 修复并缩容文件系统 (假设 sdb1 为原系统分区)
e2fsck -f /dev/sdb1
resize2fs /dev/sdb1 15G

# 2. 修改分区表
fdisk /dev/sdb
```

**Fdisk 交互操作速查：**
- `d` -> `1`：删除原系统分区。
- `n` -> `1` -> `回车` -> `+15G`：新建系统分区（移除签名选 No！）。
- `n` -> `2` -> `回车` -> `+200M`：新建救援分区。
- `n` -> `3` -> `回车` -> `回车`：新建数据分区。
- `w`：保存退出。

**3. 格式化新分区：**

```bash
# 刷新系统分区大小
resize2fs /dev/sdb1

# 格式化救援分区 (sdb2)
mkfs.ext4 /dev/sdb2 -L RESCUE

# 格式化数据分区 (sdb3, 推荐 Btrfs)
mkfs.btrfs /dev/sdb3 -L DATA
```

---

## 📥 第三步：部署 ARM 版救援弹药
我们将 Netboot.xyz (ARM64 EFI) 放入救援分区。

```bash
# 1. 挂载救援分区
mkdir -p /mnt/rescue
mount /dev/sdb2 /mnt/rescue
cd /mnt/rescue

# 2. 下载 EFI 文件
wget https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi

# 3. 获取 UUID (复制下来！)
blkid /dev/sdb2
# 输出示例: UUID="c81e0126-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## ⚙️ 第四步：配置 GRUB 启动菜单
这是最关键的一步。我们需要挂载原系统盘修改配置。

```bash
# 1. 挂载原系统盘
mkdir -p /mnt/sys_root
mount /dev/sdb1 /mnt/sys_root

# 2. 写入救援菜单
# ⚠️ 请将下面 YOUR_UUID_HERE 替换为上一步获取的真实 UUID
cat <<'EOF' >> /mnt/sys_root/etc/grub.d/40_custom

menuentry "🚑 Rescue System (Netboot.xyz ARM)" {
    insmod part_gpt
    insmod ext2
    insmod chain
    search --no-floppy --fs-uuid --set=root YOUR_UUID_HERE
    chainloader /netboot.xyz-arm64.efi
}
EOF

# 3. 强制开启串口显示 & 设置 5 秒倒计时
cat <<EOF > /mnt/sys_root/etc/default/grub.d/99-oci-arm.cfg
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
EOF
```

---

## 🪄 第五步：跨架构 Chroot (QEMU 大法)
如果你是用 AMD 辅助机修 ARM 硬盘，直接 chroot 会报错 `Exec format error`。需要安装模拟器。

```bash
# 1. 安装 QEMU 静态模拟器 (在辅助机上)
apt-get update
apt-get install -y qemu-user-static binfmt-support

# 2. 拷贝模拟器到目标盘
cp /usr/bin/qemu-aarch64-static /mnt/sys_root/usr/bin/

# 3. 挂载系统目录
mount --bind /dev /mnt/sys_root/dev
mount --bind /proc /mnt/sys_root/proc
mount --bind /sys /mnt/sys_root/sys

# 4. 进入 ARM 系统环境
chroot /mnt/sys_root

# --- 以下命令在 chroot 内部执行 ---
update-grub
exit
# --- 退出 chroot ---

# 5. 卸载所有分区
umount -R /mnt/sys_root
umount /mnt/rescue
```

---

## 🚀 第六步：归位与测试
1. 在 OCI 后台将磁盘从辅助机分离。
2. 回到 ARM 原机，点击“引导卷” -> “附加引导卷”（必须作为 Boot Volume）。
3. 启动实例，并迅速打开 **“控制台连接” -> “启动 Cloud Shell 连接”**。
4. 你应该能看到 GRUB 菜单，选择 **🚑 Rescue System**。
5. 进入 Netboot.xyz 后，选择 **Linux Network Installs -> Alpine Linux** 即可进入内存救援系统！

---

## 💡 救援小贴士
进入 Alpine Linux 救援模式后，系统是运行在内存里的。
- **默认用户名**：`root` (无密码)
- **安装工具**：`apk update && apk add util-linux nano e2fsprogs`
- **挂载数据盘**：`mount /dev/sda3 /mnt`

---

## 🚀 阶段：克隆镜像与网络修复 (避坑必读)

当你成功打造了这台“不死之身”的机器后，自然希望将其作为模板，通过 **“引导卷备份”** 或 **“自定义镜像”** 功能快速克隆出新实例。但这里有一个关键陷阱需要注意。

### ⚠️ 问题现象
克隆出来的新机器可能会出现：
- SSH 连接不上。
- 网络 Ping 不通。
- 通过 OCI 控制台的 **“Cloud Shell 连接”** 查看，发现网卡配置了两个 IP（**旧机器的 IP** 和 **新分配到的 IP**）。
- 路由表指向了**旧 IP**，导致网络包发不出去或被防火墙拦截。

### 🔍 原因分析
问题根源通常在于原系统的网络配置（如 Ubuntu 的 Netplan）**写死了旧机器的静态 IP 或 MAC 地址**。当镜像被克隆到新硬件（拥有新 MAC 地址）并分配到新 IP 后，旧的静态配置与新的动态环境冲突，导致网络无法正常初始化。

### 🛠️ 解决方法（利用已安装的救援模式）
当新克隆的机器出现此问题时，无需慌张，直接使用我们内置的救援系统进行修复。

1.  **启动至救援系统**
    通过 OCI 控制台重启新机器，并在启动时迅速从 GRUB 菜单中选择 **🚑 Rescue System (Netboot.xyz ARM)**，然后进入 Alpine Linux 内存救援环境。

2.  **挂载系统盘并安装必要工具**
    ```bash
    # 更新软件源并安装工具
    apk update && apk add util-linux nano
    # 挂载原系统根分区（通常为/dev/sda1，请用lsblk确认）
    mkdir /mnt/sys && mount /dev/sda1 /mnt/sys
    ```

3.  **修改 Netplan 配置，恢复 DHCP**
    ```bash
    # 查看并编辑 Netplan 配置文件（文件名可能略有不同）
    nano /mnt/sys/etc/netplan/20-netcfg.yaml
    ```
    **清洗配置目标**：删除所有 `macaddress`、`addresses` (静态IP)、`routes` 等固定配置项，仅保留启用 DHCP 的基本设置。
    **修改后示例** (`20-netcfg.yaml`)：
    ```yaml
    network:
      version: 2
      ethernets:
        eth0:
          dhcp4: true
          optional: true  # 可添加此项，避免启动时因网络就绪问题而延迟
    ```
    编辑完成后，按 `Ctrl+X`，然后输入 `Y` 保存退出。

4.  **重启验证**
    ```bash
    # 卸载分区并重启
    umount /mnt/sys
    reboot
    ```
    重启后，系统将通过 DHCP 自动获取新 IP，网络连接应恢复正常。

### 💡 进阶技巧：调整 GRUB 菜单倒计时
如果你觉得默认的启动菜单等待时间（5秒）太短或太长，可以直接在系统中修改：

1.  **编辑配置文件**
    ```bash
    # 在正常的系统环境中（非救援模式）执行
    sudo nano /etc/default/grub.d/99-oci-arm.cfg
    ```
2.  **修改超时参数**，例如改为10秒：
    ```bash
    GRUB_TIMEOUT=10
    ```
3.  **更新 GRUB 配置并重启生效**
    ```bash
    sudo update-grub
    sudo reboot
    ```

**祝大家的甲骨文 ARM 实例稳如老狗，永不失联！🚀**
