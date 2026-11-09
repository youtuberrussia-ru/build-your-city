extends Node3D
## NEON DISTRICT: 3D-город. Камера, здания, день и ночь, интерфейс, настройки.

const CELL := 2.0
const CYCLE := 180.0  # секунд на полные сутки
const DEMOLISH := "demolish"
const UPGRADE := "upgrade"
const QUALITY_NAMES := ["Низкое", "Среднее", "Высокое"]
const TIME_NAMES := ["Цикл дня и ночи", "Всегда день", "Всегда ночь"]

# w: ширина здания (доля клетки), h: высота в метрах
const SPECS := {
	"house":   {"w": 0.62, "h": 1.4},
	"shop":    {"w": 0.72, "h": 1.1},
	"factory": {"w": 0.78, "h": 1.6},
	"power":   {"w": 0.74, "h": 2.0},
	"tower":   {"w": 0.58, "h": 5.0},
}

# Шейдер стен: тёмный корпус + светящиеся окна, ночью горят ярче.
const SHADER_CODE := """
shader_type spatial;
uniform vec3 body_color : source_color = vec3(0.1, 0.1, 0.2);
uniform vec3 window_color : source_color = vec3(1.0, 0.9, 0.5);
uniform float night = 0.0;
uniform float density = 4.0;
varying vec3 lpos;
varying vec3 lnorm;
void vertex() {
	lpos = VERTEX;
	lnorm = NORMAL;
}
void fragment() {
	ALBEDO = body_color;
	ROUGHNESS = 0.6;
	vec2 g = vec2((lpos.x + lpos.z) * density, lpos.y * density);
	vec2 cell = floor(g);
	vec2 f = fract(g);
	float win = step(0.2, f.x) * step(f.x, 0.8) * step(0.25, f.y) * step(f.y, 0.75);
	float side = 1.0 - step(0.5, abs(lnorm.y));
	float h = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
	float lit = step(0.35, h);
	EMISSION = window_color * win * side * lit * (0.15 + 0.85 * night) * 1.5;
}
"""

# --- мир ---
var camera: Camera3D
var sun: DirectionalLight3D
var env: Environment
var grid_node: MeshInstance3D
var grid_mat: StandardMaterial3D
var marker: MeshInstance3D
var marker_tween: Tween
var buildings_root: Node3D
var buildings := {}  # Vector2i -> Node3D
var _building_shader: Shader
var _emissive_cache := {}

# --- камера ---
var focus := Vector3.ZERO
var yaw := 0.6
var pitch := 55.0
var dist := 26.0

# --- время суток ---
var clock := 0.2
var sun_h := 0.95
var _night := 0.0
var _mat_t := 0.0
var _fps_t := 0.0

# --- ввод ---
var pressing := false
var dragging := false
var pinching := false
var press_pos := Vector2.ZERO
var touches := {}
var pinch_dist := 0.0
var twist_angle := 0.0

# --- интерфейс ---
var tool: String = "house"
var money_label: Label
var income_label: Label
var fps_label: Label
var toast_label: Label
var toast_tween: Tween
var settings_layer: Control
var s_buttons := {}
var reset_button: Button
var _reset_armed := false


func _ready() -> void:
	_building_shader = Shader.new()
	_building_shader.code = SHADER_CODE
	_build_world()
	_build_ui()
	GameState.money_changed.connect(_update_hud)
	GameState.cell_changed.connect(_on_cell_changed)
	GameState.city_reset.connect(_rebuild_all)
	Settings.changed.connect(_on_settings_changed)
	_on_settings_changed()
	_rebuild_all()
	_update_environment()
	_update_camera()
	_update_hud()
	if GameState.offline_gain >= 1.0:
		_toast("Пока вас не было: +%s $" % _fmt(GameState.offline_gain), Color("#00e5ff"), 3.0)
	elif GameState.cells.is_empty():
		_toast("Выберите здание и коснитесь клетки", Color("#00e5ff"), 3.0)


