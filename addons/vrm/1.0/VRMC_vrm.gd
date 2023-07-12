extends GLTFDocumentExtension

const vrm_constants_class = preload("../vrm_constants.gd")
const vrm_meta_class = preload("../vrm_meta.gd")
const vrm_top_level = preload("../vrm_toplevel.gd")

var vrm_meta: Resource = null

func skeleton_rename(gstate: GLTFState, p_base_scene: Node, p_skeleton: Skeleton3D, p_bone_map: BoneMap):
	var original_bone_names_to_indices = {}
	var original_indices_to_bone_names = {}
	var original_indices_to_new_bone_names = {}
	var skellen: int = p_skeleton.get_bone_count()

	# Rename bones to their humanoid equivalents.
	for i in range(skellen):
		var bn: StringName = p_bone_map.find_profile_bone_name(p_skeleton.get_bone_name(i))
		original_bone_names_to_indices[p_skeleton.get_bone_name(i)] = i
		original_indices_to_bone_names[i] = p_skeleton.get_bone_name(i)
		original_indices_to_new_bone_names[i] = bn
		if bn != StringName():
			p_skeleton.set_bone_name(i, bn)

	var gnodes = gstate.nodes
	var root_bone_name = "Root"
	if p_skeleton.find_bone(root_bone_name) == -1:
		p_skeleton.add_bone(root_bone_name)
		var new_root_bone_id = p_skeleton.find_bone(root_bone_name)
		for root_bone_id in p_skeleton.get_parentless_bones():
			if root_bone_id != new_root_bone_id:
				p_skeleton.set_bone_parent(root_bone_id, new_root_bone_id)
	else:
		push_warning("VRM0: Root bone already found despite rename")
	for gnode in gnodes:
		var bn: StringName = p_bone_map.find_profile_bone_name(gnode.resource_name)
		if bn != StringName():
			gnode.resource_name = bn

	var nodes: Array[Node] = p_base_scene.find_children("*", "ImporterMeshInstance3D")
	while not nodes.is_empty():
		var mi : ImporterMeshInstance3D = nodes.pop_back() as ImporterMeshInstance3D
		var skin: Skin = mi.skin
		if skin:
			var node = mi.get_node(mi.skeleton_path)
			if node and node is Skeleton3D and node == p_skeleton:
				skellen = skin.get_bind_count()
				for i in range(skellen):
					# Bone name from skin (un-remapped bone name)
					var bind_bone_name = skin.get_bind_name(i)
					var bone_name_from_skel: StringName = p_bone_map.find_profile_bone_name(bind_bone_name)
					if not bone_name_from_skel.is_empty():
						skin.set_bind_name(i, bone_name_from_skel)

	# Rename bones in all Nodes by calling method.
	nodes = p_base_scene.find_children("*")

	p_skeleton.name = "GeneralSkeleton"
	p_skeleton.set_unique_name_in_owner(true)
	while not nodes.is_empty():
		var nd = nodes.pop_back()
		if nd.has_method(&"_notify_skeleton_bones_renamed"):
			nd.call(&"_notify_skeleton_bones_renamed", p_base_scene, p_skeleton, p_bone_map)

func skeleton_rotate(p_base_scene: Node, src_skeleton: Skeleton3D, p_bone_map: BoneMap) -> Array[Basis]:
	# is_renamed: was skeleton_rename already invoked?
	var is_renamed = true
	var profile = p_bone_map.profile
	var prof_skeleton = Skeleton3D.new()
	for i in range(profile.bone_size):
		# Add single bones.
		prof_skeleton.add_bone(profile.get_bone_name(i))
		prof_skeleton.set_bone_rest(i, profile.get_reference_pose(i))
	for i in range(profile.bone_size):
		# Set parents.
		var parent = profile.find_bone(profile.get_bone_parent(i))
		if parent >= 0:
			prof_skeleton.set_bone_parent(i, parent)

	# Overwrite axis.
	var old_skeleton_rest: Array[Transform3D]
	var old_skeleton_global_rest: Array[Transform3D]
	for i in range(src_skeleton.get_bone_count()):
		old_skeleton_rest.push_back(src_skeleton.get_bone_rest(i))
		old_skeleton_global_rest.push_back(src_skeleton.get_bone_global_rest(i))

	var diffs: Array[Basis]
	diffs.resize(src_skeleton.get_bone_count())

	var bones_to_process: PackedInt32Array = src_skeleton.get_parentless_bones()
	var bpidx = 0
	while bpidx < len(bones_to_process):
		var src_idx: int = bones_to_process[bpidx]
		bpidx += 1
		var src_children: PackedInt32Array = src_skeleton.get_bone_children(src_idx)
		for bone_idx in src_children:
			bones_to_process.push_back(bone_idx)

		var tgt_rot: Basis
		var src_bone_name: StringName = StringName(src_skeleton.get_bone_name(src_idx)) if is_renamed else p_bone_map.find_profile_bone_name(src_skeleton.get_bone_name(src_idx))
		if src_bone_name != StringName():
			var src_pg: Basis
			var src_parent_idx: int = src_skeleton.get_bone_parent(src_idx)
			if src_parent_idx >= 0:
				src_pg = src_skeleton.get_bone_global_rest(src_parent_idx).basis

			var prof_idx: int = profile.find_bone(src_bone_name)
			if prof_idx >= 0:
				tgt_rot = src_pg.inverse() * prof_skeleton.get_bone_global_rest(prof_idx).basis  # Mapped bone uses reference pose.

		if src_skeleton.get_bone_parent(src_idx) >= 0:
			diffs[src_idx] = (tgt_rot.inverse() * diffs[src_skeleton.get_bone_parent(src_idx)] * src_skeleton.get_bone_rest(src_idx).basis)
		else:
			diffs[src_idx] = tgt_rot.inverse() * src_skeleton.get_bone_rest(src_idx).basis

		var diff: Basis
		if src_skeleton.get_bone_parent(src_idx) >= 0:
			diff = diffs[src_skeleton.get_bone_parent(src_idx)]

		src_skeleton.set_bone_rest(src_idx, Transform3D(tgt_rot, diff * src_skeleton.get_bone_rest(src_idx).origin))

	prof_skeleton.queue_free()
	return diffs


func apply_rotation(p_base_scene: Node, src_skeleton: Skeleton3D):
	# Fix skin.
	var nodes: Array[Node] = p_base_scene.find_children("*", "ImporterMeshInstance3D")
	while not nodes.is_empty():
		var this_node = nodes.pop_back()
		if this_node is ImporterMeshInstance3D:
			var mi = this_node
			var skin: Skin = mi.skin
			var node = mi.get_node_or_null(mi.skeleton_path)
			if skin and node and node is Skeleton3D and node == src_skeleton:
				var skellen = skin.get_bind_count()
				for i in range(skellen):
					var bn: StringName = skin.get_bind_name(i)
					var bone_idx: int = src_skeleton.find_bone(bn)
					if bone_idx >= 0:
						# silhouette_diff[i] *
						# Normally would need to take bind-pose into account.
						# However, in this case, it works because VRM files must be baked before export.
						var new_rest: Transform3D = src_skeleton.get_bone_global_rest(bone_idx)
						skin.set_bind_pose(i, new_rest.inverse())

	# Init skeleton pose to new rest.
	for i in range(src_skeleton.get_bone_count()):
		var fixed_rest: Transform3D = src_skeleton.get_bone_rest(i)
		src_skeleton.set_bone_pose_position(i, fixed_rest.origin)
		src_skeleton.set_bone_pose_rotation(i, fixed_rest.basis.get_rotation_quaternion())
		src_skeleton.set_bone_pose_scale(i, fixed_rest.basis.get_scale())




func _get_skel_godot_node(gstate: GLTFState, nodes: Array, skeletons: Array, skel_id: int) -> Node:
	# There's no working direct way to convert from skeleton_id to node_id.
	# Bugs:
	# GLTFNode.parent is -1 if skeleton bone.
	# skeleton_to_node is empty
	# get_scene_node(skeleton bone) works though might maybe return an attachment.
	# var skel_node_idx = nodes[gltfskel.roots[0]]
	# return gstate.get_scene_node(skel_node_idx) # as Skeleton
	for i in range(nodes.size()):
		if nodes[i].skeleton == skel_id:
			return gstate.get_scene_node(i)
	return null


class SkelBone:
	var skel: Skeleton3D
	var bone_name: String


