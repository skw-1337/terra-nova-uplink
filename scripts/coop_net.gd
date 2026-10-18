# Coop over Steam (TN+ Coop build, prototype). Steam test App ID 480 ("Spacewar"), friends-only lobby for two, P2P
# through Steam's relays: no port is opened on either PC.
#  --coop-host  (the player's window): opens the lobby, shows ONLINE / CONNECTABLE / GUEST CONNECTED (F9 = invite).
#               The bridge (live_bridge.py --guest-remote) sends the guest's view to 127.0.0.1:47841 as coop_view.py
#               messages: keyframes (VKF) and decor (VDC) go reliable, deltas (VDL, VDP parts) unreliable; the guest's
#               input comes back and goes to 127.0.0.1:47834 (the bridge's coop module, which only turns it into move /
#               turn / aim / fire commands). A guest that connects gets an 'R' to the bridge: decor and keyframe now.
#  --coop-guest (the second player's window, his own copy of the game files): joins the host's lobby (Steam invite,
#               "Join game" in the friends list, or --connect-lobby ID / +connect_lobby ID), rebuilds the full view
#               packet (coop_view.gd) for its own live port, asks for the decor again ('R') while it lacks it, and sends its keys, mouse and buttons (its --play port) to the host, plus its
#               gamepad ('P' packets, ~60 a second: left stick move / strafe, right stick look, right trigger fire).
#               HUD packets ('GHD') from the host go as they are to 127.0.0.1:47832 (coop_hud.gd). F8: next teammate.
# Both sides must run the same coop files: the lobby carries "coop_version" and the guest says "HELLO" + COOP_VERSION;
# a guest with another version leaves, the host ignores the input of one that stays (an older guest).
# GodotSteam (addons/godotsteam) is loaded at run time and reached through Engine.get_singleton("Steam").
# --fake-steam: scripts/fake_steam.gd instead (one process only: nobody else to meet). live/test_coop_net.gd runs a
# host and a guest side by side over one fake Steam (fake_steam, role and the ports set before _ready).
extends CanvasLayer

const COOP_VERSION := "3"           # bump when the host / guest packets change
const APP_ID := 480
const LOBBY_FRIENDS_ONLY := 1        # ELobbyType
const RESULT_OK := 1                 # EResult
const SEND_UNRELIABLE_NO_DELAY := 1
const SEND_RELIABLE := 2
const UNRELIABLE_MAX := 1200         # Steam P2P: the biggest unreliable packet (the bridge cuts deltas to fit)
const CH_VIEW := 0                   # host -> guest: view (coop_view messages), HUD and mission name
const CH_INPUT := 1                  # guest -> host: HELLO, input packets (K / M / B) as the viewer sends them, gamepad (P), R
const VIEW_IN := 47841               # host: the bridge's guest view
const INPUT_OUT := 47834             # host: to the bridge's coop module
const LIVE_IN := 47831               # guest: its viewer's live port
const PLAY_IN := 47834               # guest: its viewer's play port
const HUD_OUT := 47832               # guest: its coop_hud.gd
const PAD_DEAD := 0.2

var steam: Object = null
var fake_steam: Object = null        # set before _ready (tests): this instead of GodotSteam; --fake-steam: a lone one
var role := ""                       # set before _ready (tests): "host" / "guest"; else from --coop-guest
var view_in := VIEW_IN               # the ports, which the tests move (host and guest in one process)
var input_out := INPUT_OUT
var live_in := LIVE_IN
var play_in := PLAY_IN
var hud_out_port := HUD_OUT
var host_mode := true
var lobby_id := 0
var peer := 0                        # the other player's Steam ID
var peer_hello := false              # host: the guest said HELLO...
var peer_ok := false                 # ... with our coop version (only then its input goes to the bridge)
var version_msg := ""                # guest: the host runs another coop version
var hello_t := -100.0
var pad_t := -100.0
var pad_live := false                # guest: the last gamepad packet was not all zero
var udp_in := PacketPeerUDP.new()
var udp_out := PacketPeerUDP.new()
var hud_out := PacketPeerUDP.new()
var label: Label
var sent := 0
var recv := 0
var rate_t := 0.0
var rate := ""
# guest: waiting screen until the host's view arrives (not connected yet, or the host is in the game's menus)
var wait_panel: ColorRect
var wait_title: Label
var wait_text: Label
var last_view := -100.0
var view: RefCounted = preload("res://scripts/coop_view.gd").new()   # guest: rebuilds the host's view
var resync_t := -100.0
var clock := 0.0
var mission_t := 0.0
var msn_want := ""                   # guest: the host's mission last asked of the viewer (loading takes a while)
var ok_col := Color(0.35, 1.0, 0.45)
var warn_col := Color(1.0, 0.75, 0.25)
var bad_col := Color(1.0, 0.35, 0.3)


