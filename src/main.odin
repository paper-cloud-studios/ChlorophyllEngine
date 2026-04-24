package main

import "core:log"
import "core:os"

import core_engine "engine:core_engine" // GPS for your new folder
import core        "engine:core"
import ecs         "engine:ecs"
import scene       "engine:scene"

// ============================================================
//  CHLOROPHYLL SDK  —  main.odin
//
//  Entry point.  Sets up the engine, loads (or creates) an
//  empty workspace scene, and hands control to the main loop.
//
//  This file is intentionally minimal.
//  No game logic lives here.  No "Player."  No "gravity."
//  Just an SDK workspace waiting for a team to build on it.
// ============================================================

WINDOW_TITLE  :: "Chlorophyll SDK — Empty Workspace"
WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

WORKSPACE_SCENE :: "scenes/workspace.chlor"

main :: proc() {
    // --- Logger
    logger := log.create_console_logger(opt = {.Level, .Short_File_Path, .Line})
    context.logger = logger
    defer log.destroy_console_logger(logger)

    // --- Engine
    eng: core_engine.Engine
    if !core_engine.engine_init(&eng, WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT) {
        log.error("[Main] Engine init failed — aborting")
        os.exit(1)
    }
    defer core_engine.engine_destroy(&eng)

    // --- Register any built-in script vtables here, before scene load.
    //     Game teams add their own registrations in this block.
    //     Example:
    //       core.register_script("scripts/follow_camera", &follow_camera_vtable)
    //
    //     The engine never hardcodes what scripts exist.

    // --- Load workspace scene (or create a default one if missing)
    if os.exists(WORKSPACE_SCENE) {
        log.infof("[Main] Loading scene: %s", WORKSPACE_SCENE)
        if !scene.scene_load(WORKSPACE_SCENE, &eng.tree) {
            log.warn("[Main] Scene load failed — starting with empty workspace")
            _create_default_workspace(&eng)
        }
    } else {
        log.info("[Main] No scene file found — creating default workspace")
        _create_default_workspace(&eng)
    }

    // --- Run
    core_engine.engine_run(&eng)
}

// ------------------------------------------------------------------
//  Default Workspace
//  Creates a minimal, empty starting scene with:
//    • A root "World" node (logical container)
//    • A Camera node
//    • Three generic visible nodes with varied properties
//      so the editor panels are non-empty on first boot.
//
//  This is NOT a game.  The nodes have no roles.
//  They exist purely to demonstrate the SDK's capabilities.
// ------------------------------------------------------------------

_create_default_workspace :: proc(eng: ^core_engine.Engine) {
    tree := &eng.tree

    // Root container
    world := core.node_create("World")
    world.tag = "root"
    ecs.tree_add_node(tree, world)

    // Camera
    cam := core.node_create("Camera")
    cam.tag = "editor_cam"
    cam.local.position = {0, 0}
    core.node_add_camera(cam, true)
    cam.camera.zoom = 1.0
    ecs.tree_add_node(tree, cam, world.id)

    // --- Three generic nodes (different sizes, colors, layer masks)
    // Node A — small, centered
    {
        n := core.node_create("NodeA")
        n.local.position = {-120, 0}
        n.local.scale    = {40, 40}
        core.node_add_sprite(n)
        n.sprite.modulate = {0.3, 0.6, 1.0, 1.0}
        n.sprite.z_index  = 0

        shape := _make_shape(20, 20)
        core.node_add_collision(n, shape, true)
        core.node_add_velocity(n)

        ecs.tree_add_node(tree, n, world.id)
    }

    // Node B — wide, below center
    {
        n := core.node_create("NodeB")
        n.local.position = {0, 80}
        n.local.scale    = {200, 24}
        core.node_add_sprite(n)
        n.sprite.modulate = {0.8, 0.4, 0.2, 1.0}
        n.sprite.z_index  = -1

        shape := _make_shape(100, 12)
        core.node_add_collision(n, shape, true)

        ecs.tree_add_node(tree, n, world.id)
    }

    // Node C — child of NodeA
    {
        parent := ecs.tree_find_by_name(tree, "NodeA")
        n := core.node_create("NodeA_Child")
        n.local.position = {0, -40}
        n.local.scale    = {20, 20}
        core.node_add_sprite(n)
        n.sprite.modulate = {0.9, 0.9, 0.3, 1.0}
        n.sprite.z_index  = 1

        if parent != nil {
            ecs.tree_add_node(tree, n, parent.id)
        } else {
            ecs.tree_add_node(tree, n, world.id)
        }
    }

    log.info("[Main] Default workspace created (4 nodes)")

    // Optionally save the freshly created scene so it persists
    // scene.scene_save(WORKSPACE_SCENE, tree, "workspace")
}

// Allocate an inline Collision_Shape_Resource and return its UID.
_make_shape :: proc(hw, hh: f32) -> u64 {
    s := new(core.Collision_Shape_Resource)
    s.kind         = .Collision_Shape
    s.ref_count    = 0
    s.half_extents = {hw, hh}
    s.offset       = {0, 0}
    return core.resource_alloc(.Collision_Shape, s)
}
