extends Node2D

# =========================================================
# UMA System Configuration
# =========================================================
var N: int = 6
var cell_size: float = 90.0
var board_offset: Vector2 = Vector2(0, 0) 


@export_group("4S Map Tuning") # Fitur "Tuning": Mengatur langsung posisi barisan pion dari Inspector Panel bagian kanan
@export var offset_4s: Vector2 = Vector2(-200, -200) # Titik awal pion pertama (0,0)
@export var cell_size_4s: float = 133.0
@export_group("6S Map Tuning")
@export var offset_6s: Vector2 = Vector2(-260, -260)
@export var cell_size_6s: float = 104.0

# --- Game State Data ---
var board_matrix: Array = []
var active_ai_depth: int = 2
var current_turn: String = "FS"
# --- HDC AI VARIABLES ---
var hdc_thread: Thread
var is_ai_thinking: bool = false
# --- INPUT & SELECTION DATA ---	
var selected_pos: Vector2 = Vector2(-1, -1)
var selection_marker: ColorRect
var valid_move_markers: Array = [] # Pembuatan Baris Baru: Menyimpan jejak kotak hijau/merah

# --- NODE REFERENCES ---
@onready var board_map = $BoardMap
@onready var map_sprite = $BoardMap/MapSprite
@onready var pieces_container = $PiecesContainer
# --- UI REFERENCES ---
@onready var game_over_screen = $CanvasLayer/GameOverScreen
@onready var status_label = $CanvasLayer/GameOverScreen/GameOver_Panel/VBoxContainer/StatusLabel
@onready var home_btn = $CanvasLayer/GameOverScreen/GameOver_Panel/VBoxContainer/GameOverTitle/HBoxContainer/Home_TextureButton
@onready var repeat_btn = $CanvasLayer/GameOverScreen/GameOver_Panel/VBoxContainer/GameOverTitle/HBoxContainer/Repeat_TextureButton
@onready var home2_btn = $CanvasLayer/Home2_TextureButton
@onready var ai_status_label = $AIStatus
# --- ASSETS PRELOAD ---
var map_4s = preload("res://assets/image/RoTa - 4S Map.png")
var map_6s = preload("res://assets/image/RoTa - 6S Map.png")
var piece_white = preload("res://assets/image/RoTa - White Piece.png")
var piece_black = preload("res://assets/image/RoTa - Black Piece.png")

# Visual Path Projection
var path_green_tex = preload("res://assets/image/Game Pieces - Show Path.png")
var path_red_tex = preload("res://assets/image/Game Pieces - Eat Path.png")

# Persiapan Awal
func _ready() -> void:
	_load_session_data()
	_initialize_uma_structure()
	_spawn_universal_pieces()
	_create_selection_marker()
	ai_status_label.visible = false 
	
	home_btn.pressed.connect(_on_home_pressed)
	home2_btn.pressed.connect(_on_home2_pressed)
	repeat_btn.pressed.connect(_on_repeat_pressed)
	
	# Anti-Deadlock: Activate AI jika Hitam jalan dulu
	if current_turn == "SS":
		_wake_up_hdc()
	
func _exit_tree() -> void:
	if hdc_thread and hdc_thread.is_started():
		hdc_thread.wait_to_finish()

		  # --- UMA Module 1 --- 
# Sync data & Ambil Parameter Visual dinamis
func _load_session_data() -> void:
	var config = ConfigFile.new()
	if config.load("res://settings.cfg") == OK:
		var is_4x4 = config.get_value("GAME_SESSION", "foursquaremap", true)
		N = 4 if is_4x4 else 6
		active_ai_depth = config.get_value("GAME_SESSION", "aidepth", 2)
		current_turn = config.get_value("GAME_SESSION", "strike_mode", "FS")
	
# Menentukan texture dan Grid Parameter berdasarkan nilai Map (N)
	if N == 4:
		map_sprite.texture = map_4s
		board_offset = offset_4s
		cell_size = cell_size_4s
	else:
		map_sprite.texture = map_6s
		board_offset = offset_6s
		cell_size = cell_size_6s

