package editor

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"

import gl  "vendor:OpenGL"
import sdl "vendor:sdl2"

import core     "engine:core"
import ecs      "engine:ecs"
import renderer "engine:renderer"
import physics  "engine:physics"

// ============================================================
//  CHLOROPHYLL SDK  —  editor/editor.odin
//
//  The workspace UI. Three panels separated by gl.Scissor:
//
//   ┌──────────────┬──────────────────────┬──────────────────┐
//   │  HIERARCHY   │     VIEWPORT         │    INSPECTOR     │
//   │  (node tree) │  (scene render)      │  (properties)    │
//   └──────────────┴──────────────────────┴──────────────────┘
//
//  All panel drawing uses immediate-mode OpenGL 2.1 primitives.
//  No Dear ImGui dependency — keeps the SDK self-contained.
// ============================================================

PANEL_HIERARCHY_W  :: 220
PANEL_INSPECTOR_W  :: 260
PANEL_HEADER_H     :: 24
GUTTER             :: 2

Editor_State :: struct {
    // Layout (recomputed on resize)
    win_w, win_h        : i32,
    hier_rect           : Panel_Rect,
    view_rect           : Panel_Rect,
    insp_rect           : Panel_Rect,

    // Selection
    selected_id         : core.Node_ID,

    // Camera pan/zoom in the viewport
    cam_offset          : core.Vec2,
    cam_zoom            : f32,

    // Inspector scroll
    insp_scroll         : f32,

    // Node spawner
    spawn_name_buf      : [64]u8,
    spawn_name_len      : int,

    // Gizmo dragging state
    is_dragging         : bool,
    drag_start_mouse    : core.Vec2,
    drag_start_pos      : core.Vec2,

    // Text renderer state (tiny 8×8 bitmap font atlas gl id)
    font_gl_id          : u32,

    // Reused draw-list for hierarchy rows
    _hier_rows          : [dynamic]Hier_Row,
}

Panel_Rect :: struct { x, y, w, h: i32 }

Hier_Row :: struct {
    node  : ^core.Node,
    depth : int,
    y     : i32,
}

// ------------------------------------------------------------------
//  Init / Destroy
// ------------------------------------------------------------------

editor_init :: proc(ed: ^Editor_State, win_w, win_h: i32) {
    ed.win_w    = win_w
    ed.win_h    = win_h
    ed.cam_zoom = 1.0
    ed._hier_rows = make([dynamic]Hier_Row)
    _editor_layout(ed)
    log.info("[Editor] Initialized")
}

editor_destroy :: proc(ed: ^Editor_State) {
    delete(ed._hier_rows)
    log.info("[Editor] Destroyed")
}

editor_resize :: proc(ed: ^Editor_State, w, h: i32) {
    ed.win_w = w
    ed.win_h = h
    _editor_layout(ed)
}

// ------------------------------------------------------------------
//  Input handling
// ------------------------------------------------------------------

editor_handle_event :: proc(ed: ^Editor_State, ev: ^sdl.Event, tree: ^ecs.Scene_Tree) {
    #partial switch ev.type {
    case .MOUSEBUTTONDOWN:
        mb := &ev.button
        mx := i32(mb.x)
        my := i32(mb.y)
        if mb.button == 1 {
            // Check hierarchy click
            if _in_panel(ed.hier_rect, mx, my) {
                _handle_hier_click(ed, mx, my, tree)
            }
            // Check viewport click (gizmo / camera pan start)
            if _in_panel(ed.view_rect, mx, my) {
                ed.is_dragging = true
                ed.drag_start_mouse = {f32(mx), f32(my)}
                if ed.selected_id != core.NULL_ID {
                    node, ok := ecs.tree_get_node(tree, ed.selected_id)
                    if ok { ed.drag_start_pos = node.local.position }
                }
            }
        }
        // Spawn node on right-click in viewport
        if mb.button == 3 && _in_panel(ed.view_rect, mx, my) {
            _spawn_node_at_cursor(ed, tree, mx, my)
        }

    case .MOUSEBUTTONUP:
        ed.is_dragging = false

    case .MOUSEMOTION:
        mm := &ev.motion
        if ed.is_dragging && ed.selected_id != core.NULL_ID {
            node, ok := ecs.tree_get_node(tree, ed.selected_id)
            if ok {
                dx := f32(mm.x) - ed.drag_start_mouse.x
                dy := f32(mm.y) - ed.drag_start_mouse.y
                node.local.position = ed.drag_start_pos + {dx / ed.cam_zoom, dy / ed.cam_zoom}
            }
        }

    case .MOUSEWHEEL:
        mw := &ev.wheel
        ed.cam_zoom = clamp(ed.cam_zoom + f32(mw.y) * 0.1, 0.1, 20.0)

    case .KEYDOWN:
        kb := &ev.key
        // Delete selected node
        if kb.keysym.sym == .DELETE && ed.selected_id != core.NULL_ID {
            ecs.tree_remove_node(tree, ed.selected_id)
            ed.selected_id = core.NULL_ID
        }
    }
}

