# Rockchip RK3568 quad core 4GB LPDDR4X 32GB eMMC GBE HDMI USB3 5x UART industrial box ("RK35-3500 hdmi")
BOARD_NAME="RK3568 Lite Box"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER=""
BOOT_SOC="rk3568"
BOOTCONFIG="generic-rk3568_defconfig"
# vendor-next is the Rockchip 6.12 BSP: the newest kernel that still has the MPP video codecs
# (rkvdec2/rkvenc/vepu/vdpu/jpeg/iep/rga). Mainline (current/edge) can decode through V4L2 stateless,
# but has no H.264/H.265 hardware encoder for the RK3568.
KERNEL_TARGET="vendor-next"
KERNEL_TEST_TARGET="vendor-next"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3568-rk35-3500.dtb"
BOOT_SCENARIO="binman"
IMAGE_PARTITION_TABLE="gpt"
# UART2 is owned by the FIQ debugger on the BSP kernel
SERIALCON="ttyFIQ0:1500000"

# Mainline U-Boot (generic RK3568 target: eMMC/SD boot, DDR init and BL31 from rkbin) instead of the Radxa BSP U-Boot
function post_family_config__rk35_3500_use_mainline_uboot() {
	display_alert "$BOARD" "Using mainline U-Boot for $BOARD / $BRANCH" "info"

	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.10"
	declare -g BOOTPATCHDIR="v2026.10"
	declare -g BOOTDELAY=1
	# serialcon=ttyFIQ0; the family default (rk35xx.txt) would put the console on ttyS2, which is UART3 here
	declare -g BOOTENV_FILE="rk35-3500.txt"
}

# Kernel configuration of this board, on top of linux-rk35xx-vendor-next.config:
#  - LED class drivers and the commonly used triggers
#  - no self-protection/hardening features and nothing else that costs performance
function custom_kernel_config__rk35_3500() {
	display_alert "$BOARD" "LED triggers on, hardening off" "info"

	# LED core and drivers
	opts_y+=("NEW_LEDS" "LEDS_CLASS" "LEDS_TRIGGERS" "LEDS_GPIO" "LEDS_PWM")
	opts_m+=("LEDS_CLASS_MULTICOLOR" "LEDS_USER")
	# LED triggers
	opts_y+=("LEDS_TRIGGER_TIMER" "LEDS_TRIGGER_ONESHOT" "LEDS_TRIGGER_HEARTBEAT" "LEDS_TRIGGER_DEFAULT_ON"
		"LEDS_TRIGGER_ACTIVITY" "LEDS_TRIGGER_CPU" "LEDS_TRIGGER_DISK" "LEDS_TRIGGER_MTD" "LEDS_TRIGGER_GPIO"
		"LEDS_TRIGGER_NETDEV" "LEDS_TRIGGER_TTY" "LEDS_TRIGGER_PANIC" "LEDS_TRIGGER_TRANSIENT"
		"LEDS_TRIGGER_PATTERN" "LEDS_TRIGGER_BACKLIGHT" "LEDS_TRIGGER_CAMERA" "LEDS_TRIGGER_INPUT_EVENTS")
	# triggers that live in other subsystems (mmc0/mmc1 come with LEDS_TRIGGERS itself)
	opts_y+=("LED_TRIGGER_PHY" "USB_LED_TRIG" "USB_LEDS_TRIGGER_USBPORT" "INPUT_LEDS")

	# 4G modem slot: some LTE modules enumerate as RNDIS (the vendor kernel had this driver too)
	opts_m+=("USB_NET_RNDIS_HOST")

	# Build for speed: the Armbian vendor config uses -Os
	kernel_config_force_n "CC_OPTIMIZE_FOR_SIZE"
	opts_y+=("CC_OPTIMIZE_FOR_PERFORMANCE")

	# KASLR. On the Cortex-A55 it also forces KPTI (kernel unmapped at EL0) on every syscall and interrupt.
	kernel_config_force_n "RANDOMIZE_BASE" "RANDOMIZE_MODULE_REGION_FULL"
	# Speculation mitigations and software PAN (the A55 has hardware PAN and is not affected by Meltdown/BHB)
	kernel_config_force_n "UNMAP_KERNEL_AT_EL0" "MITIGATE_SPECTRE_BRANCH_HISTORY" "ARM64_SW_TTBR0_PAN"
	# Pointer authentication / BTI instrumentation of the kernel (ARMv8.3/8.5, not present in this SoC)
	kernel_config_force_n "ARM64_PTR_AUTH_KERNEL" "ARM64_BTI_KERNEL"
	# rodata=full maps the whole linear region with 4K pages; without it block mappings are used
	kernel_config_force_n "RODATA_FULL_DEFAULT_ENABLED"
	# Compiler based hardening
	kernel_config_force_n "STACKPROTECTOR" "STACKPROTECTOR_STRONG" "STACKPROTECTOR_PER_TASK"
	kernel_config_force_n "FORTIFY_SOURCE" "ZERO_CALL_USED_REGS" "UBSAN"
	kernel_config_force_n "INIT_STACK_ALL_ZERO" "INIT_STACK_ALL_PATTERN"
	opts_y+=("INIT_STACK_NONE")
	# Heap and usercopy hardening
	kernel_config_force_n "HARDENED_USERCOPY" "INIT_ON_ALLOC_DEFAULT_ON" "INIT_ON_FREE_DEFAULT_ON"
	kernel_config_force_n "SLAB_FREELIST_RANDOM" "SLAB_FREELIST_HARDENED" "SLAB_BUCKETS" "RANDOM_KMALLOC_CACHES"
	kernel_config_force_n "SHUFFLE_PAGE_ALLOCATOR" "PAGE_POISONING" "PAGE_TABLE_CHECK"
	# Run-time sanity checks
	kernel_config_force_n "LIST_HARDENED" "DEBUG_LIST" "BUG_ON_DATA_CORRUPTION" "SCHED_STACK_END_CHECK" "KFENCE"
}

# udev rules: /dev/mpp_service, /dev/rga and the dma-heaps for the video group
function post_family_tweaks_bsp__rk35_3500_media_rules() {
	: "${destination:?}"
	install -d "${destination}/etc/udev/rules.d"
	install -m 644 "${SRC}/packages/bsp/rockchip/60-media.rules" "${destination}/etc/udev/rules.d/"
}

# The device tree only exists in this userpatches tree. Never let a stock rk35xx kernel/dtb/u-boot
# package from the Armbian repository replace the ones of this image.
function post_family_tweaks__rk35_3500_hold_kernel_packages() {
	display_alert "$BOARD" "Holding kernel, dtb and u-boot packages" "info"
	chroot_sdcard apt-mark hold "linux-image-${BRANCH}-${LINUXFAMILY}" "linux-dtb-${BRANCH}-${LINUXFAMILY}" "linux-u-boot-${BOARD}-${BRANCH}"
}