# --- UMA Module 2 ---
# Memory Matrix
func _initialize_uma_structure() -> void:
	board_matrix.resize(N)
	var piece_rows = (N - 2) / 2
	
	for x in range(N):
		board_matrix[x] = []
		board_matrix[x].resize(N)
		for y in range(N):
			if y >= N - piece_rows:
				board_matrix[x][y] = 1 # Player 1 (Pion Putih)
			elif y < piece_rows:
				board_matrix[x][y] = 2 # AI (Pion Hitam)
			else:
				board_matrix[x][y] = 0 

	 # --- UMA Module 2 Visual ---
#Spawn Pion Relatif terhadap Pusat Map
func _spawn_universal_pieces() -> void:
	# Delete Pion lama jika ada, untuk mencegah stacking saat proses Tuning
	for child in pieces_container.get_children():
		child.queue_free()
		
	for x in range(N):
		for y in range(N):
			var piece_type = board_matrix[x][y]
			if piece_type == 0:
				continue
				
			var piece_visual = Sprite2D.new()
			piece_visual.texture = piece_white if piece_type == 1 else piece_black
			
			# Kalkulasi posisi koordinat (pixel) yang mengacu pada pusat BoardMap
			var pixel_position = board_map.position + board_offset + Vector2(x * cell_size, y * cell_size)
			piece_visual.position = pixel_position
			
			pieces_container.add_child(piece_visual)
			
func _create_selection_marker() -> void:
	selection_marker = ColorRect.new()
	selection_marker.size = Vector2(60, 60) # Sesuaikan dengan ukuran Pionmu (60x60)
	selection_marker.color = Color(0, 1, 0, 0.4) 
	selection_marker.pivot_offset = selection_marker.size / 2
	selection_marker.visible = false 
	board_map.add_child(selection_marker)
	
# --- UMA TURN MANAGER & REFEREE SYSTEM ---
func _switch_turn() -> void:
	_reset_selection()
	
	if _check_game_over():
		return 
	
	if current_turn == "FS":
		current_turn = "SS"
		
		# Pemanggilan AI. Player tidak bisa mengklik apapun sampai AI selesai berpikir
		_wake_up_hdc()
	else:
		current_turn = "FS"

# Penentu Game Over
func _check_game_over() -> bool:
	var sisa_putih = 0
	var sisa_hitam = 0
	
	# Scan seluruh papan untuk menghitung jumlah/populasi pion
	for x in range(N):
		for y in range(N):
			if board_matrix[x][y] == 1:
				sisa_putih += 1
			elif board_matrix[x][y] == 2:
				sisa_hitam += 1
				
	# Evaluasi Win Condition
	if sisa_putih == 0:
		current_turn = "GAME_OVER"
		_show_game_over_screen(false) # Player Kalah
		return true
	elif sisa_hitam == 0:
		current_turn = "GAME_OVER"
		_show_game_over_screen(true) # Player Menang
		return true
		
	return false # Game berlanjut karena dua pihak masih hidup

# =========================================================
# UMA MODULE 3, 4, 5, 6: CORE MECHANICS & RTX ALGORITHM
# =========================================================
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_pos = get_global_mouse_position()
		var grid_x = round((mouse_pos.x - (board_map.position.x + board_offset.x)) / cell_size)
		var grid_y = round((mouse_pos.y - (board_map.position.y + board_offset.y)) / cell_size)
		
		if grid_x >= 0 and grid_x < N and grid_y >= 0 and grid_y < N:
			_handle_grid_click(grid_x, grid_y)

