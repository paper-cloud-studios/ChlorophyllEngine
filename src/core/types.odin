package core

import "core:math"

// ============================================================
//  CHLOROPHYLL SDK — core/types.odin
//  Fundamental primitives. No SDK-internal imports.
// ============================================================

Node_ID      :: distinct u64
NULL_ID      : Node_ID : 0

g_next_id    : Node_ID = 1
next_id :: proc() -> Node_ID {
    id := g_next_id
    g_next_id += 1
    return id
}

Vec2  :: [2]f32
Color :: [4]f32

color_white :: Color{1, 1, 1, 1}
color_black :: Color{0, 0, 0, 1}

// ------------------------------------------------------------------
//  Transform2D
// ------------------------------------------------------------------
Transform2D :: struct {
    position : Vec2,
    rotation : f32,
    scale    : Vec2,
}

transform_identity :: proc() -> Transform2D {
    return Transform2D{position = {0,0}, rotation = 0, scale = {1,1}}
}

transform_compose :: proc(parent, child: Transform2D) -> Transform2D {
    s  := math.sin(parent.rotation)
    c  := math.cos(parent.rotation)
    px := parent.scale.x * (child.position.x*c - child.position.y*s)
    py := parent.scale.y * (child.position.x*s + child.position.y*c)
    return Transform2D{
        position = parent.position + Vec2{px, py},
        rotation = parent.rotation + child.rotation,
        scale    = parent.scale * child.scale,
    }
}

// ------------------------------------------------------------------
//  Rect2
// ------------------------------------------------------------------
Rect2 :: struct { x, y, w, h: f32 }

rect2_overlaps :: proc(a, b: Rect2) -> bool {
    return a.x < b.x+b.w && a.x+a.w > b.x &&
           a.y < b.y+b.h && a.y+a.h > b.y
}

// Minimum translation vector to push `a` out of `b`
rect2_penetration :: proc(a, b: Rect2) -> Vec2 {
    cx_a := a.x + a.w*0.5;  cy_a := a.y + a.h*0.5
    cx_b := b.x + b.w*0.5;  cy_b := b.y + b.h*0.5
    dx := cx_b - cx_a;      dy := cy_b - cy_a
    ox := (a.w+b.w)*0.5 - abs(dx)
    oy := (a.h+b.h)*0.5 - abs(dy)
    if ox < oy { return Vec2{ox * (dx < 0 ? 1 : -1), 0} }
    return Vec2{0, oy * (dy < 0 ? 1 : -1)}
}

// ------------------------------------------------------------------
//  Variant  (serializable property value)
// ------------------------------------------------------------------
Variant_Kind :: enum { None, Bool, Int, Float, Vec2, Color, String, Node_ID }

Variant :: struct {
    kind : Variant_Kind,
    using _ : struct #raw_union {
        b   : bool,
        i   : i64,
        f   : f32,
        v2  : Vec2,
        col : Color,
        str : string,
        id  : Node_ID
    },
}

variant_bool   :: #force_inline proc(v: bool)    -> Variant { r:Variant; r.kind=.Bool;    r.b  =v; return r }
variant_int    :: #force_inline proc(v: i64)     -> Variant { r:Variant; r.kind=.Int;     r.i  =v; return r }
variant_float  :: #force_inline proc(v: f32)     -> Variant { r:Variant; r.kind=.Float;   r.f  =v; return r }
variant_vec2   :: #force_inline proc(v: Vec2)    -> Variant { r:Variant; r.kind=.Vec2;    r.v2 =v; return r }
variant_color  :: #force_inline proc(v: Color)   -> Variant { r:Variant; r.kind=.Color;   r.col=v; return r }
variant_string :: #force_inline proc(v: string)  -> Variant { r:Variant; r.kind=.String;  r.str=v; return r }
variant_id     :: #force_inline proc(v: Node_ID) -> Variant { r:Variant; r.kind=.Node_ID; r.id =v; return r }