# https://github.com/vrm-c/vrm-specification/blob/master/specification/0.0/schema/vrm.humanoid.bone.schema.json
# vrm_extension["humanoid"]["bone"]:
#"enum": ["hips","leftUpperLeg","rightUpperLeg","leftLowerLeg","rightLowerLeg","leftFoot","rightFoot",
# "spine","chest","neck","head","leftShoulder","rightShoulder","leftUpperArm","rightUpperArm",
# "leftLowerArm","rightLowerArm","leftHand","rightHand","leftToes","rightToes","leftEye","rightEye","jaw",
# "leftThumbProximal","leftThumbIntermediate","leftThumbDistal",
# "leftIndexProximal","leftIndexIntermediate","leftIndexDistal",
# "leftMiddleProximal","leftMiddleIntermediate","leftMiddleDistal",
# "leftRingProximal","leftRingIntermediate","leftRingDistal",
# "leftLittleProximal","leftLittleIntermediate","leftLittleDistal",
# "rightThumbProximal","rightThumbIntermediate","rightThumbDistal",
# "rightIndexProximal","rightIndexIntermediate","rightIndexDistal",
# "rightMiddleProximal","rightMiddleIntermediate","rightMiddleDistal",
# "rightRingProximal","rightRingIntermediate","rightRingDistal",
# "rightLittleProximal","rightLittleIntermediate","rightLittleDistal", "upperChest"]


func _create_meta(
	root_node: Node,
	animplayer: AnimationPlayer,
	vrm_extension: Dictionary,
	gstate: GLTFState,
	skeleton: Skeleton3D,
	humanBones: BoneMap,
	human_bone_to_idx: Dictionary,
	pose_diffs: Array[Basis]
) -> Resource:
	var nodes = gstate.get_nodes()

	#var skeletonPath: NodePath = root_node.get_path_to(skeleton)
	#root_node.set("vrm_skeleton", skeletonPath)

	#var animPath: NodePath = root_node.get_path_to(animplayer)
	#root_node.set("vrm_animplayer", animPath)

	var firstperson = vrm_extension.get("lookAt", null)
	var eyeOffset: Vector3

	if firstperson:
		# FIXME: Technically this is supposed to be offset relative to the "firstPersonBone"
		# However, firstPersonBone defaults to Head...
		# and the semantics of a VR player having their viewpoint out of something which does
		# not rotate with their head is unclear.
		# Additionally, the spec schema says this:
		# "It is assumed that an offset from the head bone to the VR headset is added."
		# Which implies that the Head bone is used, not the firstPersonBone.
		var fpboneoffsetxyz = firstperson["offsetFromHeadBone"]  # example: 0,0.06,0
		eyeOffset = Vector3(fpboneoffsetxyz[0], fpboneoffsetxyz[1], fpboneoffsetxyz[2])
		if human_bone_to_idx["head"] != -1:
			eyeOffset = pose_diffs[human_bone_to_idx["head"]] * eyeOffset

	vrm_meta = vrm_meta_class.new()

	vrm_meta.resource_name = "CLICK TO SEE METADATA"
	vrm_meta.spec_version = vrm_extension.get("specVersion", "1.0")
	var vrm_extension_meta = vrm_extension.get("meta")
	if vrm_extension_meta:
		vrm_meta.title = vrm_extension["meta"].get("name", "")
		vrm_meta.version = vrm_extension["meta"].get("version", "")
		vrm_meta.authors = PackedStringArray(vrm_extension["meta"].get("authors", []))
		vrm_meta.contact_information = vrm_extension["meta"].get("contactInformation", "")
		vrm_meta.references = PackedStringArray(vrm_extension["meta"].get("references", []))
		var tex: int = vrm_extension["meta"].get("thumbnailImage", -1)
		if tex >= 0:
			vrm_meta.thumbnail_image = gstate.get_images()[tex]
		var avatar_permission_map = {"": "", "onlyAuthor": "OnlyAuthor", "onlySeparatelyLicensedPerson": "ExplicitlyLicensedPerson", "everyone": "Everyone"}
		vrm_meta.allowed_user_name = avatar_permission_map[vrm_extension["meta"].get("avatarPermission", "")]
		vrm_meta.violent_usage = "Allow" if vrm_extension["meta"].get("allowExcessivelyViolentUsage", false) else "Disallow"
		vrm_meta.sexual_usage = "Allow" if vrm_extension["meta"].get("allowExcessivelySexualUsage", false) else "Disallow"
		var commercial_usage_map = {"": "", "personalNonProfit": "PersonalNonProfit", "personalProfit": "PersonalProfit", "corporation": "AllowCorporation"}
		vrm_meta.commercial_usage_type = commercial_usage_map[vrm_extension["meta"].get("commercialUsage", "")]
		vrm_meta.political_religious_usage = "Allow" if vrm_extension["meta"].get("allowPoliticalOrReligiousUsage", false) else "Disallow"
		vrm_meta.antisocial_hate_usage = "Allow" if vrm_extension["meta"].get("allowAntisocialOrHateUsage", false) else "Disallow"
		var credit_notation_map = {"": "", "required": "Required", "unnecessary": "Unnecessary"}
		vrm_meta.credit_notation = credit_notation_map[vrm_extension["meta"].get("creditNotation", "")]
		vrm_meta.allow_redistribution = "Allow" if vrm_extension["meta"].get("allowRedistribution", false) else "Disallow"
		var modification_map = {"prohibited": "Prohibited", "allowModification": "AllowModification", "allowModificationRedistribution": "AllowModificationRedistribution"}
		vrm_meta.modification = modification_map[vrm_extension["meta"].get("modification", "")]
		vrm_meta.license_name = vrm_extension["meta"].get("licenseName", "")
		vrm_meta.license_url = vrm_extension["meta"].get("licenseUrl", "")
		vrm_meta.third_party_licenses = vrm_extension["meta"].get("thirdPartyLicenses", "")
		vrm_meta.other_license_url = vrm_extension["meta"].get("otherLicenseUrl", "")

	vrm_meta.eye_offset = eyeOffset
	vrm_meta.humanoid_bone_mapping = humanBones
	return vrm_meta

static func _validate_meta(vrm_meta: vrm_meta_class) -> PackedStringArray:
	if vrm_meta == null:
		return PackedStringArray(["vrm_meta"])
	var missing: PackedStringArray = []
	for prop in ["allowed_user_name","violent_usage","sexual_usage","commercial_usage_type",
			"political_religious_usage","antisocial_hate_usage",
			"credit_notation","allow_redistribution", "modification",
			"title", "author"]:
		var val: Variant = vrm_meta.get(prop)
		print(str(prop)+":"+str(val))
		if typeof(val) != TYPE_STRING or val.strip_edges() == "":
			missing.append(prop)
	return missing
	
func _export_meta(vrm_meta: vrm_meta_class, vrm_extension: Dictionary, gstate: GLTFState):
	var meta_obj: Dictionary = {}
	meta_obj["specVersion"] = vrm_meta.spec_version
	meta_obj["name"] = vrm_meta.title
	meta_obj["version"] = vrm_meta.version
	meta_obj["authors"] = Array(vrm_meta.authors)
	meta_obj["contactInformation"] = vrm_meta.contact_information
	meta_obj["references"] = Array(vrm_meta.references)
	#FIXME: var tex: int = vrm_extension["meta"].get("thumbnailImage", -1) vrm_meta.thumbnailImage
	var avatar_permission_map_rev = {"OnlyAuthor": "onlyAuthor", "ExplicitlyLicensedPerson": "onlySeparatelyLicensedPerson", "Everyone": "everyone"}
	var commercial_usage_map_rev = {"PersonalNonProfit": "personalNonProfit", "PersonalProfit": "personalProfit", "AllowCorporation": "corporation"}
	var credit_notation_map_rev = {"Required": "required", "Unnecessary": "unnecessary"}
	var modification_map_rev = {"Prohibited": "prohibited", "AllowModification": "allowModification", "AllowModificationRedistribution": "allowModificationRedistribution"}
	meta_obj["avatarPermission"] = avatar_permission_map_rev[vrm_meta.allowed_user_name]
	meta_obj["allowExcessivelyViolentUsage"] = vrm_meta.violent_usage == "Allow"
	meta_obj["allowExcessivelySexualUsage"] = vrm_meta.sexual_usage == "Allow"
	meta_obj["commercialUsage"] = commercial_usage_map_rev[vrm_meta.commercial_usage_type]
	meta_obj["allowPoliticalOrReligiousUsage"] = vrm_meta.political_religious_usage == "Allow"
	meta_obj["allowAntisocialOrHateUsage"] = vrm_meta.antisocial_hate_usage == "Allow"
	meta_obj["creditNotation"] = credit_notation_map_rev[vrm_meta.credit_notation]
	meta_obj["allowRedistribution"] = vrm_meta.allow_redistribution == "Allow"
	meta_obj["modification"] = modification_map_rev[vrm_meta.modification]
	meta_obj["licenseName"] = vrm_meta.license_name
	meta_obj["licenseUrl"] = vrm_meta.license_url
	meta_obj["thirdPartyLicenses"] = vrm_meta.third_party_licenses
	meta_obj["otherLicenseUrl"] = vrm_meta.other_license_url
	vrm_extension["meta"] = meta_obj