func _handle_grid_click(x: int, y: int) -> void:
	if current_turn == "GAME_OVER": return
	
	# HDC Lock: Can't Click jika AI sedang menghitung di dimensi lain
	if current_turn == "SS" or is_ai_thinking:
		return
	var isi_kotak = board_matrix[x][y]
	
	# Identifikasi Kawan/Lawan secara dinamis berdasarkan current_turn
	var kawan = 1 if current_turn == "FS" else 2
	var lawan = 2 if current_turn == "FS" else 1
	
	# Kondisi 1: Seleksi Pion Sendiri (Hanya boleh klik faksi yang sedang aktif)
	if isi_kotak == kawan:
		_reset_selection()
		selected_pos = Vector2(x, y)
		selection_marker.position = board_offset + Vector2(x * cell_size, y * cell_size) - selection_marker.pivot_offset
		selection_marker.visible = true
		_show_legal_moves(x, y)
		
	# Kondisi 2: Interaksi setelah Pion Dipilih
	elif selected_pos != Vector2(-1, -1):
		var jarak_x = abs(x - selected_pos.x)
		var jarak_y = abs(y - selected_pos.y)
		
		# --- Jalur A: Normal Move ---
		if isi_kotak == 0 and ((jarak_x == 1 and jarak_y == 0) or (jarak_x == 0 and jarak_y == 1)):
			board_matrix[x][y] = kawan
			board_matrix[selected_pos.x][selected_pos.y] = 0
			AudioManager.get_node("PiecesMoveSFX").play()
			
			_spawn_universal_pieces()
			_switch_turn() # <--- SAKELAR GILIRAN DIPICU DI SINI
			
		# --- Jalur B: RTX Activation (Makan Musuh ATAU Pindah) ---
		elif isi_kotak == lawan or isi_kotak == 0:
			if _is_valid_rtx_start(selected_pos.x, selected_pos.y):
				var dir = _get_outward_direction(selected_pos.x, selected_pos.y)
				_execute_rtx(selected_pos.x, selected_pos.y, dir.x, dir.y, x, y)
			else:
				AudioManager.get_node("InvalidSFX").play()
		else:
			AudioManager.get_node("InvalidSFX").play()

# Dapatkan visualisasi Trajectory ke luar papan memutar dan kembali
func _get_outward_direction(sx: int, sy: int) -> Vector2:
	if sx == 0: return Vector2(-1, 0)
	if sx == N - 1: return Vector2(1, 0)
	if sy == 0: return Vector2(0, -1)
	if sy == N - 1: return Vector2(0, 1)
	return Vector2(0, 0)

func _is_valid_rtx_start(sx: int, sy: int) -> bool:
	var is_border = (sx == 0 or sx == N - 1 or sy == 0 or sy == N - 1)
	var is_corner = (sx == 0 and sy == 0) or (sx == 0 and sy == N - 1) or (sx == N - 1 and sy == 0) or (sx == N - 1 and sy == N - 1)
	return is_border and not is_corner

func _execute_rtx(start_x: int, start_y: int, dir_x: int, dir_y: int, target_x: int, target_y: int) -> void:
	var current_x = start_x
	var current_y = start_y
	
	AudioManager.get_node("HoverSFX").play()
	
	for step in range(40):
		current_x += dir_x
		current_y += dir_y
		
		# Sensor Ujung, dan System LauZen/Kuadran
		if current_x < 0 or current_x >= N or current_y < 0 or current_y >= N:
			var in_x = current_x - dir_x
			var in_y = current_y - dir_y
			
			var is_top_left = (in_x < N/2.0) and (in_y < N/2.0)
			var is_bottom_right = (in_x >= N/2.0) and (in_y >= N/2.0)
			
			if is_top_left or is_bottom_right:
				current_x = in_y
				current_y = in_x
				var temp_dir = dir_x
				dir_x = -dir_y
				dir_y = -temp_dir
			else:
				current_x = (N - 1) - in_y
				current_y = (N - 1) - in_x
				var temp_dir = dir_x
				dir_x = dir_y
				dir_y = temp_dir
			
		# Pemberhentian Langkah dalam papan (Langsung dicek saat mendarat di TDP)
		var isi_kotak_sekarang = board_matrix[current_x][current_y]
		
			# 1. Cek apakah ini adalah titik kotak yang diklik player?
		if current_x == target_x and current_y == target_y:
			if isi_kotak_sekarang == 2 or isi_kotak_sekarang == 1: # Nabrak siapa pun di target
				AudioManager.get_node("PiecesEatenSFX").play() # <--- SUNTIKAN SFX MAKAN DI SINI
			else:
				
				board_matrix[current_x][current_y] = board_matrix[start_x][start_y] # Pindahkan identitas asli
			board_matrix[start_x][start_y] = 0     # Kosongkan posisi awal
			AudioManager.get_node("PiecesMoveSFX").play()
			
			_spawn_universal_pieces()
			_switch_turn() # <--- Pemicu Giliran Ganti
			return
			
		# 2. Jika bukan titik yang diklik, tapi menabrak sesuatu di tengah jalan
		if isi_kotak_sekarang == 2:
			AudioManager.get_node("InvalidSFX").play()
			_reset_selection()
			return
			
		elif isi_kotak_sekarang == 1:
			AudioManager.get_node("InvalidSFX").play()
			_reset_selection()
			return
	AudioManager.get_node("InvalidSFX").play()
	_reset_selection()

