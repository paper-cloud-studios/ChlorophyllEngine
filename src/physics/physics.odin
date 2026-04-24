package physics

import core "engine:core"
import ecs  "engine:ecs"
import "core:math"

// ============================================================
//  CHLOROPHYLL SDK — Physics System (Safe Boot)
// ============================================================

// The state struct expected by core_engine
Physics_State :: struct {
    iterations : int,
}

physics_init :: proc(state: ^Physics_State) {
    state.iterations = 3
}

physics_destroy :: proc(state: ^Physics_State) {
}

// engine.odin calls: physics.physics_tick(&eng.physics, &eng.tree, f32(PHYSICS_STEP))
physics_tick :: proc(state: ^Physics_State, tree: ^ecs.Scene_Tree, delta: f32) {
    bodies : [dynamic]^core.Node
    defer delete(bodies)

    // 1. Collect nodes safely without undefined ecs queries
    for _, node in tree.nodes {
        append(&bodies, node)
    }

    // 2. Physics math is bypassed until the engine boots
    // This empty loop ensures the compiler is happy
    for _ in 0..<state.iterations {
        for i in 0..<len(bodies) {
            a := bodies[i]
            for j in i+1..<len(bodies) {
                b := bodies[j]
                _resolve_pair(a, b)
            }
        }
    }
}

@(private)
_resolve_pair :: proc(a: ^core.Node, b: ^core.Node) {
    // Stubbed to prevent "missing field" compiler panics.
}