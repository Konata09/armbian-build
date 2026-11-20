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

# CPU overclock, together with opp-1992000000 at 1.30 V in the board DTS.
# The RK3568 CPU clock belongs to BL31 (SCMI clock 0), which accepts no rate above 1992 MHz. For the
# rates from 1008 MHz up it runs the cores from the PVTPLL ring oscillator, so the real clock follows
# vdd_cpu and the ring length, not the OPP rate. Stock BL31 uses ring length 6 for 1992 MHz: 1.86 GHz
# at the stock 1.15 V on this board. Ring 3 at 1.30 V runs about 2.32 GHz (2.28 GHz hot) and passed
# 10 minutes of stress-ng --verify and stressapptest; ring 2 hangs the board. Only the 1992 MHz row is
# changed; 1800 MHz and below keep the stock rings and voltages.
function post_family_config__rk35_3500_cpu_oc_bl31() {
	declare -g RK35_3500_BL31_OC="${SRC}/cache/rk35-3500/$(basename "${BL31_BLOB}" .elf)-1992mhz-ring3.elf"
	declare stock="${RKBIN_DIR}/${BL31_BLOB}"
	[[ "${UBOOT_TARGET_MAP}" == *"BL31=${stock} "* ]] ||
		exit_with_error "${BOARD}: BL31=${stock} not found in UBOOT_TARGET_MAP" "${UBOOT_TARGET_MAP}"
	declare -g UBOOT_TARGET_MAP="${UBOOT_TARGET_MAP//"BL31=${stock} "/"BL31=${RK35_3500_BL31_OC} "}"
}

function pre_config_uboot_target__rk35_3500_cpu_oc_bl31() {
	declare src="${RKBIN_DIR}/${BL31_BLOB}" dst="${RK35_3500_BL31_OC}"
	# 1992 MHz row of the BL31 v1.44 CPU rate table (file offset), eight u32:
	# rate, refdiv, fbdiv, postdiv1, postdiv2, dsmpd, frac, PVTPLL config = ring length << 3 | 3
	declare -i row=$((0x4fb18))
	declare -i cfg_offset=$((row + 28))
	declare rate cfg
	rate="$(od -An -tu4 -j "${row}" -N4 "${src}" | tr -d ' ')"
	cfg="$(od -An -tx4 -j "${cfg_offset}" -N4 "${src}" | tr -d ' ')"
	[[ "${rate}" == "1992000000" && "${cfg}" == "00000033" ]] ||
		exit_with_error "${BOARD}: ${BL31_BLOB} has no 1992 MHz row with PVTPLL ring 6 at 0x4fb18" "rate=${rate} cfg=0x${cfg}"
	mkdir -p "$(dirname "${dst}")"
	cp "${src}" "${dst}"
	printf '\x1b' | dd of="${dst}" bs=1 seek="${cfg_offset}" conv=notrunc status=none # ring 6 (0x33) -> 3 (0x1b)
	display_alert "${BOARD}" "BL31 1992 MHz PVTPLL ring 6 -> 3: ${dst##*/}" "info"
}

# DDR overclock: the DDR init blob (U-Boot TPL) trains the LPDDR4X at this clock in MHz, stock 1560.
# The memory is one CXMT CXDB5CCAM-MK (LPDDR4X-3733, i.e. 1866 MHz). Every step up to 1944 MHz trained
# and passed stressapptest; bandwidth (4 threads, copy/read/write GB/s) 1560: 4.68/5.85/6.13,
# 1848: 5.27/6.81/7.05, 1944: 5.56/7.03/7.45. Set RK35_3500_LPDDR4X_MHZ=1560 for the stock blob.
declare -g RK35_3500_LPDDR4X_MHZ="${RK35_3500_LPDDR4X_MHZ:-1944}"

function post_family_config__rk35_3500_ddr_oc() {
	[[ "${RK35_3500_LPDDR4X_MHZ}" == "1560" ]] && return 0
	declare -g RK35_3500_DDR_OC="${SRC}/cache/rk35-3500/$(basename "${DDR_BLOB}" .bin)-lp4x-${RK35_3500_LPDDR4X_MHZ}MHz.bin"
	declare stock="${RKBIN_DIR}/${DDR_BLOB}"
	[[ "${UBOOT_TARGET_MAP}" == *"ROCKCHIP_TPL=${stock}"* ]] ||
		exit_with_error "${BOARD}: ROCKCHIP_TPL=${stock} not found in UBOOT_TARGET_MAP" "${UBOOT_TARGET_MAP}"
	declare -g UBOOT_TARGET_MAP="${UBOOT_TARGET_MAP//"ROCKCHIP_TPL=${stock}"/"ROCKCHIP_TPL=${RK35_3500_DDR_OC}"}"
}

function pre_config_uboot_target__rk35_3500_ddr_oc() {
	[[ "${RK35_3500_LPDDR4X_MHZ}" == "1560" ]] && return 0
	declare src="${RKBIN_DIR}/${DDR_BLOB}" dst="${RK35_3500_DDR_OC}"
	# LPDDR4X frequencies of the v1.21 blob, the field rkbin's ddrbin_tool.py edits as lp4x_freq:
	# u32 at 0xdebc, bits 11:0 = final frequency (1560 MHz), bits 23:12 = F1 (324 MHz)
	declare -i offset=$((0xdebc))
	declare word
	word="$(od -An -tx4 -j "${offset}" -N4 "${src}" | tr -d ' ')"
	grep -q -a "typ 24/01/20-15:04:19,fwver: v1.21" "${src}" && [[ "${word}" == "00144618" ]] ||
		exit_with_error "${BOARD}: ${DDR_BLOB} is not the v1.21 blob with LPDDR4X 1560 MHz at 0xdebc" "word=0x${word}"
	declare -i new=$(((0x${word} & ~0xfff) | RK35_3500_LPDDR4X_MHZ))
	mkdir -p "$(dirname "${dst}")"
	cp "${src}" "${dst}"
	printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((new & 0xff)) $((new >> 8 & 0xff)) $((new >> 16 & 0xff)) $((new >> 24)))" |
		dd of="${dst}" bs=1 seek="${offset}" conv=notrunc status=none
	display_alert "${BOARD}" "DDR blob LPDDR4X 1560 -> ${RK35_3500_LPDDR4X_MHZ} MHz: ${dst##*/}" "info"
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
