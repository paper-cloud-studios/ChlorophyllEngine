package core_engine

import "core:log"
import "core:time"
import "core:fmt"

import gl  "vendor:OpenGL"
import sdl "vendor:sdl2"

import core     "engine:core"
import ecs      "engine:ecs"
import renderer "engine:renderer"
import physics  "engine:physics"
import editor   "engine:editor"

// ============================================================
//  CHLOROPHYLL SDK  —  core/engine.odin
//
//  The Engine Shell.
//  Owns:  • The SDL window and OpenGL context
//         • The Scene Tree
//         • The three decoupled systems (Renderer, Physics, Editor)
//         • The main loop with fixed-timestep physics
//
//  The engine loop contains NO game-specific logic.
//  It is a pure System Driver.
//
//  Loop:
//    each frame:
//      1. Poll SDL events  → Editor input, window management
//      2. Accumulate delta time
//      3. While accumulated >= PHYSICS_STEP:
//           physics_tick()          ← fixed timestep
//      4. tree_update(delta)        ← scripts, transforms
//      5. Render frame
//         a. Clear
//         b. renderer_draw_tree()   ← scene sprites
//         c. editor_draw()          ← UI overlay
//         d. SDL_GL_SwapWindow()
// ============================================================

PHYSICS_STEP     :: 1.0 / 60.0
MAX_PHYSICS_SUBS :: 5     // prevent spiral-of-death

Engine :: struct {
    window       : ^sdl.Window,
    gl_context   : sdl.GLContext,
    win_w, win_h : i32,

    running      : bool,

    tree         : ecs.Scene_Tree,
    renderer     : renderer.Renderer_State,
    physics      : physics.Physics_State,
    editor       : editor.Editor_State,

    // Timing
    last_tick    : time.Tick,
    accumulator  : f64,

    // Metrics (readonly for game code)
    frame_count  : u64,
    fps          : f32,
    _fps_acc     : f32,
    _fps_frames  : int,
}

// ------------------------------------------------------------------
//  engine_init
// ------------------------------------------------------------------

engine_init :: proc(eng: ^Engine, title: string, width, height: i32) -> bool {
    // SDL
    if sdl.Init({.VIDEO, .EVENTS}) != 0 {
        log.errorf("[Engine] SDL_Init failed: %s", sdl.GetError())
        return false
    }

    sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 2)
    sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 1)
    sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLprofile.CORE))
    sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
    sdl.GL_SetAttribute(.DEPTH_SIZE, 24)

    eng.window = sdl.CreateWindow(
        fmt.ctprintf("%s", title),
        sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
        width, height,
        {.OPENGL, .RESIZABLE})
    if eng.window == nil {
        log.errorf("[Engine] CreateWindow failed: %s", sdl.GetError())
        return false
    }

    eng.gl_context = sdl.GL_CreateContext(eng.window)
    if eng.gl_context == nil {
        log.errorf("[Engine] GL context failed: %s", sdl.GetError())
        return false
    }
    sdl.GL_SetSwapInterval(1)  // vsync on by default

    gl.load_up_to(2, 1, sdl.gl_set_proc_address)

    eng.win_w = width
    eng.win_h = height

    // Resource registry
    core.resource_registry_init()

    // Subsystems
    ecs.tree_init(&eng.tree)
    physics.physics_init(&eng.physics)
    editor.editor_init(&eng.editor, width, height)

    if !renderer.renderer_init(&eng.renderer, width, height) {
        log.error("[Engine] Renderer init failed")
        return false
    }

    eng.running   = true
    eng.last_tick = time.tick_now()

    log.infof("[Engine] Chlorophyll SDK initialized (%d×%d)", width, height)
    return true
}

// ------------------------------------------------------------------
//  engine_destroy
// ------------------------------------------------------------------

engine_destroy :: proc(eng: ^Engine) {
    renderer.renderer_destroy(&eng.renderer)
    physics.physics_destroy(&eng.physics)
    editor.editor_destroy(&eng.editor)
    ecs.tree_destroy(&eng.tree)
    core.resource_registry_destroy()
    sdl.GL_DeleteContext(eng.gl_context)
    sdl.DestroyWindow(eng.window)
    sdl.Quit()
    log.info("[Engine] Shutdown complete")
}

// ------------------------------------------------------------------
//  engine_run  — the main loop
// ------------------------------------------------------------------

engine_run :: proc(eng: ^Engine) {
    for eng.running {
        // --- 1. Timing
        now   := time.tick_now()
        delta := f64(time.tick_diff(eng.last_tick, now)) / f64(time.Second)
        eng.last_tick = now
        delta = min(delta, 0.25)   // clamp spiral-of-death
        eng.accumulator += delta

        // --- 2. Events
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            editor.editor_handle_event(&eng.editor, &ev, &eng.tree)
            #partial switch ev.type {
            case .QUIT:
                eng.running = false
            case .WINDOWEVENT:
                we := &ev.window
                if we.event == .RESIZED {
                    eng.win_w = we.data1
                    eng.win_h = we.data2
                    gl.Viewport(0, 0, eng.win_w, eng.win_h)
                    renderer.renderer_resize(&eng.renderer, eng.win_w, eng.win_h)
                    editor.editor_resize(&eng.editor, eng.win_w, eng.win_h)
                }
            }
        }

        // --- 3. Fixed-timestep physics
        steps := 0
        for eng.accumulator >= PHYSICS_STEP && steps < MAX_PHYSICS_SUBS {
            physics.physics_tick(&eng.physics, &eng.tree, f32(PHYSICS_STEP))
            eng.accumulator -= PHYSICS_STEP
            steps += 1
        }

        // --- 4. Tree update (transforms, scripts)
        ecs.tree_update(&eng.tree, f32(delta))

        // --- 5. Render
        gl.Viewport(0, 0, eng.win_w, eng.win_h)
        gl.ClearColor(0.06, 0.06, 0.08, 1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT)

        renderer.renderer_draw_tree(&eng.renderer, &eng.tree)
        editor.editor_draw(&eng.editor, &eng.tree)

        sdl.GL_SwapWindow(eng.window)

        // --- Metrics
        eng.frame_count += 1
        eng._fps_acc    += f32(delta)
        eng._fps_frames += 1
        if eng._fps_acc >= 1.0 {
            eng.fps         = f32(eng._fps_frames) / eng._fps_acc
            eng._fps_acc    = 0
            eng._fps_frames = 0
            sdl.SetWindowTitle(eng.window,
                fmt.ctprintf("Chlorophyll SDK  |  %.0f fps  |  %d nodes",
                    eng.fps, len(eng.tree.nodes)))
        }
    }
}
