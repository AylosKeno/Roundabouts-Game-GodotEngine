extends CanvasLayer

@onready var color_rect = $ColorRect

func pindah_scene(target_path: String):
	var tween_in = create_tween()
	# Kita ubah Alpha (transparansi) si kotak jadi 1 (gelap total) dalam 0.5 detik
	tween_in.tween_property(color_rect, "modulate:a", 1.0, 0.5)
	
	# Tunggu sampai animasinya selesai
	await get_tree().create_timer(2.0, true, false, true).timeout
	
	# 2. Pindah Scene (saat layar lagi hitam pekat, lag-nya jadi gak kelihatan)
	get_tree().change_scene_to_file(target_path)
	
	# 3. Hilangkan Tirai Hitam (Fade Out)
	var tween_out = create_tween()
	# Kita balikin Alpha jadi 0 (transparan) dalam 0.5 detik
	tween_out.tween_property(color_rect, "modulate:a", 0.0, 0.5)