# ====================== МИР ======================

func _build_world() -> void:
	var size := GameState.GRID * CELL

	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 50.0
	add_child(sun)

	# земля
	var ground := MeshInstance3D.new()
	var gbox := BoxMesh.new()
	gbox.size = Vector3(size, 0.4, size)
	ground.mesh = gbox
	ground.position = Vector3(size / 2.0, -0.2, size / 2.0)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color("#161634")
	gmat.roughness = 0.9
	ground.material_override = gmat
	add_child(ground)

	# тёмная площадка вокруг карты
	var apron := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300, 300)
	apron.mesh = pm
	apron.position = Vector3(size / 2.0, -0.41, size / 2.0)
	var amat := StandardMaterial3D.new()
	amat.albedo_color = Color("#0d0d20")
	amat.roughness = 1.0
	apron.material_override = amat
	add_child(apron)

	# неоновая сетка
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := 0.03
	var y := 0.02
	for i in range(GameState.GRID + 1):
		var p := i * CELL
		_quad(st, Vector3(p - hw, y, 0), Vector3(p + hw, y, 0), Vector3(p + hw, y, size), Vector3(p - hw, y, size))
		_quad(st, Vector3(0, y, p - hw), Vector3(size, y, p - hw), Vector3(size, y, p + hw), Vector3(0, y, p + hw))
	grid_node = MeshInstance3D.new()
	grid_node.mesh = st.commit()
	grid_mat = StandardMaterial3D.new()
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	grid_mat.albedo_color = Color(0.0, 0.9, 1.0, 0.3)
	grid_node.material_override = grid_mat
	grid_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(grid_node)

	# маркер нажатой клетки
	marker = MeshInstance3D.new()
	var mm := PlaneMesh.new()
	mm.size = Vector2(CELL, CELL)
	marker.mesh = mm
	var mmat := StandardMaterial3D.new()
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmat.albedo_color = Color(0.0, 0.9, 1.0, 0.4)
	marker.material_override = mmat
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.visible = false
	add_child(marker)

	buildings_root = Node3D.new()
	add_child(buildings_root)

	camera = Camera3D.new()
	camera.fov = 55.0
	camera.near = 0.1
	camera.far = 250.0
	add_child(camera)
	focus = Vector3(size / 2.0, 0.0, size / 2.0)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)


func _emissive(col: Color, energy: float) -> StandardMaterial3D:
	var key := "%s_%.1f" % [col.to_html(), energy]
	if _emissive_cache.has(key):
		return _emissive_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	_emissive_cache[key] = m
	return m


func _add_box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, shadow := false) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


func _add_cylinder(parent: Node3D, pos: Vector3, r_top: float, r_bottom: float, height: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bottom
	cm.height = height
	cm.radial_segments = 10
	cm.rings = 1
	mi.mesh = cm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)


