package renderer

import "core:log"
import "core:sort"
import "core:math"

import gl  "vendor:OpenGL"
import sdl "vendor:sdl2"

import core "../core"
import ecs  "../ecs"

// ============================================================
//  CHLOROPHYLL SDK  —  renderer/renderer.odin
//
//  2D sprite batch renderer backed by OpenGL 2.1.
//
//  The renderer knows nothing about gameplay.
//  It iterates the scene tree, collects all nodes with a
//  Sprite_Renderer component, sorts by z_index, and draws
//  each using its global transform.
//
//  Camera: if any node has a Camera component marked
//  is_current, that node's global transform becomes the
//  view matrix (world is shifted/rotated/scaled accordingly).
// ============================================================

// Vertex layout: position(2) + uv(2)
Vertex2D :: struct { x, y, u, v: f32 }

Renderer_State :: struct {
    // Compiled shader program (flat color + optional texture)
    program         : u32,
    vao, vbo, ebo   : u32,

    // Uniform locations
    u_projection    : i32,
    u_model         : i32,
    u_view          : i32,
    u_modulate      : i32,
    u_use_texture   : i32,
    u_texture       : i32,

    // Scratch: nodes to draw this frame
    _draw_list      : [dynamic]^core.Node,

    // Viewport dimensions (updated on window resize)
    viewport_w      : i32,
    viewport_h      : i32,
}

// ------------------------------------------------------------------
//  Shaders  —  OpenGL 2.1 compatible GLSL 120
// ------------------------------------------------------------------

VERT_SRC :: `
#version 120
attribute vec2 a_pos;
attribute vec2 a_uv;
varying   vec2 v_uv;
uniform mat3 u_projection;
uniform mat3 u_view;
uniform mat3 u_model;
void main() {
    vec3 world = u_model * vec3(a_pos, 1.0);
    vec3 cam   = u_view  * world;
    vec3 clip  = u_projection * cam;
    gl_Position = vec4(clip.xy, 0.0, 1.0);
    v_uv = a_uv;
}
`

FRAG_SRC :: `
#version 120
varying   vec2      v_uv;
uniform   sampler2D u_texture;
uniform   vec4      u_modulate;
uniform   int       u_use_texture;
void main() {
    vec4 col;
    if (u_use_texture == 1) {
        col = texture2D(u_texture, v_uv) * u_modulate;
    } else {
        col = u_modulate;
    }
    if (col.a < 0.01) discard;
    gl_FragColor = col;
}
`

// ------------------------------------------------------------------
//  Init / Destroy
// ------------------------------------------------------------------

renderer_init :: proc(r: ^Renderer_State, viewport_w, viewport_h: i32) -> bool {
    r.viewport_w = viewport_w
    r.viewport_h = viewport_h
    r._draw_list = make([dynamic]^core.Node)

    // --- Compile shaders
    vert := _compile_shader(VERT_SRC, gl.VERTEX_SHADER)
    frag := _compile_shader(FRAG_SRC, gl.FRAGMENT_SHADER)
    if vert == 0 || frag == 0 { return false }
    r.program = gl.CreateProgram()
    gl.AttachShader(r.program, vert)
    gl.AttachShader(r.program, frag)
    gl.BindAttribLocation(r.program, 0, "a_pos")
    gl.BindAttribLocation(r.program, 1, "a_uv")
    gl.LinkProgram(r.program)
    gl.DeleteShader(vert)
    gl.DeleteShader(frag)

    ok: i32
    gl.GetProgramiv(r.program, gl.LINK_STATUS, &ok)
    if ok == 0 {
        buf: [512]u8
        gl.GetProgramInfoLog(r.program, 512, nil, &buf[0])
        log.errorf("[Renderer] Link error: %s", buf[:])
        return false
    }

    // --- Uniform locations
    r.u_projection  = gl.GetUniformLocation(r.program, "u_projection")
    r.u_model       = gl.GetUniformLocation(r.program, "u_model")
    r.u_view        = gl.GetUniformLocation(r.program, "u_view")
    r.u_modulate    = gl.GetUniformLocation(r.program, "u_modulate")
    r.u_use_texture = gl.GetUniformLocation(r.program, "u_use_texture")
    r.u_texture     = gl.GetUniformLocation(r.program, "u_texture")

    // --- Geometry buffers (unit quad: -0.5 to 0.5)
    verts := [4]Vertex2D{
        {-0.5, -0.5,  0, 1},
        { 0.5, -0.5,  1, 1},
        { 0.5,  0.5,  1, 0},
        {-0.5,  0.5,  0, 0},
    }
    indices := [6]u16{0,1,2, 0,2,3}

    gl.GenVertexArrays(1, &r.vao)
    gl.GenBuffers(1, &r.vbo)
    gl.GenBuffers(1, &r.ebo)

    gl.BindVertexArray(r.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
    gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts[0], gl.STATIC_DRAW)
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.ebo)
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices), &indices[0], gl.STATIC_DRAW)

    stride := i32(size_of(Vertex2D))
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, 0)
    gl.EnableVertexAttribArray(1)
    gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, uintptr(size_of(f32)*2))

    gl.BindVertexArray(0)

    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    log.info("[Renderer] Initialized")
    return true
}

renderer_destroy :: proc(r: ^Renderer_State) {
    gl.DeleteVertexArrays(1, &r.vao)
    gl.DeleteBuffers(1, &r.vbo)
    gl.DeleteBuffers(1, &r.ebo)
    gl.DeleteProgram(r.program)
    delete(r._draw_list)
    log.info("[Renderer] Destroyed")
}

renderer_resize :: proc(r: ^Renderer_State, w, h: i32) {
    r.viewport_w = w
    r.viewport_h = h
}