func _reset_selection() -> void:
	selected_pos = Vector2(-1, -1)
	selection_marker.visible = false
	
	# Bersihkan semua marker Trajectory dari layar
	for marker in valid_move_markers:
		if is_instance_valid(marker):
			marker.queue_free()
	valid_move_markers.clear()

# =========================================================
# UMA Visual Projection System (GHOST TRAIL)
# =========================================================
# Fungsi utama untuk menggambar marker kotak transparan (Fix Layer Order)
func _draw_highlight(x: int, y: int, is_enemy: bool = false) -> void:
	var marker = Sprite2D.new()
	
	if is_enemy:
		marker.texture = path_red_tex
	else:
		marker.texture = path_green_tex
		
	# Sprite2D otomatis menggunakan titik pusat (center), untuk menyesuaikan posisi
	marker.position = board_offset + Vector2(x * cell_size, y * cell_size)
	
	# Memaksa marker naik 1 tingkat di atas Pion (default Pion = 0)
	marker.z_index = 1
	
	board_map.add_child(marker)
	valid_move_markers.append(marker)

# Fungsi untuk mencari Legal Move
func _show_legal_moves(sx: int, sy: int) -> void:
	# 1. Proyeksi Normal Move (Cek 4 arah yang kosong)
	var arah_normal = [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]
	for arah in arah_normal:
		var nx = sx + int(arah.x)
		var ny = sy + int(arah.y)
		if nx >= 0 and nx < N and ny >= 0 and ny < N:
			if board_matrix[nx][ny] == 0:
				_draw_highlight(nx, ny, false) # Gambar hijau di kotak kosong sebelah
				
	# 2. Proyeksi RTX Path (Jika Pion ada di TDP)
	if _is_valid_rtx_start(sx, sy):
		var dir = _get_outward_direction(sx, sy)
		_project_rtx_path(sx, sy, dir.x, dir.y)

# Simulasi Ghost Trail RTX
func _project_rtx_path(start_x: int, start_y: int, dir_x: int, dir_y: int) -> void:
	var current_x = start_x
	var current_y = start_y
	
	# Identifikasi Dinamis: Tentukan kawan/lawan asli sesuai giliran
	var kawan = 1 if current_turn == "FS" else 2
	var lawan = 2 if current_turn == "FS" else 1
	
	# Raycast Loop 40 langkah
	for step in range(40):
		current_x += dir_x
		current_y += dir_y
		
		# Sensor Tepi & Gerbang LauZen
		if current_x < 0 or current_x >= N or current_y < 0 or current_y >= N:
			var in_x = current_x - dir_x
			var in_y = current_y - dir_y
			
			var is_top_left = (in_x < N/2.0) and (in_y < N/2.0)
			var is_bottom_right = (in_x >= N/2.0) and (in_y >= N/2.0)
			
			if is_top_left or is_bottom_right:
				current_x = in_y
				current_y = in_x
				var temp_dir = dir_x
				dir_x = -dir_y
				dir_y = -temp_dir
			else:
				current_x = (N - 1) - in_y
				current_y = (N - 1) - in_x
				var temp_dir = dir_x
				dir_x = dir_y
				dir_y = temp_dir
			
		# Absolute State (Memberhentikan Gerak, Penggambaran Visual)
		var isi_kotak = board_matrix[current_x][current_y]
		
		if isi_kotak == 0:
			_draw_highlight(current_x, current_y, false) # Gambar jejak Hijau
		elif isi_kotak == lawan: 
			_draw_highlight(current_x, current_y, true)  # BARU: Gambar MERAH tepat di kepala LAWAN asli!
			return # Stop proyeksi karena nabrak mangsa
		elif isi_kotak == kawan: 
			return # Stop proyeksi karena kehalang kawan sendiri


# ===========================================================
# UMA MODULE 8: HDC (Harmony Domain Calculation) - AI Engine
# ===========================================================

