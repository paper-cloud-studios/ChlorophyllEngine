package core

// ============================================================
//  CHLOROPHYLL SDK — core/node.odin
//  The universal scene-tree element.
//  Lives in package `core` alongside types.odin and resource.odin.
//  No SDK-internal cross-package imports needed here.
// ============================================================

Component_Flag :: enum u32 {
    Sprite_Renderer,
    Collision_Body,
    Velocity,
    Camera,
    Point_Light,
    Audio_Emitter,
    Script,
}
Component_Flags :: bit_set[Component_Flag; u32]

// ------------------------------------------------------------------
//  Component data
// ------------------------------------------------------------------

Sprite_Renderer_Component :: struct {
    texture_uid : u64,
    modulate    : Color,
    flip_h      : bool,
    flip_v      : bool,
    z_index     : i32,
    visible     : bool,
    src_rect    : Rect2,
}

Collision_Body_Component :: struct {
    shape_uid   : u64,
    is_solid    : bool,
    is_trigger  : bool,
    layer_mask  : u32,
    test_mask   : u32,
}

Velocity_Component :: struct {
    linear  : Vec2,
    angular : f32,
    damping : f32,
}

Camera_Component :: struct {
    zoom       : f32,
    offset     : Vec2,
    is_current : bool,
}

Point_Light_Component :: struct {
    color     : Color,
    radius    : f32,
    intensity : f32,
}

Audio_Emitter_Component :: struct {
    buffer_uid : u64,
    volume     : f32,
    pitch      : f32,
    looping    : bool,
    playing    : bool,
}

Script_Component :: struct {
    script_uid : u64,
    vtable     : ^Script_VTable,
    user_data  : rawptr,
}

// ------------------------------------------------------------------
//  Node
// ------------------------------------------------------------------

Node :: struct {
    // Identity
    id         : Node_ID,
    name       : string,
    tag        : string,

    // Hierarchy
    parent_id  : Node_ID,
    children   : [dynamic]Node_ID,

    // Transforms
    local      : Transform2D,
    global     : Transform2D,

    // Lifecycle
    active      : bool,
    visible     : bool,
    in_tree     : bool,
    ready_fired : bool,

    // Components
    components : Component_Flags,
    sprite     : Sprite_Renderer_Component,
    collision  : Collision_Body_Component,
    velocity   : Velocity_Component,
    camera     : Camera_Component,
    light      : Point_Light_Component,
    audio      : Audio_Emitter_Component,
    script     : Script_Component,

    // Freeform user properties (editor + script)
    properties : map[string]Variant,
}

// ------------------------------------------------------------------
//  Constructors
// ------------------------------------------------------------------

node_create :: proc(name: string) -> ^Node {
    n            := new(Node)
    n.id          = next_id()
    n.name        = name
    n.local       = transform_identity()
    n.global      = transform_identity()
    n.active      = true
    n.visible     = true
    n.children    = make([dynamic]Node_ID)
    n.properties  = make(map[string]Variant)
    return n
}

node_destroy :: proc(n: ^Node) {
    if .Script in n.components && n.script.vtable != nil && n.script.vtable.on_destroy != nil {
        n.script.vtable.on_destroy(n)
    }
    if .Script          in n.components && n.script.script_uid != 0   { resource_release(n.script.script_uid)    }
    if .Sprite_Renderer in n.components && n.sprite.texture_uid != 0  { resource_release(n.sprite.texture_uid)   }
    if .Collision_Body  in n.components && n.collision.shape_uid != 0 { resource_release(n.collision.shape_uid)  }
    delete(n.children)
    delete(n.properties)
    free(n)
}

// ------------------------------------------------------------------
//  Component attach helpers
// ------------------------------------------------------------------

node_add_sprite :: proc(n: ^Node, tex_uid: u64 = 0) {
    n.sprite = {texture_uid=tex_uid, modulate=color_white, visible=true}
    if tex_uid != 0 { resource_retain(tex_uid) }
    n.components += {.Sprite_Renderer}
}