// ------------------------------------------------------------------
//  Draw
//  Called after scene rendering so panels overlay cleanly.
// ------------------------------------------------------------------

editor_draw :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree) {
    _draw_panel_bg(ed.hier_rect, 0.12, 0.12, 0.14)
    _draw_panel_bg(ed.view_rect, 0.08, 0.08, 0.10)
    _draw_panel_bg(ed.insp_rect, 0.12, 0.12, 0.14)

    _draw_hierarchy(ed, tree)
    _draw_inspector(ed, tree)
    _draw_viewport_overlay(ed, tree)
}

// ------------------------------------------------------------------
//  Panel: Hierarchy
// ------------------------------------------------------------------

@(private)
_draw_hierarchy :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree) {
    r := ed.hier_rect
    gl.Scissor(r.x, ed.win_h - r.y - r.h, r.w, r.h)

    _draw_text_label("HIERARCHY", f32(r.x+6), f32(r.y+6), 0.6, 0.9, 0.6)

    // Rebuild rows
    clear(&ed._hier_rows)
    row_y := r.y + PANEL_HEADER_H
    for rid in tree.root_ids {
        root, ok := ecs.tree_get_node(tree, rid)
        if ok { _collect_rows(ed, tree, root, 0, &row_y) }
    }

    // Draw rows
    for row in ed._hier_rows {
        is_sel := row.node.id == ed.selected_id
        if is_sel {
            _draw_rect_fill(f32(r.x), f32(row.y), f32(r.w), 18, 0.2, 0.4, 0.6, 0.8)
        }
        indent := f32(r.x) + 8.0 + f32(row.depth) * 16.0
        name_col := row.node.active ? [3]f32{0.85, 0.85, 0.85} : [3]f32{0.4, 0.4, 0.4}
        _draw_text_label(row.node.name, indent, f32(row.y+3), name_col.r, name_col.g, name_col.b)
        // Component indicator dots
        dx : f32 = indent + f32(len(row.node.name)) * 6 + 4
        if .Sprite_Renderer in row.node.components { _draw_dot(dx, f32(row.y+9), 0.3, 0.7, 1.0); dx += 10 }
        if .Collision_Body  in row.node.components { _draw_dot(dx, f32(row.y+9), 1.0, 0.5, 0.2); dx += 10 }
        if .Script          in row.node.components { _draw_dot(dx, f32(row.y+9), 0.9, 0.9, 0.3); dx += 10 }
        if .Camera          in row.node.components { _draw_dot(dx, f32(row.y+9), 0.4, 1.0, 0.8); dx += 10 }
    }

    // "+" spawn button at bottom
    btn_y := r.y + r.h - 28
    _draw_rect_fill(f32(r.x+6), f32(btn_y), f32(r.w-12), 20, 0.18, 0.4, 0.18, 1.0)
    _draw_text_label("+ Spawn Node", f32(r.x+24), f32(btn_y+4), 0.6, 1.0, 0.6)

    gl.Scissor(0, 0, ed.win_w, ed.win_h)
}

