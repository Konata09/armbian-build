# Rockchip RK3399 hexa core 4GB LPDDR4 16GB eMMC GbE 2nd-LAN(SR9900) 4xUART(CH9344) USB3/Type-C WiFi/BT
BOARD_NAME="Lenovo ECG-AR70P"
BOARD_VENDOR="lenovo"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER=""
INTRODUCED="2020"
BOOT_SOC="rk3399"
BOOTCONFIG="lenovo-ecg-ar70p-rk3399_defconfig"
# vendor-next is the Rockchip 6.12 BSP: the newest kernel that provides full RK3399 hardware video
# encode & decode (MPP vepu2 H.264/VP8/JPEG encode + vdpu2/rkvdec 4K H.264/HEVC/VP9 decode + IEP + RGA2).
KERNEL_TARGET="vendor-next"
KERNEL_TEST_TARGET="vendor-next"
FULL_DESKTOP="no"
BOOT_LOGO="no"
BOOT_FDT_FILE="rockchip/rk3399-lenovo-ecg-ar70p.dtb"
BOOT_SCENARIO="binman"
DDR_BLOB="rk33/rk3399_ddr_933MHz_v1.30.bin"
BL31_BLOB="rk33/rk3399_bl31_v1.36.elf"
IMAGE_PARTITION_TABLE="gpt"
SERIALCON="ttyS2"
CPUMAX="2208000"

# Mainline U-Boot v2026.10 + proprietary Rockchip DDR TPL v1.30 (safe 856 MHz boot, pre-trains up to
# 928 MHz) + proprietary Rockchip BL31 v1.36 (required for reliable RK3399 LPDDR4 runtime DFS).
function post_family_config__lenovo_ecg_ar70p_uboot() {
	display_alert "$BOARD" "Using mainline U-Boot v2026.10 + Rockchip rkbin DDR v1.30 & BL31 v1.36 for $BOARD / $BRANCH" "info"
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.10"
	declare -g BOOTPATCHDIR="v2026.10"
	declare -g BOOTDELAY=1
	declare -g BOOTENV_FILE="lenovo-ecg-ar70p.txt"
}

# LPDDR4-2400 (1200 MHz) runtime DDR overclock via minimal binary patch to Rockchip BL31 v1.36.
# The board has 4 GB Samsung K4F6E3S4HM-MGCJ (LPDDR4-3733 / 1866 MHz rated). TPL always boots safely
# at 856 MHz and pre-trains PHY slots [416, 856, 328, 666, 928] MHz; Linux rockchip-dmc then scales
# up to 1200 MHz (vdd_center 1.00 V, JEDEC >1066 MHz MR1=0x44/MR2=0x24 RL=24/WL=12).
# Verified with >1 TB stressapptest (-s 180 -M 2048 -W: 5585 MB/s, 0 errors, 60 C peak) + memtester 512M.
# Set LENOVO_ECG_AR70P_DDR_OC=no to build with unmodified stock BL31 (928 MHz max).
declare -g LENOVO_ECG_AR70P_DDR_OC="${LENOVO_ECG_AR70P_DDR_OC:-yes}"

function post_family_config__lenovo_ecg_ar70p_ddr_oc_bl31() {
	[[ "${LENOVO_ECG_AR70P_DDR_OC}" != "yes" ]] && return 0
	declare -g LENOVO_ECG_AR70P_BL31_OC="${SRC}/cache/lenovo-ecg-ar70p/$(basename "${BL31_BLOB}" .elf)-lpddr4-2400.elf"
	declare stock="${RKBIN_DIR}/${BL31_BLOB}"
	[[ "${UBOOT_TARGET_MAP}" == *"BL31=${stock} "* ]] ||
		exit_with_error "${BOARD}: BL31=${stock} not found in UBOOT_TARGET_MAP" "${UBOOT_TARGET_MAP}"
	declare -g UBOOT_TARGET_MAP="${UBOOT_TARGET_MAP//"BL31=${stock} "/"BL31=${LENOVO_ECG_AR70P_BL31_OC} "}"
}