func _ready() -> void:
	layer = 10
	host_mode = role == "host" if role != "" else not ("--coop-guest" in OS.get_cmdline_user_args())
	if not host_mode:
		wait_panel = ColorRect.new()
		wait_panel.color = Color(0.04, 0.06, 0.08)
		wait_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		wait_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(wait_panel)
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_CENTER)
		box.grow_horizontal = Control.GROW_DIRECTION_BOTH
		box.grow_vertical = Control.GROW_DIRECTION_BOTH
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		wait_panel.add_child(box)
		wait_title = Label.new()
		wait_title.text = "TERRA NOVA  ·  COOP"
		wait_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wait_title.add_theme_font_size_override("font_size", 44)
		wait_title.add_theme_color_override("font_color", Color(0.95, 0.75, 0.3))
		box.add_child(wait_title)
		wait_text = Label.new()
		wait_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wait_text.add_theme_font_size_override("font_size", 20)
		wait_text.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
		box.add_child(wait_text)
	label = Label.new()
	label.position = Vector2(12, 8)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	add_child(label)
	_show("STEAM...", "", warn_col)
	if fake_steam == null and "--fake-steam" in OS.get_cmdline_user_args():
		fake_steam = load("res://scripts/fake_steam.gd").new()
	if fake_steam:
		steam = fake_steam
	else:
		if not Engine.has_singleton("Steam"):
			var r := GDExtensionManager.load_extension("res://addons/godotsteam/godotsteam.gdextension")
			if r != GDExtensionManager.LOAD_STATUS_OK and r != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
				_show("OFFLINE", "GodotSteam not loaded (%d)" % r, bad_col)
				return
		steam = Engine.get_singleton("Steam")
	var init: Dictionary = steam.steamInitEx(APP_ID, false)
	if int(init.get("status", 1)) != 0:
		_show("OFFLINE", "Steam: %s" % init.get("verbal", "?"), bad_col)
		steam = null
		return
	steam.connect("lobby_created", _on_lobby_created)
	steam.connect("lobby_chat_update", _on_lobby_update)
	steam.connect("lobby_joined", _on_lobby_joined)
	steam.connect("join_requested", _on_join_requested)
	steam.connect("p2p_session_request", _on_p2p_request)
	if steam.has_signal("avatar_loaded"):
		steam.connect("avatar_loaded", _on_avatar)
	if host_mode:
		udp_in.bind(view_in, "127.0.0.1")
		udp_out.set_dest_address("127.0.0.1", input_out)
		_show("ONLINE", "%s - opening a friends-only lobby..." % steam.getPersonaName(), warn_col)
		steam.createLobby(LOBBY_FRIENDS_ONLY, 2)
	else:
		udp_in.bind(play_in, "127.0.0.1")
		udp_out.set_dest_address("127.0.0.1", live_in)
		hud_out.set_dest_address("127.0.0.1", hud_out_port)
		var want := _lobby_arg()
		if want:
			_show("ONLINE", "joining the host's lobby...", warn_col)
			steam.joinLobby(want)
		else:
			_show("ONLINE", "%s - waiting for an invite (or Join game from your friends list)" % steam.getPersonaName(), warn_col)


func _lobby_arg() -> int:
	var a := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for i in a.size() - 1:
		if a[i] == "+connect_lobby" or a[i] == "--connect-lobby":
			return int(a[i + 1])
	return 0


