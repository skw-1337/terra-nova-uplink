# Coop over Steam (TN+ Coop build, prototype): the host's window signs in to Steam (test App ID 480, "Spacewar"),
# opens a friends-only lobby for two and shows whether it is online and connectable; F9 opens Steam's invite dialog.
# GodotSteam (addons/godotsteam, GDExtension) is loaded at run time: the project also runs from its sources without
# an editor import, so the Steam class is reached through Engine.get_singleton, not by name.
extends CanvasLayer

const APP_ID := 480
const LOBBY_FRIENDS_ONLY := 1        # ELobbyType
const RESULT_OK := 1                 # EResult

var steam: Object = null
var lobby_id := 0
var state := "STEAM..."
var detail := ""
var label: Label
var ok_col := Color(0.35, 1.0, 0.45)
var warn_col := Color(1.0, 0.75, 0.25)
var bad_col := Color(1.0, 0.35, 0.3)


func _ready() -> void:
	layer = 10
	label = Label.new()
	label.position = Vector2(12, 8)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	add_child(label)
	_show("STEAM...", "", warn_col)
	var ext := "res://addons/godotsteam/godotsteam.gdextension"
	if not Engine.has_singleton("Steam"):
		var r := GDExtensionManager.load_extension(ext)
		if r != GDExtensionManager.LOAD_STATUS_OK and r != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			_show("OFFLINE", "GodotSteam not loaded (%d)" % r, bad_col)
			return
	if not Engine.has_singleton("Steam"):
		_show("OFFLINE", "GodotSteam not available", bad_col)
		return
	steam = Engine.get_singleton("Steam")
	var init: Dictionary = steam.steamInitEx(APP_ID, false)
	if int(init.get("status", 1)) != 0:
		_show("OFFLINE", "Steam: %s" % init.get("verbal", "?"), bad_col)
		steam = null
		return
	steam.connect("lobby_created", _on_lobby_created)
	steam.connect("lobby_chat_update", _on_lobby_update)
	_show("ONLINE", "%s - opening a friends-only lobby..." % steam.getPersonaName(), warn_col)
	steam.createLobby(LOBBY_FRIENDS_ONLY, 2)


func _process(_d: float) -> void:
	if steam:
		steam.run_callbacks()


func _unhandled_input(event: InputEvent) -> void:
	if steam and lobby_id and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F9:
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


func _on_lobby_update(_lobby: int, _changed: int, _maker: int, _change: int) -> void:
	_refresh()


func _refresh() -> void:
	if not lobby_id:
		return
	var n: int = steam.getNumLobbyMembers(lobby_id)
	if n >= 2:
		var guest := ""
		for i in n:
			var m: int = steam.getLobbyMemberByIndex(lobby_id, i)
			if m != steam.getSteamID():
				guest = steam.getFriendPersonaName(m)
		_show("ONLINE · GUEST CONNECTED", guest, ok_col)
	else:
		_show("ONLINE · CONNECTABLE", "friends can join from Steam (F9: invite)", ok_col)


func _show(t: String, d: String, c: Color) -> void:
	state = t
	detail = d
	label.text = "● " + t + ("\n   " + d if d != "" else "")
	label.add_theme_color_override("font_color", c)
