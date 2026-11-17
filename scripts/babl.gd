# The game's mission scripts: bytecode of Looking Glass's "babl" stack machine, in TNOVA\DATA\RESBABL2.RES.
# One module per compound resource (type 12): item 0 = its name (9 bytes) and a word, items 1.. = its functions.
# A mission's three functions (objectives, debriefing, "director" giving the groups their orders) are called by
# the module "do3d", which switches on the mission number. The debriefing's texts are the string table at the
# next resource id.
#
# What matters to read and to write it:
#   - a branch target is a 16-bit offset from the start of item 0 (so inside the whole module, not the function);
#   - a call to a script function is (resource id << 16) | function index, a call to one of the game's own
#     functions ("native") an index in the game's table and a count of arguments;
#   - arguments: the values are pushed in order, then one 0x29 each, then the call; the result is left on the stack;
#   - 0x7F nn nn is the source line, skipped by the machine (0x2E9FD4: add eax, 3 / ret).
# split() / join() take a module apart and put it back, walk() lists the instructions, lift() turns a function
# into statements with expression trees (each immediate keeps its place in the module, which is what an edit
# needs), Asm builds new code, shift() moves the branch targets when bytes are added or removed.
extends RefCounted

const OP_LINE := 0x7F
const OP_I8 := 0x01
const OP_I16 := 0x02
const OP_I32 := 0x03
const OP_STR := 0x0D
const OP_DROP := 0x0E
const OP_SET := 0x23
const OP_IFNOT := 0x24
const OP_CALL := 0x25
const OP_RET := 0x26
const OP_ENTER := 0x27
const OP_ARG := 0x29
const OP_NATIVE := 0x2A
const OP_CASE := 0x2B
const OP_GOTO := 0x2D
const OP_YIELD := 0x31
const OP_SAY := 0x36
const OP_MSG_WAIT := 0x3B
const OP_MSG_TYPE := 0x3C
const OP_MSG_FREE := 0x3D
const OP_HALT := 0x3E

# opcode -> length in bytes (the machine's table at 0x449100 has no other opcode)
const LEN := {
	0x7F: 3, 0x01: 2, 0x02: 3, 0x03: 5, 0x04: 3, 0x05: 3, 0x06: 3, 0x07: 3, 0x08: 3, 0x09: 3, 0x0A: 3, 0x0B: 3,
	0x0C: 2, 0x0D: 5, 0x0E: 1, 0x0F: 1, 0x10: 1, 0x11: 1, 0x12: 1, 0x13: 1, 0x14: 1, 0x15: 1, 0x16: 1, 0x17: 1,
	0x18: 1, 0x19: 1, 0x1A: 1, 0x1B: 1, 0x1C: 1, 0x1D: 1, 0x1E: 1, 0x1F: 1, 0x20: 1, 0x21: 1, 0x22: 1, 0x23: 1,
	0x24: 3, 0x25: 5, 0x26: 3, 0x27: 3, 0x29: 1, 0x2A: 4, 0x2B: 3, 0x2C: 3, 0x2D: 3, 0x2E: 5, 0x2F: 1, 0x30: 1,
	0x31: 1, 0x32: 1, 0x33: 1, 0x34: 1, 0x35: 3, 0x36: 1, 0x37: 2, 0x38: 1, 0x39: 2, 0x3A: 2, 0x3B: 2, 0x3C: 4,
	0x3D: 1, 0x3E: 1,
	0x40: 2, 0x41: 2, 0x42: 1, 0x43: 1, 0x44: 1, 0x45: 1, 0x46: 1, 0x48: 1, 0x49: 1, 0x4A: 1, 0x4B: 1,
	0x50: 2, 0x51: 1, 0x52: 1, 0x53: 1, 0x54: 1, 0x55: 1, 0x56: 1, 0x57: 2, 0x58: 1, 0x59: 1, 0x5A: 1, 0x5B: 1,
	0x5C: 1, 0x5D: 1, 0x5E: 1, 0x5F: 1, 0x60: 1, 0x61: 1, 0x62: 2, 0x68: 2, 0x69: 2,
}
# where an opcode keeps a branch target (offset of the u16 inside the instruction)
const TARGET := {0x24: 1, 0x2B: 1, 0x2C: 1, 0x2D: 1, 0x35: 1, 0x3C: 2}
# the interface opcodes (menus, pictures, text of the briefing rooms): [values popped, pushes one]
# (0x57 and 0x62 pop a number that depends on their operand; no mission script uses them)
const UI := {
	0x40: [4, false], 0x41: [2, false], 0x42: [1, false], 0x43: [1, false], 0x44: [2, false], 0x45: [4, false],
	0x46: [1, false], 0x48: [1, false], 0x49: [1, false], 0x4A: [1, false], 0x4B: [1, false], 0x50: [5, true],
	0x51: [1, false], 0x52: [4, false], 0x53: [4, false], 0x54: [1, false], 0x55: [1, false], 0x56: [1, false],
	0x58: [1, false], 0x59: [1, false], 0x5A: [1, false], 0x5B: [4, false], 0x5C: [1, false], 0x5D: [4, false],
	0x5E: [4, false], 0x5F: [4, false], 0x60: [3, false], 0x61: [3, false], 0x68: [1, false], 0x69: [1, false],
}
const BIN := {
	0x0F: "+", 0x10: "-", 0x11: "*", 0x12: "/", 0x13: "%", 0x14: "&", 0x15: "|", 0x16: "^", 0x17: "&&",
	0x18: "||", 0x19: "==", 0x1A: "!=", 0x1B: ">", 0x1C: ">=", 0x1D: "<", 0x1E: "<=",
}


