extends Node
## Состояние игры (autoload "GameState"): деньги, город, уровни зданий, доход, сохранение.

signal money_changed
signal cell_changed(cell: Vector2i)
signal city_reset

const GRID := 12
const SAVE_PATH := "user://save.json"
const OFFLINE_CAP := 7200.0  # максимум 2 часа дохода в офлайне
const REFUND := 0.5          # при сносе возвращается 50% цены здания
const MAX_LEVEL := 3
const LEVEL_MULT := [1.0, 2.2, 4.5]

const ORDER := ["house", "shop", "factory", "power", "tower"]
const BUILDINGS := {
	"house":   {"name": "Дом",       "cost": 100,  "income": 2.0,   "color": Color("#4fc3f7")},
	"shop":    {"name": "Магазин",   "cost": 250,  "income": 6.0,   "color": Color("#ffb74d")},
	"factory": {"name": "Завод",     "cost": 600,  "income": 16.0,  "color": Color("#ba68c8")},
	"power":   {"name": "Станция",   "cost": 1200, "income": 35.0,  "color": Color("#81c784")},
	"tower":   {"name": "Небоскрёб", "cost": 3000, "income": 100.0, "color": Color("#ff4081")},
}

var money := 500.0
var cells := {}   # Vector2i -> String (id здания)
var levels := {}  # Vector2i -> int (уровень, по умолчанию 1)

var offline_gain := 0.0  # сколько заработано, пока игра была закрыта

var _tick := 0.0
var _save_timer := 0.0


func _ready() -> void:
	load_game()


func _process(delta: float) -> void:
	_tick += delta
	if _tick >= 1.0:
		var n := floorf(_tick)
		_tick -= n
		money += income_per_sec() * n
		money_changed.emit()
	_save_timer += delta
	if _save_timer >= 10.0:
		_save_timer = 0.0
		save_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save_game()


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID and c.y < GRID


func level_of(c: Vector2i) -> int:
	return int(levels.get(c, 1))


func income_of(c: Vector2i) -> float:
	return float(BUILDINGS[cells[c]]["income"]) * float(LEVEL_MULT[level_of(c) - 1])


func income_per_sec() -> float:
	var total := 0.0
	for c in cells:
		total += income_of(c)
	return total


func upgrade_cost(c: Vector2i) -> int:
	return int(float(BUILDINGS[cells[c]]["cost"]) * 1.5 * float(level_of(c)))


## Все три метода возвращают "" при успехе, иначе текст ошибки.
func build(c: Vector2i, id: String) -> String:
	if not in_bounds(c):
		return "Вне карты"
	if cells.has(c):
		return "Клетка занята"
	var cost: float = BUILDINGS[id]["cost"]
	if money < cost:
		return "Не хватает денег"
	money -= cost
	cells[c] = id
	levels.erase(c)
	money_changed.emit()
	cell_changed.emit(c)
	return ""


func upgrade(c: Vector2i) -> String:
	if not cells.has(c):
		return "Здесь нет здания"
	var lvl := level_of(c)
	if lvl >= MAX_LEVEL:
		return "Максимальный уровень"
	var cost := upgrade_cost(c)
	if money < cost:
		return "Не хватает денег"
	money -= cost
	levels[c] = lvl + 1
	money_changed.emit()
	cell_changed.emit(c)
	return ""


func demolish(c: Vector2i) -> void:
	if not cells.has(c):
		return
	money += floorf(float(BUILDINGS[cells[c]]["cost"]) * REFUND)
	cells.erase(c)
	levels.erase(c)
	money_changed.emit()
	cell_changed.emit(c)


func reset() -> void:
	money = 500.0
	cells.clear()
	levels.clear()
	money_changed.emit()
	city_reset.emit()
	save_game()


func save_game() -> void:
	var data := {"money": money, "time": Time.get_unix_time_from_system(), "cells": {}}
	for c in cells:
		data["cells"]["%d,%d" % [c.x, c.y]] = {"id": cells[c], "lvl": level_of(c)}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return
	money = float(data.get("money", money))
	cells.clear()
	levels.clear()
	var saved: Dictionary = data.get("cells", {})
	for key in saved:
		var parts: PackedStringArray = str(key).split(",")
		if parts.size() != 2:
			continue
		var entry = saved[key]
		var id := ""
		var lvl := 1
		if typeof(entry) == TYPE_DICTIONARY:  # новый формат
			id = str(entry.get("id", ""))
			lvl = clampi(int(entry.get("lvl", 1)), 1, MAX_LEVEL)
		else:                                  # формат версии 0.1
			id = str(entry)
		if BUILDINGS.has(id):
			var c := Vector2i(int(parts[0]), int(parts[1]))
			cells[c] = id
			if lvl > 1:
				levels[c] = lvl
	var elapsed := clampf(Time.get_unix_time_from_system() - float(data.get("time", 0)), 0.0, OFFLINE_CAP)
	offline_gain = elapsed * income_per_sec()
	money += offline_gain
