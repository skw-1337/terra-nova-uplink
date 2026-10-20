# A stand-in for the GodotSteam singleton, for testing coop_net.gd without Steam (--fake-steam, live/test_coop_net.gd).
# Only what coop_net.gd uses: init, persona names, lobbies (create, join, leave, data, members, owner, invites), the old
# P2P API (sendP2PPacket / getAvailableP2PPacketSize / readP2PPacket per channel, session requests) and run_callbacks,
# with the same signal and dictionary shapes as GodotSteam 4.23.
# Every FakeSteam is one Steam user; users that share a Net see each other (one process: the test runs a host and a
# guest side by side). Net.loss drops that share of the packets: unreliable ones are gone, reliable ones come later
# (one more round trip per loss, still in order). Net.delay (s, one way) and Net.jitter apply to packets and lobby
# callbacks alike. Unreliable packets over 1200 bytes are refused (sendP2PPacket returns false), as by Steam.
extends RefCounted

signal lobby_created(connect: int, lobby_id: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_chat_update(lobby_id: int, changed_id: int, making_change_id: int, chat_state: int)
signal join_requested(lobby_id: int, friend_id: int)
signal p2p_session_request(remote_steam_id: int)

const UNRELIABLE_MAX := 1200
const RELIABLE_MAX := 1048576
const CHAT_ENTERED := 1              # EChatMemberStateChange
const CHAT_LEFT := 2
const ENTER_OK := 1                  # EChatRoomEnterResponse
const ENTER_DOESNT_EXIST := 2
const ENTER_FULL := 4


class Net:
	extends RefCounted
	var users := {}                  # steam id -> FakeSteam (weak: the users hold the net)
	var lobbies := {}                # lobby id -> {owner, members, max, data, joinable}
	var next_lobby := 109775240000000000
	var next_user := 76561190000000001
	var loss := 0.0
	var delay := 0.0
	var jitter := 0.0
	var rng := RandomNumberGenerator.new()
	var sent := 0                    # packets, for the tests
	var lost := 0
	var resent := 0
	var refused := 0

	func now() -> float:
		return Time.get_ticks_usec() / 1e6

	func user(id: int) -> Object:
		var w: WeakRef = users.get(id)
		return w.get_ref() if w else null

	func latency() -> float:
		return delay + (rng.randf() * jitter if jitter > 0.0 else 0.0)


var net: Net
var steam_id := 0
var persona := ""
var running := false
var callbacks := []                  # [due time, signal name, args]
var inbox := {}                      # channel -> [[due time, order, from, data]]
var accepted := {}                   # remote id -> true: its packets are read
var held := {}                       # remote id -> [[channel, packet]]: waiting for acceptP2PSessionWithUser
var asked := {}                      # remote id -> true: p2p_session_request already sent
var talked := {}                     # remote id -> true: we sent to it (Steam then accepts its packets)
var reliable_t := {}                 # [remote, channel] -> due time of our last reliable packet (keeps them in order)
var order := 0
var rich := {}
var invites := []                    # lobby ids activateGameOverlayInviteDialog was called with


func _init(net_: Net = null, name := "Fake player", id := 0) -> void:
	net = net_ if net_ else Net.new()
	steam_id = id if id else net.next_user
	net.next_user = maxi(net.next_user, steam_id) + 1
	persona = name
	net.users[steam_id] = weakref(self)


func steamInitEx(_app_id := 0, _embed_callbacks := false) -> Dictionary:
	running = true
	return {"status": 0, "verbal": "Fake Steam API initialized"}


func run_callbacks() -> void:
	var t := net.now()
	var due := []
	var keep := []
	for c in callbacks:
		(due if c[0] <= t else keep).append(c)
	callbacks = keep
	due.sort_custom(func(a, b): return a[0] < b[0])
	for c in due:
		callv("emit_signal", [c[1]] + c[2])


func _later(name: String, args: Array, after := -1.0) -> void:
	callbacks.append([net.now() + (net.latency() if after < 0.0 else after), name, args])


# --- users

func getSteamID() -> int:
	return steam_id


func getPersonaName() -> String:
	return persona


func getFriendPersonaName(id: int) -> String:
	var u: Object = net.user(id)
	return u.persona if u else ""


func setRichPresence(key: String, value: String) -> bool:
	rich[key] = value
	return true


func activateGameOverlayInviteDialog(lobby: int) -> void:
	invites.append(lobby)


# friends: every other user on the net is an online friend; one in a lobby plays app 480 with that lobby
func _friends() -> Array:
	var out := []
	for id in net.users:
		if id != steam_id and net.user(id):
			out.append(id)
	out.sort()
	return out


func getFriendCount(_flags := 4) -> int:
	return _friends().size()


func getFriendByIndex(i: int, _flags := 4) -> int:
	var f := _friends()
	return f[i] if i >= 0 and i < f.size() else 0


func getFriendPersonaState(id: int) -> int:
	return 1 if net.user(id) else 0


func getFriendGamePlayed(id: int) -> Dictionary:
	for l in net.lobbies:
		if id in net.lobbies[l]["members"]:
			return {"id": 480, "ip": "0.0.0.0", "game_port": 0, "query_port": 0, "lobby": l}
	return {"id": 480, "ip": "0.0.0.0", "game_port": 0, "query_port": 0, "lobby": 0} if net.user(id) else {}


# the host's Invite button: Steam shows the invite, the friend accepts it (join_requested on him)
func inviteUserToLobby(lobby: int, to: int) -> bool:
	invite(to, lobby)
	return true


# the test's side of "Join game" / an accepted invite: join_requested on `to`
func invite(to: int, lobby: int) -> void:
	var u: Object = net.user(to)
	if u:
		u._later("join_requested", [lobby, steam_id])


# --- lobbies

func createLobby(_type: int, max_members: int) -> void:
	var id := net.next_lobby
	net.next_lobby += 1
	net.lobbies[id] = {"owner": steam_id, "members": [steam_id], "max": max_members, "data": {}, "joinable": true}
	_later("lobby_created", [1, id])
	_later("lobby_joined", [id, 0, false, ENTER_OK])


func joinLobby(id: int) -> void:
	var l: Dictionary = net.lobbies.get(id, {})
	if l.is_empty() or not l["joinable"]:
		_later("lobby_joined", [id, 0, false, ENTER_DOESNT_EXIST])
		return
	if steam_id in l["members"]:
		_later("lobby_joined", [id, 0, false, ENTER_OK])
		return
	if l["members"].size() >= l["max"]:
		_later("lobby_joined", [id, 0, false, ENTER_FULL])
		return
	l["members"].append(steam_id)
	_later("lobby_joined", [id, 0, false, ENTER_OK])
	_tell(l, id, CHAT_ENTERED)


func leaveLobby(id: int) -> void:
	var l: Dictionary = net.lobbies.get(id, {})
	if l.is_empty() or not (steam_id in l["members"]):
		return
	l["members"].erase(steam_id)
	if l["members"].is_empty():
		net.lobbies.erase(id)
		return
	if l["owner"] == steam_id:
		l["owner"] = l["members"][0]                       # Steam hands the lobby to another member
	_tell(l, id, CHAT_LEFT)


func _tell(l: Dictionary, id: int, change: int) -> void:
	for m in l["members"]:
		var u: Object = net.user(m)
		if u and m != steam_id:
			u._later("lobby_chat_update", [id, steam_id, steam_id, change])


func setLobbyJoinable(id: int, joinable: bool) -> bool:
	var l: Dictionary = net.lobbies.get(id, {})
	if l.is_empty() or l["owner"] != steam_id:
		return false
	l["joinable"] = joinable
	return true


func setLobbyData(id: int, key: String, value: String) -> bool:
	var l: Dictionary = net.lobbies.get(id, {})
	if l.is_empty() or l["owner"] != steam_id:
		return false
	l["data"][key] = value
	return true


func getLobbyData(id: int, key: String) -> String:
	var l: Dictionary = net.lobbies.get(id, {})
	return str(l["data"].get(key, "")) if not l.is_empty() else ""


func getLobbyOwner(id: int) -> int:
	var l: Dictionary = net.lobbies.get(id, {})
	return int(l["owner"]) if not l.is_empty() else 0


func getNumLobbyMembers(id: int) -> int:
	var l: Dictionary = net.lobbies.get(id, {})
	return l["members"].size() if not l.is_empty() else 0


func getLobbyMemberByIndex(id: int, i: int) -> int:
	var l: Dictionary = net.lobbies.get(id, {})
	return int(l["members"][i]) if not l.is_empty() and i >= 0 and i < l["members"].size() else 0


# --- P2P (ISteamNetworking)

func sendP2PPacket(to: int, data: PackedByteArray, send_type: int, channel := 0) -> bool:
	var u: Object = net.user(to)
	var reliable := send_type >= 2                          # 0 / 1 unreliable (no delay), 2 / 3 reliable
	if not running or u == null or to == steam_id or data.size() > (RELIABLE_MAX if reliable else UNRELIABLE_MAX):
		net.refused += 1
		return false
	talked[to] = true
	net.sent += 1
	var due := net.now() + net.latency()
	if reliable:
		while net.loss > 0.0 and net.rng.randf() < net.loss:
			due += 2.0 * net.delay + 0.05                   # lost once: sent again a round trip later
			net.resent += 1
		var k := [to, channel]
		due = maxf(due, reliable_t.get(k, 0.0))
		reliable_t[k] = due
	elif net.loss > 0.0 and net.rng.randf() < net.loss:
		net.lost += 1
		return true
	u._arrive(steam_id, channel, data.duplicate(), due)
	return true


func _arrive(from: int, channel: int, data: PackedByteArray, due: float) -> void:
	order += 1
	var pk := [due, order, from, data]
	if accepted.has(from) or talked.has(from):
		_queue(channel, pk)
		return
	if not held.has(from):
		held[from] = []
	held[from].append([channel, pk])
	if not asked.has(from):
		asked[from] = true
		_later("p2p_session_request", [from], maxf(0.0, due - net.now()))


func _queue(channel: int, pk: Array) -> void:
	if not inbox.has(channel):
		inbox[channel] = []
	inbox[channel].append(pk)
	inbox[channel].sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))


func acceptP2PSessionWithUser(remote: int) -> bool:
	accepted[remote] = true
	for h in held.get(remote, []):
		_queue(h[0], h[1])
	held.erase(remote)
	return true


func closeP2PSessionWithUser(remote: int) -> bool:
	accepted.erase(remote)
	talked.erase(remote)
	asked.erase(remote)
	held.erase(remote)
	return true


func getAvailableP2PPacketSize(channel := 0) -> int:
	var q: Array = inbox.get(channel, [])
	if q.is_empty() or q[0][0] > net.now():
		return 0
	return q[0][3].size()


func readP2PPacket(packet_size: int, channel := 0) -> Dictionary:
	var q: Array = inbox.get(channel, [])
	if q.is_empty() or q[0][0] > net.now():
		return {}
	var pk: Array = q.pop_front()
	var data: PackedByteArray = pk[3]
	return {"data": data.slice(0, packet_size), "remote_steam_id": pk[2]}