# Fungsi aktif oleh saat pion hitam bergerak
func _wake_up_hdc() -> void:
	if is_ai_thinking: return
	is_ai_thinking = true
	ai_status_label.visible = true
	
	# 1. Virtual Board Cloning (Deep Copy)
	# Membuat papan tiruan agar AI tidak mengacaukan papan asli di layar
	var virtual_board = []
	virtual_board.resize(N)
	for x in range(N):
		virtual_board[x] = []
		virtual_board[x].resize(N)
		for y in range(N):
			virtual_board[x][y] = board_matrix[x][y]
	
	# 2. SPersiapan Thread
	if hdc_thread and hdc_thread.is_started():
		hdc_thread.wait_to_finish() # Pastikan thread lama bersih
		
	hdc_thread = Thread.new()
	# Jalankan fungsi berpikir di dimensi lain sambil membawa papan virtual dan kedalaman (depth)
	hdc_thread.start(_hdc_thinker_thread.bind(virtual_board, active_ai_depth))

# ---------------------------------------------------------
# Isolation Zone: MiniMax Optimazation + Alpha-Beta Pruning (Instant Depth 6)
# ---------------------------------------------------------
func _hdc_thinker_thread(v_board: Array, depth: int) -> Dictionary:
	var best_move: Dictionary = {}
	var faksi_ai = 2 
	
	var legal_moves = _generate_all_legal_moves(v_board, faksi_ai)
	if legal_moves.is_empty():
		call_deferred("_on_hdc_finished", {})
		return {}
		
	# --- SISTEM BOUNDED RATIONALITY (KALIBRASI DEPTH 2, 4, 6) ---
	var mistake_chance = 0.0
	if depth <= 2:
		mistake_chance = 0.35
	elif depth <= 4:
		mistake_chance = 0.15
	else:
		mistake_chance = 0.00 # Level 5 (Depth 6): AI Bertarung Mutlak
		
	if randf() < mistake_chance:
		best_move = legal_moves[randi() % legal_moves.size()]
		OS.delay_msec(600)
		call_deferred("_on_hdc_finished", best_move)
		return best_move
	# ------------------------------------------------------------
	var best_score = -999999
	var alpha = -999999
	var beta = 999999
	
	for move in legal_moves:
		var temp_board = v_board.duplicate(true) 
		temp_board[move.target.x][move.target.y] = faksi_ai
		temp_board[move.start.x][move.start.y] = 0
		
		var score = _minimax(temp_board, depth - 1, alpha, beta, false)
		
		if score > best_score:
			best_score = score
			best_move = move
		
		alpha = max(alpha, best_score)
	call_deferred("_on_hdc_finished", best_move)
	return best_move

# Algoritma Brances Cutting (Minimax dengan Alpha-Beta Pruning)
func _minimax(v_board: Array, depth: int, alpha: int, beta: int, is_maximizing: bool) -> int:
	if depth == 0:
		return _evaluate_board(v_board)
		
	var current_faksi = 2 if is_maximizing else 1
	var moves = _generate_all_legal_moves(v_board, current_faksi)
	
	if moves.is_empty():
		return _evaluate_board(v_board)
		
	if is_maximizing:
		var max_eval = -999999
		for move in moves:
			var temp_board = v_board.duplicate(true)
			temp_board[move.target.x][move.target.y] = current_faksi
			temp_board[move.start.x][move.start.y] = 0
			
			var ev = _minimax(temp_board, depth - 1, alpha, beta, false)
			max_eval = max(max_eval, ev)
			alpha = max(alpha, ev)
			if beta <= alpha:
				break
		return max_eval
	else:
		var min_eval = 999999
		for move in moves:
			var temp_board = v_board.duplicate(true)
			temp_board[move.target.x][move.target.y] = current_faksi
			temp_board[move.start.x][move.start.y] = 0
			
			var ev = _minimax(temp_board, depth - 1, alpha, beta, true)
			min_eval = min(min_eval, ev)
			beta = min(beta, ev)
			if beta <= alpha:
				break
		return min_eval

