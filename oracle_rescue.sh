#!/bin/bash

# ==========================================================
# 🚑 OCI Rescue Kit - 甲骨文云救火队一键部署工具
# 功能：交互式分区 / 部署 Netboot.xyz / 跨架构 Chroot 修复
# ==========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 Root
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 sudo 运行!${NC}"; exit 1; fi

# =========================
# 1. 交互式分区模块
# =========================
do_partition() {
    clear
    echo -e "${BLUE}=== 🛠️  磁盘分区向导 ===${NC}"
    
    # 列出磁盘供参考
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v "loop"
    echo ""
    
    echo -e "${YELLOW}请确认挂载过来的目标磁盘名称 (例如 sdb)${NC}"
    read -p "目标磁盘 (不带/dev/): " DISK_NAME
    TARGET_DISK="/dev/$DISK_NAME"
    
    if [ ! -b "$TARGET_DISK" ]; then echo -e "${RED}磁盘不存在!${NC}"; return; fi

    echo -e "\n${YELLOW}请确认该磁盘上的【系统分区】编号 (通常是容量最大的那个)${NC}"
    echo -e "例如: sdb1 或 sdb2 (请看上面的 lsblk 输出)"
    read -p "系统分区 (例如 1): " PART_NUM
    TARGET_PART="${TARGET_DISK}${PART_NUM}"

    echo -e "\n${YELLOW}请输入系统盘保留大小 (例如 15G)${NC}"
    read -p "系统盘大小: " SYS_SIZE
    
    echo -e "\n${YELLOW}请输入救援盘大小 (默认 200M)${NC}"
    read -p "救援盘大小 [200M]: " RESCUE_SIZE
    RESCUE_SIZE=${RESCUE_SIZE:-200M}

    echo -e "\n${RED}⚠️  即将对 $TARGET_DISK 进行操作：${NC}"
    echo -e "1. 缩小 $TARGET_PART 到 $SYS_SIZE"
    echo -e "2. 删除原分区并重建 (保留数据)"
    echo -e "3. 创建救援分区 ($RESCUE_SIZE) 和数据分区"
    read -p "确认继续吗? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then return; fi

    # 1. 检测并缩容文件系统
    echo -e "${CYAN}正在检查文件系统...${NC}"
    e2fsck -f "$TARGET_PART"
    
    echo -e "${CYAN}正在缩小文件系统...${NC}"
    resize2fs "$TARGET_PART" "$SYS_SIZE"
    if [ $? -ne 0 ]; then echo -e "${RED}缩容失败!${NC}"; return; fi

    # 2. fdisk 操作 (自动计算分区号)
    # 假设系统分区是 1，那么救援是 2，数据是 3
    # 注意：这里需要处理 fdisk 的交互，使用 EOF 可能因版本差异失败，改用 parted 可能更稳，
    # 但为了保持教程一致性，这里用 carefully crafted fdisk input
    
    echo -e "${CYAN}正在修改分区表...${NC}"
    
    # 逻辑：删除原分区 -> 新建系统分区(保留签名) -> 新建救援 -> 新建数据
    # 下面的 N 是关键，拒绝移除 Ext4 签名
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk "$TARGET_DISK"
d
$PART_NUM
n
$PART_NUM

+$SYS_SIZE
N
n
2

+$RESCUE_SIZE
n
3


w
EOF

    echo -e "${CYAN}刷新分区大小...${NC}"
    resize2fs "$TARGET_PART"
    
    echo -e "${CYAN}格式化新分区...${NC}"
    mkfs.ext4 "${TARGET_DISK}2" -L RESCUE
    mkfs.btrfs "${TARGET_DISK}3" -L DATA

    echo -e "${GREEN}✅ 分区操作完成!${NC}"
    lsblk "$TARGET_DISK"
    read -p "按回车继续..."
}