node_add_collision :: proc(n: ^Node, shape_uid: u64, solid: bool = true) {
    n.collision = {shape_uid=shape_uid, is_solid=solid, layer_mask=1, test_mask=1}
    resource_retain(shape_uid)
    n.components += {.Collision_Body}
}

node_add_velocity :: proc(n: ^Node) {
    n.velocity = {}
    n.components += {.Velocity}
}

node_add_camera :: proc(n: ^Node, is_current: bool = false) {
    n.camera = {zoom=1.0, is_current=is_current}
    n.components += {.Camera}
}

node_attach_script :: proc(n: ^Node, vtable: ^Script_VTable, script_uid: u64 = 0) {
    n.script = {vtable=vtable, script_uid=script_uid}
    if script_uid != 0 { resource_retain(script_uid) }
    n.components += {.Script}
}

// ------------------------------------------------------------------
//  Property reflection
// ------------------------------------------------------------------

node_get_property :: proc(n: ^Node, name: string) -> (Variant, bool) {
    switch name {
    case "name":      return variant_string(n.name),            true
    case "tag":       return variant_string(n.tag),             true
    case "active":    return variant_bool(n.active),            true
    case "visible":   return variant_bool(n.visible),           true
    case "pos_x":     return variant_float(n.local.position.x), true
    case "pos_y":     return variant_float(n.local.position.y), true
    case "rotation":  return variant_float(n.local.rotation),   true
    case "scale_x":   return variant_float(n.local.scale.x),    true
    case "scale_y":   return variant_float(n.local.scale.y),    true
    case "z_index":
        if .Sprite_Renderer in n.components { return variant_int(i64(n.sprite.z_index)), true }
    case "is_solid":
        if .Collision_Body in n.components  { return variant_bool(n.collision.is_solid), true }
    case "is_trigger":
        if .Collision_Body in n.components  { return variant_bool(n.collision.is_trigger), true }
    case "vel_x":
        if .Velocity in n.components        { return variant_float(n.velocity.linear.x), true }
    case "vel_y":
        if .Velocity in n.components        { return variant_float(n.velocity.linear.y), true }
    }
    if .Script in n.components && n.script.vtable != nil && n.script.vtable.get_property != nil {
        v := n.script.vtable.get_property(n, name)
        if v.kind != .None { return v, true }
    }
    if v, ok := n.properties[name]; ok { return v, true }
    return {}, false
}

node_set_property :: proc(n: ^Node, name: string, val: Variant) {
    switch name {
    case "name":     if val.kind == .String { n.name = val.str }
    case "tag":      if val.kind == .String { n.tag  = val.str }
    case "active":   if val.kind == .Bool   { n.active  = val.b }
    case "visible":  if val.kind == .Bool   { n.visible = val.b }
    case "pos_x":    if val.kind == .Float  { n.local.position.x = val.f }
    case "pos_y":    if val.kind == .Float  { n.local.position.y = val.f }
    case "rotation": if val.kind == .Float  { n.local.rotation   = val.f }
    case "scale_x":  if val.kind == .Float  { n.local.scale.x    = val.f }
    case "scale_y":  if val.kind == .Float  { n.local.scale.y    = val.f }
    case "z_index":
        if .Sprite_Renderer in n.components && val.kind == .Int { n.sprite.z_index = i32(val.i) }
    case "is_solid":
        if .Collision_Body in n.components && val.kind == .Bool { n.collision.is_solid = val.b }
    case "is_trigger":
        if .Collision_Body in n.components && val.kind == .Bool { n.collision.is_trigger = val.b }
    case "vel_x":
        if .Velocity in n.components && val.kind == .Float { n.velocity.linear.x = val.f }
    case "vel_y":
        if .Velocity in n.components && val.kind == .Float { n.velocity.linear.y = val.f }
    case:
        if .Script in n.components && n.script.vtable != nil && n.script.vtable.set_property != nil {
            n.script.vtable.set_property(n, name, val)
            return
        }
        n.properties[name] = val
    }
}
