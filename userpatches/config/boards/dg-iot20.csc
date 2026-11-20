# Rockchip RK3328 quad core 2GB RAM SoC eMMC
BOARD_NAME="DG-IOT20"
BOARDFAMILY="rockchip64"
BOARD_MAINTAINER="dg741a"
BOOTCONFIG="evb-rk3328_defconfig"
KERNEL_TARGET="current"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3328-dg-iot20.dtb"
IMAGE_PARTITION_TABLE="gpt"
BOOT_SCENARIO="spl-blobs"
BOOTFS_TYPE="fat"

function image_specific_armbian_env_ready__dg_iot20_armbian_env() {
	if grep -q '^verbosity=' "${SDCARD}/boot/armbianEnv.txt"; then
		sed -i 's/^verbosity=.*/verbosity=7/' "${SDCARD}/boot/armbianEnv.txt"
	else
		echo 'verbosity=7' >> "${SDCARD}/boot/armbianEnv.txt"
	fi
	if grep -q '^docker_optimizations=' "${SDCARD}/boot/armbianEnv.txt"; then
		sed -i 's/^docker_optimizations=.*/docker_optimizations=off/' "${SDCARD}/boot/armbianEnv.txt"
	else
		echo 'docker_optimizations=off' >> "${SDCARD}/boot/armbianEnv.txt"
	fi
}