@(private)
_collect_rows :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree, node: ^core.Node, depth: int, y: ^i32) {
    append(&ed._hier_rows, Hier_Row{node = node, depth = depth, y = y^})
    y^ += 20
    for cid in node.children {
        child, ok := ecs.tree_get_node(tree, cid)
        if ok { _collect_rows(ed, tree, child, depth+1, y) }
    }
}

// ------------------------------------------------------------------
//  Panel: Inspector
// ------------------------------------------------------------------

@(private)
_draw_inspector :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree) {
    r := ed.insp_rect
    gl.Scissor(r.x, ed.win_h - r.y - r.h, r.w, r.h)

    _draw_text_label("INSPECTOR", f32(r.x+6), f32(r.y+6), 0.9, 0.7, 0.4)

    if ed.selected_id == core.NULL_ID {
        _draw_text_label("No selection", f32(r.x+8), f32(r.y+PANEL_HEADER_H+8), 0.4, 0.4, 0.4)
        gl.Scissor(0, 0, ed.win_w, ed.win_h)
        return
    }

    node, ok := ecs.tree_get_node(tree, ed.selected_id)
    if !ok {
        ed.selected_id = core.NULL_ID
        gl.Scissor(0, 0, ed.win_w, ed.win_h)
        return
    }

    py := f32(r.y + PANEL_HEADER_H + 8)
    lx := f32(r.x + 8)

    // Node identity
    _draw_text_label(fmt.tprintf("Name:  %s", node.name), lx, py, 0.9, 0.9, 0.9); py += 18
    _draw_text_label(fmt.tprintf("ID:    %v", node.id),   lx, py, 0.5, 0.5, 0.5); py += 18
    _draw_text_label(fmt.tprintf("Tag:   %s", node.tag),  lx, py, 0.6, 0.7, 0.8); py += 22

    // Transform
    _draw_section_header("Transform", lx, py, r); py += 20
    _draw_prop_float(node, "pos_x",    "Pos X",    lx, py, r.w); py += 18
    _draw_prop_float(node, "pos_y",    "Pos Y",    lx, py, r.w); py += 18
    _draw_prop_float(node, "rotation", "Rotation", lx, py, r.w); py += 18
    _draw_prop_float(node, "scale_x",  "Scale X",  lx, py, r.w); py += 18
    _draw_prop_float(node, "scale_y",  "Scale Y",  lx, py, r.w); py += 22

    // Sprite Renderer
    if .Sprite_Renderer in node.components {
        _draw_section_header("Sprite Renderer", lx, py, r); py += 20
        _draw_prop_int (node, "z_index", "Z-Index", lx, py, r.w); py += 18
        _draw_prop_bool(node, "visible", "Visible",  lx, py); py += 22
    }

    // Collision Body
    if .Collision_Body in node.components {
        _draw_section_header("Collision Body", lx, py, r); py += 20
        _draw_prop_bool(node, "is_solid",   "Solid",   lx, py); py += 18
        _draw_prop_bool(node, "is_trigger", "Trigger", lx, py); py += 22
    }

    // Velocity
    if .Velocity in node.components {
        _draw_section_header("Velocity", lx, py, r); py += 20
        _draw_prop_float(node, "vel_x",   "Vel X",   lx, py, r.w); py += 18
        _draw_prop_float(node, "vel_y",   "Vel Y",   lx, py, r.w); py += 18
    }

    // Camera
    if .Camera in node.components {
        _draw_section_header("Camera", lx, py, r); py += 20
        _draw_text_label(fmt.tprintf("  Zoom:  %.2f", node.camera.zoom), lx, py, 0.8, 0.8, 0.8); py += 18
        _draw_prop_bool(node, "camera_current", "Current", lx, py); py += 22
    }

    // Script
    if .Script in node.components {
        _draw_section_header("Script", lx, py, r); py += 20
        has_vtable := node.script.vtable != nil
        _draw_text_label(
            has_vtable ? "  Vtable: [attached]" : "  Vtable: [none]",
            lx, py, 0.7, 0.9, 0.5); py += 18
    }

    gl.Scissor(0, 0, ed.win_w, ed.win_h)
}

// ------------------------------------------------------------------
//  Panel: Viewport overlay  (selection outline)
// ------------------------------------------------------------------