const vrm_animation_to_look_at : Dictionary = {
		"lookLeft": "rangeMapHorizontalOuter",
		"lookRight": "rangeMapHorizontalOuter",
		"lookDown": "rangeMapVerticalDown",
		"lookUp": "rangeMapVerticalUp",
	}
const vrm_animation_presets: Dictionary = {
		"happy": true,
		"angry": true,
		"sad": true,
		"relaxed": true,
		"surprised": true,
		"aa": true,
		"ih": true,
		"ou": true,
		"ee": true,
		"oh": true,
		"blink": true,
		"blinkLeft": true,
		"blinkRight": true,
		"lookUp": true,
		"lookDown": true,
		"lookLeft": true,
		"lookRight": true,
		"neutral": true,
}

func _create_animation(default_values: Dictionary, default_blend_shapes: Dictionary, anim_name: String, expression: Dictionary, animplayer: AnimationPlayer, gstate: GLTFState, material_idx_to_mesh_and_surface_idx: Dictionary, mesh_idx_to_meshinstance: Dictionary, node_to_head_hidden_node: Dictionary, look_at: Dictionary):
	#print("Blend shape group: " + shape["name"])
	var anim = Animation.new()
	anim.resource_name = anim_name

	var extra_weight: float = 1.0
	var input_key: float = 0.0
	if vrm_animation_to_look_at.has(anim_name):
		extra_weight = look_at.get(vrm_animation_to_look_at[anim_name], {}).get("outputScale", 1.0)
		input_key = look_at.get(vrm_animation_to_look_at[anim_name], {}).get("inputMaxValue", 90.0) / 180.0

	var interpolation_type = Animation.INTERPOLATION_NEAREST if bool(expression["isBinary"]) else Animation.INTERPOLATION_LINEAR
	anim.set_meta("vrm_is_binary", expression.get("isBinary", false))
	anim.set_meta("vrm_override_blink", expression.get("overrideBlink", false))
	anim.set_meta("vrm_override_look_at", expression.get("overrideLookAt", false))
	anim.set_meta("vrm_override_mouth", expression.get("overrideMouth", false))
	for textransformbind in expression.get("textureTransformBinds", []):
		var mesh_and_surface_idx = material_idx_to_mesh_and_surface_idx[int(textransformbind["material"])]
		var node: ImporterMeshInstance3D = mesh_idx_to_meshinstance[mesh_and_surface_idx[0]]
		var surface_idx = mesh_and_surface_idx[1]
		var mat: Material = node.mesh.get_surface_material(surface_idx)
		var scale = textransformbind["scale"]
		var offset = textransformbind["offset"]
		var newvalue1: Variant
		var origvalue1: Variant
		var property_path1: String

		var newvalue2: Variant
		var origvalue2: Variant
		var property_path2: String

		if mat is ShaderMaterial:
			var smat: ShaderMaterial = mat
			var param = smat.get_shader_parameter("_MainTex_ST")
			if param is Vector4:
				newvalue1 = Vector4(scale[0], scale[1], offset[0], offset[1])
				newvalue2 = newvalue1
				origvalue1 = param
				origvalue2 = param
				property_path1 = "shader_parameter/_MainTex_ST"
				if smat.next_pass != null:
					property_path2 = "next_pass:" + property_path1
			else:
				printerr("Unknown type for tex transform parameter" + " surface " + node.name + "/" + str(surface_idx))
		elif mat is BaseMaterial3D:
			var smat: BaseMaterial3D = mat
			property_path1 = "uv1_offset"
			origvalue1 = smat.uv1_offset
			newvalue1 = Vector3(offset[0], offset[1], 0)
			property_path2 = "uv1_scale"
			origvalue2 = smat.uv1_scale
			newvalue2 = Vector3(scale[0], scale[1], 0)

		if not property_path1.is_empty():
			var animtrack: int = anim.add_track(Animation.TYPE_VALUE)
			var anim_path = str(animplayer.get_parent().get_path_to(node)) + ":mesh:surface_" + str(surface_idx) + "/material:" + property_path1
			anim.track_set_path(animtrack, anim_path)
			anim.track_set_interpolation_type(animtrack, interpolation_type)
			anim.track_insert_key(animtrack, input_key, origvalue1.lerp(newvalue1, extra_weight))
			default_values[anim_path] = origvalue1
		if not property_path2.is_empty():
			var animtrack: int = anim.add_track(Animation.TYPE_VALUE)
			var anim_path = str(animplayer.get_parent().get_path_to(node)) + ":mesh:surface_" + str(surface_idx) + "/material:" + property_path2
			anim.track_set_path(animtrack, anim_path)
			anim.track_set_interpolation_type(animtrack, interpolation_type)
			anim.track_insert_key(animtrack, input_key, origvalue2.lerp(newvalue2, extra_weight))
			default_values[anim_path] = origvalue2

	for matbind in expression.get("materialColorBinds", []):
		var mesh_and_surface_idx = material_idx_to_mesh_and_surface_idx[matbind["material"]]
		var node: ImporterMeshInstance3D = mesh_idx_to_meshinstance[mesh_and_surface_idx[0]]
		var surface_idx = mesh_and_surface_idx[1]

		var mat: Material = node.get_surface_material(surface_idx)
		var tv: Array = matbind["targetValue"]
		var property_path: String = ""
		var newvalue: Color = Color(tv[0], tv[1], tv[2], tv[3])
		if matbind["type"] != "color" and matbind["type"] != "outlineColor":
			newvalue.a = 1.0
		var origvalue: Color

		if mat is ShaderMaterial:
			var smat: ShaderMaterial = mat
			var property_mapping = {
				"color": "_Color",
				"emissionColor": "_EmissionColor",
				"shadeColor": "_ShadeColor",
				"matcapColor": "_SphereColor",
				"rimColor": "_RimColor",
				"outlineColor": "_OutlineColor",
			}
			var param = smat.get_shader_parameter(property_mapping.get(matbind["type"], matbind["type"]))
			if param is Color:
				origvalue = param
				property_path = "shader_parameter/" + property_mapping.get(matbind["type"], matbind["type"])
				if matbind["type"] == "outlineColor":
					property_path = "next_pass:" + property_path
			else:
				printerr("Unknown type for parameter " + matbind["type"] + " surface " + node.name + "/" + str(surface_idx))
		elif mat is BaseMaterial3D:
			var smat: BaseMaterial3D = mat
			if matbind["type"] == "color":
				property_path = "albedo_color"
				origvalue = mat.albedo_color
			elif matbind["type"] == "emissionColor":
				property_path = "emission"
				origvalue = mat.emission

		if not property_path.is_empty():
			var animtrack: int = anim.add_track(Animation.TYPE_VALUE)
			var anim_path = str(animplayer.get_parent().get_path_to(node)) + ":mesh:surface_" + str(surface_idx) + "/material:" + property_path
			anim.track_set_path(animtrack, anim_path)
			anim.track_set_interpolation_type(animtrack, interpolation_type)
			anim.track_insert_key(animtrack, input_key, origvalue.lerp(newvalue, extra_weight))
			default_values[anim_path] = origvalue
	for bind in expression.get("morphTargetBinds", []):
		# FIXME: Is this a mesh_idx or a node_idx???
		var node_maybe: Node = gstate.get_scene_node(int(bind["node"]))
		if not node_maybe is ImporterMeshInstance3D:
			push_warning("Morph target bind is a " + str(node_maybe.get_class()))
			continue
		var node: ImporterMeshInstance3D = node_maybe as ImporterMeshInstance3D
		var nodeMesh: ImporterMesh = node.mesh

		if bind["index"] < 0 || bind["index"] >= nodeMesh.get_blend_shape_count():
			printerr("Invalid blend shape index in bind " + str(expression) + " for mesh " + str(node.name))
			continue
		var animtrack: int = anim.add_track(Animation.TYPE_BLEND_SHAPE)
		# nodeMesh.set_blend_shape_name(int(bind["index"]), shape["name"] + "_" + str(bind["index"]))
		var anim_path: String = str(animplayer.get_parent().get_path_to(node)) + ":" + str(nodeMesh.get_blend_shape_name(int(bind["index"])))
		anim.track_set_path(animtrack, anim_path)
		anim.track_set_interpolation_type(animtrack, interpolation_type)
		# FIXME: Godot has weird normal/tangent singularities at weight=1.0 or weight=0.5
		anim.blend_shape_track_insert_key(animtrack, input_key, 0.99999 * float(bind["weight"]) / 100.0)
		#var mesh:ArrayMesh = meshes[bind["mesh"]].mesh
		#print("Mesh name: " + mesh.resource_name)
		#print("Bind index: " + str(bind["index"]))
		#print("Bind weight: " + str(float(bind["weight"]) / 100.0))
		var head_hidden_node: ImporterMeshInstance3D = node_to_head_hidden_node.get(node, null)
		if head_hidden_node != null:
			animtrack = anim.add_track(Animation.TYPE_BLEND_SHAPE)
			# nodeMesh.set_blend_shape_name(int(bind["index"]), shape["name"] + "_" + str(bind["index"]))
			anim_path = str(animplayer.get_parent().get_path_to(head_hidden_node)) + ":" + str(nodeMesh.get_blend_shape_name(int(bind["index"])))
			anim.track_set_path(animtrack, anim_path)
			anim.track_set_interpolation_type(animtrack, interpolation_type)
			# FIXME: Godot has weird normal/tangent singularities at weight=1.0 or weight=0.5
			anim.blend_shape_track_insert_key(animtrack, input_key, extra_weight * 0.99999 * float(bind["weight"]) / 100.0)
			default_blend_shapes[anim_path] = 0.0 # TODO: Find the default value from gltf??

	return anim

