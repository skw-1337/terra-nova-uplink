# Test of scripts/coop_net.gd without Steam: a host and a guest coop_net in one process over scripts/fake_steam.gd,
# the host bridge simulated by live/coop_net_sim_bridge.py (coop_view.py messages to the host's port 47841). This
# script plays the rest: the bridge's coop port (47834: guest input, 'R' relayed to the simulator), the guest's
# viewer (live port 47831, play port: here 47844) and the guest's coop_hud.gd (47832). Checks: the host's lobby, a
# guest turned away by a host with another coop version, a guest with another version (and one that never says
# HELLO) whose input stays out of the bridge, a late guest (HELLO, peer_ok, 'R', views rebuilt on its live port,
# HUD packets, mission name, input), the guest's own 'R', 20% loss, the guest leaving and coming back, the host
# leaving.
#   godot --headless --path . --script res://live/test_coop_net.gd     (PYTHON: the python to run, else python3)
extends SceneTree

const FakeSteam := preload("res://scripts/fake_steam.gd")
const CoopNet := preload("res://scripts/coop_net.gd")
const CoopView := preload("res://scripts/coop_view.gd")
const BRIDGE_IN := 47834             # the bridge's coop port: coop_net.gd's input_out
const LIVE := 47831
const HUD := 47832
const PLAY := 47844                  # the guest's play port (47834 is the bridge's here: one machine)
const CTL := 47851                   # the simulator's control port
const CH_INPUT := 1


class Viewer:
	extends Node
	var current := {}
	var loaded: Array[String] = []

	func _load_by_label(t: String) -> void:
		loaded.append(t)
		current = {"entry": {"file": t}}


var net: FakeSteam.Net
var hs: FakeSteam                    # the host's Steam user
var gs: FakeSteam                    # the guest's
var host: CoopNet
var guest: CoopNet
var host_vp: Viewer
var guest_vp: Viewer
var bridge_in := PacketPeerUDP.new()
var live := PacketPeerUDP.new()
var hud := PacketPeerUDP.new()
var play := PacketPeerUDP.new()
var ctl := PacketPeerUDP.new()
var sim_pid := -1
var sim_out := ""
var t0 := 0.0
var inputs := []                     # [t, packet, host peer_ok then] at the bridge's coop port (not 'R')
var resyncs := []                    # t of each 'R' at the bridge's coop port
var views := []                      # [t, md5] on the guest's live port
var huds := []                       # [t, hex] on the guest's HUD port
var results := []                    # [ok, name, detail]


func now() -> float:
	return Time.get_ticks_usec() / 1e6 - t0


func _initialize() -> void:
	t0 = Time.get_ticks_usec() / 1e6
	Engine.max_fps = 120
	_run()


func _process(_delta: float) -> bool:
	while bridge_in.get_available_packet_count() > 0:
		var pk := bridge_in.get_packet()
		if pk.size() == 1 and pk[0] == 82:                 # 'R': to the simulator, as the bridge would apply it
			resyncs.append([now()])
			ctl.put_packet(pk)
		else:
			inputs.append([now(), pk, host.peer_ok if host else false])
	while live.get_available_packet_count() > 0:
		views.append([now(), _md5(live.get_packet())])
	while hud.get_available_packet_count() > 0:
		huds.append([now(), hud.get_packet().hex_encode()])
	return false