func _make_building(c: Vector2i) -> Node3D:
	var id: String = GameState.cells[c]
	var lvl := GameState.level_of(c)
	var col: Color = GameState.BUILDINGS[id]["color"]
	var spec: Dictionary = SPECS[id]
	var w := float(spec["w"]) * CELL
	var h := float(spec["h"]) * (1.0 + 0.3 * (lvl - 1))

	var root := Node3D.new()
	root.position = Vector3((c.x + 0.5) * CELL, 0.0, (c.y + 0.5) * CELL)

	# корпус с шейдером окон
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w, h, w)
	body.mesh = bm
	body.position.y = h / 2.0
	var mat := ShaderMaterial.new()
	mat.shader = _building_shader
	mat.set_shader_parameter("body_color", col.darkened(0.7))
	mat.set_shader_parameter("window_color", Color(1.0, 0.92, 0.6).lerp(col, 0.25))
	mat.set_shader_parameter("night", _night)
	body.material_override = mat
	root.add_child(body)
	root.set_meta("mat", mat)

	# неоновый ободок крыши
	var top := h + 0.05
	_add_box(root, Vector3(0, top, 0), Vector3(w + 0.08, 0.1, w + 0.08), _emissive(col, 1.5 + 0.5 * lvl))
	top += 0.05

	# детали по типу здания
	match id:
		"factory":
			var metal := _emissive(Color("#2a2a3a"), 0.0)
			_add_cylinder(root, Vector3(w * 0.25, top + 0.45, -w * 0.25), 0.12, 0.15, 0.9, metal)
			_add_cylinder(root, Vector3(-w * 0.2, top + 0.3, -w * 0.25), 0.1, 0.12, 0.6, metal)
		"power":
			_add_cylinder(root, Vector3(0, top + 0.5, 0), 0.3, 0.45, 1.0, _emissive(col.lightened(0.2), 0.8))
		"tower":
			_add_box(root, Vector3(0, top + 0.6, 0), Vector3(0.06, 1.2, 0.06), _emissive(Color("#ff1744"), 2.5))

	# звёздочки уровня на крыше
	for i in range(lvl - 1):
		var px := (i - (lvl - 2) / 2.0) * 0.28
		_add_box(root, Vector3(px, top + 0.1, w * 0.3), Vector3(0.16, 0.16, 0.16), _emissive(Color.WHITE, 2.5))

	return root


func _on_cell_changed(c: Vector2i) -> void:
	_remove_building(c)
	if GameState.cells.has(c):
		_place_building(c, true)


func _remove_building(c: Vector2i) -> void:
	if buildings.has(c):
		buildings[c].queue_free()
		buildings.erase(c)


func _place_building(c: Vector2i, animate: bool) -> void:
	var b := _make_building(c)
	buildings_root.add_child(b)
	buildings[c] = b
	if animate:
		b.scale = Vector3(1.0, 0.01, 1.0)
		var tw := create_tween()
		tw.tween_property(b, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _rebuild_all() -> void:
	for c in buildings:
		buildings[c].queue_free()
	buildings.clear()
	for c in GameState.cells:
		_place_building(c, false)


# ====================== ВРЕМЯ СУТОК ======================

func _process(delta: float) -> void:
	if Settings.time_mode == 0:
		clock = fposmod(clock + delta / CYCLE, 1.0)
	var target := sin(clock * TAU)
	if Settings.time_mode == 1:
		target = 1.0
	elif Settings.time_mode == 2:
		target = -1.0
	sun_h = move_toward(sun_h, target, delta * 0.8)
	_update_environment()

	_mat_t += delta
	if _mat_t >= 0.2:
		_mat_t = 0.0
		for c in buildings:
			var m: ShaderMaterial = buildings[c].get_meta("mat")
			m.set_shader_parameter("night", _night)

	if Settings.show_fps:
		_fps_t += delta
		if _fps_t >= 0.5:
			_fps_t = 0.0
			fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _update_environment() -> void:
	var day_amt := smoothstep(-0.1, 0.3, sun_h)
	_night = 1.0 - day_amt
	sun.visible = day_amt > 0.01
	sun.light_energy = 1.15 * day_amt
	sun.rotation_degrees = Vector3(-(15.0 + 50.0 * clampf(sun_h, 0.0, 1.0)), -35.0, 0.0)
	sun.light_color = Color("#ffb070").lerp(Color("#fff4e0"), clampf(sun_h * 2.0, 0.0, 1.0))
	env.ambient_light_color = Color("#3b3f8f").lerp(Color("#bcd7ff"), day_amt)
	env.ambient_light_energy = lerpf(0.6, 0.9, day_amt)
	var sky := Color("#0b0b1a").lerp(Color("#6fb1e8"), day_amt)
	var dusk := clampf(1.0 - absf(sun_h) / 0.35, 0.0, 1.0)
	env.background_color = sky.lerp(Color("#ff6aa8"), dusk * 0.5)
	grid_mat.albedo_color = Color(0.0, 0.9, 1.0, lerpf(0.16, 0.5, _night))


# ====================== НАСТРОЙКИ ======================

func _on_settings_changed() -> void:
	var q: int = Settings.quality
	sun.shadow_enabled = q >= 1
	RenderingServer.directional_shadow_atlas_set_size(2048 if q == 2 else 1024, true)
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_2X if q == 2 else Viewport.MSAA_DISABLED
	vp.scaling_3d_scale = [0.7, 0.85, 1.0][q]
	grid_node.visible = Settings.grid_lines
	fps_label.visible = Settings.show_fps
	_refresh_settings_ui()


func _refresh_settings_ui() -> void:
	if s_buttons.is_empty():
		return
	s_buttons["quality"].text = "Графика: %s" % QUALITY_NAMES[Settings.quality]
	s_buttons["fps"].text = "Лимит кадров: %d" % Settings.fps
	s_buttons["time_mode"].text = "Время: %s" % TIME_NAMES[Settings.time_mode]
	s_buttons["grid_lines"].text = "Сетка: %s" % _onoff(Settings.grid_lines)
	s_buttons["vibration"].text = "Вибрация: %s" % _onoff(Settings.vibration)
	s_buttons["show_fps"].text = "Счётчик FPS: %s" % _onoff(Settings.show_fps)


func _onoff(v: bool) -> String:
	return "вкл" if v else "выкл"


func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		reset_button.text = "Нажмите ещё раз: город будет удалён"
		get_tree().create_timer(3.0).timeout.connect(func():
			_reset_armed = false
			reset_button.text = "Сбросить город")
		return
	_reset_armed = false
	reset_button.text = "Сбросить город"
	GameState.reset()
	settings_layer.visible = false
	_toast("Город сброшен", Color("#ffb74d"))


# ====================== КАМЕРА И ВВОД ======================

func _update_camera() -> void:
	var rot := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -deg_to_rad(pitch))
	var pos := focus + rot * Vector3(0.0, 0.0, dist)
	camera.look_at_from_position(pos, focus, Vector3.UP)