# ---- a module <-> its items
# {"name": String, "frames": [PackedByteArray]} (frames[0] = the name item); empty when d is not a module
static func split(d: PackedByteArray) -> Dictionary:
	if d.size() < 6:
		return {}
	var n := d.decode_u16(0)
	if n < 1 or 2 + 4 * (n + 1) > d.size():
		return {}
	var frames := []
	var prev := d.decode_u32(2)
	if prev != 2 + 4 * (n + 1):
		return {}
	for k in n:
		var nxt := d.decode_u32(2 + 4 * (k + 1))
		if nxt < prev or nxt > d.size():
			return {}
		frames.append(d.slice(prev, nxt))
		prev = nxt
	var f0: PackedByteArray = frames[0]
	var name := ""
	for c in f0:
		if c == 0:
			break
		name += String.chr(c)
	return {"name": name, "frames": frames}


static func join(frames: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + 4 * (frames.size() + 1))
	out.encode_u16(0, frames.size())
	var off := out.size()
	for k in frames.size():
		out.encode_u32(2 + 4 * k, off)
		off += frames[k].size()
	out.encode_u32(2 + 4 * frames.size(), off)
	for f in frames:
		out.append_array(f)
	return out


# the offset of function fi in the module's own numbering (from the start of item 0)
static func base_of(frames: Array, fi: int) -> int:
	var o := 0
	for k in fi:
		o += frames[k].size()
	return o


# ---- the instructions of one function: [[offset in the function, opcode, length]]; null at an unknown opcode
# or when the last one runs past the end
static func walk(code: PackedByteArray):
	var out := []
	var pc := 0
	while pc < code.size():
		var op := code[pc]
		if not LEN.has(op):
			return null
		var n: int = LEN[op]
		if pc + n > code.size():
			return null
		out.append([pc, op, n])
		pc += n
	return out


# ---- bytes added (delta > 0) or removed (delta < 0) at module offset `at`: every branch target of the module
# at or after it moves. Call it BEFORE changing frames (the instructions are walked as they are).
# false: a function could not be read, or holds a table of targets (opcode 0x35), which is not handled.
static func shift(frames: Array, at: int, delta: int) -> bool:
	var todo := []
	for fi in range(1, frames.size()):
		var code: PackedByteArray = frames[fi]
		var ins = walk(code)
		if ins == null:
			return false
		for i in ins:
			if i[1] == 0x35:
				return false
			if TARGET.has(i[1]):
				var p: int = i[0] + TARGET[i[1]]
				var t := code.decode_u16(p)
				if t >= at:
					if t + delta < 0 or t + delta > 0xFFFF:
						return false
					todo.append([fi, p, t + delta])
	for t in todo:
		var code: PackedByteArray = frames[t[0]]
		code.encode_u16(t[1], t[2])
		frames[t[0]] = code
	return true