func _process(delta: float) -> void:
	clock += delta
	if wait_panel:
		_waiting()
	if not steam:
		return
	steam.run_callbacks()
	if host_mode:
		while udp_in.get_available_packet_count() > 0:
			var pk := udp_in.get_packet()
			if peer_ok and pk.size() >= 3:                 # only to a guest that said HELLO with our version
				var tag := pk.slice(0, 3).get_string_from_ascii()
				var fast := (tag == "VDL" or tag == "VDP") and pk.size() <= UNRELIABLE_MAX   # a lost delta breaks nothing
				steam.sendP2PPacket(peer, pk, SEND_UNRELIABLE_NO_DELAY if fast else SEND_RELIABLE, CH_VIEW)
				sent += pk.size()
		mission_t += delta
		var vp := get_parent()
		if peer_ok and mission_t > 2.0 and vp and not vp.current.is_empty():
			mission_t = 0.0
			steam.sendP2PPacket(peer, ("MSN" + str(vp.current["entry"]["file"]).get_file().to_upper()).to_ascii_buffer(), SEND_RELIABLE, CH_VIEW)
		_read(CH_INPUT)
		_drop(CH_VIEW)                                  # nothing comes this way: never let it pile up
	else:
		while udp_in.get_available_packet_count() > 0:
			var pk := udp_in.get_packet()
			if peer and pk.size() > 0:
				# mouse moves may be dropped; keys and buttons must arrive
				steam.sendP2PPacket(peer, pk, SEND_UNRELIABLE_NO_DELAY if pk[0] == 77 else SEND_RELIABLE, CH_INPUT)
				sent += pk.size()
		if peer:
			if clock - hello_t > 2.0:                       # again now and then: the host may have missed it
				_hello()
			_pad()
		_read(CH_VIEW)
		if peer and view.waiting_decor() and clock - resync_t > 1.0:   # joined late: the decor again, please
			resync_t = clock
			steam.sendP2PPacket(peer, "R".to_ascii_buffer(), SEND_RELIABLE, CH_INPUT)
			sent += 1
		_drop(CH_INPUT)
	rate_t += delta
	if rate_t >= 1.0:
		rate = "%d KB/s out, %d KB/s in" % [sent / 1024, recv / 1024]
		sent = 0
		recv = 0
		rate_t = 0.0
		_refresh()


func _read(ch: int) -> void:
	var n: int = steam.getAvailableP2PPacketSize(ch)
	while n > 0:
		var r: Dictionary = steam.readP2PPacket(n, ch)
		var data: PackedByteArray = r.get("data", PackedByteArray())
		var from: int = int(r.get("remote_steam_id", 0))      # GodotSteam 4: remote_steam_id
		if from == peer and data.size() > 0:
			recv += data.size()
			var tag := data.slice(0, 3).get_string_from_ascii()
			if host_mode:
				if data.size() >= 5 and data.slice(0, 5).get_string_from_ascii() == "HELLO":
					var ok := data.get_string_from_ascii() == "HELLO" + COOP_VERSION
					if ok != peer_ok or not peer_hello:
						peer_hello = true
						peer_ok = ok
						if ok:
							udp_out.put_packet("R".to_ascii_buffer())   # the bridge: full decor and a keyframe for him
							udp_out.put_packet(("N" + steam.getFriendPersonaName(peer)).to_utf8_buffer())   # his name on our HUD
							if steam.has_method("getPlayerAvatar"):
								steam.getPlayerAvatar(2, peer)          # and his avatar as the portrait (avatar_loaded)
						_refresh()
				elif peer_ok:
					udp_out.put_packet(data)               # guest input: the bridge validates and uses it
			elif tag == "GHD" or tag == "GCK":                # HUD and cockpit: to coop_hud.gd
				hud_out.put_packet(data)                   # HUD packet: to coop_hud.gd as it is (not zlib)
			elif data.size() > 3 and tag == "MSN":
				var mf := data.slice(3).get_string_from_ascii()
				var vp := get_parent()
				if vp and mf != msn_want and (vp.current.is_empty() or str(vp.current["entry"]["file"]).get_file().to_upper() != mf):
					msn_want = mf                           # once: not again every 2 s while it loads
					vp._load_by_label(mf)
			elif tag == "VKF" or tag == "VDL" or tag == "VDP" or tag == "VDC":
				var full: PackedByteArray = view.feed(data)
				if full.size() > 0:
					udp_out.put_packet(full)                   # the same packet as the local coop's
					last_view = clock
		n = steam.getAvailableP2PPacketSize(ch)


func _drop(ch: int) -> void:
	var n: int = steam.getAvailableP2PPacketSize(ch)
	while n > 0:
		steam.readP2PPacket(n, ch)
		n = steam.getAvailableP2PPacketSize(ch)


# host: the guest left (or another one came): let go of his keys and fire, their releases will never arrive
func _release_input() -> void:
	for sc in [0x11, 0x1F, 0x1E, 0x20]:
		udp_out.put_packet(PackedByteArray([0x4B, sc, 0, 0]))
	udp_out.put_packet(PackedByteArray([0x42, 1, 0]))
	udp_out.put_packet(PackedByteArray([80, 0, 0, 0, 0, 0]))


func _unhandled_input(event: InputEvent) -> void:
	if steam and host_mode and lobby_id and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F9:
		steam.activateGameOverlayInviteDialog(lobby_id)