function pre_config_uboot_target__lenovo_ecg_ar70p_ddr_oc_bl31() {
	[[ "${LENOVO_ECG_AR70P_DDR_OC}" != "yes" ]] && return 0
	declare src="${RKBIN_DIR}/${BL31_BLOB}" dst="${LENOVO_ECG_AR70P_BL31_OC}"
	mkdir -p "$(dirname "${dst}")"
	python3 - "${src}" "${dst}" <<-'PY'
		import hashlib, struct, sys

		src, dst = sys.argv[1], sys.argv[2]
		data = bytearray(open(src, "rb").read())

		# Verify exact upstream blob before patching (rk3399_bl31_v1.36.elf)
		orig_sha = hashlib.sha256(data).hexdigest()
		assert orig_sha == "3be6cdf32462d7f676d109bb2a97af9a1f469f058674ef0a5cb20941af2923d5", (
		    f"Unexpected BL31 sha256: {orig_sha}"
		)

		# 1) Replace 13-row descending dpll_rates_table at file offset 0x41cc8 (stride 0x1c):
		#    struct dpll_rate { u32 mhz, refdiv, fbdiv, postdiv1, postdiv2, dsmpd, frac; }
		base = 0x41CC8
		orig_mhz = [struct.unpack_from("<I", data, base + i * 0x1C)[0] for i in range(13)]
		assert orig_mhz == [1056, 928, 856, 800, 732, 666, 600, 528, 416, 400, 328, 300, 200], (
		    f"Unexpected dpll_rates_table: {orig_mhz}"
		)
		new_table = [
		    (1200, 1, 100, 2, 1, 0, 0),
		    (1152, 1,  96, 2, 1, 0, 0),
		    (1104, 1,  92, 2, 1, 0, 0),
		    (1056, 1,  88, 2, 1, 0, 0),
		    ( 928, 1, 116, 3, 1, 0, 0),
		    ( 856, 1, 107, 3, 1, 0, 0),
		    ( 666, 1, 111, 4, 1, 0, 0),
		    ( 528, 1,  66, 3, 1, 0, 0),
		    ( 416, 1,  52, 3, 1, 0, 0),
		    ( 400, 1,  50, 3, 1, 0, 0),
		    ( 328, 1,  82, 3, 2, 0, 0),
		    ( 300, 1, 100, 4, 2, 0, 0),
		    ( 200, 1, 100, 6, 2, 0, 0),
		]
		for i, row in enumerate(new_table):
		    struct.pack_into("<7I", data, base + i * 0x1C, *row)

		# 2) VA 0x4b3d8 (file 0x1b3d8): bypass >max_trained_mhz error return so BL31 computes native
		#    JEDEC timings (MR1=0x44/MR2=0x24 RL=24/WL=12 for >1066 MHz) instead of clamping/failing.
		assert struct.unpack_from("<I", data, 0x1B3D8)[0] == 0x528001E0  # mov w0, #0xf
		struct.pack_into("<I", data, 0x1B3D8, 0x14000002)               # b 0x4b3e0

		# 3) VA 0xff8c3830..0xff8c3834 (file 0x53830): SRAM PHY snapshot lookup fallback to highest
		#    pre-trained slot (slot 4 = 928 MHz) when target frequency exceeds 928 MHz.
		assert struct.unpack_from("<2I", data, 0x53830) == (0x12800000, 0x14000032)
		struct.pack_into("<2I", data, 0x53830, 0xD1172294, 0x17FFFFF6)  # sub x20, x20, #0x5c8; b 0xff8c380c

		new_sha = hashlib.sha256(data).hexdigest()
		assert new_sha == "e3cff51c0e8b08f3683ee44855768a663858f1aaa8010ce2d0807b1a533dc29e", (
		    f"Unexpected patched BL31 sha256: {new_sha}"
		)
		open(dst, "wb").write(data)
	PY
	display_alert "${BOARD}" "Patched ${BL31_BLOB##*/} for LPDDR4-2400 (1200 MHz) runtime DFS: ${dst##*/}" "info"
}