func _recurse_bones(bones: Dictionary, skel: Skeleton3D, bone_idx: int):
	bones[skel.get_bone_name(bone_idx)] = bone_idx
	for child in skel.get_bone_children(bone_idx):
		_recurse_bones(bones, skel, child)


func _generate_hide_bone_mesh(mesh: ImporterMesh, skin: Skin, bone_names_to_hide: Dictionary) -> ImporterMesh:
	var bind_indices_to_hide: Dictionary = {}
	
	for i in range(skin.get_bind_count()):
		var bind_name: StringName = skin.get_bind_name(i)
		if bind_name != &"":
			if bone_names_to_hide.has(bind_name):
				bind_indices_to_hide[bone_names_to_hide[bind_name]] = true
		else: # non-named binds???
			if bone_names_to_hide.values().count(skin.get_bind_bone(i)) != 0:
				bind_indices_to_hide[bone_names_to_hide[bind_name]] = true

	# MESH and SKIN data divide, to compensate for object position multiplying.
	var surf_count: int = mesh.get_surface_count()
	var surf_data_by_mesh = [].duplicate()
	var blendshapes = []
	for bsidx in mesh.get_blend_shape_count():
		blendshapes.append(mesh.get_blend_shape_name(bsidx))
	var did_hide_any_surface_verts: bool = false
	for surf_idx in range(surf_count):
		var prim: int = mesh.get_surface_primitive_type(surf_idx)
		var fmt_compress_flags: int = mesh.get_surface_format(surf_idx)
		var arr: Array = mesh.get_surface_arrays(surf_idx)
		var name: String = mesh.get_surface_name(surf_idx)
		var bscount = mesh.get_blend_shape_count()
		var bsarr: Array[Array] = []
		for bsidx in range(bscount):
			bsarr.append(mesh.get_surface_blend_shape_arrays(surf_idx, bsidx))
		var lods: Dictionary = {}  # mesh.surface_get_lods(surf_idx) # get_lods(mesh, surf_idx)
		var mat: Material = mesh.get_surface_material(surf_idx)
		var vert_arr_len: int = len(arr[ArrayMesh.ARRAY_VERTEX])
		var hide_verts: PackedInt32Array
		hide_verts.resize(vert_arr_len)
		var did_hide_verts: bool = false
		if typeof(arr[ArrayMesh.ARRAY_BONES]) == TYPE_PACKED_INT32_ARRAY:
			var bonearr: PackedInt32Array = arr[ArrayMesh.ARRAY_BONES]
			var bones_per_vert = len(bonearr) / vert_arr_len
			var outidx = 0
			for i in range(vert_arr_len):
				var keepvert = true
				for j in range(bones_per_vert):
					if bind_indices_to_hide.has(bonearr[i + j * bones_per_vert]):
						hide_verts[i] = 1
						did_hide_verts = true
						did_hide_any_surface_verts = true
						break
		if did_hide_verts and prim == Mesh.PRIMITIVE_TRIANGLES:
			var indexarr: PackedInt32Array = arr[ArrayMesh.ARRAY_INDEX]
			var new_indexarr: PackedInt32Array = PackedInt32Array()
			for i in range(0, len(indexarr) - 2, 3):
				if hide_verts[indexarr[i]] == 0 && hide_verts[indexarr[i + 1]] == 0 && hide_verts[indexarr[i + 2]] == 0:
					new_indexarr.append(indexarr[i])
					new_indexarr.append(indexarr[i + 1])
					new_indexarr.append(indexarr[i + 2])
			arr[ArrayMesh.ARRAY_INDEX] = new_indexarr
			if new_indexarr.is_empty():
				continue # We skip this primitive entirely.

		surf_data_by_mesh.push_back({"prim": prim, "arr": arr, "bsarr": bsarr, "lods": lods, "fmt_compress_flags": fmt_compress_flags, "name": name, "mat": mat})

	if len(surf_data_by_mesh) == 0: # all primitives were gobbled up
		return null
	if not did_hide_any_surface_verts:
		return mesh

	var new_mesh: ImporterMesh = ImporterMesh.new()
	new_mesh.set_blend_shape_mode(mesh.get_blend_shape_mode())
	new_mesh.set_lightmap_size_hint(mesh.get_lightmap_size_hint())
	new_mesh.resource_name = mesh.resource_name
	for blend_name in blendshapes:
		new_mesh.add_blend_shape(blend_name)
	for surf_idx in range(len(surf_data_by_mesh)):
		var prim: int = surf_data_by_mesh[surf_idx].get("prim")
		var arr: Array = surf_data_by_mesh[surf_idx].get("arr")
		var bsarr: Array[Array] = surf_data_by_mesh[surf_idx].get("bsarr")
		var lods: Dictionary = surf_data_by_mesh[surf_idx].get("lods")
		var fmt_compress_flags: int = surf_data_by_mesh[surf_idx].get("fmt_compress_flags")
		var name: String = surf_data_by_mesh[surf_idx].get("name")
		var mat: Material = surf_data_by_mesh[surf_idx].get("mat")
		new_mesh.add_surface(prim, arr, bsarr, lods, mat, name, fmt_compress_flags)
	return new_mesh