// ------------------------------------------------------------------
//  renderer_draw_tree
//  Query the scene tree and render all visible Sprite nodes.
// ------------------------------------------------------------------

renderer_draw_tree :: proc(r: ^Renderer_State, tree: ^ecs.Scene_Tree) {
    // --- Find active camera
    view := _identity_mat3()
    cam_nodes: [dynamic]^core.Node
    defer delete(cam_nodes)
    cam_nodes = make([dynamic]^core.Node)
    ecs.tree_query(tree, {.Camera}, &cam_nodes)
    for cam in cam_nodes {
        if cam.camera.is_current {
            view = _view_from_camera(cam)
            break
        }
    }

    // --- Orthographic projection matrix (pixel-space, y-down)
    proj := _ortho_mat3(f32(r.viewport_w), f32(r.viewport_h))

    // --- Collect drawable nodes
    clear(&r._draw_list)
    ecs.tree_query(tree, {.Sprite_Renderer}, &r._draw_list)

    // Sort by z_index (ascending)
    sort.sort(sort.Interface{
        collection = &r._draw_list,
        len        = proc(it: sort.Interface) -> int {
            return len((cast(^[dynamic]^core.Node)it.collection)^)
        },
        less = proc(it: sort.Interface, i, j: int) -> bool {
            arr := (cast(^[dynamic]^core.Node)it.collection)^
            return arr[i].sprite.z_index < arr[j].sprite.z_index
        },
        swap = proc(it: sort.Interface, i, j: int) {
            arr := cast(^[dynamic]^core.Node)it.collection
            arr[i], arr[j] = arr[j], arr[i]
        },
    })

    // --- Draw
    gl.UseProgram(r.program)
    gl.UniformMatrix3fv(r.u_projection, 1, false, &proj[0][0])
    gl.UniformMatrix3fv(r.u_view,       1, false, &view[0][0])
    gl.BindVertexArray(r.vao)

    for node in r._draw_list {
        if !node.visible || !node.sprite.visible { continue }

        tex_uid := node.sprite.texture_uid
        if tex_uid != 0 {
            entry, ok := core.resource_get(tex_uid)
            if ok {
                tex := cast(^core.Texture_Resource)entry.ptr
                gl.ActiveTexture(gl.TEXTURE0)
                gl.BindTexture(gl.TEXTURE_2D, tex.gl_id)
                gl.Uniform1i(r.u_use_texture, 1)
                gl.Uniform1i(r.u_texture, 0)
            } else {
                gl.Uniform1i(r.u_use_texture, 0)
            }
        } else {
            gl.Uniform1i(r.u_use_texture, 0)
        }

        m := node.global
        // Apply scale from sprite size (use 1×1 for untextured quads drawn at actual scale)
        model := _transform_to_mat3(m)
        gl.UniformMatrix3fv(r.u_model, 1, false, &model[0][0])

        col := node.sprite.modulate
        gl.Uniform4f(r.u_modulate, col.r, col.g, col.b, col.a)

        gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_SHORT, nil)
    }

    gl.BindVertexArray(0)
    gl.UseProgram(0)
}

// ------------------------------------------------------------------
//  Debug: draw AABB wireframes for collision bodies
// ------------------------------------------------------------------

renderer_draw_debug_colliders :: proc(r: ^Renderer_State, tree: ^ecs.Scene_Tree) {
    // Reuse the same shader; just set modulate to a debug color
    // and draw as GL_LINE_LOOP instead of filled quads.
    // (Omitted for brevity; hook in physics_world_aabb per node.)
}

// ------------------------------------------------------------------
//  Private helpers
// ------------------------------------------------------------------

@(private)
_compile_shader :: proc(src: string, kind: u32) -> u32 {
    id := gl.CreateShader(kind)
    cstr := cstring(raw_data(src))
    gl.ShaderSource(id, 1, &cstr, nil)
    gl.CompileShader(id)
    ok: i32
    gl.GetShaderiv(id, gl.COMPILE_STATUS, &ok)
    if ok == 0 {
        buf: [512]u8
        gl.GetShaderInfoLog(id, 512, nil, &buf[0])
        log.errorf("[Renderer] Shader compile error: %s", buf[:])
        gl.DeleteShader(id)
        return 0
    }
    return id
}

@(private)
_identity_mat3 :: proc() -> [3][3]f32 {
    return [3][3]f32{
        {1, 0, 0},
        {0, 1, 0},
        {0, 0, 1},
    }
}

@(private)
_ortho_mat3 :: proc(w, h: f32) -> [3][3]f32 {
    // Maps [0..w] × [0..h] → [-1..1] × [1..-1] (y-down screen space)
    return [3][3]f32{
        {2.0/w, 0,      0},
        {0,    -2.0/h,  0},
        {-1,    1,      1},
    }
}

@(private)
_view_from_camera :: proc(cam: ^core.Node) -> [3][3]f32 {
    // Inverse of the camera's world transform
    p  := cam.global.position
    r  := -cam.global.rotation
    sx := 1.0 / (cam.global.scale.x * cam.camera.zoom)
    sy := 1.0 / (cam.global.scale.y * cam.camera.zoom)
    s  := math.sin(r)
    c  := math.cos(r)
    return [3][3]f32{
        {sx*c,  sx*s, 0},
        {-sy*s, sy*c, 0},
        {(-p.x*c + p.y*s)*sx, (-p.x*s - p.y*c)*sy, 1},
    }
}

@(private)
_transform_to_mat3 :: proc(t: core.Transform2D) -> [3][3]f32 {
    s := math.sin(t.rotation)
    c := math.cos(t.rotation)
    return [3][3]f32{
        {t.scale.x*c,  t.scale.x*s, 0},
        {-t.scale.y*s, t.scale.y*c, 0},
        {t.position.x, t.position.y, 1},
    }
}