func _clamp_focus() -> void:
	var size := GameState.GRID * CELL
	focus.x = clampf(focus.x, 0.0, size)
	focus.z = clampf(focus.z, 0.0, size)
	focus.y = 0.0


func _zoom_by(factor: float) -> void:
	dist = clampf(dist / factor, 8.0, 40.0)
	_update_camera()


func _pan(rel: Vector2) -> void:
	var b := Basis(Vector3.UP, yaw)
	var right := b * Vector3.RIGHT
	var forward := b * Vector3.FORWARD
	var k := dist * 0.0012
	focus -= right * rel.x * k
	focus += forward * rel.y * k
	_clamp_focus()
	_update_camera()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed:
			touches[e.index] = e.position
		else:
			touches.erase(e.index)
			if touches.size() < 2:
				pinching = false
				pinch_dist = 0.0
				twist_angle = 0.0
		if touches.size() == 2:
			pinching = true
			dragging = true  # чтобы отпускание пальцев не считалось тапом
			var pts := touches.values()
			pinch_dist = pts[0].distance_to(pts[1])
			twist_angle = (pts[1] - pts[0]).angle()
	elif e is InputEventScreenDrag:
		touches[e.index] = e.position
		if touches.size() == 2:
			var pts := touches.values()
			var d: float = pts[0].distance_to(pts[1])
			if pinch_dist > 0.0 and d > 0.0:
				_zoom_by(d / pinch_dist)
			pinch_dist = d
			var a: float = (pts[1] - pts[0]).angle()
			yaw -= wrapf(a - twist_angle, -PI, PI)
			twist_angle = a
			_update_camera()
	elif e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.1)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 1.1)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				pressing = true
				dragging = false
				press_pos = e.position
			else:
				if pressing and not dragging and not pinching:
					_tap(e.position)
				pressing = false
	elif e is InputEventMouseMotion:
		if e.button_mask & MOUSE_BUTTON_MASK_RIGHT:  # ПК: правая кнопка вращает камеру
			yaw -= e.relative.x * 0.005
			_update_camera()
		elif pressing and not pinching:
			if not dragging and e.position.distance_to(press_pos) > 16.0:
				dragging = true
			if dragging:
				_pan(e.relative)