func _create_animation_player(
	animplayer: AnimationPlayer, vrm_extension: Dictionary, gstate: GLTFState, human_bone_to_idx: Dictionary, pose_diffs: Array[Basis]
) -> AnimationPlayer:
	# Remove all glTF animation players for safety.
	# VRM does not support animation import in this way.
	for i in range(gstate.get_animation_players_count(0)):
		var node: AnimationPlayer = gstate.get_animation_player(i)
		node.get_parent().remove_child(node)

	var animation_library: AnimationLibrary = AnimationLibrary.new()

	var materials = gstate.get_materials()
	var meshes = gstate.get_meshes()
	var nodes = gstate.get_nodes()

	var firstperson = vrm_extension.get("firstPerson", {})
	var lookAt = vrm_extension.get("lookAt", {})

	var skeletons: Array = gstate.get_skeletons()

	var head_relative_bones: Dictionary = {} # To determine which meshes to hide.

	var mesh_to_head_hidden_mesh: Dictionary = {}
	var node_to_head_hidden_node: Dictionary = {}

	var lefteye: int = human_bone_to_idx.get("leftEye", -1)
	var righteye: int = human_bone_to_idx.get("rightEye", -1)

	var head_bone_idx = human_bone_to_idx.get("head", -1)
	if head_bone_idx >= 0:
		var headNode: GLTFNode = nodes[head_bone_idx]
		var skel: Skeleton3D = _get_skel_godot_node(gstate, nodes, skeletons, headNode.skeleton)

		var head_attach: BoneAttachment3D = null
		for child in skel.find_children("*", "BoneAttachment3D"):
			var child_attach: BoneAttachment3D = child as BoneAttachment3D
			if child_attach.bone_name == "Head":
				head_attach = child_attach
				break
		if head_attach == null:
			head_attach = BoneAttachment3D.new()
			head_attach.name = "Head"
			skel.add_child(head_attach)
			head_attach.owner = skel.owner
			head_attach.bone_name = "Head"
			var head_bone_offset: Node3D = Node3D.new()
			head_bone_offset.name = "LookOffset"
			head_attach.add_child(head_bone_offset)
			head_bone_offset.unique_name_in_owner = true
			head_bone_offset.owner = skel.owner
			var look_offset = Vector3(0,0,0)
			if lookAt.has("offsetFromHeadBone"):
				var gltf_look_offset = lookAt["offsetFromHeadBone"]
				look_offset = Vector3(gltf_look_offset[0], gltf_look_offset[1], gltf_look_offset[2])
			elif lefteye >= 0 and righteye >= 0:
				look_offset = skel.get_bone_rest(lefteye).origin.lerp(skel.get_bone_rest(righteye).origin, 0.5)
			head_bone_offset.position = look_offset

		_recurse_bones(head_relative_bones, skel, head_bone_idx)

	var mesh_annotations_by_node = {}
	for meshannotation in firstperson.get("meshAnnotations", []):
		mesh_annotations_by_node[int(meshannotation["node"])] = meshannotation

	for node_idx in range(len(nodes)):
		var gltf_node: GLTFNode = nodes[node_idx]
		var node: Node = gstate.get_scene_node(node_idx)
		if node is ImporterMeshInstance3D:
			var meshannotation = mesh_annotations_by_node.get(node_idx, {})

			var flag: String = meshannotation.get("firstPersonFlag", "auto")

			# Non-skinned meshes: use flag.
			var mesh: ImporterMesh = node.mesh
			var head_hidden_mesh: ImporterMesh = mesh
			if flag == "auto":
				if node.skin == null:
					var parent_node = node.get_parent()
					if parent_node is BoneAttachment3D:
						if head_relative_bones.has(parent_node.bone_name):
							flag = "thirdPersonOnly"
				else:
					head_hidden_mesh = _generate_hide_bone_mesh(mesh, node.skin, head_relative_bones)
					if head_hidden_mesh == null:
						flag = "thirdPersonOnly"
					if head_hidden_mesh == mesh:
						flag = "both" # Nothing to do: No head verts.

			var layer_mask: int = 6 # "both"
			if flag == "thirdPersonOnly":
				layer_mask = 4
			elif flag == "firstPersonOnly":
				layer_mask = 2
				
			if flag == "auto": # If it is still "auto", we have something to hide.
				mesh_to_head_hidden_mesh[mesh] = head_hidden_mesh
				var head_hidden_node: ImporterMeshInstance3D = ImporterMeshInstance3D.new()
				head_hidden_node.name = node.name + " (Headless)"
				head_hidden_node.skin = node.skin
				head_hidden_node.mesh = head_hidden_mesh
				head_hidden_node.skeleton_path = node.skeleton_path
				head_hidden_node.owner = node.owner
				head_hidden_node.set_meta("layers", 2) # ImporterMeshInstance3D is missing APIs.
				node.add_sibling(head_hidden_node)
				gstate.meshes.append(head_hidden_mesh)
				node_to_head_hidden_node[node] = head_hidden_node
				layer_mask = 4

			node.set_meta("layers", layer_mask) # ImporterMeshInstance3D is missing APIs.


	var expressions = vrm_extension.get("expressions", {})
	# FIXME: Do we need to handle multiple references to the same mesh???
	var mesh_idx_to_meshinstance: Dictionary = {}
	var material_idx_to_mesh_and_surface_idx: Dictionary = {}
	var material_to_idx: Dictionary = {}
	for i in range(materials.size()):
		material_to_idx[materials[i]] = i
	for i in range(meshes.size()):
		var gltfmesh: GLTFMesh = meshes[i]
		for j in range(gltfmesh.mesh.get_surface_count()):
			material_idx_to_mesh_and_surface_idx[material_to_idx[gltfmesh.mesh.get_surface_material(j)]] = [i, j]

	for i in range(nodes.size()):
		var gltfnode: GLTFNode = nodes[i]
		var mesh_idx: int = gltfnode.mesh
		#print("node idx " + str(i) + " node name " + gltfnode.resource_name + " mesh idx " + str(mesh_idx))
		if mesh_idx != -1:
			var scenenode: ImporterMeshInstance3D = gstate.get_scene_node(i)
			mesh_idx_to_meshinstance[mesh_idx] = scenenode
			#print("insert " + str(mesh_idx) + " node name " + scenenode.name)

	var default_values: Dictionary = {}
	var default_blend_shapes: Dictionary = {}
	for expression_name in expressions.get("preset", {}):
		var expression = expressions["preset"][expression_name]
		if lookAt.get("type", "") != "bone" or not vrm_animation_to_look_at.has(expression_name):
			var anim: Animation = _create_animation(default_values, default_blend_shapes, expression_name, expression, animplayer, gstate, material_idx_to_mesh_and_surface_idx, mesh_idx_to_meshinstance, node_to_head_hidden_node, lookAt)
			# https://github.com/vrm-c/vrm-specification/tree/master/specification/0.0#blendshape-name-identifier
			animation_library.add_animation(expression_name, anim)
		if vrm_animation_to_look_at.has(expression_name):
			expression_name += "Raw"
			var anim: Animation = _create_animation(default_values, default_blend_shapes, expression_name, expression, animplayer, gstate, material_idx_to_mesh_and_surface_idx, mesh_idx_to_meshinstance, node_to_head_hidden_node, {})
			# https://github.com/vrm-c/vrm-specification/tree/master/specification/0.0#blendshape-name-identifier
			animation_library.add_animation(expression_name, anim)
	for expression_name in expressions.get("custom", {}):
		if expressions["preset"].has(expression_name):
			continue
		if vrm_animation_to_look_at.has(expression_name):
			continue
		var expression = expressions["custom"][expression_name]
		var anim: Animation = _create_animation(default_values, default_blend_shapes, expression_name, expression, animplayer, gstate, material_idx_to_mesh_and_surface_idx, mesh_idx_to_meshinstance, node_to_head_hidden_node, lookAt)
		# https://github.com/vrm-c/vrm-specification/tree/master/specification/0.0#blendshape-name-identifier
		animation_library.add_animation(expression_name, anim)

	var leftEyePath: String = ""
	var rightEyePath: String = ""
	if lookAt.get("type", "") == "bone" and lefteye >= 0 and righteye >= 0:
		var leftEyeNode: GLTFNode = nodes[lefteye]
		var rightEyeNode: GLTFNode = nodes[righteye]
		var skeleton: Skeleton3D = _get_skel_godot_node(gstate, nodes, skeletons, leftEyeNode.skeleton)
		var skeletonPath: NodePath = animplayer.get_parent().get_path_to(skeleton)
		leftEyePath = (str(skeletonPath) + ":" + nodes[human_bone_to_idx["leftEye"]].resource_name)
		rightEyePath = (str(skeletonPath) + ":" + nodes[human_bone_to_idx["rightEye"]].resource_name)

	if lookAt.get("type", "") == "bone" and not leftEyePath.is_empty() and not rightEyePath.is_empty():
		var horizout = lookAt.get("rangeMapHorizontalOuter", {})
		var horizin = lookAt.get("rangeMapHorizontalOuter", {})
		var vertdown = lookAt.get("rangeMapVerticalDown", {})
		var vertup = lookAt.get("rangeMapVerticalUp", {})


		var anim: Animation = null
		var animtrack: int
		var input_val: float
		pose_diffs[lefteye] = Quaternion()
		pose_diffs[righteye] = Quaternion()
		anim = Animation.new()
		animation_library.add_animation("lookLeft", anim)
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, leftEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = horizout.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[lefteye] * Basis(Vector3(0, 1, 0), horizout.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, rightEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = horizin.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[righteye] * Basis(Vector3(0, 1, 0), horizin.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())

		anim = Animation.new()
		animation_library.add_animation("lookRight", anim)
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, leftEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = horizout.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[lefteye] * Basis(Vector3(0, 1, 0), -horizout.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, rightEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = horizin.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[righteye] * Basis(Vector3(0, 1, 0), -horizin.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())

		anim = Animation.new()
		animation_library.add_animation("lookUp", anim)
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, leftEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = vertup.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[lefteye] * Basis(Vector3(1, 0, 0), vertup.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, rightEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = vertup.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[righteye] * Basis(Vector3(1, 0, 0), vertup.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())

		anim = Animation.new()
		animation_library.add_animation("lookDown", anim)
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, leftEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = vertdown.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[lefteye] * Basis(Vector3(1, 0, 0), -vertdown.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())
		animtrack = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(animtrack, rightEyePath)
		anim.track_set_interpolation_type(animtrack, Animation.INTERPOLATION_LINEAR)
		input_val = vertdown.get("inputMaxValue", 90) / 180.0
		anim.rotation_track_insert_key(animtrack, input_val,
			(pose_diffs[righteye] * Basis(Vector3(1, 0, 0), -vertdown.get("outputScale", 1.0) * input_val * 3.14159 / 180.0)).get_rotation_quaternion())

	var reset_anim: Animation = Animation.new()
	reset_anim.resource_name = "RESET"
	for anim_path in default_values:
		var animtrack: int = reset_anim.add_track(Animation.TYPE_VALUE)
		reset_anim.track_set_path(animtrack, anim_path)
		reset_anim.track_insert_key(animtrack, 0.0, default_values[anim_path])
	for anim_path in default_blend_shapes:
		var animtrack: int = reset_anim.add_track(Animation.TYPE_BLEND_SHAPE)
		reset_anim.track_set_path(animtrack, anim_path)
		reset_anim.blend_shape_track_insert_key(animtrack, 0.0, default_blend_shapes[anim_path])

	if lookAt.get("type", "") == "bone" and not leftEyePath.is_empty() and not rightEyePath.is_empty():
		var animtrack = reset_anim.add_track(Animation.TYPE_ROTATION_3D)
		reset_anim.track_set_path(animtrack, leftEyePath)
		reset_anim.rotation_track_insert_key(animtrack, 0.0, pose_diffs[lefteye].get_rotation_quaternion() * Quaternion.IDENTITY)
		animtrack = reset_anim.add_track(Animation.TYPE_ROTATION_3D)
		reset_anim.track_set_path(animtrack, rightEyePath)
		reset_anim.rotation_track_insert_key(animtrack, 0.0, pose_diffs[righteye].get_rotation_quaternion() * Quaternion.IDENTITY)

	

	animation_library.add_animation(&"RESET", reset_anim)

	animplayer.add_animation_library("", animation_library)
	return animplayer

func _export_animations(root_node: Node, skel: Skeleton3D, animplayer: AnimationPlayer, vrm_extension: Dictionary, gstate: GLTFState):

	var first_person = {}
	var mesh_annotations = []

	var nodes = gstate.nodes
	for node_idx in range(len(nodes)):
		var gltf_node: GLTFNode = nodes[node_idx]
		var node: Node = gstate.get_scene_node(node_idx)
		if node is ImporterMeshInstance3D:
			var layers = node.get_meta("layers", 0) # ImporterMeshInstance3D is missing APIs.
			var mesh_annotation = {"node": node_idx}
			if layers == 2:
				mesh_annotation["firstPersonType"] = "firstPersonOnly"
			elif layers == 4:
				mesh_annotation["firstPersonType"] = "thirdPersonOnly"
			elif layers == 6:
				mesh_annotation["firstPersonType"] = "both"
			else:
				mesh_annotation["firstPersonType"] = "auto"
			mesh_annotations.append(mesh_annotation)

	first_person["meshAnnotations"] = mesh_annotations
	vrm_extension["firstPerson"] = first_person

	var look_left_anim: Animation = animplayer.get_animation("lookLeft")
	var look_up_anim: Animation = animplayer.get_animation("lookUp")
	var look_down_anim: Animation = animplayer.get_animation("lookDown")
	var look_at = {"rangeMapHorizontalInner": {}, "rangeMapHorizontalOuter": {}, "rangeMapVerticalDown": {}, "rangeMapVerticalUp": {}}
	if look_left_anim.track_get_type(0) == Animation.TYPE_ROTATION_3D:
		look_at["type"] = "bone"
	else:
		look_at["type"] = "expression"
	if look_at["type"] == "bone":
		for i in range(look_left_anim.get_track_count()):
			var key: String
			if look_left_anim.track_get_path(i).get_subname(0) == "leftEye":
				key = "rangeMapHorizontalOuter"
			elif look_left_anim.track_get_path(i).get_subname(0) == "rightEye":
				key = "rangeMapHorizontalInner"
			else:
				continue
			var look_length = look_left_anim.track_get_key_time(i, 0)
			var quat: Quaternion = look_left_anim.track_get_key_value(i, 0)
			var angle_from_quat: float = quat.get_angle() * sign(quat.get_axis().y)
			look_at[key] = {"inputMaxValue": look_length * 180.0, "outputScale": abs(angle_from_quat * 180.0 / PI)}
		for i in range(look_up_anim.get_track_count()):
			if look_up_anim.track_get_path(i).get_subname(0) != "leftEye":
				continue
			var look_length = look_up_anim.track_get_key_time(i, 0)
			var quat: Quaternion = look_up_anim.track_get_key_value(i, 0)
			var angle_from_quat: float = quat.get_angle() * sign(quat.get_axis().y)
			look_at["rangeMapVerticalUp"] = {"inputMaxValue": look_length * 180.0, "outputScale": abs(angle_from_quat * 180.0 / PI)}
		for i in range(look_down_anim.get_track_count()):
			if look_down_anim.track_get_path(i).get_subname(0) != "leftEye":
				continue
			var look_length = look_down_anim.track_get_key_time(i, 0)
			var quat: Quaternion = look_down_anim.track_get_key_value(i, 0)
			var angle_from_quat: float = quat.get_angle() * sign(quat.get_axis().y)
			look_at["rangeMapVerticalDown"] = {"inputMaxValue": look_length * 180.0, "outputScale": abs(angle_from_quat * 180.0 / PI)}
	else:
		var look_length = look_left_anim.track_get_key_time(0, 0)
		look_at["rangeMapHorizontalOuter"] = {"inputMaxValue": look_length * 180.0, "outputScale": 1.0}
		look_at["rangeMapHorizontalInner"] = {"inputMaxValue": look_length * 180.0, "outputScale": 1.0}
		look_length = look_up_anim.track_get_key_time(0, 0)
		look_at["rangeMapVerticalUp"] = {"inputMaxValue": look_length * 180.0, "outputScale": 1.0}
		look_length = look_down_anim.track_get_key_time(0, 0)
		look_at["rangeMapVerticalDown"] = {"inputMaxValue": look_length * 180.0, "outputScale": 1.0}

	# TODO: port VRM 0.0 names.
	var presets: Dictionary = {}
	var custom: Dictionary = {}
	var mat_lookup: Dictionary = {}
	var gltf_materials: Array[Material] = gstate.materials
	for i in range(len(gltf_materials)):
		mat_lookup[gltf_materials[i]] = i
	var mesh_bs_lookup: Dictionary = {}
	var gltf_meshes: Array[GLTFMesh] = gstate.meshes
	for i in range(len(gltf_meshes)):
		var mesh: ImporterMesh = gltf_meshes[i].mesh
		var blend_shape_to_idx: Dictionary = {}
		for bsi in range(mesh.get_blend_shape_count()):
			blend_shape_to_idx[mesh.get_blend_shape_name(bsi)] = bsi
		mesh_bs_lookup[gltf_meshes[i].mesh] = blend_shape_to_idx

	for exp in animplayer.get_animation_list():
		if exp == "RESET":
			continue
		var expression: Dictionary = {}
		var texture_transform_binds = {}
		var morph_target_binds = []
		var material_color_binds = []
		var anim: Animation = animplayer.get_animation(exp)
		for i in range(anim.get_track_count()):
			var anim_path = anim.track_get_path(i)
			var meshinst = animplayer.get_parent().get_node(NodePath(str(anim_path.get_concatenated_names()))) as ImporterMeshInstance3D
			var val = anim.track_get_key_value(i, 0)
			if anim.track_get_type(i) == Animation.TYPE_BLEND_SHAPE:
				var gltf_blendshape_idx = mesh_bs_lookup[meshinst][anim_path.get_subname(0)]
				morph_target_binds.push_back({"node": gstate.get_node_index(meshinst), "index": gltf_blendshape_idx, "weight": val})
			elif anim.track_get_type(i) == Animation.TYPE_VALUE:
				var material_idx = int(anim_path.get_subname(1).split("/")[0].split("_")[1])
				var gltf_material_idx = mat_lookup[meshinst.mesh.get_surface_material(material_idx)]
				if typeof(val) == TYPE_COLOR:
					var property_mapping = {
						"shader_parameter/_Color": "color",
						"shader_parameter/_EmissionColor": "emissionColor",
						"shader_parameter/_ShadeColor": "shadeColor",
						"shader_parameter/_SphereColor": "matcapColor",
						"shader_parameter/_RimColor": "rimColor",
						"shader_parameter/_OutlineColor": "outlineColor",
						"albedo_color": "color",
						"emission": "emissionColor",
					}
					var shader_prop = anim_path.get_subname(2)
					if not property_mapping.has(shader_prop):
						push_warning("Unable to serialize color animation " + str(shader_prop) + " for material " + str(gltf_materials[gltf_material_idx].resource_name))
						continue
					var material_bind = {"material": gltf_material_idx, "type": property_mapping[shader_prop], "targetValue": [val.r, val.g, val.b, val.a]}
					material_color_binds.push_back(material_bind)
				elif typeof(val) == TYPE_VECTOR4:
					var shader_prop = anim_path.get_subname(2)
					assert(shader_prop == "shader_parameter/_MainTex_ST")
					texture_transform_binds[gltf_material_idx] = {"material": gltf_material_idx, "scale": [val.x, val.y], "offset": [val.z, val.w]}
				elif typeof(val) == TYPE_VECTOR3:
					var shader_prop = anim_path.get_subname(2)
					if not texture_transform_binds.has(gltf_material_idx):
						texture_transform_binds[gltf_material_idx] = {}
					var tex_bind = texture_transform_binds[gltf_material_idx]
					tex_bind["material"] = gltf_material_idx
					if shader_prop == "uv1_offset":
						tex_bind["offset"] = [val.z, val.w]
					elif shader_prop == "uv1_scale":
						tex_bind["scale"] = [val.x, val.y]

		expression["morphTargetBinds"] = morph_target_binds
		expression["materialColorBinds"] = material_color_binds
		expression["textureTransformBinds"] = texture_transform_binds.values()
		expression["isBinary"] = anim.get_meta("vrm_is_binary", anim.track_get_interpolation_type(0) == Animation.INTERPOLATION_NEAREST)
		if anim.has_meta("vrm_override_blink"):
			expression["overrideBlink"] = anim.get_meta("vrm_override_blink")
		if anim.has_meta("vrm_override_blink"):
			expression["overrideLookAt"] = anim.get_meta("vrm_override_look_at")
		if anim.has_meta("vrm_override_blink"):
			expression["overrideMouth"] = anim.get_meta("vrm_override_mouth")
		if vrm_animation_presets.has(exp):
			presets[exp] = expression
		elif "/" not in exp:
			custom[exp] = expression

	var expressions: Dictionary = {"preset": presets, "custom": custom}
	vrm_extension["expressions"] = expressions

func _add_joints_recursive(new_joints_set: Dictionary, gltf_nodes: Array, bone: int, include_child_meshes: bool = false) -> void:
	if bone < 0:
		return
	var gltf_node: Dictionary = gltf_nodes[bone]
	if not include_child_meshes and gltf_node.get("mesh", -1) != -1:
		return
	new_joints_set[bone] = true
	for child_node in gltf_node.get("children", []):
		if not new_joints_set.has(child_node):
			_add_joints_recursive(new_joints_set, gltf_nodes, int(child_node))


func _add_joint_set_as_skin(obj: Dictionary, new_joints_set: Dictionary) -> void:
	var new_joints = [].duplicate()
	for node in new_joints_set:
		new_joints.push_back(node)
	new_joints.sort()

	var new_skin: Dictionary = {"joints": new_joints}

	if not obj.has("skins"):
		obj["skins"] = [].duplicate()

	obj["skins"].push_back(new_skin)


func _add_vrm_nodes_to_skin(obj: Dictionary) -> bool:
	var vrm_extension: Dictionary = obj.get("extensions", {}).get("VRMC_vrm", {})
	if not vrm_extension.has("humanoid"):
		return false
	var new_joints_set = {}.duplicate()

	var human_bones: Dictionary = vrm_extension["humanoid"]["humanBones"]
	var gltf_nodes: Array = obj["nodes"]
	for i in range(len(gltf_nodes)):
		if gltf_nodes[i]["name"] == "Root":
			pass
			
	for human_bone in human_bones:
		_add_joints_recursive(new_joints_set, obj["nodes"], int(human_bones[human_bone]["node"]), false)
	_add_joint_set_as_skin(obj, new_joints_set)

	return true


func remove_null_owner(node: Node):
	if node.owner == null:
		node.get_parent().remove_child(node)
		node.queue_free()
		return
	for child in node.get_children():
		remove_null_owner(child)

const required_bones = ["hips", "spine", "head", "leftUpperLeg", "leftLowerLeg", "leftFoot", "rightUpperLeg", "rightLowerLeg", "rightFoot", "leftUpperArm", "leftLowerArm", "leftHand", "rightUpperArm", "rightLowerArm", "rightHand"]

func _export_preflight(gstate: GLTFState, root: Node) -> Error:
	if gstate.get_meta("vrm", "") != "1.0":
		return ERR_INVALID_DATA
	if root.script != vrm_top_level:
		return ERR_INVALID_DATA
	gstate.set_meta("vrm_root", root)

	# Do not call remove_null_owner on root, since root will not have an owner.
	for node in root.get_children():
		remove_null_owner(node) # should be done by builtin exporter.
	var vrm_extension: Dictionary = {}
	var humanoid_skeleton: Skeleton3D = _get_humanoid_skel(root)
	var anim_player: AnimationPlayer
	if root.has_node("AnimationPlayer"):
		anim_player = root.get_node("AnimationPlayer") as AnimationPlayer
	if anim_player == null:
		for n in root.get_children():
			if n is AnimationPlayer:
				anim_player = n
				break
	if anim_player != null:
		_export_animations(root, humanoid_skeleton, anim_player, vrm_extension, gstate)
		anim_player.get_parent().remove_child(anim_player)
		anim_player.queue_free()
	gstate.set_meta("vrm_extension", vrm_extension)

	gstate.add_used_extension("VRMC_vrm", false)
	var skels = root.find_children("*", "Skeleton3D")
	for skelx in skels:
		var skel: Skeleton3D = skelx
		var root_bone: int = skel.find_bone("Root")
		if root_bone == -1:
			continue
		var root_children = skel.get_bone_children(root_bone)
		var root_parent = skel.get_bone_parent(root_bone)
		for b in root_children:
			skel.set_bone_parent(b, root_parent)
		# remove_bone(idx):
		var bone_storage = []
		for b in range(skel.get_bone_count()):
			var parent: int = skel.get_bone_parent(b)
			if parent > root_bone:
				parent -= 1
			if b != root_bone:
				bone_storage.append([skel.get_bone_name(b), parent, skel.get_bone_rest(b),
					skel.get_bone_pose_position(b), skel.get_bone_pose_rotation(b), skel.get_bone_pose_scale(b)])
		skel.clear_bones()
		for bone_data in bone_storage:
			skel.add_bone(bone_data[0])
		for b in range(skel.get_bone_count()):
			var bone_data = bone_storage[b]
			skel.set_bone_parent(b, bone_data[1])
			skel.set_bone_rest(b, bone_data[2])
			skel.set_bone_pose_position(b, bone_data[3])
			skel.set_bone_pose_rotation(b, bone_data[4])
			skel.set_bone_pose_scale(b, bone_data[5])
		var skins: Dictionary = {}
		var meshes = root.find_children("*", "ImporterMeshInstance3D")
		for meshx in meshes:
			var mesh: ImporterMeshInstance3D = meshx
			if mesh.skin != null:
				skins[mesh.skin] = true
		meshes = root.find_children("*", "MeshInstance3D")
		for meshx in meshes:
			var mesh: MeshInstance3D = meshx
			if mesh.skin != null:
				skins[mesh.skin] = true
		for skinx in skins:
			var skin: Skin = skinx
			for b in range(skin.get_bind_count()):
				if skin.get_bind_name(b) != "":
					skin.set_bind_name(b, skin.get_bind_name(b))
				var bind_bone = skin.get_bind_bone(b)
				if bind_bone != -1 and bind_bone > root_bone:
					skin.set_bind_bone(b, bind_bone - 1)
	#var ps:PackedScene = PackedScene.new()
	#ps.pack(root)
	#ResourceSaver.save(ps, "res://saved_outgoing_vrm.tscn", ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS)
	return OK

static func _get_humanoid_skel(root_node: Node3D) -> Skeleton3D:
	var humanoid_skeleton: Skeleton3D
	if root_node.has_node("%GeneralSkeleton"):
		humanoid_skeleton = root_node.get_node("%GeneralSkeleton")
	else:
		var skels: Array[Node] = root_node.find_children("*", "Skeleton3D", true)
		if not skels.is_empty():
			humanoid_skeleton = skels[0]
	return humanoid_skeleton

static func _validate_humanoid(root_node: Node3D) -> Dictionary:
	var human_to_vrm_bone: Dictionary
	for vrm_bone in vrm_constants_class.vrm_to_human_bone:
		human_to_vrm_bone[vrm_constants_class.vrm_to_human_bone[vrm_bone]] = vrm_bone


	var humanoid_skeleton: Skeleton3D = _get_humanoid_skel(root_node)

	var vrm_bone_mapping: Dictionary = {}
	for i in range(humanoid_skeleton.get_bone_count()):
		var bone_name = humanoid_skeleton.get_bone_name(i)
		if human_to_vrm_bone.has(bone_name):
			vrm_bone_mapping[human_to_vrm_bone[bone_name]] = bone_name
	for bone_name in required_bones:
		if not vrm_bone_mapping.has(bone_name):
			push_warning("Skeleton " + str(humanoid_skeleton.name) + " missing required humanoid bone " + str(bone_name))
			return {}

	return vrm_bone_mapping

func _export_post(gstate: GLTFState) -> Error:
	var json_gltf_nodes: Array = gstate.json["nodes"]
	for i in range(len(json_gltf_nodes)):
		if json_gltf_nodes[i]["name"] == "Root":
			print("Found a Root at index " + str(i))
		if json_gltf_nodes[i]["name"] == "BoneNodeConstraintApplier":
			print("Found a BoneNodeConstraintApplier at index " + str(i))
			json_gltf_nodes[i]["name"] = "_unused_applier"
	var root_node: Node3D = gstate.get_meta("vrm_root")
	var json: Dictionary = gstate.json

	# HACK: Avoid extra root node to make sure export/import is idempotent.
	var gltf_root_nodes: Array = json["scenes"][0]["nodes"]
	if len(gltf_root_nodes) == 1:
		var orig_gltf_root_node: Dictionary = json["nodes"][gltf_root_nodes[0]]
		var orig_children: Array = orig_gltf_root_node["children"]
		print("Orig root: " + orig_gltf_root_node["name"])
		print("First child: " + json["nodes"][orig_children[0]]["name"])
		orig_gltf_root_node["name"] = "_unused" # Removing nodes in glTF is very difficulty.
		orig_gltf_root_node.erase("children")
		gltf_root_nodes.clear()
		gltf_root_nodes.append_array(orig_children)
		print(gltf_root_nodes)
		print(orig_children)

	var gltf_nodes: Array[GLTFNode] = gstate.nodes

	var vrm_extension: Dictionary = gstate.get_meta("vrm_extension")
	vrm_extension["specVersion"] = "1.0"
	if not json.has("extensions"):
		json["extensions"] = {}
	json["extensions"]["VRMC_vrm"] = vrm_extension
	_export_meta(root_node.vrm_meta, vrm_extension, gstate)

	var orig_bone_map: BoneMap = root_node.vrm_meta.humanoid_bone_mapping
	var orig_bone_name_dict: Dictionary = {}
	if orig_bone_map != null and orig_bone_map.profile != null:
		for i in range(orig_bone_map.profile.bone_size):
			var bn: StringName = orig_bone_map.get_skeleton_bone_name(orig_bone_map.profile.get_bone_name(i))
			if not bn.is_empty():
				orig_bone_name_dict[orig_bone_map.profile.get_bone_name(i)] = bn

	var humanoid_skeleton: Skeleton3D = _get_humanoid_skel(root_node)
	var humanoid_bone_mapping: Dictionary = _validate_humanoid(root_node)
	var godot_bone_to_gltf_node_map: Dictionary
	var human_bones: Dictionary = {}
	var humanoid: Dictionary = {"humanBones": human_bones}
	for skel in gstate.skeletons:
		if skel.get_godot_skeleton() == humanoid_skeleton:
			godot_bone_to_gltf_node_map = skel.get_godot_bone_node()

	for vrm_bone in humanoid_bone_mapping:
		var bone_idx = humanoid_skeleton.find_bone(humanoid_bone_mapping[vrm_bone])
		var gltf_node_idx: int = godot_bone_to_gltf_node_map[bone_idx]
		human_bones[vrm_bone] = {"node": gltf_node_idx}
		if orig_bone_name_dict.has(json_gltf_nodes[gltf_node_idx]["name"]):
			json_gltf_nodes[gltf_node_idx]["name"] = orig_bone_name_dict[json_gltf_nodes[gltf_node_idx]["name"]]
	vrm_extension["humanoid"] = humanoid

	var ei: EditorInspector = EditorInspector.new()

	if not _add_vrm_nodes_to_skin(json):
		push_error("Failed to find vrm humanBones in VRMC_vrm extension")
		return ERR_INVALID_DATA
	# firstPerson
	# lookAt
	# expressions

	return OK

func _import_preflight(gstate: GLTFState, extensions: PackedStringArray = PackedStringArray()) -> Error:
	if not extensions.has("VRMC_vrm"):
		return ERR_INVALID_DATA
	var gltf_json_parsed: Dictionary = gstate.json
	var gltf_nodes = gltf_json_parsed["nodes"]
	if not _add_vrm_nodes_to_skin(gltf_json_parsed):
		push_error("Failed to find vrm humanBones in VRMC_vrm extension")
		return ERR_INVALID_DATA
	for node in gltf_nodes:
		if node.get("name","") == "Root":
			node["name"] = "Root_"
		if node.get("name","") == "AnimationPlayer":
			node["name"] = "AnimationPlayer_"
		if node.get("name","") == "BoneNodeConstraintApplier":
			node["name"] = "BoneNodeConstraintApplier_"
	return OK


func apply_retarget(gstate: GLTFState, root_node: Node, skeleton: Skeleton3D, bone_map: BoneMap) -> Array[Basis]:
	var skeletonPath: NodePath = root_node.get_path_to(skeleton)

	skeleton_rename(gstate, root_node, skeleton, bone_map)
	var hips_bone_idx = skeleton.find_bone("Hips")
	if hips_bone_idx != -1:
		skeleton.motion_scale = abs(skeleton.get_bone_global_rest(hips_bone_idx).origin.y)
		if skeleton.motion_scale < 0.0001:
			skeleton.motion_scale = 1.0

	var poses = skeleton_rotate(root_node, skeleton, bone_map)
	apply_rotation(root_node, skeleton)
	return poses


func _import_post(gstate: GLTFState, node: Node) -> Error:
	var root_node: Node = node

	var gltf_json: Dictionary = gstate.json
	var vrm_extension: Dictionary = gltf_json["extensions"]["VRMC_vrm"]

	var human_bone_to_idx: Dictionary = {}
	# Ignoring in ["humanoid"]: armStretch, legStretch, upperArmTwist
	# lowerArmTwist, upperLegTwist, lowerLegTwist, feetSpacing,
	# and hasTranslationDoF
	var human_bones: Dictionary = vrm_extension["humanoid"]["humanBones"]
	for human_bone in human_bones:
		human_bone_to_idx[human_bone] = int(human_bones[human_bone]["node"])

	var skeletons = gstate.get_skeletons()
	var hipsNode: GLTFNode = gstate.nodes[human_bone_to_idx["hips"]]
	var skeleton: Skeleton3D = _get_skel_godot_node(gstate, gstate.nodes, skeletons, hipsNode.skeleton)
	var gltfnodes: Array = gstate.nodes

	var humanBones: BoneMap = BoneMap.new()
	humanBones.profile = SkeletonProfileHumanoid.new()

	for humanBoneName in human_bone_to_idx:
		humanBones.set_skeleton_bone_name(vrm_constants_class.vrm_to_human_bone[humanBoneName], gltfnodes[human_bone_to_idx[humanBoneName]].resource_name)

	var do_retarget = true

	var pose_diffs: Array[Basis]
	if do_retarget:
		pose_diffs = apply_retarget(gstate, root_node, skeleton, humanBones)
	else:
		# resize is busted for TypedArray and crashes Godot
		for i in range(skeleton.get_bone_count()):
			pose_diffs.append(Basis.IDENTITY)

	skeleton.set_meta("vrm_pose_diffs", pose_diffs)

	var animplayer: AnimationPlayer
	if root_node.has_node("AnimationPlayer"):
		animplayer = root_node.get_node("AnimationPlayer")
	else:
		animplayer = AnimationPlayer.new()
		animplayer.name = "AnimationPlayer"
		root_node.add_child(animplayer, true)
		animplayer.owner = root_node
	_create_animation_player(animplayer, vrm_extension, gstate, human_bone_to_idx, pose_diffs)

	root_node.set_script(vrm_top_level)

	var vrm_meta: Resource = _create_meta(root_node, animplayer, vrm_extension, gstate, skeleton, humanBones, human_bone_to_idx, pose_diffs)
	root_node.set("vrm_meta", vrm_meta)
	root_node.set("vrm_secondary", NodePath())

	return OK