function post_config_uboot_target__lenovo_ecg_ar70p_features() {
	display_alert "$BOARD" "u-boot: enable external TPL, network boot, storage and debug commands" "info"
	local opt
	for opt in ROCKCHIP_EXTERNAL_TPL \
		CMD_DHCP CMD_PING CMD_PXE CMD_TFTPBOOT CMD_NFS CMD_WGET CMD_DNS \
		ROCKCHIP_EFUSE MISC_INIT_R CMD_NVME CMD_SCSI CMD_EXT4_WRITE FAT_WRITE \
		CMD_GPIO CMD_I2C CMD_PMIC CMD_REGULATOR CMD_POWEROFF \
		DM_RNG RNG_ROCKCHIP CMD_RNG CMD_KASLRSEED CMD_HASH CMD_BOOTMENU CMD_EFICONFIG; do
		run_host_command_logged scripts/config --enable "CONFIG_${opt}"
	done
}

# Kernel configuration on top of linux-rk35xx-vendor-next.config:
#  - Headless multimedia: RK3399 MPP video codecs, RGA2, IEP (GPU and display drivers disabled)
#  - Board peripherals: CH9344 quad-UART, SR9900 CDC-Ethernet, Type-C USB3/OTG, ES8316 audio, RK808 PMIC
#  - Common LED class drivers and triggers
#  - Performance optimization (-O2) with CPU mitigations and hardening disabled
function custom_kernel_config__lenovo_ecg_ar70p() {
	display_alert "$BOARD" "Headless MPP codecs + LED triggers on, GPU/display/mitigations/hardening off" "info"

	# Board & headless hardware video codec / 2D acceleration
	opts_y+=("CPU_RK3399" "ROCKCHIP_OPP" "ROCKCHIP_PVTM"
		"MFD_RK808" "REGULATOR_RK808" "COMMON_CLK_RK808" "RTC_DRV_RK808"
		"ROCKCHIP_MPP_SERVICE" "ROCKCHIP_MPP_VEPU2" "ROCKCHIP_MPP_VDPU2" "ROCKCHIP_MPP_RKVDEC"
		"ROCKCHIP_MULTI_RGA" "IEP"
		"TYPEC_FUSB302"
		"SND_SOC_ES8316" "SND_SIMPLE_CARD")
	opts_m+=("USB_NET_CDCETHER" "USB_SERIAL_CH9344")

	# Disable GPU and display drivers (headless appliance)
	kernel_config_force_n "MALI_MIDGARD" "MALI_VALHALL" "DRM_PANFROST" \
		"DRM_ROCKCHIP" "ROCKCHIP_CDN_DP" "ROCKCHIP_DW_HDMI" "DRM_DW_HDMI_I2S_AUDIO"

	# LED core, drivers and common triggers
	opts_y+=("NEW_LEDS" "LEDS_CLASS" "LEDS_TRIGGERS" "LEDS_GPIO" "LEDS_PWM")
	opts_m+=("LEDS_CLASS_MULTICOLOR" "LEDS_USER")
	opts_y+=("LEDS_TRIGGER_TIMER" "LEDS_TRIGGER_ONESHOT" "LEDS_TRIGGER_HEARTBEAT" "LEDS_TRIGGER_DEFAULT_ON"
		"LEDS_TRIGGER_ACTIVITY" "LEDS_TRIGGER_CPU" "LEDS_TRIGGER_DISK" "LEDS_TRIGGER_MTD" "LEDS_TRIGGER_GPIO"
		"LEDS_TRIGGER_NETDEV" "LEDS_TRIGGER_TTY" "LEDS_TRIGGER_PANIC" "LEDS_TRIGGER_TRANSIENT"
		"LEDS_TRIGGER_PATTERN" "LEDS_TRIGGER_BACKLIGHT" "LEDS_TRIGGER_CAMERA" "LEDS_TRIGGER_INPUT_EVENTS")
	opts_y+=("LED_TRIGGER_PHY" "USB_LED_TRIG" "USB_LEDS_TRIGGER_USBPORT" "INPUT_LEDS" "BT_LEDS" "RFKILL_LEDS")

	# Build for speed (-O2) instead of size (-Os)
	kernel_config_force_n "CC_OPTIMIZE_FOR_SIZE"
	opts_y+=("CC_OPTIMIZE_FOR_PERFORMANCE")

	# Disable CPU speculation mitigations, KPTI, KASLR, software PAN, and unsupported ARMv8.3/8.5 PAC/BTI
	kernel_config_force_n "CPU_MITIGATIONS" "UNMAP_KERNEL_AT_EL0" "MITIGATE_SPECTRE_BRANCH_HISTORY" "ARM64_SW_TTBR0_PAN"
	kernel_config_force_n "RANDOMIZE_BASE" "RANDOMIZE_MODULE_REGION_FULL" "RANDOMIZE_KSTACK_OFFSET"
	kernel_config_force_n "ARM64_PTR_AUTH" "ARM64_PTR_AUTH_KERNEL" "ARM64_BTI" "ARM64_BTI_KERNEL"
	# Avoid 4K page splitting of the linear map so large block TLB entries are used
	kernel_config_force_n "RODATA_FULL_DEFAULT_ENABLED"

	# Compiler-based hardening off
	kernel_config_force_n "STACKPROTECTOR" "STACKPROTECTOR_STRONG" "STACKPROTECTOR_PER_TASK"
	kernel_config_force_n "FORTIFY_SOURCE" "ZERO_CALL_USED_REGS" "UBSAN"
	kernel_config_force_n "INIT_STACK_ALL_ZERO" "INIT_STACK_ALL_PATTERN"
	opts_y+=("INIT_STACK_NONE")

	# Heap, page allocator, and usercopy hardening off
	kernel_config_force_n "HARDENED_USERCOPY" "INIT_ON_ALLOC_DEFAULT_ON" "INIT_ON_FREE_DEFAULT_ON"
	kernel_config_force_n "SLAB_FREELIST_RANDOM" "SLAB_FREELIST_HARDENED" "SLAB_BUCKETS" "RANDOM_KMALLOC_CACHES"
	kernel_config_force_n "SHUFFLE_PAGE_ALLOCATOR" "PAGE_POISONING" "PAGE_TABLE_CHECK"

	# Runtime sanity checks & syscall auditing / MAC LSM overhead off
	kernel_config_force_n "LIST_HARDENED" "DEBUG_LIST" "BUG_ON_DATA_CORRUPTION" "SCHED_STACK_END_CHECK" "KFENCE"
	kernel_config_force_n "AUDIT" "AUDITSYSCALL" "SECURITY_SELINUX" "SECURITY_APPARMOR"
}