func _on_lobby_created(result: int, id: int) -> void:
	if result != RESULT_OK:
		_show("ONLINE", "lobby not created (result %d)" % result, warn_col)
		return
	lobby_id = id
	steam.setLobbyJoinable(id, true)
	steam.setLobbyData(id, "game", "terra-nova-coop")
	steam.setLobbyData(id, "coop_version", COOP_VERSION)
	steam.setRichPresence("connect", "+connect_lobby %d" % id)
	steam.setRichPresence("status", "Terra Nova coop: room for a second player")
	_refresh()


func _on_join_requested(id: int, _friend: int) -> void:
	if not host_mode:
		version_msg = ""
		if lobby_id and lobby_id != id:
			steam.leaveLobby(lobby_id)
			if peer:
				steam.closeP2PSessionWithUser(peer)
			lobby_id = 0
			peer = 0
		_show("ONLINE", "joining the host's lobby...", warn_col)
		steam.joinLobby(id)


func _on_lobby_joined(id: int, _permissions: int, _locked: int, response: int) -> void:
	if host_mode:
		return
	if response != 1:                                       # k_EChatRoomEnterResponseSuccess
		_show("ONLINE", "could not join the lobby (%d)" % response, bad_col)
		return
	var hv := str(steam.getLobbyData(id, "coop_version"))
	if hv != COOP_VERSION:
		steam.leaveLobby(id)
		peer = 0
		lobby_id = 0
		var hs := hv if hv != "" else "older"
		version_msg = "The host has another coop version (host %s, you %s): both need the same Uplink coop files." % [hs, COOP_VERSION]
		_show("ONLINE · ANOTHER COOP VERSION", "host %s, you %s" % [hs, COOP_VERSION], bad_col)
		return
	version_msg = ""
	lobby_id = id
	peer = steam.getLobbyOwner(id)
	view = preload("res://scripts/coop_view.gd").new()     # nothing kept from another host
	_hello()                                                # opens the P2P session
	for n in get_parent().get_children():                   # the host's name now, his avatar when Steam has it
		if n.has_method("set_mate"):
			n.set_mate(steam.getFriendPersonaName(peer), null)
	if steam.has_method("getPlayerAvatar"):
		steam.getPlayerAvatar(2, peer)
	_refresh()


func _hello() -> void:
	hello_t = clock
	steam.sendP2PPacket(peer, ("HELLO" + COOP_VERSION).to_ascii_buffer(), SEND_RELIABLE, CH_INPUT)


# guest: gamepad 0 through Godot, XInput signs (stick up = positive), at most 60 packets a second while it is used:
# 'P' + lx, ly, rx, ry (int8, -127..127) + fire (0 / 1); the host's coop_guest.py drops values older than 0.3 s
func _pad() -> void:
	if clock - pad_t < 1.0 / 60.0 or not (0 in Input.get_connected_joypads()):
		return
	var lx := _axis(JOY_AXIS_LEFT_X, 1.0)
	var ly := _axis(JOY_AXIS_LEFT_Y, -1.0)                # Godot: up = negative
	var rx := _axis(JOY_AXIS_RIGHT_X, 1.0)
	var ry := _axis(JOY_AXIS_RIGHT_Y, -1.0)
	var fire := 1 if Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.25 else 0
	var used := lx != 0 or ly != 0 or rx != 0 or ry != 0 or fire != 0
	if not used and not pad_live:                         # idle pad: nothing to send (one last all-zero packet)
		return
	pad_live = used
	pad_t = clock
	var pk := PackedByteArray([80, 0, 0, 0, 0, fire])     # 'P'
	pk.encode_s8(1, lx)
	pk.encode_s8(2, ly)
	pk.encode_s8(3, rx)
	pk.encode_s8(4, ry)
	steam.sendP2PPacket(peer, pk, SEND_UNRELIABLE_NO_DELAY, CH_INPUT)
	sent += pk.size()


func _axis(a: JoyAxis, sign_: float) -> int:
	var v := Input.get_joy_axis(0, a) * sign_
	if absf(v) < PAD_DEAD:
		return 0
	return clampi(roundi(signf(v) * (absf(v) - PAD_DEAD) / (1.0 - PAD_DEAD) * 127.0), -127, 127)