func _md5(b: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(b)
	return h.finish().hex_encode()


func check(ok: bool, name: String, detail := "") -> void:
	results.append([ok, name, detail])
	print(("  ok    " if ok else "  FAIL  ") + name + ("   (" + detail + ")" if detail != "" else ""))


func wait(s: float) -> void:
	await create_timer(s).timeout


func until(cond: Callable, limit: float) -> float:
	var start := now()
	while not cond.call() and now() - start < limit:
		await process_frame
	return now() - start


func count(a: Array, from: float, to := 1e9) -> int:
	var n := 0
	for e in a:
		if e[0] >= from and e[0] < to:
			n += 1
	return n


func input_pk(tag: int, k: int) -> PackedByteArray:
	var pk := PackedByteArray([tag, 0, 0, 0])
	pk.encode_u16(1, 30 + k % 20)                           # K: scan code, down; M: dx, dy as the viewer would
	pk[3] = k & 1
	return pk


func send_input(tag: int, k: int) -> void:
	play.put_packet(input_pk(tag, k))


func got_input(tag: int, from: float, to := 1e9) -> int:
	var n := 0
	for e in inputs:
		if e[0] >= from and e[0] < to and e[1].size() > 0 and e[1][0] == tag:
			n += 1
	return n


func _run() -> void:
	print("coop_net.gd over fake Steam")
	bridge_in.bind(BRIDGE_IN, "127.0.0.1")
	live.bind(LIVE, "127.0.0.1")
	hud.bind(HUD, "127.0.0.1")
	play.set_dest_address("127.0.0.1", PLAY)
	ctl.set_dest_address("127.0.0.1", CTL)
	sim_out = ProjectSettings.globalize_path("user://coop_net_sim.txt")
	var py := OS.get_environment("PYTHON")
	if py == "":
		py = "python" if OS.get_name() == "Windows" else "python3"
	sim_pid = OS.create_process(py, [ProjectSettings.globalize_path("res://live/coop_net_sim_bridge.py"),
		"--out", sim_out, "--seconds", "90", "--ctl", str(CTL)])
	if sim_pid <= 0:
		check(false, "bridge simulator started", py)
		_end()
		return

	net = FakeSteam.Net.new()
	net.delay = 0.04
	net.jitter = 0.02
	net.rng.seed = 7
	hs = FakeSteam.new(net, "Host player")
	gs = FakeSteam.new(net, "Guest player")
	host_vp = Viewer.new()
	host_vp.current = {"entry": {"file": "C:/TN/MISSIONS/M07.MIS"}}
	guest_vp = Viewer.new()
	host = CoopNet.new()
	host.role = "host"
	host.fake_steam = hs
	guest = CoopNet.new()
	guest.role = "guest"
	guest.fake_steam = gs
	guest.play_in = PLAY
	root.add_child(host_vp)
	root.add_child(guest_vp)
	host_vp.add_child(host)
	guest_vp.add_child(guest)

	# --- the host's lobby
	await until(func(): return host.lobby_id != 0, 2.0)
	check(host.lobby_id != 0 and hs.getLobbyData(host.lobby_id, "coop_version") == CoopNet.COOP_VERSION,
		"host opens a lobby with coop_version", "lobby %d, version '%s'" % [host.lobby_id, hs.getLobbyData(host.lobby_id, "coop_version")])
	check(hs.rich.get("connect", "") == "+connect_lobby %d" % host.lobby_id, "host's rich presence: +connect_lobby")
	check(guest.peer == 0 and guest.wait_panel.visible, "guest waits for an invite")

	# --- the friends lists that replace Steam's overlay: the host's Invite buttons, the guest's JOIN on the host
	var row_btn := func(cn, who: String) -> Button:
		for h in cn.friends_box.get_children():
			if h is HBoxContainer and h.get_child(1).text == who:   # status dot, name, button
				return h.get_child(2)
		return null
	await until(func(): return row_btn.call(host, "Guest player") != null and row_btn.call(guest, "Host player") != null, 5.0)
	var inv: Button = row_btn.call(host, "Guest player")
	var join: Button = row_btn.call(guest, "Host player")
	check(host.friends_panel.visible and inv != null and inv.text == "Invite", "host: the guest in INVITE A FRIEND")
	check(guest.friends_panel.visible and join != null and join.text == "JOIN", "guest: the host in FRIENDS HOSTING A GAME")
	host.friends_search.text = "zzz"
	host.friends_search.text_changed.emit("zzz")
	await wait(0.2)
	var none_left: bool = row_btn.call(host, "Guest player") == null
	host.friends_search.text = "gues"
	host.friends_search.text_changed.emit("gues")
	await wait(0.2)
	check(none_left and row_btn.call(host, "Guest player") != null, "host: the search filters the friends list")
	host.friends_search.text = ""
	host.friends_search.text_changed.emit("")

	# --- a host with another coop version: the guest leaves its lobby
	var old_host := FakeSteam.new(net, "Old host")
	old_host.steamInitEx()
	old_host.createLobby(1, 2)
	var old_lobby := 0
	for id in net.lobbies:
		if net.lobbies[id]["owner"] == old_host.steam_id:
			old_lobby = id
	old_host.setLobbyData(old_lobby, "coop_version", "2")
	old_host.invite(gs.steam_id, old_lobby)
	await until(func(): return guest.version_msg != "", 2.0)
	check(guest.version_msg.contains("host 2") and guest.peer == 0 and guest.lobby_id == 0, "guest turned away by a host with another version",
		guest.version_msg)
	check(old_host.getNumLobbyMembers(old_lobby) == 1, "guest left that lobby", "%d members" % old_host.getNumLobbyMembers(old_lobby))
	old_host.leaveLobby(old_lobby)

	# --- guests the host must not listen to: one that never says HELLO, one with another version
	var old_guest := FakeSteam.new(net, "Old guest")
	old_guest.steamInitEx()
	old_guest.joinLobby(host.lobby_id)
	await until(func(): return host.peer == old_guest.steam_id, 2.0)
	check(host.peer == old_guest.steam_id, "host sees a guest join (lobby_chat_update)")
	var t_old := now()
	for k in 5:
		old_guest.sendP2PPacket(hs.steam_id, input_pk(75, k), 2, CH_INPUT)
	await wait(0.5)
	check(not host.peer_hello and got_input(75, t_old) == 0, "no HELLO yet: its input stays out of the bridge", "%d at the bridge" % got_input(75, t_old))
	old_guest.sendP2PPacket(hs.steam_id, "HELLO2".to_ascii_buffer(), 2, CH_INPUT)
	for k in 5:
		old_guest.sendP2PPacket(hs.steam_id, input_pk(75, k), 2, CH_INPUT)
		old_guest.sendP2PPacket(hs.steam_id, "R".to_ascii_buffer(), 2, CH_INPUT)
	await wait(0.6)
	check(host.peer_hello and not host.peer_ok, "HELLO2: host knows the guest has another version", host.label.text.replace("\n", " "))
	check(got_input(75, t_old) == 0 and count(resyncs, t_old) == 0, "... and keeps its input and 'R' out of the bridge",
		"%d input, %d R" % [got_input(75, t_old), count(resyncs, t_old)])
	old_guest.run_callbacks()
	check(old_guest.getAvailableP2PPacketSize(0) == 0, "... and sends it no view", "%d bytes waiting" % old_guest.getAvailableP2PPacketSize(0))
	old_guest.leaveLobby(host.lobby_id)
	await until(func(): return host.peer == 0, 2.0)
	check(host.peer == 0 and not host.peer_hello and host.label.text.contains("CONNECTABLE"), "that guest leaves: host connectable again")

	# --- the guest joins late (the bridge has been sending for a few seconds)
	await wait(maxf(0.0, 4.0 - now()))
	var t_join := now()
	hs.invite(gs.steam_id, host.lobby_id)
	var took := await until(func(): return host.peer_ok and guest.peer != 0, 4.0)
	check(guest.lobby_id == host.lobby_id and guest.peer == hs.steam_id and host.peer == gs.steam_id, "guest joins the host's lobby",
		"%.2f s" % took)
	check(host.peer_ok and host.peer_hello, "HELLO3: peer_ok on the host", host.label.text.replace("\n", " "))
	await until(func(): return count(resyncs, t_join) > 0, 2.0)
	check(count(resyncs, t_join) > 0, "host asks the bridge for decor and keyframe ('R')", "%d" % count(resyncs, t_join))
	await until(func(): return count(views, t_join) > 0, 4.0)
	var t_view := now()
	check(count(views, t_join) > 0, "late guest: view rebuilt on its live port", "first after %.2f s" % (t_view - t_join))
	await wait(3.0)
	var rate := count(views, t_view, t_view + 3.0) / 3.0
	check(rate > 16.0, "views on the guest's live port, no loss", "%.1f a second (20 sent)" % rate)
	check(not guest.wait_panel.visible and guest.label.text.contains("CONNECTED TO HOST"), "guest shows connected, no waiting screen",
		guest.label.text.replace("\n", " "))
	check(count(huds, t_join) >= 4, "GHD packets on the guest's 47832", "%d in %.1f s" % [count(huds, t_join), now() - t_join])
	check(guest_vp.loaded.has("M07.MIS"), "guest loads the host's mission (MSN)", str(guest_vp.loaded))

	# --- the guest's input, to the bridge (peer_ok)
	var t_in := now()
	for k in 20:
		send_input(75, k)                                   # K: reliable
		send_input(77, k)                                   # M: unreliable
		await wait(0.02)
	await wait(0.5)
	check(got_input(75, t_in) == 20 and got_input(77, t_in) == 20, "guest input reaches the bridge",
		"K %d / 20, M %d / 20" % [got_input(75, t_in), got_input(77, t_in)])
	var early := 0
	for e in inputs:
		var pk: PackedByteArray = e[1]
		var release := (pk[0] == 75 and pk[3] == 0) or (pk[0] == 66 and pk[2] == 0) or (pk[0] == 80 and pk.slice(1).count(0) == pk.size() - 1)
		if not e[2] and not release:                    # the host lets go of a leaving guest's keys: allowed
			early += 1
	check(early == 0, "no input at the bridge before peer_ok", "%d" % early)

	# --- the guest's own 'R': its decor table lost (a new decoder), it must ask again
	var r_before := count(resyncs, 0.0)
	guest.view = CoopView.new()
	var t_r := now()
	await until(func(): return count(views, t_r + 0.1) > 0 and guest.view.decor_ok, 4.0)
	check(count(resyncs, t_r) > 0 and guest.view.decor_ok and count(views, t_r + 0.1) > 0, "guest without the decor asks 'R' and gets it",
		"%d R, %.2f s" % [count(resyncs, 0.0) - r_before, now() - t_r])

	# --- 20% loss
	net.loss = 0.2
	var lost0 := net.lost
	var t_loss := now()
	for k in 60:
		send_input(75, k)
		send_input(77, k)
		await wait(0.1)
	var t_loss_end := now()
	net.loss = 0.0
	await wait(1.0)
	var lrate := count(views, t_loss + 0.5, t_loss_end) / (t_loss_end - t_loss - 0.5)
	check(lrate > 8.0, "views with 20% loss", "%.1f a second, %d unreliable packets lost" % [lrate, net.lost - lost0])
	check(got_input(75, t_loss) == 60, "keys (reliable) all arrive with 20% loss", "%d / 60" % got_input(75, t_loss))
	var m := got_input(77, t_loss)
	check(m >= 35 and m < 60, "mouse (unreliable) about 80% with 20% loss", "%d / 60" % m)
	check(host.peer_ok and guest.peer == hs.steam_id, "still connected after the loss")
	var t_after := now()
	await wait(1.0)
	check(count(views, t_after) >= 15, "views back to full rate", "%d in 1 s" % count(views, t_after))

	# --- the guest leaves (window closed) and comes back
	gs.leaveLobby(host.lobby_id)
	await until(func(): return host.peer == 0, 2.0)
	check(host.peer == 0 and not host.peer_ok and host.label.text.contains("CONNECTABLE"), "guest gone: host connectable again")
	var t_back := now()
	hs.invite(gs.steam_id, host.lobby_id)
	await until(func(): return host.peer_ok and count(views, t_back + 0.3) > 0, 5.0)
	check(host.peer_ok and count(views, t_back + 0.3) > 0, "guest comes back: peer_ok and views again", "%.2f s" % (now() - t_back))

	# --- the host leaves
	hs.leaveLobby(host.lobby_id)
	await until(func(): return guest.peer == 0, 2.0)
	await wait(0.5)
	check(guest.peer == 0 and guest.lobby_id == 0 and guest.wait_panel.visible, "host gone: the guest waits for an invite again",
		"peer %d, lobby %d, %s" % [guest.peer, guest.lobby_id, guest.label.text.replace("\n", " ")])

	# --- every view the guest rebuilt is one the bridge's lossless decoder made; every HUD packet is the bridge's
	ctl.put_packet("Q".to_ascii_buffer())
	await wait(0.5)
	var ref_views := {}
	var ref_huds := {}
	var f := FileAccess.open(sim_out, FileAccess.READ)
	while f and not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("V "):
			ref_views[line.substr(2)] = true
		elif line.begins_with("H "):
			ref_huds[line.substr(2)] = true
	var wrong := 0
	for v in views:
		if not ref_views.has(v[1]):
			wrong += 1
	check(views.size() > 0 and wrong == 0, "every rebuilt view is the host's (byte for byte)", "%d views, %d wrong" % [views.size(), wrong])
	wrong = 0
	for h in huds:
		if not ref_huds.has(h[1]):
			wrong += 1
	check(huds.size() > 0 and wrong == 0, "every GHD packet as the bridge sent it", "%d, %d wrong" % [huds.size(), wrong])
	_end()


func _end() -> void:
	if sim_pid > 0 and OS.is_process_running(sim_pid):
		OS.kill(sim_pid)
	var bad := 0
	for r in results:
		if not r[0]:
			bad += 1
	print("%d / %d passed" % [results.size() - bad, results.size()])
	print("FAILED" if bad or results.is_empty() else "OK")
	for n in [host_vp, guest_vp]:
		if n:
			n.queue_free()
	quit(1 if bad or results.is_empty() else 0)