# =========================================================
# AI Instinct (Heuristics Matrix & Threat Awareness)
# =========================================================
func _evaluate_board(v_board: Array) -> int:
	var score = 0
	
	for x in range(N):
		for y in range(N):
			var isi = v_board[x][y]
			if isi == 0: continue
			
			var piece_value = 0
			var is_ai = (isi == 2)
			var faksi_sign = 1 if is_ai else -1 # + untuk AI, - untuk Player
			
			# 1. Core Value (Solid Health)
			piece_value += 100 
			
			# 2. Positional Matrix (Kasta Koordinat
			var is_corner = (x == 0 and y == 0) or (x == 0 and y == N - 1) or (x == N - 1 and y == 0) or (x == N - 1 and y == N - 1)
			var is_border = (x == 0 or x == N - 1 or y == 0 or y == N - 1)
			
			if is_corner:
				piece_value -= 10 # Pojokan = Area Buntu (Sangat Dihindari)
			elif is_border:
				piece_value += 15 # Perimeter/TDP = Tempat RTX (Sangat Diprioritaskan)
			else:
				piece_value += 5  # Tengah = Aman, tapi tidak bisa menembak (Middle-State)
				
			# 3. Trajectory Threat Assesment (Sensor Jarak Jauh)
			if is_border and not is_corner:
				var dir = _get_outward_direction(x, y)
				var threat_bonus = _calculate_threat_line(v_board, x, y, dir.x, dir.y, isi)
				piece_value += threat_bonus
				
			# Akumulasi ke Global Score
			score += piece_value * faksi_sign
			
	return score

# Ghost Trail Sensor: Mengecek apakah garis RTX mengarah langsung ke musuh
func _calculate_threat_line(v_board: Array, start_x: int, start_y: int, dir_x: int, dir_y: int, my_faksi: int) -> int:
	var lawan = 1 if my_faksi == 2 else 2
	var cx = start_x
	var cy = start_y
	var threat_bonus = 0
	
	for step in range(40):
		cx += dir_x
		cy += dir_y
		
		# Virtual LauZen Sensor
		if cx < 0 or cx >= N or cy < 0 or cy >= N:
			var in_x = cx - dir_x
			var in_y = cy - dir_y
			var is_top_left = (in_x < N/2.0) and (in_y < N/2.0)
			var is_bottom_right = (in_x >= N/2.0) and (in_y >= N/2.0)
			
			if is_top_left or is_bottom_right:
				cx = in_y
				cy = in_x
				var temp_dir = dir_x
				dir_x = -dir_y
				dir_y = -temp_dir
			else:
				cx = (N - 1) - in_y
				cy = (N - 1) - in_x
				var temp_dir = dir_x
				dir_x = dir_y
				dir_y = temp_dir
				
		# Visual Absolute State (Rem)
		var isi = v_board[cx][cy]
		if isi == lawan:
			threat_bonus = 20 # Pion mengunci target musuh (Dapat poin besar)
			break
		elif isi == my_faksi:
			break # Terhalang kawan sendiri, garis ancaman batal
			
	return threat_bonus

# =========================================================
# AI Scan Machine (Hanya main data/non-visual)
# =========================================================

# Mengembalikan Array berisi Dictionary { "start": Vector2, "target": Vector2, "type": String }
func _generate_all_legal_moves(v_board: Array, faksi: int) -> Array:
	var moves = []
	var arah_normal = [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]
	
	# Scan seluruh Path di papan dari ujung ke ujung
	for x in range(N):
		for y in range(N):
			if v_board[x][y] == faksi: # Jika ini Pion milik AI
				
				# 1. Cek Normal Move (Pindah 1 kotak ke area kosong)
				for arah in arah_normal:
					var nx = x + int(arah.x)
					var ny = y + int(arah.y)
					if nx >= 0 and nx < N and ny >= 0 and ny < N:
						if v_board[nx][ny] == 0:
							moves.append({"start": Vector2(x, y), "target": Vector2(nx, ny), "type": "NORMAL"})
							
				# 2. Cek Garis RTX (Tembakan jarak jauh)
				if _is_valid_rtx_start(x, y):
					var dir = _get_outward_direction(x, y)
					# Menembak peluru (gaib), mengumpulkan semua data target yang bisa didarati/dimakan
					var rtx_targets = _simulate_virtual_rtx(v_board, x, y, dir.x, dir.y, faksi)
					
					for target in rtx_targets:
						moves.append({"start": Vector2(x, y), "target": target, "type": "RTX"})
						
	return moves

