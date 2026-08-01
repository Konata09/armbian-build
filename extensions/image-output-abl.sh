function add_host_dependencies__abl_host_deps() {
	EXTRA_BUILD_DEPS+=("build-tools::mkbootimg")
}

function post_build_image__900_convert_to_abl_img() {
	[[ -z $version ]] && exit_with_error "version is not set"

	if [[ -n "$UEFI_GRUB_TARGET" ]]; then
		display_alert "Ignore" "${EXTENSION}" "info"
		return 0
	fi

	if [[ -n "$BOOTFS_TYPE" ]]; then
		return 0
	fi

	display_alert "Converting image $version to rootfs" "${EXTENSION}" "info"
	declare -g ROOTFS_IMAGE_FILE="${DESTIMG}/${version}.rootfs.img"
	rootfs_start_sector=$(gdisk -l "${DESTIMG}/${version}.img" | grep rootfs | awk '{print $2}')
	rootfs_end_sector=$(gdisk -l "${DESTIMG}/${version}.img" | grep rootfs | awk '{print $3}')
	old_rootfs_image_mount_dir=${DESTIMG}/rootfs-old
	new_rootfs_image_mount_dir=${DESTIMG}/rootfs-new
	mkdir -p "${old_rootfs_image_mount_dir}" "${new_rootfs_image_mount_dir}"

	# 先挂上源镜像，量一下真实占用，据此决定新盘尺寸。
	# ext4 那套是"先开 9728M、最后 resize2fs -M 缩到实际大小"，
	# 但 XFS 根本不支持缩容（只有 xfs_growfs 能扩），所以必须一次开对。
	old_image_loop_device=$(losetup -f -P --show "${DESTIMG}/${version}.img")
	old_rootfs_image_uuid=$(blkid -s UUID -o value "${old_image_loop_device}p1")
	mount "${old_image_loop_device}p1" "${old_rootfs_image_mount_dir}"

	declare -i rootfs_used_mib rootfs_size_mib
	rootfs_used_mib=$(du -sm --apparent-size "${old_rootfs_image_mount_dir}" | awk '{print $1}')
	# 留 35% 余量 + 512M 底噪：XFS 元数据（AG、日志区）比 ext4 占得多，
	# 且几乎填满的 XFS 性能很差。最小 2048M，最大不超过原来的 9728M。
	rootfs_size_mib=$((rootfs_used_mib * 135 / 100 + 512))
	((rootfs_size_mib < 2048)) && rootfs_size_mib=2048
	((rootfs_size_mib > 9728)) && rootfs_size_mib=9728
	display_alert "Creating XFS rootfs image" "used=${rootfs_used_mib}MiB size=${rootfs_size_mib}MiB" "info"

	rm -f "${ROOTFS_IMAGE_FILE}"
	truncate --size="${rootfs_size_mib}M" "${ROOTFS_IMAGE_FILE}"
	# -m reflink=0：ABL/initramfs 侧没必要开 reflink，关掉更保守
	# -L armbi_root：与 Armbian 主流程给根分区的卷标保持一致
	mkfs.xfs -f -L armbi_root -m reflink=0 "${ROOTFS_IMAGE_FILE}"
	new_rootfs_image_uuid=$(blkid -s UUID -o value "${ROOTFS_IMAGE_FILE}")

	mount "${ROOTFS_IMAGE_FILE}" "${new_rootfs_image_mount_dir}"
	# 用 rsync 而不是 cp -rfp：要保留 acl/硬链接/稀疏文件，
	# cp -rfp 不保 xattr，SELinux 标签和 capabilities 会丢。
	rsync -aHXx --numeric-ids \
		"${old_rootfs_image_mount_dir}/" "${new_rootfs_image_mount_dir}/"
	umount "${old_rootfs_image_mount_dir}"
	losetup -d "${old_image_loop_device}"
	rm "${DESTIMG}/${version}.img"
	display_alert "Replace root partition uuid from ${old_rootfs_image_uuid} to ${new_rootfs_image_uuid} in /etc/fstab" "${EXTENSION}" "info"
	sed -i "s|${old_rootfs_image_uuid}|${new_rootfs_image_uuid}|g" "${new_rootfs_image_mount_dir}/etc/fstab"
	# 根文件系统已经换成 XFS，fstab 里的类型也得跟着改，
	# 否则 systemd 挂载 / 时类型对不上会掉进 emergency shell。
	sed -i -E "s|^(UUID=${new_rootfs_image_uuid}[[:space:]]+/[[:space:]]+)[a-z0-9]+|\\1xfs|" \
		"${new_rootfs_image_mount_dir}/etc/fstab"
	display_alert "rootfs fstab entry" "$(grep -E "[[:space:]]/[[:space:]]" "${new_rootfs_image_mount_dir}/etc/fstab" | head -1)" "info"
	source "${new_rootfs_image_mount_dir}/boot/armbianEnv.txt"
	declare -g bootimg_cmdline="${BOOTIMG_CMDLINE_EXTRA} root=UUID=${new_rootfs_image_uuid} slot_suffix=${abl_boot_partition_label#boot} ${extraargs}"

	if [[ ${#ABL_DTB_LIST[@]} -ne 0 ]]; then
		display_alert "Going to create abl kernel boot image" "${EXTENSION}" "info"
		gzip -c "${new_rootfs_image_mount_dir}"/boot/vmlinuz-*-* > "${DESTIMG}/Image.gz"
		for dtb_name in "${ABL_DTB_LIST[@]}"; do
			display_alert "Creatng abl kernel boot image with dtb ${dtb_name} and cmdline ${bootimg_cmdline} " "${EXTENSION}" "info"
			cat "${DESTIMG}/Image.gz" "${new_rootfs_image_mount_dir}"/usr/lib/linux-image-*/qcom/"${dtb_name}.dtb" > "${DESTIMG}/Image.gz-${dtb_name}"
			/usr/bin/mkbootimg \
				--kernel "${DESTIMG}/Image.gz-${dtb_name}" \
				--ramdisk "${new_rootfs_image_mount_dir}"/boot/initrd.img-*-* \
				--base 0x0 \
				--second_offset 0x00f00000 \
				--cmdline "${bootimg_cmdline}" \
				--kernel_offset 0x8000 \
				--ramdisk_offset 0x1000000 \
				--tags_offset 0x100 \
				--pagesize 4096 \
				-o "${DESTIMG}/${version}.boot_${dtb_name}.img"
		done
		display_alert "Creatng abl kernel boot recovery image with dtb ${ABL_DTB_LIST[0]}" "${EXTENSION}" "info"
		/usr/bin/mkbootimg \
			--kernel "${DESTIMG}/Image.gz-${ABL_DTB_LIST[0]}" \
			--ramdisk "${new_rootfs_image_mount_dir}"/boot/initrd.img-*-* \
			--base 0x0 \
			--second_offset 0x00f00000 \
			--kernel_offset 0x8000 \
			--ramdisk_offset 0x1000000 \
			--tags_offset 0x100 \
			--pagesize 4096 \
			-o "${DESTIMG}/${version}.boot_recovery.img"
	fi

	umount "${new_rootfs_image_mount_dir}"
	rm -rf "${new_rootfs_image_mount_dir}"
	# XFS 不能缩容，所以没有对应 resize2fs -M 的步骤 —— 尺寸在上面一次开对。
	# 挂载再卸载会重放并清空日志，让镜像落到干净状态；xfs_repair 拒绝处理带脏日志的镜像。
	xfs_repair "${ROOTFS_IMAGE_FILE}" || exit_with_error "xfs_repair failed on ${ROOTFS_IMAGE_FILE}"
	# 把未使用的块打成空洞，镜像文件实际占用能小很多（刷写时 dd 读到的仍是完整大小）
	fallocate -d "${ROOTFS_IMAGE_FILE}" 2> /dev/null || true
	display_alert "XFS rootfs ready" "$(du -h --apparent-size "${ROOTFS_IMAGE_FILE}" | awk '{print $1}') apparent, $(du -h "${ROOTFS_IMAGE_FILE}" | awk '{print $1}') on disk" "info"
	return 0
}
