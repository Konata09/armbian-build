# Thundercomm TurboX EB5U — Qualcomm QRB5165 (SM8250) octa core, 12GB RAM, 128GB UFS
# 板载 2x LAN7430 1GbE + M.2 槽（本机装了 RTL8126 5GbE）, NVMe, CAN, USB Hub
declare -g BOARD_NAME="Thundercomm TurboX EB5U"
declare -g BOARD_VENDOR="thundercomm"
declare -g BOARD_MAINTAINER=""
declare -g INTRODUCED="2026"
declare -g BOARDFAMILY="sm8250"
declare -g KERNEL_TARGET="current,edge"
declare -g KERNEL_TEST_TARGET="current"
declare -g BOOTCONFIG="none"          # 由 Qualcomm ABL 引导，无 u-boot
declare -g EXTRAWIFI="no"
declare -g IMAGE_PARTITION_TABLE="gpt"
declare -g SERIALCON="${SERIALCON:-ttyMSM0}"

# ABL 会把 DTB 从 boot.img 的 kernel 段末尾取走；这里指定要生成哪些 DTB 的引导镜像
# 留空让公共扩展 image-output-abl 跳过 boot.img 生成（它的 DTB 路径与
# sm8250 的包布局不符、加载地址也不对），改由下面的 950 hook 完整接管。
# 扩展仍会做 rootfs.img 的转换，那部分是好用的。
declare -g -a ABL_DTB_LIST=()
declare -g EB5_ABL_DTB="qrb5165-thundercomm-eb5"

# 本机 boot_a 是活动槽（生产系统也在 A 槽）。
# 注意：QTI 的槽位切换不是 Android 标准，除 `fastboot set_active` 外不要用别的方式切槽。
# 注意：家族配置 config/sources/families/sm8250.conf 在板级配置之后被 source，
# 其中无条件写死 BOOTENV_FILE="qcom-abl.txt"（对应 boot_b），会覆盖这里的赋值。
# 因此必须用 post_family_config 钩子在家族配置之后再设置一次。
declare -g BOOTENV_FILE="qcom-abl-slot-a.txt"

function post_family_config__thundercomm_eb5_bootenv() {
	declare -g BOOTENV_FILE="qcom-abl-slot-a.txt"
	display_alert "${BOARD}" "boot slot: A (boot_a)" "info"

	# 内核配置同样是家族级共享的：LINUXCONFIG 默认解析成 linux-sm8250-current，
	# 那份配置由 5 块 sm8250 板共用。EB5 需要 LAN743X 等板载器件的驱动，
	# 直接改共享配置会波及其它板（实测会误删蓝牙/ath9k/rfkill 等）。
	# 这里改指向板级专属配置 config/kernel/linux-sm8250-eb5-current.config。
	declare -g LINUXCONFIG="linux-sm8250-eb5-current"
	display_alert "${BOARD}" "kernel config: ${LINUXCONFIG}" "info"
}

# clk_ignore_unused / pd_ignore_unused：主线对 SM8250 的时钟/电源域引用计数不完整，
#   不加会在启动早期关掉仍在用的时钟
# pcie_pme=nomsi：SM8250 的 PCIe PME 走 MSI 有问题
# earlycon 地址 0xa90000 = uart12(ttyMSM0)，与厂商一致
declare -g BOOTIMG_CMDLINE_EXTRA="clk_ignore_unused pd_ignore_unused loglevel=7 audit=0 allow_mismatched_32bit_el0 mem_sleep_default=s2idle earlycon=qcom_geni,0xa90000 console=ttyMSM0,115200n8 pcie_pme=nomsi"

# QCA6390 WiFi/BT 的固件在 armbian-firmware-full 里。
# 如果确定不用无线，可以去掉这行以缩小镜像。
# declare -g BOARD_FIRMWARE_INSTALL="-full"

declare -g PACKAGE_LIST_BOARD="pciutils ethtool nvme-cli"