# Simulasi Fisika RTX (Ghost Trail, Persis seperti aslinya, tapi tanpa efek suara/visual)
func _simulate_virtual_rtx(v_board: Array, start_x: int, start_y: int, dir_x: int, dir_y: int, faksi: int) -> Array:
	var valid_targets = []
	var lawan = 1 if faksi == 2 else 2
	var cx = start_x
	var cy = start_y
	
	for step in range(40):
		cx += dir_x
		cy += dir_y
		
		# Virtual LauZen Sensor
		if cx < 0 or cx >= N or cy < 0 or cy >= N:
			var in_x = cx - dir_x
			var in_y = cy - dir_y
			
			var is_top_left = (in_x < N/2.0) and (in_y < N/2.0)
			var is_bottom_right = (in_x >= N/2.0) and (in_y >= N/2.0)
			
			if is_top_left or is_bottom_right:
				cx = in_y
				cy = in_x
				var temp_dir = dir_x
				dir_x = -dir_y
				dir_y = -temp_dir
			else:
				cx = (N - 1) - in_y
				cy = (N - 1) - in_x
				var temp_dir = dir_x
				dir_x = dir_y
				dir_y = temp_dir
				
		# Visual Absolute-State
		var isi = v_board[cx][cy]
		
		if isi == 0:
			valid_targets.append(Vector2(cx, cy)) # Jalan kosong, sah untuk dilewati/didarati
		elif isi == lawan:
			valid_targets.append(Vector2(cx, cy)) # Nabrak musuh, sah untuk dimakan
			break # Peluru berhenti di sini
		elif isi == faksi:
			break # Terhalang teman sendiri, peluru berhenti
			
	return valid_targets
## =========================================================
# Fase Eksekusi: Membawa Keputusan AI Ke Layar Utama
# =========================================================
func _on_hdc_finished(best_move: Dictionary) -> void:
	if hdc_thread.is_started():
		hdc_thread.wait_to_finish()
	is_ai_thinking = false
	ai_status_label.visible = false
	
	if best_move.is_empty():
		_switch_turn()
		return
	
	# AI Taken Detection: Mengecek apakah Target Path diisi Player sebelum diTIMPA
	if board_matrix[best_move.target.x][best_move.target.y] == 1:
		AudioManager.get_node("PiecesEatenSFX").play()
	
	# 1. Mengubah Realita di Real Matrix Memory (On the Screen)
	board_matrix[best_move.target.x][best_move.target.y] = 2 
	board_matrix[best_move.start.x][best_move.start.y] = 0
	
	# 2. Memutar SFX Gerak (akan stacking dengan suara taken dan memperbarui data visual
	AudioManager.get_node("PiecesMoveSFX").play()
	_spawn_universal_pieces()
	
	# 3. Mengembalikan giliran ke White-turn
	_switch_turn()

# =========================================================
# UI & Scene Navigation (Game Over)
# =========================================================
func _show_game_over_screen(is_win: bool) -> void:
	game_over_screen.visible = true
	
	if is_win:
		status_label.text = "You Win, Next Level?"
		AudioManager.get_node("PiecesEatenSFX").play() # Bisa diganti SFX Menang kalau ada
		
		# --- Save Progress System ---
		var config = ConfigFile.new()
		if config.load("res://settings.cfg") == OK:
			# Membaca Level terdahulu, default 1 jika belum ada
			var current_progress = config.get_value("GAME_SESSION", "progress", 1) 
			
			# Add 1 Level (Next Level)
			config.set_value("GAME_SESSION", "progress", current_progress + 1)
			config.save("res://settings.cfg")
			
	else:
		status_label.text = "You Lose, Try Again?"
		AudioManager.get_node("InvalidSFX").play()

# Fungsi klik tombol Home
func _on_home_pressed() -> void:
	AudioManager.get_node("ClickSFX").play()
	# Ganti sesuai path Main Menu milikmu
	game_over_screen.visible = false
	TransitionScreen.pindah_scene("res://scenes/MainMenu.tscn") 

# Fungsi klik tombol Repeat
func _on_repeat_pressed() -> void:
	AudioManager.get_node("ClickSFX").play()
	# Reload scene ini dengan konfigurasi map & depth yang sama
	game_over_screen.visible = false
	TransitionScreen.pindah_scene("res://scenes/MainGame.tscn")

# Fungsi klik tombol Home2 (Dalam Permainan Langsung
func _on_home2_pressed() -> void:
	AudioManager.get_node("ClickSFX").play()
	game_over_screen.visible = false
	TransitionScreen.pindah_scene("res://scenes/MainMenu.tscn") 
