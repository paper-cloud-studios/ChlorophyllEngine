package core

import "core:log"
import "core:strings"
import "core:sync"

// ============================================================
//  CHLOROPHYLL SDK — core/resource.odin
//  Shared, reference-counted data objects.
//  No imports from other SDK packages.
// ============================================================

Resource_Kind :: enum {
    Unknown, Texture, Shader, Audio_Buffer, Collision_Shape, Script, Atlas,
}

Resource_Header :: struct {
    uid       : u64,
    kind      : Resource_Kind,
    ref_count : int,
    path      : string,
    loaded    : bool,
}

// ------------------------------------------------------------------
//  Concrete resource types
// ------------------------------------------------------------------

Texture_Resource :: struct {
    using header : Resource_Header,
    gl_id        : u32,
    width, height, channels : i32,
}

Shader_Resource :: struct {
    using header : Resource_Header,
    gl_program   : u32,
}

Collision_Shape_Resource :: struct {
    using header : Resource_Header,
    half_extents : Vec2,   // local-space half-extents
    offset       : Vec2,
}

// ------------------------------------------------------------------
//  Script_VTable
//  Forward-declared here so Node can reference it.
//  The Node type is defined in node.odin (same package).
// ------------------------------------------------------------------
Script_VTable :: struct {
    on_ready     : proc(node: ^Node),
    on_update    : proc(node: ^Node, delta: f32),
    on_destroy   : proc(node: ^Node),
    get_property : proc(node: ^Node, name: string) -> Variant,
    set_property : proc(node: ^Node, name: string, val: Variant),
}

Script_Resource :: struct {
    using header : Resource_Header,
    script_name  : string,
    vtable       : ^Script_VTable,
}

// ------------------------------------------------------------------
//  Resource Registry
// ------------------------------------------------------------------

Resource_Entry :: struct {
    kind : Resource_Kind,
    ptr  : rawptr,
}

Resource_Registry :: struct {
    mu       : sync.Mutex,
    entries  : map[u64]Resource_Entry,
    next_uid : u64,
    scripts  : map[string]^Script_VTable,
}

g_resources : Resource_Registry

resource_registry_init :: proc() {
    g_resources.next_uid = 1
    g_resources.entries  = make(map[u64]Resource_Entry)
    g_resources.scripts  = make(map[string]^Script_VTable)
}

resource_registry_destroy :: proc() {
    delete(g_resources.entries)
    delete(g_resources.scripts)
}

register_script :: proc(name: string, vtable: ^Script_VTable) {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    g_resources.scripts[strings.clone(name)] = vtable
}

find_script_vtable :: proc(name: string) -> (^Script_VTable, bool) {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    v, ok := g_resources.scripts[name]
    return v, ok
}

resource_alloc :: proc(kind: Resource_Kind, ptr: rawptr) -> u64 {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    uid := g_resources.next_uid
    g_resources.next_uid += 1
    g_resources.entries[uid] = Resource_Entry{kind=kind, ptr=ptr}
    return uid
}

resource_get :: proc(uid: u64) -> (Resource_Entry, bool) {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    e, ok := g_resources.entries[uid]
    return e, ok
}

resource_retain :: proc(uid: u64) {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    if e, ok := &g_resources.entries[uid]; ok {
        (cast(^Resource_Header)e.ptr).ref_count += 1
    }
}

resource_release :: proc(uid: u64) {
    sync.mutex_lock(&g_resources.mu)
    defer sync.mutex_unlock(&g_resources.mu)
    if e, ok := &g_resources.entries[uid]; ok {
        h := cast(^Resource_Header)e.ptr
        h.ref_count -= 1
        if h.ref_count <= 0 {
            log.debugf("[Resource] freed uid=%d path='%s'", uid, h.path)
            free(e.ptr)
            delete_key(&g_resources.entries, uid)
        }
    }
}
