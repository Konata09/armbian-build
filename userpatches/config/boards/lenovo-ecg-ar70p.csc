# Rockchip RK3399 hexa core 4GB LPDDR4 16GB eMMC GbE 2nd-LAN(SR9900) 4xUART(CH9344) Type-C/DP HDMI WiFi/BT
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
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3399-lenovo-ecg-ar70p.dtb"
BOOT_SCENARIO="binman-atf-mainline"
DDR_BLOB="rk33/rk3399_ddr_800MHz_v1.27.bin"
IMAGE_PARTITION_TABLE="gpt"
SERIALCON="ttyS2"

# Mainline U-Boot v2026.10 + TF-A lts-v2.14.11 + RK3399 800MHz LPDDR4 TPL instead of Radxa BSP U-Boot
function post_family_config__lenovo_ecg_ar70p_uboot() {
	display_alert "$BOARD" "Using mainline U-Boot v2026.10 + TF-A lts-v2.14.11 for $BOARD / $BRANCH" "info"
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.10"
	declare -g BOOTPATCHDIR="v2026.10"
	declare -g BOOTDELAY=1
	declare -g BOOTENV_FILE="lenovo-ecg-ar70p.txt"

	declare -g ATFSOURCE="https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git"
	declare -g ATFBRANCH="tag:lts-v2.14.11"
	declare -g ATFPATCHDIR="atf-rockchip64/v2.14"
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
#  - RK3399 MPP video codecs, RGA2, IEP, Panfrost GPU, CH9344 quad-UART, SR9900 CDC-Ethernet, Type-C DP
#  - Common LED class drivers and triggers
#  - Performance optimization (-O2) with CPU mitigations and hardening disabled
function custom_kernel_config__lenovo_ecg_ar70p() {
	display_alert "$BOARD" "Enabling RK3399 hardware/codecs + LED triggers, disabling mitigations and hardening" "info"

	# Board & multimedia hardware support
	opts_y+=("CPU_RK3399" "ROCKCHIP_OPP" "ROCKCHIP_PVTM"
		"ROCKCHIP_MPP_SERVICE" "ROCKCHIP_MPP_VEPU2" "ROCKCHIP_MPP_VDPU2" "ROCKCHIP_MPP_RKVDEC"
		"ROCKCHIP_MULTI_RGA" "IEP"
		"TYPEC_FUSB302" "TYPEC_DP_ALTMODE"
		"SND_SOC_ES8316" "SND_SIMPLE_CARD")
	opts_m+=("USB_NET_CDCETHER" "USB_SERIAL_CH9344" "DRM_PANFROST")
	# Use Mesa Panfrost on Mali-T860 instead of vendor Mali kbase (which also enables MALI_DEBUG)
	kernel_config_force_n "MALI_MIDGARD" "MALI_VALHALL"

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
}

function post_family_tweaks__lenovo_ecg_ar70p_hold_packages() {
	display_alert "$BOARD" "Holding custom kernel, dtb and u-boot packages" "info"
	chroot_sdcard apt-mark hold "linux-image-${BRANCH}-${LINUXFAMILY}" "linux-dtb-${BRANCH}-${LINUXFAMILY}" "linux-u-boot-${BOARD}-${BRANCH}"
}