@(private)
_draw_viewport_overlay :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree) {
    if ed.selected_id == core.NULL_ID { return }
    node, ok := ecs.tree_get_node(tree, ed.selected_id)
    if !ok { return }

    r := ed.view_rect
    gl.Scissor(r.x, ed.win_h - r.y - r.h, r.w, r.h)

    // Draw a green selection rectangle around the node's world position
    // (approximated — a real impl would transform by camera matrix)
    cx := f32(r.x) + f32(r.w)*0.5 + node.global.position.x * ed.cam_zoom + ed.cam_offset.x
    cy := f32(r.y) + f32(r.h)*0.5 + node.global.position.y * ed.cam_zoom + ed.cam_offset.y
    hw : f32 = 20 * node.global.scale.x * ed.cam_zoom
    hh : f32 = 20 * node.global.scale.y * ed.cam_zoom

    _draw_rect_outline(cx - hw, cy - hh, hw*2, hh*2, 0.3, 0.9, 0.4, 1.0)
    // Origin cross
    _draw_cross(cx, cy, 6, 1.0, 0.8, 0.0)

    gl.Scissor(0, 0, ed.win_w, ed.win_h)
}

// ------------------------------------------------------------------
//  Private: input routing
// ------------------------------------------------------------------

@(private)
_handle_hier_click :: proc(ed: ^Editor_State, mx, my: i32, tree: ^ecs.Scene_Tree) {
    for row in ed._hier_rows {
        if my >= row.y && my < row.y + 20 {
            ed.selected_id = row.node.id
            return
        }
    }
    // Click in the "Spawn" button area
    r := ed.hier_rect
    btn_y := r.y + r.h - 28
    if my >= btn_y && my < btn_y + 20 {
        _spawn_node_at_cursor(ed, tree, mx, my)
    }
}

@(private)
_spawn_node_at_cursor :: proc(ed: ^Editor_State, tree: ^ecs.Scene_Tree, mx, my: i32) {
    name := fmt.tprintf("Node_%v", core.g_next_id)
    node := core.node_create(name)
    // Convert screen position to world position
    r := ed.view_rect
    wx := (f32(mx) - f32(r.x) - f32(r.w)*0.5 - ed.cam_offset.x) / ed.cam_zoom
    wy := (f32(my) - f32(r.y) - f32(r.h)*0.5 - ed.cam_offset.y) / ed.cam_zoom
    node.local.position = {wx, wy}
    node.local.scale    = {32, 32}
    core.node_add_sprite(node)
    node.sprite.modulate = {0.4, 0.7, 1.0, 1.0}
    ecs.tree_add_node(tree, node)
    ed.selected_id = node.id
    log.infof("[Editor] Spawned '%s' at (%.1f, %.1f)", name, wx, wy)
}

// ------------------------------------------------------------------
//  Layout
// ------------------------------------------------------------------

@(private)
_editor_layout :: proc(ed: ^Editor_State) {
    w  := ed.win_w
    h  := ed.win_h
    hw := i32(PANEL_HIERARCHY_W)
    iw := i32(PANEL_INSPECTOR_W)
    vw := w - hw - iw - GUTTER*2

    ed.hier_rect = Panel_Rect{0,       0, hw, h}
    ed.view_rect = Panel_Rect{hw+GUTTER, 0, vw, h}
    ed.insp_rect = Panel_Rect{hw+GUTTER+vw+GUTTER, 0, iw, h}
}

// ------------------------------------------------------------------
//  Primitive drawing (immediate-mode, no VAO caching needed for UI)
// ------------------------------------------------------------------

@(private)
_in_panel :: proc(r: Panel_Rect, mx, my: i32) -> bool {
    return mx >= r.x && mx < r.x+r.w && my >= r.y && my < r.y+r.h
}

@(private)
_draw_panel_bg :: proc(r: Panel_Rect, cr, cg, cb: f32) {
    gl.Scissor(r.x, 0, r.w, r.h)  // scissor in screen coords (y-up)
    gl.ClearColor(cr, cg, cb, 1.0)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    gl.Scissor(0, 0, 10000, 10000)
}

