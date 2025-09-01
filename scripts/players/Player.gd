extends CharacterBody3D

# ===== Tunables =====
@export var walk_speed := 4.0
@export var sprint_multiplier := 1.5
@export var acceleration := 10.0
@export var air_control := 0.5
@export var jump_velocity := 4.0

@export var mouse_sens := 0.12          # degrees per pixel-ish
@export var mouse_smooth_speed := 10.0   # camera yaw/pitch interpolation speed

# Stamina
@export var stamina_max := 5.0
@export var stamina_drain := 1.5         # per second while sprinting
@export var stamina_recover := 1.0       # per second while not sprinting
@export var stamina_regen_delay := 0.25  # seconds after sprint before regen starts

# Bob / sway
@export var move_bob_amp := 0.05
@export var move_bob_freq := 8.0
@export var idle_bob_amp := 0.015
@export var idle_bob_freq := 1.5

# Footstep bump
@export var bump_strength := 0.03
@export var bump_restore_speed := 8.0

# Snap length (exported knob). We assign it to the built-in floor_snap_length.
@export var snap_len := 0.2

signal stamina_changed(current: float, max_value: float)

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# ===== Runtime state =====
var stamina := 0.0
var time_since_sprint := 0.0

# Camera smoothing (target vs smoothed)
var target_yaw := 0.0
var target_pitch := 0.0
var smooth_yaw := 0.0
var smooth_pitch := 0.0

# Head bob / bump
var bob_time := 0.0
var last_step_phase := 0.0     # for step detection
var cam_base_local_pos := Vector3.ZERO
var cam_bump_y := 0.0          # extra Y offset from footstep "impact"

# Jump state to disable snap for one frame
var _just_jumped := false

@onready var pivot: Node3D = $Pivot
@onready var cam: Camera3D = $Pivot/Camera3D
@onready var bump_audio := AudioStreamPlayer3D.new()

func _ready() -> void:
	stamina = stamina_max
	add_child(bump_audio)  # assign a footstep/bump AudioStream in the inspector if you want sound
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Up direction & snap configured here
	up_direction = Vector3.UP
	floor_snap_length = snap_len

	# Initialize camera smoothing targets to current rotation to avoid snapping.
	target_yaw = rotation.y
	target_pitch = pivot.rotation.x
	smooth_yaw = target_yaw
	smooth_pitch = target_pitch

	# Remember the camera's rest local position; bob/bump are offsets from this.
	cam_base_local_pos = cam.position

func _unhandled_input(event: InputEvent) -> void:
	# Release / recapture mouse
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Mouse look (update targets; smoothing happens in _process)
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		target_yaw -= deg_to_rad(event.relative.x * mouse_sens)
		target_pitch -= deg_to_rad(event.relative.y * mouse_sens)
		target_pitch = clamp(target_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))

func _process(delta: float) -> void:
	# Smooth camera rotation toward targets
	smooth_yaw = lerp_angle(smooth_yaw, target_yaw, delta * mouse_smooth_speed)
	smooth_pitch = lerp_angle(smooth_pitch, target_pitch, delta * mouse_smooth_speed)
	rotation.y = smooth_yaw
	pivot.rotation.x = smooth_pitch

func _physics_process(delta: float) -> void:
	_just_jumped = false

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Movement input: x = left/right, y = forward/back (forward is negative Y)
	var iv := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var moving := iv.length() > 0.001

	# Desired direction in world space
	var wish_dir := (transform.basis * Vector3(iv.x, 0.0, iv.y))
	if wish_dir.length() > 0.0:
		wish_dir = wish_dir.normalized()

	# Stamina logic
	var wants_sprint := Input.is_action_pressed("sprint") and moving and stamina > 0.0
	if wants_sprint:
		stamina = max(0.0, stamina - stamina_drain * delta)
		time_since_sprint = 0.0
	else:
		time_since_sprint += delta
		if time_since_sprint >= stamina_regen_delay:
			stamina = min(stamina_max, stamina + stamina_recover * delta)
	emit_signal("stamina_changed", stamina, stamina_max)

	# Current speed with float branches (avoid INCOMPATIBLE_TERNARY)
	var speed_factor := sprint_multiplier if wants_sprint else 1.0
	var current_speed := walk_speed * speed_factor

	# Smooth horizontal acceleration (manual XZ handling; Vector3 has no 'xz' swizzle)
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	var target_v := wish_dir * current_speed
	var accel := acceleration if is_on_floor() else acceleration * air_control
	horiz = horiz.lerp(target_v, clamp(accel * delta, 0.0, 1.0))
	velocity.x = horiz.x
	velocity.z = horiz.z

	# Jump (disable snap for this frame)
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity + 0.01 # tiny nudge to avoid ledge sticking
		_just_jumped = true

	# Toggle snapping: off the frame we jump, on otherwise
	if _just_jumped:
		floor_snap_length = 0.0
	else:
		floor_snap_length = snap_len

	move_and_slide()

	# ---- Head bob / idle sway & step bump ----
	var bob_offset := Vector3.ZERO

	if is_on_floor():
		if moving:
			bob_time += delta * current_speed
			# Step phase used both for bob and to detect "foot contact"
			var phase := sin(bob_time * move_bob_freq)
			bob_offset.x = phase * move_bob_amp
			bob_offset.y = sin(bob_time * move_bob_freq * 2.0) * (move_bob_amp * 0.5)

			# Simple step trigger on rising zero-crossing
			if phase > 0.0 and last_step_phase <= 0.0:
				_perform_bump()
			last_step_phase = phase
		else:
			# Idle sway: subtle vertical breathing
			bob_time += delta * idle_bob_freq
			bob_offset.y = sin(bob_time) * idle_bob_amp
			last_step_phase = 0.0
	else:
		# In air: decay step phase
		last_step_phase = 0.0

	# Update bump offset toward zero
	cam_bump_y = lerp(cam_bump_y, 0.0, delta * bump_restore_speed)

	# Apply camera local offset (bob + bump) toward target smoothly
	var cam_target_local := cam_base_local_pos + bob_offset + Vector3(0.0, cam_bump_y, 0.0)
	cam.position = cam.position.lerp(cam_target_local, clamp(10.0 * delta, 0.0, 1.0))

func _perform_bump() -> void:
	if bump_audio.stream and not bump_audio.playing:
		bump_audio.play()
	cam_bump_y -= bump_strength
