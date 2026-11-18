# Files in Uplink's user folder that two Uplink windows can share (the co-op host and a guest started on the same PC,
# or two copies at once): each is written under a name of its own (".part" + the process id) and then renamed onto
# the real name, so that the other window never reads half a file, nor two windows write into the same one.
extends RefCounted


static func tmp_name(dst: String) -> String:
	return "%s.part%d" % [dst, OS.get_process_id()]


# Puts the finished temporary file in place. When the rename fails (the other window holds the file open, having
# written it first): the temporary file is dropped and the one already there is kept.
static func commit(tmp: String, dst: String) -> bool:
	tmp = ProjectSettings.globalize_path(tmp)
	dst = ProjectSettings.globalize_path(dst)
	if DirAccess.rename_absolute(tmp, dst) == OK:
		return true
	DirAccess.remove_absolute(tmp)
	return FileAccess.file_exists(dst)


static func write_bytes(dst: String, data: PackedByteArray) -> bool:
	var tmp := tmp_name(dst)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return commit(tmp, dst)