# =========================
# 2. 部署救火队模块
# =========================
do_deploy() {
    echo -e "${BLUE}=== 📥 部署 Netboot.xyz (ARM) ===${NC}"
    
    read -p "请输入救援分区设备 (例如 /dev/sdb2): " RESCUE_DEV
    if [ ! -b "$RESCUE_DEV" ]; then echo "设备不存在"; return; fi

    mkdir -p /mnt/rescue
    mount "$RESCUE_DEV" /mnt/rescue
    
    echo "下载 EFI 文件..."
    wget -O /mnt/rescue/netboot.xyz-arm64.efi https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi
    
    # 获取 UUID
    R_UUID=$(blkid -s UUID -o value "$RESCUE_DEV")
    echo -e "救援盘 UUID: ${GREEN}$R_UUID${NC}"
    
    # 保存 UUID 供下一步用
    export SAVED_UUID="$R_UUID"
    
    umount /mnt/rescue
    echo -e "${GREEN}✅ 部署完成!${NC}"
    read -p "按回车继续..."
}

# =========================
# 3. 配置 Grub (含 QEMU)
# =========================
do_grub() {
    echo -e "${BLUE}=== ⚙️  配置 GRUB & 修复引导 ===${NC}"
    
    read -p "请输入系统分区设备 (例如 /dev/sdb1): " SYS_DEV
    if [ ! -b "$SYS_DEV" ]; then echo "设备不存在"; return; fi
    
    UUID=${SAVED_UUID}
    if [ -z "$UUID" ]; then
        read -p "请输入救援分区的 UUID: " UUID
    fi

    echo -e "${CYAN}正在挂载系统...${NC}"
    mkdir -p /mnt/sys_root
    mount "$SYS_DEV" /mnt/sys_root
    
    # 写入 40_custom
    cat <<EOF >> /mnt/sys_root/etc/grub.d/40_custom

menuentry "🚑 Rescue System (Netboot.xyz ARM)" {
    insmod part_gpt
    insmod ext2
    insmod chain
    search --no-floppy --fs-uuid --set=root $UUID
    chainloader /netboot.xyz-arm64.efi
}
EOF

    # 写入 99-oci-arm.cfg (5秒倒计时)
    cat <<EOF > /mnt/sys_root/etc/default/grub.d/99-oci-arm.cfg
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
EOF

    # === 跨架构处理核心 ===
    # 检测当前机器架构
    HOST_ARCH=$(uname -m)
    # 检测目标磁盘架构 (简单判断：看有没有 ld-linux-aarch64)
    if [ -f "/mnt/sys_root/lib/ld-linux-aarch64.so.1" ] && [ "$HOST_ARCH" == "x86_64" ]; then
        echo -e "${YELLOW}[检测到跨架构] 宿主机: x86_64 -> 目标机: ARM64${NC}"
        echo -e "${CYAN}正在安装 QEMU 模拟器...${NC}"
        
        # 安装依赖
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq qemu-user-static binfmt-support
        fi
        
        # 复制 qemu 到目标盘
        if [ -f "/usr/bin/qemu-aarch64-static" ]; then
            cp /usr/bin/qemu-aarch64-static /mnt/sys_root/usr/bin/
        else
            echo -e "${RED}错误：未找到 qemu-aarch64-static，chroot 可能会失败！${NC}"
        fi
    fi

    # 挂载虚拟文件系统
    mount --bind /dev /mnt/sys_root/dev
    mount --bind /proc /mnt/sys_root/proc
    mount --bind /sys /mnt/sys_root/sys

    echo -e "${CYAN}进入系统更新 Grub...${NC}"
    chroot /mnt/sys_root update-grub
    
    # 清理
    umount -R /mnt/sys_root
    
    echo -e "${GREEN}✅ GRUB 配置完成！${NC}"
    read -p "按回车返回..."
}

# 主菜单
while true; do
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    🚑 OCI Rescue Kit (ARM版)           ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 🛠️  第一步：交互式分区 (15G系统 + 200M救援)"
    echo "2) 📥 第二步：下载 Netboot.xyz 镜像"
    echo "3) ⚙️  第三步：配置 GRUB (含 QEMU 修复)"
    echo "q) 退出"
    echo ""
    read -p "请输入步骤 [1-3]: " choice
    case $choice in
        1) do_partition ;;
        2) do_deploy ;;
        3) do_grub ;;
        q) exit 0 ;;
    esac
done
