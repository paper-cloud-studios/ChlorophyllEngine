package scene

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

import core   "engine:core"
import ecs    "engine:ecs"

// ============================================================
//  CHLOROPHYLL SDK  —  scene/serializer.odin
//
//  Loads and saves .chlor scene files (JSON format).
//
//  .chlor file anatomy:
//  {
//    "name": "my_scene",
//    "nodes": [
//      {
//        "name":        "World",
//        "tag":         "",
//        "parent":      "",          // "" = root; or name of parent node
//        "transform":   { "x":0, "y":0, "rotation":0, "sx":1, "sy":1 },
//        "script_path": "scripts/my_logic",   // optional; resolves vtable
//        "components": {
//          "sprite":    { "texture": "res://sprites/tile.png", "z": 0 },
//          "collision": { "half_w": 16, "half_h": 16, "solid": true },
//          "velocity":  { "damping": 0.1 },
//          "camera":    { "zoom": 1.0, "current": false }
//        },
//        "properties": {  
//          // freeform; engine never reads these
//          "health": 100,
//          "speed":  200.5
//        }
//      }
//    ]
//  }
// ============================================================

Scene_Def :: struct {
    name  : string,
    nodes : []Node_Def,
}

Node_Def :: struct {
    name        : string,
    tag         : string,
    parent      : string,
    transform   : Transform_Def,
    script_path : string,
    components  : Component_Def,
    properties  : map[string]json.Value,
}

Transform_Def :: struct {
    x, y     : f32,
    rotation : f32,
    sx, sy   : f32,
}

Component_Def :: struct {
    has_sprite    : bool,
    sprite        : Sprite_Def,
    has_collision : bool,
    collision     : Collision_Def,
    has_velocity  : bool,
    velocity      : Velocity_Def,
    has_camera    : bool,
    camera        : Camera_Def,
}

Sprite_Def    :: struct { texture: string, z: i32 }
Collision_Def :: struct { half_w, half_h, offset_x, offset_y: f32, solid, trigger: bool }
Velocity_Def  :: struct { damping: f32 }
Camera_Def    :: struct { zoom: f32, current: bool }

// ------------------------------------------------------------------
//  Load  — parse a .chlor file and populate the tree
// ------------------------------------------------------------------

scene_load :: proc(path: string, tree: ^ecs.Scene_Tree) -> bool {
    data, ok := os.read_entire_file(path)
    if !ok {
        log.errorf("[Serializer] Cannot read '%s'", path)
        return false
    }
    defer delete(data)
    return scene_load_from_bytes(data, tree)
}

scene_load_from_bytes :: proc(data: []u8, tree: ^ecs.Scene_Tree) -> bool {
    val, err := json.parse(data, json.DEFAULT_SPECIFICATION, true)
    if err != .None {
        log.errorf("[Serializer] JSON parse error: %v", err)
        return false
    }
    defer json.destroy_value(val)

    root_obj, is_obj := val.(json.Object)
    if !is_obj {
        log.error("[Serializer] Root must be a JSON object")
        return false
    }

    nodes_val, has_nodes := root_obj["nodes"]
    if !has_nodes {
        log.warn("[Serializer] Scene has no 'nodes' array")
        return true  // empty scene is valid
    }

    nodes_arr, is_arr := nodes_val.(json.Array)
    if !is_arr {
        log.error("[Serializer] 'nodes' must be an array")
        return false
    }

    // Two-pass approach:
    //   Pass 1: Create all nodes (collect name → id map)
    //   Pass 2: Set parents (by name)
    name_to_id := make(map[string]core.Node_ID)
    defer delete(name_to_id)

    node_ptrs := make([dynamic]^core.Node)
    defer delete(node_ptrs)

    parent_names := make([dynamic]string)
    defer delete(parent_names)

    // --- Pass 1: instantiate nodes
    for item in nodes_arr {
        obj, iok := item.(json.Object)
        if !iok { continue }

        node := core.node_create(_jstr(obj, "name", "Node"))
        node.tag = _jstr(obj, "tag", "")

        // Transform
        if t_val, tok := obj["transform"]; tok {
            if t_obj, tobjok := t_val.(json.Object); tobjok {
                node.local.position.x = _jfloat(t_obj, "x",  0)
                node.local.position.y = _jfloat(t_obj, "y",  0)
                node.local.rotation   = _jfloat(t_obj, "rotation", 0)
                node.local.scale.x    = _jfloat(t_obj, "sx", 1)
                node.local.scale.y    = _jfloat(t_obj, "sy", 1)
            }
        } else {
            node.local.scale = {1, 1}
        }

        // Script
        if sp := _jstr(obj, "script_path", ""); sp != "" {
            if vtable, vok := core.find_script_vtable(sp); vok {
                core.node_attach_script(node, vtable)
                log.debugf("[Serializer] Script '%s' attached to '%s'", sp, node.name)
            } else {
                log.warnf("[Serializer] Script '%s' not registered (node='%s')", sp, node.name)
            }
        }

        // Components
        if comps, cok := obj["components"].(json.Object); cok {
            // Sprite
            if sd, sok := comps["sprite"].(json.Object); sok {
                tex_uid : u64 = 0
                // In a real impl, look up texture in asset DB
                // texture_uid = asset_db_load_texture(_jstr(sd, "texture", ""))
                core.node_add_sprite(node, tex_uid)
                node.sprite.z_index = i32(_jfloat(sd, "z", 0))
            }
            // Collision
            if cd, cdk := comps["collision"].(json.Object); cdk {
                // Create an inline collision shape resource
                shape := new(core.Collision_Shape_Resource)
                shape.kind         = .Collision_Shape
                shape.ref_count    = 0
                shape.half_extents = {_jfloat(cd, "half_w", 8), _jfloat(cd, "half_h", 8)}
                shape.offset       = {_jfloat(cd, "offset_x", 0), _jfloat(cd, "offset_y", 0)}
                uid := core.resource_alloc(.Collision_Shape, shape)
                core.node_add_collision(node, uid, _jbool(cd, "solid", true))
                node.collision.is_trigger = _jbool(cd, "trigger", false)
            }
            // Velocity
            if vd, vdk := comps["velocity"].(json.Object); vdk {
                core.node_add_velocity(node)
                node.velocity.damping = _jfloat(vd, "damping", 0)
            }
            // Camera
            if camv, camok := comps["camera"].(json.Object); camok {
                core.node_add_camera(node, _jbool(camv, "current", false))
                node.camera.zoom = _jfloat(camv, "zoom", 1.0)
            }
        }

        // User properties
        if props, pok := obj["properties"].(json.Object); pok {
            for k, v in props {
                node.properties[k] = _json_to_variant(v)
            }
        }

        // Stash parent name for pass 2
        append(&parent_names, _jstr(obj, "parent", ""))
        append(&node_ptrs, node)
        name_to_id[node.name] = node.id
    }

    // --- Pass 2: add to tree with correct parents
    for i in 0..<len(node_ptrs) {
        node        := node_ptrs[i]
        parent_name := parent_names[i]
        parent_id   := core.NULL_ID

        if parent_name != "" {
            if pid, pok := name_to_id[parent_name]; pok {
                parent_id = pid
            } else {
                log.warnf("[Serializer] Parent '%s' not found for '%s'", parent_name, node.name)
            }
        }
        ecs.tree_add_node(tree, node, parent_id)
    }

    log.infof("[Serializer] Loaded %d nodes", len(node_ptrs))
    return true
}