func _cell_at(screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
	if hit == null:
		return null
	return Vector2i(floori(hit.x / CELL), floori(hit.z / CELL))


func _tap(screen_pos: Vector2) -> void:
	var found = _cell_at(screen_pos)
	if found == null:
		return
	var c: Vector2i = found
	if not GameState.in_bounds(c):
		return
	_flash_marker(c)
	var err := ""
	if tool == DEMOLISH:
		if not GameState.cells.has(c):
			return
		GameState.demolish(c)
	elif tool == UPGRADE:
		err = GameState.upgrade(c)
	else:
		err = GameState.build(c, tool)
	if err != "":
		_toast(err, Color("#ff5252"))
	elif Settings.vibration:
		Input.vibrate_handheld(25)


func _flash_marker(c: Vector2i) -> void:
	marker.position = Vector3((c.x + 0.5) * CELL, 0.04, (c.y + 0.5) * CELL)
	marker.visible = true
	if marker_tween:
		marker_tween.kill()
	marker_tween = create_tween()
	marker_tween.tween_interval(0.3)
	marker_tween.tween_callback(func(): marker.visible = false)


# ====================== ИНТЕРФЕЙС ======================

func _box(bg: Color, border: Color, bw := 2, radius := 16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(12)
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 30
	var pressed := _box(Color("#0a3a4a"), Color("#00e5ff"), 4)
	t.set_stylebox("normal", "Button", _box(Color("#15153a"), Color("#3a3a8a")))
	t.set_stylebox("hover", "Button", _box(Color("#1d1d4d"), Color("#00e5ff")))
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.04, 0.04, 0.12, 0.92), Color("#2a2a66"), 2, 0))
	return t


func _make_button(text: String, height := 150.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()
	layer.add_child(root)

	# --- верхняя панель ---
	var top := PanelContainer.new()
	top.anchor_left = 0.0
	top.anchor_right = 1.0
	top.anchor_top = 0.0
	top.anchor_bottom = 0.0
	root.add_child(top)
	var tbox := VBoxContainer.new()
	top.add_child(tbox)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 40)  # место под вырез экрана
	tbox.add_child(spacer)
	money_label = Label.new()
	money_label.add_theme_font_size_override("font_size", 56)
	money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tbox.add_child(money_label)
	income_label = Label.new()
	income_label.add_theme_font_size_override("font_size", 30)
	income_label.add_theme_color_override("font_color", Color("#00e5ff"))
	income_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tbox.add_child(income_label)

	# кнопка настроек
	var gear := _make_button("Меню", 100.0)
	gear.anchor_left = 1.0
	gear.anchor_right = 1.0
	gear.anchor_top = 0.0
	gear.anchor_bottom = 0.0
	gear.offset_left = -190.0
	gear.offset_right = -20.0
	gear.offset_top = 56.0
	gear.offset_bottom = 156.0
	gear.pressed.connect(func(): settings_layer.visible = true)
	root.add_child(gear)

	# счётчик FPS
	fps_label = Label.new()
	fps_label.position = Vector2(20, 60)
	fps_label.add_theme_font_size_override("font_size", 26)
	fps_label.add_theme_color_override("font_color", Color("#81c784"))
	fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fps_label)

	# --- нижняя панель ---
	var bottom := PanelContainer.new()
	bottom.anchor_left = 0.0
	bottom.anchor_right = 1.0
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_top = -360.0
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(bottom)
	var grid := GridContainer.new()
	grid.columns = 4
	bottom.add_child(grid)

	var group := ButtonGroup.new()
	for id in GameState.ORDER:
		var data: Dictionary = GameState.BUILDINGS[id]
		var b := _make_button("%s\n%d $" % [data["name"], data["cost"]])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = (id == tool)
		b.pressed.connect(func(): tool = id)
		grid.add_child(b)
	var up := _make_button("Улучшить\nуровень")
	up.toggle_mode = true
	up.button_group = group
	up.pressed.connect(func(): tool = UPGRADE)
	grid.add_child(up)
	var del := _make_button("Снос\n+50%")
	del.toggle_mode = true
	del.button_group = group
	del.pressed.connect(func(): tool = DEMOLISH)
	grid.add_child(del)

	# --- всплывающее сообщение ---
	toast_label = Label.new()
	toast_label.anchor_left = 0.0
	toast_label.anchor_right = 1.0
	toast_label.anchor_top = 0.3
	toast_label.anchor_bottom = 0.3
	toast_label.offset_bottom = 70.0
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 40)
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label.modulate.a = 0.0
	root.add_child(toast_label)

	_build_settings(root)