#
# 内核配置
# ---------
# 这块板用的是 config/kernel/linux-sm8250-eb5-current.config，
# 由上面 post_family_config 钩子里的 LINUXCONFIG 指定，与其它 4 块 sm8250 板隔离。
# 板级配置里不做 custom_kernel_config 干预，改配置请直接 menuconfig：
#
#   ./compile.sh BOARD=thundercomm-eb5 BRANCH=current RELEASE=trixie KERNEL_CONFIGURE=yes
#
# 退出 menuconfig 后框架会 savedefconfig 并写回上面那个板级配置文件。
#
# ⚠️ KERNEL_CONFIGURE=yes 有个坑：这种模式下内核 deb 文件名里的配置哈希段是
#    固定占位符 C999999，不是真实哈希 —— 也就是说每次交互式定制产出的 deb 都同名。
#    output/debs/ 里若已有同名旧包，新包不会覆盖它，装进 rootfs 的会是旧内核。
#    症状是：menuconfig 里明明开了某个驱动、构建日志里也能看到它被编译，
#    但最终镜像里没有。定制完成后建议：
#      rm -f output/debs/*C999999*.deb
#      ./compile.sh ... KERNEL_CONFIGURE=no      # 此时哈希是真实值，不会重名
#
# ⚠️ QCOM_Q6V5_PAS / QCOM_Q6V5_MSS 必须保持关闭。
#    打开后内核会把 ADSP/CDSP/SLPI 拉起来，关机时 glink-edge/fastrpc 的 udev
#    事件处理会卡死，且 PSCI SYSTEM_RESET 挂住 —— 表现为 systemd 打完
#    "Rebooting." 之后再无输出、机器不复位，只能断电。
#
#
# 完整接管 ABL boot.img 的生成。
#
# 公共扩展 image-output-abl 有两个与本板不符的地方：
#   1. 它从 ${rootfs}/usr/lib/linux-image-*/qcom/ 取 DTB，
#      而 sm8250 的 linux-dtb 包把 DTB 装在 /boot/dtb-<ver>/qcom/
#   2. 它用 `--base 0x0`，算出 kernel_addr=0x8000；
#      而本机 ABL 需要 0x80008000（与原厂 boot_a 镜像逐字段一致，实测可引导）
#
# 与其打补丁，不如在它之后（900 < 950）用正确的素材和地址重造一遍。
#
function post_build_image__950_thundercomm_eb5_rebuild_bootimg() {
	[[ -n "$UEFI_GRUB_TARGET" ]] && return 0
	[[ -n "$BOOTFS_TYPE" ]] && return 0
	[[ -z "${EB5_ABL_DTB}" ]] && return 0
	[[ -z "${version}" ]] && exit_with_error "version is not set"
	[[ -z "${ROOTFS_IMAGE_FILE}" || ! -f "${ROOTFS_IMAGE_FILE}" ]] && {
		display_alert "No rootfs image, skipping boot.img rebuild" "${BOARD}" "wrn"
		return 0
	}

	display_alert "Rebuilding ABL boot image" "${BOARD}: correct DTB path + ABL load addresses" "info"

	declare workdir="${DESTIMG}/eb5-bootimg"
	declare mnt="${workdir}/mnt"
	declare img="${DESTIMG}/${version}.boot_${EB5_ABL_DTB}.img"

	run_host_command_logged mkdir -pv "${mnt}"
	run_host_command_logged mount -o ro "${ROOTFS_IMAGE_FILE}" "${mnt}"

	# 取素材（sm8250 的 DTB 在 /boot/dtb-<ver>/qcom/，不是扩展假设的 /usr/lib/linux-image-*）
	declare vmlinuz initrd kver dtb uuid
	vmlinuz="$(ls "${mnt}"/boot/vmlinuz-*-* 2> /dev/null | head -1)"
	initrd="$(ls "${mnt}"/boot/initrd.img-*-* 2> /dev/null | head -1)"
	if [[ ! -f "${vmlinuz}" || ! -f "${initrd}" ]]; then
		run_host_command_logged umount "${mnt}" || true
		exit_with_error "kernel or initrd not found in rootfs image"
	fi
	kver="$(basename "${vmlinuz}")"; kver="${kver#vmlinuz-}"
	dtb="${mnt}/boot/dtb-${kver}/qcom/${EB5_ABL_DTB}.dtb"
	[[ -f "${dtb}" ]] || dtb="${mnt}/boot/dtb/qcom/${EB5_ABL_DTB}.dtb"
	if [[ ! -f "${dtb}" ]]; then
		run_host_command_logged umount "${mnt}" || true
		exit_with_error "DTB ${EB5_ABL_DTB}.dtb not found in rootfs image"
	fi
	uuid="$(blkid -s UUID -o value "${ROOTFS_IMAGE_FILE}")"
	display_alert "boot.img inputs" "kver=${kver} dtb=$(basename "${dtb}") root=UUID=${uuid}" "info"

	# ABL 从 kernel 段末尾取紧跟其后的 DTB
	run_host_command_logged gzip -9c "${vmlinuz}" ">" "${workdir}/Image.gz"
	run_host_command_logged cat "${workdir}/Image.gz" "${dtb}" ">" "${workdir}/Image.gz-dtb"

	declare cmdline="root=UUID=${uuid} rootwait rw ${BOOTIMG_CMDLINE_EXTRA}"

	# 不用容器里的 /usr/bin/mkbootimg —— 它缺 gki 模块，一跑就
	# ModuleNotFoundError: No module named 'gki'（公共扩展也栽在这上面）。
	# boot_img_hdr_v0 结构很简单，这里直接生成，顺便把本机 ABL 需要的
	# 加载地址一次写对（kernel 0x80008000 / ramdisk 0x81208000 /
	# second 0x80f00000 / tags 0x80000100，与原厂 boot_a 逐字段一致）。
	cat > "${workdir}/mkboot.py" <<- 'EB5_MKBOOT'
		import hashlib, struct, sys

		kernel_path, ramdisk_path, cmdline, out_path = sys.argv[1:5]
		PAGE = 4096
		kernel = open(kernel_path, 'rb').read()
		ramdisk = open(ramdisk_path, 'rb').read()
		second = b''

		cmd = cmdline.encode()
		if len(cmd) > 1535:
		    sys.exit('cmdline too long: %d bytes' % len(cmd))

		hdr = bytearray(PAGE)
		hdr[0:8] = b'ANDROID!'
		struct.pack_into('<8I', hdr, 8,
		                 len(kernel),  0x80008000,   # kernel size / addr
		                 len(ramdisk), 0x81208000,   # ramdisk size / addr
		                 len(second),  0x80f00000,   # second size / addr
		                 0x80000100,   PAGE)         # tags addr / page size
		struct.pack_into('<I', hdr, 40, 0)           # header_version = 0
		struct.pack_into('<I', hdr, 44, 0)           # os_version
		hdr[64:64 + min(len(cmd), 512)] = cmd[:512]  # cmdline
		if len(cmd) > 512:
		    hdr[608:608 + (len(cmd) - 512)] = cmd[512:]   # extra_cmdline

		sha = hashlib.sha1()
		for blob in (kernel, ramdisk, second):
		    sha.update(blob)
		    sha.update(struct.pack('<I', len(blob)))
		hdr[576:596] = sha.digest()

		def pad(b):
		    r = len(b) % PAGE
		    return b + (b'\0' * (PAGE - r) if r else b'')

		with open(out_path, 'wb') as f:
		    f.write(bytes(hdr) + pad(kernel) + pad(ramdisk) + (pad(second) if second else b''))
		print('wrote %s: kernel=%d ramdisk=%d' % (out_path, len(kernel), len(ramdisk)))
	EB5_MKBOOT

	run_host_command_logged python3 "${workdir}/mkboot.py" \
		"${workdir}/Image.gz-dtb" "${initrd}" "'${cmdline}'" "${img}"

	run_host_command_logged umount "${mnt}" || true
	run_host_command_logged rm -rf "${workdir}"

	# 校验：mkbootimg 有时会静默失败，务必确认真的产出了镜像
	if [[ ! -f "${img}" ]]; then
		exit_with_error "mkbootimg produced no output at ${img}"
	fi
	declare -i sz
	sz="$(stat -c%s "${img}")"
	if [[ ${sz} -lt 1048576 ]]; then
		exit_with_error "boot image too small (${sz} bytes), mkbootimg likely failed"
	fi
	if [[ "$(dd if="${img}" bs=8 count=1 status=none)" != "ANDROID!" ]]; then
		exit_with_error "boot image has no ANDROID! magic"
	fi

	# 这个 boot 镜像是本钩子重造的，Armbian 之前算的 .sha 已经对不上了，重算一遍。
	if [[ -f "${img}.sha" ]]; then
		(cd "$(dirname "${img}")" && sha256sum "$(basename "${img}")" > "$(basename "${img}").sha")
	fi
	display_alert "ABL boot image ready" "$(basename "${img}") (${sz} bytes)" "info"
	return 0
}