function post_family_tweaks_bsp__lenovo_ecg_ar70p() {
	: "${destination:?}"
	display_alert "$BOARD" "Installing Rockchip media rules, AP6256 NVRAM and CH9344 udev rules" "info"
	install -d "${destination}/etc/udev/rules.d"
	install -m 644 "${SRC}/packages/bsp/rockchip/60-media.rules" \
		"${destination}/etc/udev/rules.d/60-media.rules"
	install -m 644 "${USERPATCHES_PATH}/packages/bsp/lenovo-ecg-ar70p/60-ch9344-wchusb.rules" \
		"${destination}/etc/udev/rules.d/60-ch9344-wchusb.rules"
	install -d "${destination}/lib/firmware/brcm"
	install -m 644 "${USERPATCHES_PATH}/packages/bsp/lenovo-ecg-ar70p/brcmfmac43456-sdio.lenovo,ecg-ar70p.txt" \
		"${destination}/lib/firmware/brcm/brcmfmac43456-sdio.lenovo,ecg-ar70p.txt"
	install -d "${destination}/etc/modprobe.d"
	install -m 644 "${USERPATCHES_PATH}/packages/bsp/lenovo-ecg-ar70p/blacklist-wifi-bt.conf" \
		"${destination}/etc/modprobe.d/blacklist-wifi-bt.conf"
	install -d "${destination}/etc/systemd/system/serial-getty@ttyS2.service.d"
	cat > "${destination}/etc/systemd/system/serial-getty@ttyS2.service.d/autologin.conf" <<-'AUTOLOGIN'
		[Service]
		ExecStart=
		ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
	AUTOLOGIN
	chmod 644 "${destination}/etc/systemd/system/serial-getty@ttyS2.service.d/autologin.conf"
}

function post_family_tweaks__lenovo_ecg_ar70p_hold_packages() {
	display_alert "$BOARD" "Holding custom kernel, dtb and u-boot packages" "info"
	chroot_sdcard apt-mark hold "linux-image-${BRANCH}-${LINUXFAMILY}" "linux-dtb-${BRANCH}-${LINUXFAMILY}" "linux-u-boot-${BOARD}-${BRANCH}"
}
