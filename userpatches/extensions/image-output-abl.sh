function add_host_dependencies__abl_host_deps() {
	EXTRA_BUILD_DEPS+=("build-tools::mkbootimg" "fs-tools::xfsprogs")
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

	truncate --size="5120M" "${ROOTFS_IMAGE_FILE}"
	mkfs.xfs -f -L armbi_root -m reflink=0 -s size=4096 -b size=4096 "${ROOTFS_IMAGE_FILE}"

	declare xfs_sectsize
	xfs_sectsize="$(xfs_db -r -c "sb 0" -c "print sectsize" "${ROOTFS_IMAGE_FILE}" 2> /dev/null | sed -n "s/.*= *//p" | head -1)"
	if [[ "${xfs_sectsize}" != "4096" ]]; then
		exit_with_error "XFS sector size is '${xfs_sectsize}', expected 4096; image would not mount on 4K-sector UFS"
	fi
  	new_rootfs_image_uuid=$(blkid -s UUID -o value "${ROOTFS_IMAGE_FILE}")
	old_image_loop_device=$(losetup -f -P --show "${DESTIMG}/${version}.img")
	old_rootfs_image_uuid=$(blkid -s UUID -o value "${old_image_loop_device}p1")
	mount "${old_image_loop_device}p1" "${old_rootfs_image_mount_dir}"
	mount "${ROOTFS_IMAGE_FILE}" "${new_rootfs_image_mount_dir}"
	cp -rfp "${old_rootfs_image_mount_dir}"/* "${new_rootfs_image_mount_dir}"/
	umount "${old_rootfs_image_mount_dir}"
	losetup -d "${old_image_loop_device}"
	rm "${DESTIMG}/${version}.img"
	display_alert "Replace root partition uuid from ${old_rootfs_image_uuid} to ${new_rootfs_image_uuid} in /etc/fstab" "${EXTENSION}" "info"
	sed -i "s|${old_rootfs_image_uuid}|${new_rootfs_image_uuid}|g" "${new_rootfs_image_mount_dir}/etc/fstab"
	sed -i -E "s|^(UUID=${new_rootfs_image_uuid}[[:space:]]+/[[:space:]]+)[a-z0-9]+|\\1xfs|" \
		"${new_rootfs_image_mount_dir}/etc/fstab"
	display_alert "rootfs fstab entry" "$(grep -E "[[:space:]]/[[:space:]]" "${new_rootfs_image_mount_dir}/etc/fstab" | head -1)" "info"
	source "${new_rootfs_image_mount_dir}/boot/armbianEnv.txt"
	declare -g bootimg_cmdline="${BOOTIMG_CMDLINE_EXTRA} root=UUID=${new_rootfs_image_uuid} slot_suffix=${abl_boot_partition_label#boot} ${extraargs}"

	if [[ ${#ABL_DTB_LIST[@]} -ne 0 ]]; then
		display_alert "Going to create abl kernel boot image" "${EXTENSION}" "info"
		gzip -c "${new_rootfs_image_mount_dir}"/boot/vmlinuz-*-* > "${DESTIMG}/Image.gz"
		for dtb_name in "${ABL_DTB_LIST[@]}"; do
			display_alert "Creating abl kernel boot image with dtb ${dtb_name} and cmdline ${bootimg_cmdline} " "${EXTENSION}" "info"
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
	fi

	umount "${new_rootfs_image_mount_dir}"
	rm -rf "${new_rootfs_image_mount_dir}"
	xfs_repair "${ROOTFS_IMAGE_FILE}" || exit_with_error "xfs_repair failed on ${ROOTFS_IMAGE_FILE}"
	fallocate -d "${ROOTFS_IMAGE_FILE}" 2> /dev/null || true
	display_alert "XFS rootfs ready" "$(du -h --apparent-size "${ROOTFS_IMAGE_FILE}" | awk '{print $1}') apparent, $(du -h "${ROOTFS_IMAGE_FILE}" | awk '{print $1}') on disk" "info"
	return 0
}