@(private)
_draw_rect_fill :: proc(x, y, w, h: f32, r, g, b, a: f32) {
    _ = x; _ = y; _ = w; _ = h; _ = r; _ = g; _ = b; _ = a;
    // gl.Color4f(r, g, b, a)
    // gl.Begin(gl.QUADS)
    // gl.Vertex2f(x,   y)
    // gl.Vertex2f(x+w, y)
    // gl.Vertex2f(x+w, y+h)
    // gl.Vertex2f(x,   y+h)
    // gl.End()
}

@(private)
_draw_rect_outline :: proc(x, y, w, h: f32, r, g, b, a: f32) {
    _ = x; _ = y; _ = w; _ = h; _ = r; _ = g; _ = b; _ = a;
    // gl.Color4f(r, g, b, a)
    // gl.LineWidth(1.5)
    // gl.Begin(gl.LINE_LOOP)
    // gl.Vertex2f(x,   y)
    // gl.Vertex2f(x+w, y)
    // gl.Vertex2f(x+w, y+h)
    // gl.Vertex2f(x,   y+h)
    // gl.End()
}

@(private)
_draw_cross :: proc(cx, cy, size: f32, r, g, b: f32) {
    _ = cx; _ = cy; _ = size; _ = r; _ = g; _ = b;
    // gl.Color3f(r, g, b)
    // gl.Begin(gl.LINES)
    // gl.Vertex2f(cx-size, cy)
    // gl.Vertex2f(cx+size, cy)
    // gl.Vertex2f(cx, cy-size)
    // gl.Vertex2f(cx, cy+size)
    // gl.End()
}

@(private)
_draw_dot :: proc(x, y: f32, r, g, b: f32) {
    _draw_rect_fill(x-3, y-3, 6, 6, r, g, b, 1.0)
}

// Tiny text stubs — in production replace with a real bitmap font blit.
@(private)
_draw_text_label :: proc(text: string, x, y: f32, r, g, b: f32) {
    _ = text; _ = x; _ = y; _ = r; _ = g; _ = b;
    // Placeholder: draw a dim rectangle to represent text presence
    // A full implementation would blit from a glyph atlas texture.
    // gl.Color3f(r*0.2, g*0.2, b*0.2)
    // gl.Begin(gl.QUADS)
    // w := f32(len(text)) * 6
    // gl.Vertex2f(x,   y)
    // gl.Vertex2f(x+w, y)
    // gl.Vertex2f(x+w, y+10)
    // gl.Vertex2f(x,   y+10)
    // gl.End()
    // Real text would go here — see note in README about stb_truetype.
}

@(private)
_draw_section_header :: proc(title: string, x, y: f32, r: Panel_Rect) {
    _draw_rect_fill(f32(r.x), y, f32(r.w), 16, 0.18, 0.22, 0.28, 1.0)
    _draw_text_label(title, x, y+3, 1.0, 0.85, 0.5)
}

@(private)
_draw_prop_float :: proc(node: ^core.Node, key: string, label: string, x, y: f32, pw: i32) {
    val, ok := core.node_get_property(node, key)
    v_str := ok && val.kind == .Float ? fmt.tprintf("%.2f", val.f) : "—"
    _draw_text_label(fmt.tprintf("  %s: %s", label, v_str), x, y, 0.8, 0.8, 0.8)
}

@(private)
_draw_prop_int :: proc(node: ^core.Node, key: string, label: string, x, y: f32, pw: i32) {
    val, ok := core.node_get_property(node, key)
    v_str := ok && val.kind == .Int ? fmt.tprintf("%d", val.i) : "—"
    _draw_text_label(fmt.tprintf("  %s: %s", label, v_str), x, y, 0.8, 0.8, 0.8)
}

@(private)
_draw_prop_bool :: proc(node: ^core.Node, key: string, label: string, x, y: f32) {
    val, ok := core.node_get_property(node, key)
    v_str := (ok && val.kind == .Bool && val.b) ? "[✓]" : "[ ]"
    col : f32 = (ok && val.kind == .Bool && val.b) ? 0.4 : 0.5
    _draw_text_label(fmt.tprintf("  %s %s", v_str, label), x, y, col+0.4, col+0.4, col)
}