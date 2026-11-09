extends Node
## Настройки игры (autoload "Settings"). Хранятся в user://settings.cfg

signal changed

const PATH := "user://settings.cfg"
const KEYS := ["quality", "fps", "time_mode", "grid_lines", "vibration", "show_fps"]

var quality := 1        # 0 низкая, 1 средняя, 2 высокая
var fps := 60           # лимит кадров: 30 или 60
var time_mode := 0      # 0 цикл дня и ночи, 1 всегда день, 2 всегда ночь
var grid_lines := true  # светящаяся сетка на земле
var vibration := true   # вибрация при строительстве
var show_fps := false   # счётчик FPS


func _ready() -> void:
	load_settings()
	apply()


func apply() -> void:
	Engine.max_fps = fps


func set_value(key: String, value) -> void:
	set(key, value)
	apply()
	save_settings()
	changed.emit()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in KEYS:
		cfg.set_value("game", key, get(key))
	cfg.save(PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for key in KEYS:
		if cfg.has_section_key("game", key):
			set(key, cfg.get_value("game", key))