# ---- a function as statements. base = base_of(frames, fi): every "at" below is an offset in the module.
# Expressions: {"k": "imm", "v", "at" (of its bytes), "n" (their number)} | {"k": "g" / "loc" / "cv", "o"} a
# global, a local (o < 0: an argument), one of the game's variables | {"k": "&g" / "&loc" / "&cv", "o"} their
# address (the left side of a "set") | {"k": "msg", "t", "i"} a field of the waited message | {"k": "str", "res",
# "i"} | {"k": "bin", "op", "a", "b"} | {"k": "neg" / "not", "a"} | {"k": "idx", "a", "b"} | {"k": "nat", "i",
# "args", "at"} a call of the game's function i | {"k": "ret", "res", "f", "args"} the result of a script call |
# {"k": "spawn", "res", "f"} | {"k": "wake"} | {"k": "ui", "op"} | {"k": "?"}.
# Statements: {"at", "k", ...}: "enter" (n) | "drop" (e) | "set" (dst, e) | "ifnot" (e, to) | "case" (on, e, to) |
# "goto" (to) | "call" (res, f, args) | "ret" (n, e) | "msgtype" (t, to) | "msg_wait" | "msg_free" | "yield" |
# "halt" | "say" (ch, e) | "wait" (op, e) | "other" (op).
# Returns null when the function cannot be read.
static func lift(code: PackedByteArray, base: int):
	var ins = walk(code)
	if ins == null:
		return null
	var out := []
	var stack := []
	var args := []
	for i in ins:
		var pc: int = i[0]
		var op: int = i[1]
		var at := base + pc
		match op:
			0x7F:
				pass
			0x01:
				stack.append({"k": "imm", "v": code.decode_s8(pc + 1), "at": at + 1, "n": 1})
			0x02:
				stack.append({"k": "imm", "v": code.decode_s16(pc + 1), "at": at + 1, "n": 2})
			0x03:
				stack.append({"k": "imm", "v": code.decode_s32(pc + 1), "at": at + 1, "n": 4})
			0x04, 0x05:
				stack.append({"k": "g", "o": code.decode_u16(pc + 1)})
			0x06:
				stack.append({"k": "loc", "o": code.decode_s16(pc + 1)})
			0x07:
				stack.append({"k": "cv", "o": code.decode_u16(pc + 1)})
			0x08, 0x09:
				stack.append({"k": "&g", "o": code.decode_u16(pc + 1)})
			0x0A:
				stack.append({"k": "&loc", "o": code.decode_s16(pc + 1) & ~1})
			0x0B:
				stack.append({"k": "&cv", "o": code.decode_u16(pc + 1)})
			0x0C:
				stack.append({"k": "msg", "t": code[pc + 1] >> 5, "i": code[pc + 1] & 0x1F})
			0x0D:
				var v := code.decode_u32(pc + 1)
				stack.append({"k": "str", "res": v >> 16, "i": v & 0xFFFF, "at": at + 1})
			0x0E:
				out.append({"at": at, "k": "drop", "e": _pop(stack)})
			0x1F:
				stack.append({"k": "neg", "a": _pop(stack)})
			0x20:
				stack.append({"k": "not", "a": _pop(stack)})
			0x21, 0x22:
				var b = _pop(stack)
				var x = _pop(stack)
				stack.append({"k": "idx", "a": b, "b": x})
			0x23:
				var v = _pop(stack)
				var dst = _pop(stack)
				out.append({"at": at, "k": "set", "dst": dst, "e": v})
			0x24:
				out.append({"at": at, "k": "ifnot", "e": _pop(stack), "to": code.decode_u16(pc + 1)})
			0x25:
				var v := code.decode_u32(pc + 1)
				var a := args.duplicate()
				a.reverse()                         # (the 0x29s took them last pushed first)
				args.clear()
				out.append({"at": at, "k": "call", "res": v >> 16, "f": v & 0xFFFF, "args": a})
				stack.append({"k": "ret", "res": v >> 16, "f": v & 0xFFFF, "args": a})
			0x26:
				out.append({"at": at, "k": "ret", "n": code.decode_u16(pc + 1),
					"e": stack[-1] if not stack.is_empty() else {"k": "?"}})
				stack.clear()
			0x27:
				out.append({"at": at, "k": "enter", "n": code.decode_u16(pc + 1)})
			0x29:
				args.append(_pop(stack))
			0x2A:
				var argc := code[pc + 3]
				var av := []
				for _k in argc:
					av.append(args.pop_back() if not args.is_empty() else {"k": "?"})
				stack.append({"k": "nat", "i": code.decode_s16(pc + 1), "args": av, "at": at})
			0x2B, 0x2C:
				var v = _pop(stack)
				out.append({"at": at, "k": "case", "on": stack[-1] if not stack.is_empty() else {"k": "?"},
					"e": v, "to": code.decode_u16(pc + 1)})
			0x2D:
				out.append({"at": at, "k": "goto", "to": code.decode_u16(pc + 1)})
			0x2E:
				var v := code.decode_u32(pc + 1)
				stack.append({"k": "spawn", "res": v >> 16, "f": v & 0xFFFF})
			0x2F:
				var val = _pop(stack)
				var st = _pop(stack)
				var th = _pop(stack)
				out.append({"at": at, "k": "other", "op": op, "e": [th, st, val]})
			0x30:
				var arg = _pop(stack)
				var st = _pop(stack)
				out.append({"at": at, "k": "wait", "op": op, "e": st, "arg": arg})
				stack.append({"k": "wake"})
			0x31:
				out.append({"at": at, "k": "yield"})
			0x32, 0x33, 0x34:
				out.append({"at": at, "k": "wait", "op": op, "e": _pop(stack)})
				stack.append({"k": "wake"})
			0x35:
				out.append({"at": at, "k": "other", "op": op, "to": code.decode_u16(pc + 1)})
			0x36:
				var s = _pop(stack)
				var ch = _pop(stack)
				out.append({"at": at, "k": "say", "ch": ch, "e": s})
			0x37:
				out.append({"at": at, "k": "wait", "op": op, "e": _pop(stack) if code[pc + 1] else {"k": "?"}})
				stack.append({"k": "wake"})
			0x38:
				out.append({"at": at, "k": "other", "op": op})
			0x39:
				out.append({"at": at, "k": "other", "op": op, "e": _pop(stack), "field": code[pc + 1]})
			0x3A:
				var a1 = _pop(stack)
				var a2 = _pop(stack)
				out.append({"at": at, "k": "other", "op": op, "e": [a1, a2], "type": code[pc + 1]})
			0x3B:
				if code[pc + 1]:
					_pop(stack)
				out.append({"at": at, "k": "msg_wait"})
			0x3C:
				out.append({"at": at, "k": "msgtype", "t": code[pc + 1], "to": code.decode_u16(pc + 2)})
			0x3D:
				out.append({"at": at, "k": "msg_free"})
			0x3E:
				out.append({"at": at, "k": "halt"})
			_:
				if BIN.has(op):
					var b = _pop(stack)
					var x = _pop(stack)
					stack.append({"k": "bin", "op": BIN[op], "a": x, "b": b})
				elif UI.has(op):
					var e := []
					for _k in UI[op][0]:
						e.append(_pop(stack))
					if UI[op][1] or (op == 0x40 and (code[pc + 1] & 0x80)):
						stack.append({"k": "ui", "op": op})
					else:
						out.append({"at": at, "k": "other", "op": op, "e": e})
				else:
					out.append({"at": at, "k": "other", "op": op})
	return out