func _build_settings(root: Control) -> void:
	settings_layer = Control.new()
	settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_layer.visible = false
	root.add_child(settings_layer)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	settings_layer.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.05
	panel.anchor_right = 0.95
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	settings_layer.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Настройки"
	title.add_theme_font_size_override("font_size", 52)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var qb := _make_button("", 110.0)
	qb.pressed.connect(func(): Settings.set_value("quality", (Settings.quality + 1) % 3))
	box.add_child(qb)
	s_buttons["quality"] = qb

	var fb := _make_button("", 110.0)
	fb.pressed.connect(func(): Settings.set_value("fps", 30 if Settings.fps == 60 else 60))
	box.add_child(fb)
	s_buttons["fps"] = fb

	var tb := _make_button("", 110.0)
	tb.pressed.connect(func(): Settings.set_value("time_mode", (Settings.time_mode + 1) % 3))
	box.add_child(tb)
	s_buttons["time_mode"] = tb

	var gb := _make_button("", 110.0)
	gb.pressed.connect(func(): Settings.set_value("grid_lines", not Settings.grid_lines))
	box.add_child(gb)
	s_buttons["grid_lines"] = gb

	var vb := _make_button("", 110.0)
	vb.pressed.connect(func(): Settings.set_value("vibration", not Settings.vibration))
	box.add_child(vb)
	s_buttons["vibration"] = vb

	var sb := _make_button("", 110.0)
	sb.pressed.connect(func(): Settings.set_value("show_fps", not Settings.show_fps))
	box.add_child(sb)
	s_buttons["show_fps"] = sb

	reset_button = _make_button("Сбросить город", 110.0)
	reset_button.pressed.connect(_on_reset_pressed)
	box.add_child(reset_button)

	var close := _make_button("Закрыть", 120.0)
	close.pressed.connect(func(): settings_layer.visible = false)
	box.add_child(close)

	var ver := Label.new()
	ver.text = "Построй свой город v0.2"
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size", 24)
	ver.add_theme_color_override("font_color", Color("#7a7aa8"))
	box.add_child(ver)


func _fmt(v: float) -> String:
	if v >= 1000000.0:
		return "%.2fM" % (v / 1000000.0)
	if v >= 10000.0:
		return "%.1fK" % (v / 1000.0)
	return str(int(v))


func _update_hud() -> void:
	money_label.text = "$ %s" % _fmt(GameState.money)
	income_label.text = "+%s в секунду" % _fmt(GameState.income_per_sec())


func _toast(text: String, col: Color, duration := 1.0) -> void:
	toast_label.text = text
	toast_label.add_theme_color_override("font_color", col)
	if toast_tween:
		toast_tween.kill()
	toast_label.modulate.a = 1.0
	toast_tween = create_tween()
	toast_tween.tween_interval(duration)
	toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.5)