#
# LAN7430 网口 LED。
# 主线 lan743x 驱动没有任何 LED 初始化代码，芯片复位后 PHY 的 LED 输出
# 不与封装引脚相连，网口灯全灭。依据 Microchip 知识库 000011849，
# 需要置 HW_CFG(CSR 0x010) 的 LED0..3_EN(bit23:20)；本板未贴 EEPROM，
# 还要置 EEP_GPIO_LED_PIN_DIS(bit2) 阻止 EEPROM 控制器抢占这些引脚。
#
function post_family_tweaks_bsp__thundercomm_eb5_lan7430_led() {
	display_alert "Adding to bsp-cli" "${BOARD}: LAN7430 LED enable" "info"

	declare file_added_to_bsp_destination
	add_file_from_stdin_to_bsp_destination "/usr/local/sbin/lan7430-led-enable" <<- 'LED_SCRIPT'
		#!/usr/bin/env python3
		"""LAN7430 网口 LED 使能（主线 lan743x 驱动没有 LED 初始化代码）"""
		import mmap, os, struct, sys, glob

		HW_CFG               = 0x010
		LED_EN_ALL           = 0x00F00000   # bit23..20 = LED3..LED0 enable
		EEP_GPIO_LED_PIN_DIS = 1 << 2       # 本板无 EEPROM，须置位释放引脚

		def enable(bdf):
		    fd = os.open('/sys/bus/pci/devices/%s/resource0' % bdf, os.O_RDWR | os.O_SYNC)
		    try:
		        m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
		    finally:
		        os.close(fd)
		    old = struct.unpack_from('<I', m, HW_CFG)[0]
		    new = old | LED_EN_ALL | EEP_GPIO_LED_PIN_DIS
		    struct.pack_into('<I', m, HW_CFG, new)
		    m.flush()
		    return struct.unpack_from('<I', m, HW_CFG)[0] == new

		def find_all():
		    out = []
		    for d in glob.glob('/sys/bus/pci/devices/*'):
		        try:
		            if (open(d + '/vendor').read().strip() == '0x1055' and
		                    open(d + '/device').read().strip() == '0x7430'):
		                out.append(os.path.basename(d))
		        except OSError:
		            pass
		    return sorted(out)

		if __name__ == '__main__':
		    targets = [a for a in sys.argv[1:] if not a.startswith('-')] or find_all()
		    sys.exit(0 if all(enable(b) for b in targets) else 1)
	LED_SCRIPT
	run_host_command_logged chmod -v +x "${file_added_to_bsp_destination}"

	# 用 bind 而非 add：驱动 probe 里会做软复位(SRST)清空 HW_CFG，必须等 probe 完成后再写
	add_file_from_stdin_to_bsp_destination "/etc/udev/rules.d/70-eb5-lan7430-led.rules" <<- 'LED_RULE'
		ACTION=="bind", SUBSYSTEM=="pci", DRIVER=="lan743x", ATTR{vendor}=="0x1055", ATTR{device}=="0x7430", RUN+="/usr/local/sbin/lan7430-led-enable %k"
	LED_RULE
}


function post_family_tweaks__thundercomm_eb5_enable_services() {
	display_alert "$BOARD" "Enable services" "info"
	chroot_sdcard systemctl enable eb5-pcie-coldboot.service
	# 没有驱动支持挂起
	chroot_sdcard systemctl mask suspend.target
	return 0
}
