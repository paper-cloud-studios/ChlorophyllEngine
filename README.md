# Chlorophyll SDK

A professional, data-driven 2D game engine built in **Odin** using **SDL2** and **OpenGL 2.1**.

Architecture inspired by Godot. Built to be a *tool*, not a template.

---

## File Map

```
chlorophyll/
│
├── main.odin                   Entry point. Initializes engine, loads workspace.
│
├── core/
│   ├── types.odin              Vec2, Color, Transform2D, Rect2, Variant
│   ├── node.odin               Node struct, Component flags, property reflection
│   ├── resource.odin           Resource_Registry, Script_VTable, ref-counting
│   └── engine.odin             Engine shell: window, SDL, main loop, system driver
│
├── ecs/
│   └── tree.odin               Scene Tree: hierarchy, global transform propagation,
│                                on_ready, on_update dispatch
│
├── scene/
│   └── serializer.odin         .chlor (JSON) scene load/save
│
├── renderer/
│   └── renderer.odin           OpenGL 2.1 sprite batch; camera; z-sorting
│
├── physics/
│   └── physics.odin            Fixed-step AABB physics; velocity integration;
│                                solid/trigger resolution; collision events
│
└── editor/
    └── editor.odin             3-panel workspace UI (Hierarchy/Viewport/Inspector)
                                 using gl.Scissor; node spawner; property editor
```

---

## Core Concepts

### Node
Everything is a `Node`. A Node has:
- A **unique ID** (never reused)
- A **local Transform2D** (position, rotation, scale)
- A **global Transform2D** (computed top-down each frame)
- A **Component_Flags** bitset (which systems act on it)
- An optional **Script** (vtable of callbacks)
- An arbitrary **properties** map (editor-visible key-value bag)

A Node has no inherent "role." It becomes a sprite by gaining `Sprite_Renderer`. It becomes a physics body by gaining `Collision_Body`. It gains behavior by having a script attached.

### Scene Tree
`ecs/tree.odin` owns all live nodes. It:
1. Propagates global transforms **top-down** each frame
2. Fires `on_ready` **bottom-up** (children before parents)
3. Dispatches `on_update` to every scripted node
4. Provides `tree_query(flags)` for system iteration

### Resources
`Texture`, `CollisionShape`, `Script`, `Shader` are all **Resources**: shared, reference-counted objects stored in the `Resource_Registry`. Nodes hold UIDs, not raw pointers. The registry frees GPU memory when `ref_count` reaches zero.

### Physics
`physics/physics.odin` runs at a **fixed timestep** (1/60 s). It:
1. Integrates velocity → moves nodes
2. Builds world AABBs from `Collision_Shape` resources + global transforms
3. Resolves **solid-solid** overlaps by pushing movers
4. Emits `Collision_Event` records (consumed by scripts or the engine)

It knows nothing about what a node "represents."

### Renderer
`renderer/renderer.odin` collects all nodes with `Sprite_Renderer`, sorts by `z_index`, and draws each using its **global transform** as the model matrix. The active `Camera` node provides the view matrix.

### Script System
Scripts are **registered vtables**:

```odin
my_vtable := core.Script_VTable{
    on_ready   = proc(n: ^core.Node) { ... },
    on_update  = proc(n: ^core.Node, dt: f32) { ... },
    on_destroy = proc(n: ^core.Node) { ... },
    get_property = proc(n: ^core.Node, name: string) -> core.Variant { ... },
    set_property = proc(n: ^core.Node, name: string, val: core.Variant) { ... },
}

// In main, before scene load:
core.register_script("scripts/my_behavior", &my_vtable)
```

In a `.chlor` scene file, set `"script_path": "scripts/my_behavior"` on a node and the engine wires it up at load time.

### .chlor Scene Format

```json
{
  "name": "my_scene",
  "nodes": [
    {
      "name":      "World",
      "tag":       "root",
      "parent":    "",
      "transform": { "x": 0, "y": 0, "rotation": 0, "sx": 1, "sy": 1 },
      "components": {}
    },
    {
      "name":        "Tile",
      "tag":         "",
      "parent":      "World",
      "transform":   { "x": 0, "y": 80, "rotation": 0, "sx": 200, "sy": 24 },
      "script_path": "scripts/platform_tile",
      "components": {
        "sprite":    { "texture": "res://sprites/tile.png", "z": 0 },
        "collision": { "half_w": 100, "half_h": 12, "solid": true }
      },
      "properties": { "friction": 0.8 }
    }
  ]
}
```

---

## Editor

| Panel | Purpose |
|---|---|
| **Hierarchy** (left, 220px) | Shows node tree; click to select; right-click viewport to spawn |
| **Viewport** (center) | Scene render; drag selected node to reposition |
| **Inspector** (right, 260px) | Shows all properties of selected node; component sections auto-appear |

The editor uses `gl.Scissor` — no Dear ImGui, no external UI lib.

> **Text rendering note:** `_draw_text_label` in `editor.odin` is a stub that renders placeholder rectangles. Replace it with a stb_truetype or similar glyph-atlas blit for readable labels.

---

## Building

```bash
# Install SDL2
sudo apt install libsdl2-dev   # Linux
brew install sdl2               # macOS

# Build
chmod +x build.sh
./build.sh

# Run
./chlorophyll
```

---

## Extending the SDK

| Goal | Where to change |
|---|---|
| Add a new component type | `core/node.odin` — add flag, struct, attach proc |
| Add a new system | New package; call `tree_query(required_flags)` |
| Add a new resource type | `core/resource.odin` — add `Resource_Kind` variant |
| Add editor widget for property | `editor/editor.odin` — add a `_draw_prop_*` call |
| Load assets | `core/resource.odin` — fill in `_resource_free_gpu`; add `load_texture` proc |

The engine core is never modified for game-specific needs.
Game behavior lives entirely in registered script vtables.