# host: the guest's Steam avatar, 21 x 27 like the game's portraits (the bridge turns it into the game's colours)
func _on_avatar(id: int, size: int, data: PackedByteArray) -> void:
	if id != peer or size <= 0 or data.size() != size * size * 4:
		return
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	# the game's screen has half-height rows (320 x 400 shown 4:3): a portrait's 21 x 27 pixels show a wide band,
	# 1.73 wide for 1 high; the avatar's middle band, a little above the centre (faces)
	var h := int(size / 1.73)
	img = img.get_region(Rect2i(0, int((size - h) * 0.4), size, h))
	if not host_mode:                                       # guest: the host's face in our cockpit's COMM panel
		for n in get_parent().get_children():
			if n.has_method("set_mate"):
				n.set_mate(steam.getFriendPersonaName(peer), img)
		return
	img.resize(21, 27, Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_RGB8)
	udp_out.put_packet("A".to_ascii_buffer() + img.get_data())


func _on_p2p_request(remote: int) -> void:
	if remote == peer or (host_mode and lobby_id and _in_lobby(remote)):
		steam.acceptP2PSessionWithUser(remote)


func _in_lobby(id: int) -> bool:
	for i in steam.getNumLobbyMembers(lobby_id):
		if steam.getLobbyMemberByIndex(lobby_id, i) == id:
			return true
	return false


func _on_lobby_update(lobby: int, changed: int, _maker: int, change: int) -> void:
	if not host_mode and peer and lobby == lobby_id and changed == peer and change & 30:   # host left / disconnected
		steam.leaveLobby(lobby_id)                          # (else Steam makes us the owner of an empty room)
		peer = 0
		lobby_id = 0
		view = preload("res://scripts/coop_view.gd").new()
		_show("ONLINE", "the host left - waiting for an invite (or Join game from your friends list)", warn_col)
		return
	if host_mode:
		var was := peer
		peer = 0
		for i in steam.getNumLobbyMembers(lobby_id):
			var m: int = steam.getLobbyMemberByIndex(lobby_id, i)
			if m != steam.getSteamID():
				peer = m
		if peer != was:
			if was:
				steam.closeP2PSessionWithUser(was)
				_release_input()
			peer_hello = false
			peer_ok = false
	elif lobby_id and peer and not _in_lobby(peer):         # guest: the host left (quit, crash, Steam closed)
		steam.leaveLobby(lobby_id)
		steam.closeP2PSessionWithUser(peer)
		lobby_id = 0
		peer = 0
		msn_want = ""
		_show("ONLINE", "the host left - waiting for an invite", warn_col)
		return
	_refresh()


func _refresh() -> void:
	if not steam:
		return
	if host_mode:
		if not lobby_id:
			return
		if peer and peer_ok:
			_show("ONLINE · GUEST CONNECTED", "%s   %s" % [steam.getFriendPersonaName(peer), rate], ok_col)
		elif peer and peer_hello:
			_show("ONLINE · GUEST HAS ANOTHER VERSION", "%s: both need the same Uplink coop files (yours: %s)" % [
				steam.getFriendPersonaName(peer), COOP_VERSION], warn_col)
		elif peer:
			_show("ONLINE · GUEST JOINING", steam.getFriendPersonaName(peer), warn_col)
		else:
			_show("ONLINE · CONNECTABLE", "friends can join from Steam (F9: invite)", ok_col)
	elif peer:
		_show("ONLINE · CONNECTED TO HOST", "%s   %s" % [steam.getFriendPersonaName(peer), rate], ok_col)


func _waiting() -> void:
	var live := steam != null and peer != 0 and clock - last_view < 2.0
	wait_panel.visible = not live
	if live:
		return
	var dots := ".".repeat(1 + int(clock * 2.0) % 3)
	wait_text.add_theme_color_override("font_color", bad_col if version_msg != "" and peer == 0 else Color(0.8, 0.85, 0.9))
	if steam == null:
		wait_text.text = "Steam is not available: start Steam, then this window again."
	elif peer == 0 and version_msg != "":
		wait_text.text = version_msg
	elif peer == 0:
		wait_text.text = "Waiting for an invite%s\nAccept your friend's invite in Steam, or use Join game on your friend in your friends list." % dots
	else:
		wait_text.text = "Connected to %s.\nWaiting for the host to start a mission%s\nYou will drive the teammate nearest to the host: W/S/A/D, mouse, left button to fire,\nor a gamepad (left stick move, right stick look, right trigger fire). F8: next teammate." % [
			steam.getFriendPersonaName(peer), dots]


func _show(t: String, d: String, c: Color) -> void:
	label.text = "● " + t + ("\n   " + d if d != "" else "")
	label.add_theme_color_override("font_color", c)