// ------------------------------------------------------------------
//  Save  — serialize the live tree back to JSON
// ------------------------------------------------------------------

scene_save :: proc(path: string, tree: ^ecs.Scene_Tree, scene_name: string = "scene") -> bool {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    strings.write_string(&sb, "{\n")
    strings.write_string(&sb, `  "name": "`)
    strings.write_string(&sb, scene_name)
    strings.write_string(&sb, "\",\n  \"nodes\": [\n")

    first := true
    for _, node in tree.nodes {
        if !first { strings.write_string(&sb, ",\n") }
        first = false
        _serialize_node(&sb, node, tree)
    }

    strings.write_string(&sb, "\n  ]\n}\n")

    bytes := transmute([]u8)strings.to_string(sb)
    ok := os.write_entire_file(path, bytes)
    if ok { log.infof("[Serializer] Saved scene to '%s'", path) }
    return ok
}

@(private)
_serialize_node :: proc(sb: ^strings.Builder, node: ^core.Node, tree: ^ecs.Scene_Tree) {
    strings.write_string(sb, "    {\n")
    _wkv(sb, "name", node.name)
    strings.write_string(sb, ",\n")
    _wkv(sb, "tag", node.tag)
    strings.write_string(sb, ",\n")

    parent_name := ""
    if node.parent_id != core.NULL_ID {
        parent, ok := ecs.tree_get_node(tree, node.parent_id)
        if ok { parent_name = parent.name }
    }
    _wkv(sb, "parent", parent_name)
    strings.write_string(sb, ",\n")

    // Transform
    strings.write_string(sb, `      "transform": {`)
    strings.write_string(sb, `"x":`)
    strings.write_string(sb, _f32str(node.local.position.x))
    strings.write_string(sb, `,"y":`)
    strings.write_string(sb, _f32str(node.local.position.y))
    strings.write_string(sb, `,"rotation":`)
    strings.write_string(sb, _f32str(node.local.rotation))
    strings.write_string(sb, `,"sx":`)
    strings.write_string(sb, _f32str(node.local.scale.x))
    strings.write_string(sb, `,"sy":`)
    strings.write_string(sb, _f32str(node.local.scale.y))
    strings.write_string(sb, "}")

    strings.write_string(sb, "\n    }")
}

// ------------------------------------------------------------------
//  JSON parsing helpers
// ------------------------------------------------------------------

@(private) _jstr :: proc(obj: json.Object, key: string, default: string) -> string {
    if v, ok := obj[key]; ok { 
        if s, sok := v.(string); sok { return s } 
    }
    return default
}

@(private) _jfloat :: proc(obj: json.Object, key: string, default: f32) -> f32 {
    if v, ok := obj[key]; ok {
        #partial switch n in v {
        case f64: return f32(n)
        case i64: return f32(n)
        case:     return default
        }
    }
    return default
}

@(private) _jbool :: proc(obj: json.Object, key: string, default: bool) -> bool {
    if v, ok := obj[key]; ok { 
        if b, bok := v.(bool); bok { return b } 
    }
    return default
}

@(private) _json_to_variant :: proc(v: json.Value) -> core.Variant {
    #partial switch x in v {
    case bool:   return core.variant_bool(x)
    case i64:    return core.variant_int(x)
    case f64:    return core.variant_float(f32(x))
    case string: return core.variant_string(x)
    case:        return {} // Safety catch-all
    }
    return {}
}

@(private) _wkv :: proc(sb: ^strings.Builder, k, v: string) {
    strings.write_string(sb, `      "`)
    strings.write_string(sb, k)
    strings.write_string(sb, `": "`)
    strings.write_string(sb, v)
    strings.write_string(sb, `"`)
}

@(private) _f32str :: proc(v: f32) -> string {
    buf: [32]u8
    return strconv.ftoa(buf[:], f64(v), 'f', 2, 32)
}