static func _pop(stack: Array):
	return stack.pop_back() if not stack.is_empty() else {"k": "?"}


# every node of an expression (itself first), to look for calls and immediates
static func nodes(e, out: Array) -> void:
	if e is Array:
		for x in e:
			nodes(x, out)
		return
	if not (e is Dictionary):
		return
	out.append(e)
	for key in ["a", "b", "args", "e"]:
		if e.has(key):
			nodes(e[key], out)


# every expression node of a statement
static func stmt_nodes(s: Dictionary) -> Array:
	var out := []
	for key in ["e", "dst", "args", "on", "ch", "arg"]:
		if s.has(key):
			nodes(s[key], out)
	return out


# a readable form, for the tests and for "custom logic" notes
static func text(e, names: Dictionary = {}) -> String:
	if e is Array:
		var parts := PackedStringArray()
		for x in e:
			parts.append(text(x, names))
		return ", ".join(parts)
	if not (e is Dictionary):
		return str(e)
	match e["k"]:
		"imm":
			return str(e["v"])
		"g":
			return "g_%x" % e["o"]
		"&g":
			return "g_%x" % e["o"]
		"loc", "&loc":
			var o: int = e["o"]
			return ("a%d" % ((-o - 12) / 4)) if o < 0 else ("loc%d" % (o / 4))
		"cv", "&cv":
			return names.get("cv%d" % e["o"], "cvar%d" % e["o"])
		"msg":
			return "msg.f%d_%d" % [e["t"], e["i"]]
		"str":
			return "S%d[%d]" % [e["res"], e["i"]]
		"bin":
			return "(%s %s %s)" % [text(e["a"], names), e["op"], text(e["b"], names)]
		"neg":
			return "-(%s)" % text(e["a"], names)
		"not":
			return "!(%s)" % text(e["a"], names)
		"idx":
			return "%s[%s]" % [text(e["a"], names), text(e["b"], names)]
		"nat":
			return "%s(%s)" % [names.get("fn%d" % e["i"], "fn%d" % e["i"]), text(e["args"], names)]
		"ret":
			return "call %d.%d(%s)" % [e["res"], e["f"], text(e["args"], names)]
		"spawn":
			return "spawn(%d.%d)" % [e["res"], e["f"]]
		"wake":
			return "wakeval"
	return "?"


