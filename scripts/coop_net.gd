# Coop over Steam (TN+ Coop build, prototype). Steam test App ID 480 ("Spacewar"), friends-only lobby for two, P2P
# through Steam's relays: no port is opened on either PC.
#  --coop-host  (the player's window): opens the lobby, shows ONLINE / CONNECTABLE / GUEST CONNECTED (F9 = invite).
#               The bridge (live_bridge.py --guest-remote) sends the guest's view to 127.0.0.1:47841: it goes to the
#               guest, zlib-compressed by the bridge; the guest's input comes back and goes to 127.0.0.1:47834 (the
#               bridge's coop module, which only turns it into move / turn / aim / fire commands).
#  --coop-guest (the second player's window, his own copy of the game files): joins the host's lobby (Steam invite,
#               "Join game" in the friends list, or --connect-lobby ID / +connect_lobby ID), feeds the received view
#               to its own live port and sends its keys, mouse and buttons (its --play port) to the host.
# GodotSteam (addons/godotsteam) is loaded at run time and reached through Engine.get_singleton("Steam").
extends CanvasLayer

const APP_ID := 480
const LOBBY_FRIENDS_ONLY := 1        # ELobbyType
const RESULT_OK := 1                 # EResult
const SEND_UNRELIABLE_NO_DELAY := 1
const SEND_RELIABLE := 2
const CH_VIEW := 0                   # host -> guest: view (zlib) and mission name
const CH_INPUT := 1                  # guest -> host: input packets (K / M / B), as the viewer sends them
const VIEW_IN := 47841               # host: the bridge's guest view
const INPUT_OUT := 47834             # host: to the bridge's coop module
const LIVE_IN := 47831               # guest: its viewer's live port
const PLAY_IN := 47834               # guest: its viewer's play port

var steam: Object = null
var host_mode := true
var lobby_id := 0
var peer := 0                        # the other player's Steam ID
var udp_in := PacketPeerUDP.new()
var udp_out := PacketPeerUDP.new()
var label: Label
var sent := 0
var recv := 0
var rate_t := 0.0
var rate := ""
var mission_t := 0.0
var ok_col := Color(0.35, 1.0, 0.45)
var warn_col := Color(1.0, 0.75, 0.25)
var bad_col := Color(1.0, 0.35, 0.3)


func _ready() -> void:
	layer = 10
	host_mode = not ("--coop-guest" in OS.get_cmdline_user_args())
	label = Label.new()
	label.position = Vector2(12, 8)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	add_child(label)
	_show("STEAM...", "", warn_col)
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
	if host_mode:
		udp_in.bind(VIEW_IN, "127.0.0.1")
		udp_out.set_dest_address("127.0.0.1", INPUT_OUT)
		_show("ONLINE", "%s - opening a friends-only lobby..." % steam.getPersonaName(), warn_col)
		steam.createLobby(LOBBY_FRIENDS_ONLY, 2)
	else:
		udp_in.bind(PLAY_IN, "127.0.0.1")
		udp_out.set_dest_address("127.0.0.1", LIVE_IN)
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
	if not steam:
		return
	steam.run_callbacks()
	if host_mode:
		while udp_in.get_available_packet_count() > 0:
			var pk := udp_in.get_packet()
			if peer:
				steam.sendP2PPacket(peer, pk, SEND_RELIABLE, CH_VIEW)
				sent += pk.size()
		mission_t += delta
		var vp := get_parent()
		if peer and mission_t > 2.0 and vp and not vp.current.is_empty():
			mission_t = 0.0
			steam.sendP2PPacket(peer, ("MSN" + str(vp.current["entry"]["file"]).get_file().to_upper()).to_ascii_buffer(), SEND_RELIABLE, CH_VIEW)
		_read(CH_INPUT)
	else:
		while udp_in.get_available_packet_count() > 0:
			var pk := udp_in.get_packet()
			if peer and pk.size() > 0:
				# mouse moves may be dropped; keys and buttons must arrive
				steam.sendP2PPacket(peer, pk, SEND_UNRELIABLE_NO_DELAY if pk[0] == 77 else SEND_RELIABLE, CH_INPUT)
				sent += pk.size()
		_read(CH_VIEW)
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
		var from: int = int(r.get("steam_id_remote", 0))
		if from == peer and data.size() > 0:
			recv += data.size()
			if host_mode:
				udp_out.put_packet(data)                   # guest input: the bridge validates and uses it
			elif data.size() > 3 and data.slice(0, 3).get_string_from_ascii() == "MSN":
				var mf := data.slice(3).get_string_from_ascii()
				var vp := get_parent()
				if vp and (vp.current.is_empty() or str(vp.current["entry"]["file"]).get_file().to_upper() != mf):
					vp._load_by_label(mf)
			else:
				udp_out.put_packet(data.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE))
		n = steam.getAvailableP2PPacketSize(ch)


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
	steam.setRichPresence("connect", "+connect_lobby %d" % id)
	steam.setRichPresence("status", "Terra Nova coop: room for a second player")
	_refresh()


func _on_join_requested(id: int, _friend: int) -> void:
	if not host_mode:
		_show("ONLINE", "joining the host's lobby...", warn_col)
		steam.joinLobby(id)


func _on_lobby_joined(id: int, _permissions: int, _locked: int, response: int) -> void:
	if host_mode:
		return
	if response != 1:                                       # k_EChatRoomEnterResponseSuccess
		_show("ONLINE", "could not join the lobby (%d)" % response, bad_col)
		return
	lobby_id = id
	peer = steam.getLobbyOwner(id)
	steam.sendP2PPacket(peer, "HELLO".to_ascii_buffer(), SEND_RELIABLE, CH_INPUT)   # opens the P2P session
	_refresh()


func _on_p2p_request(remote: int) -> void:
	if remote == peer or (host_mode and lobby_id and _in_lobby(remote)):
		steam.acceptP2PSessionWithUser(remote)


func _in_lobby(id: int) -> bool:
	for i in steam.getNumLobbyMembers(lobby_id):
		if steam.getLobbyMemberByIndex(lobby_id, i) == id:
			return true
	return false


func _on_lobby_update(_lobby: int, _changed: int, _maker: int, _change: int) -> void:
	if host_mode:
		peer = 0
		for i in steam.getNumLobbyMembers(lobby_id):
			var m: int = steam.getLobbyMemberByIndex(lobby_id, i)
			if m != steam.getSteamID():
				peer = m
	_refresh()


func _refresh() -> void:
	if not steam:
		return
	if host_mode:
		if not lobby_id:
			return
		if peer:
			_show("ONLINE · GUEST CONNECTED", "%s   %s" % [steam.getFriendPersonaName(peer), rate], ok_col)
		else:
			_show("ONLINE · CONNECTABLE", "friends can join from Steam (F9: invite)", ok_col)
	elif peer:
		_show("ONLINE · CONNECTED TO HOST", "%s   %s" % [steam.getFriendPersonaName(peer), rate], ok_col)


func _show(t: String, d: String, c: Color) -> void:
	label.text = "● " + t + ("\n   " + d if d != "" else "")
	label.add_theme_color_override("font_color", c)