# ---- building code. Offsets are those of the module: give the function's base (base_of) when it is known,
# or build with base 0 and call rebase() once it is.
class Asm:
	extends RefCounted
	var code := PackedByteArray()
	var base := 0
	var labels := {}       # name -> offset in the function
	var fixups := []       # [offset of the u16 in the function, label]

	func _init(b: int = 0) -> void:
		base = b

	func here() -> int:
		return code.size()

	func label(name: String) -> void:
		labels[name] = code.size()

	func raw(b: PackedByteArray) -> void:
		code.append_array(b)

	func _u16(v: int) -> void:
		code.append(v & 0xFF)
		code.append((v >> 8) & 0xFF)

	func _u32(v: int) -> void:
		_u16(v & 0xFFFF)
		_u16((v >> 16) & 0xFFFF)

	func _target(name: String) -> void:
		fixups.append([code.size(), name])
		_u16(0)

	# an immediate, in the smallest form the compiler would use
	func imm(v: int) -> void:
		if v >= -128 and v <= 127:
			code.append(0x01)
			code.append(v & 0xFF)
		elif v >= -32768 and v <= 32767:
			code.append(0x02)
			_u16(v)
		else:
			code.append(0x03)
			_u32(v)

	func enter(locals_bytes: int) -> void:
		code.append(0x27)
		_u16(locals_bytes)

	func local(off: int) -> void:
		code.append(0x06)
		_u16(off)

	func cvar(i: int) -> void:
		code.append(0x07)
		_u16(i)

	func msg_field(t: int, i: int) -> void:
		code.append(0x0C)
		code.append((t << 5) | (i & 0x1F))

	func string(res: int, i: int) -> void:
		code.append(0x0D)
		_u32((res << 16) | i)

	func op(o: int) -> void:
		code.append(o)

	# dst = value: set_begin, the value's code, set_end
	func set_local(off: int) -> void:
		code.append(0x0A)
		_u16(off)

	func set_global(off: int) -> void:
		code.append(0x08)
		_u16(off)

	func set_cvar(i: int) -> void:
		code.append(0x0B)
		_u16(i)

	func store() -> void:
		code.append(0x23)

	# the game's function i with constant arguments; its result stays on the stack
	func native(i: int, a: Array = []) -> void:
		for v in a:
			imm(v)
		for _k in a.size():
			code.append(0x29)
		code.append(0x2A)
		_u16(i)
		code.append(a.size())

	# a script function (resource id, function index) with constant arguments; its result stays on the stack
	func call_script(res: int, f: int, a: Array = []) -> void:
		for v in a:
			imm(v)
		for _k in a.size():
			code.append(0x29)
		code.append(0x25)
		_u32((res << 16) | f)

	func drop() -> void:
		code.append(0x0E)

	func ifnot(name: String) -> void:
		code.append(0x24)
		_target(name)

	func goto(name: String) -> void:
		code.append(0x2D)
		_target(name)

	func case_not(name: String) -> void:
		code.append(0x2B)
		_target(name)

	func msg_wait() -> void:
		code.append(0x3B)
		code.append(0)

	func msg_type_not(t: int, name: String) -> void:
		code.append(0x3C)
		code.append(t)
		_target(name)

	func ret(arg_bytes: int = 0) -> void:
		imm(0)
		code.append(0x26)
		_u16(arg_bytes)

	# the finished function; empty when a label is missing or a target does not fit
	func done() -> PackedByteArray:
		var out := code.duplicate()
		for f in fixups:
			if not labels.has(f[1]):
				return PackedByteArray()
			var t: int = base + labels[f[1]]
			if t > 0xFFFF:
				return PackedByteArray()
			out.encode_u16(f[0], t)
		return out
