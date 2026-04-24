package ecs

import "core:log"
import "core:slice"
import core "../core"

// ============================================================
//  CHLOROPHYLL SDK  —  ecs/tree.odin
//
//  The Scene Tree.
//  Owns every live Node.  Manages the parent-child hierarchy,
//  propagates global transforms, fires lifecycle callbacks,
//  and provides O(1) node lookup by ID.
//
//  Deliberately knows nothing about rendering or physics.
// ============================================================

Scene_Tree :: struct {
    nodes         : map[core.Node_ID]^core.Node,
    root_ids      : [dynamic]core.Node_ID,
    // Flat list of nodes in depth-first order; rebuilt when dirty.
    sorted_nodes  : [dynamic]^core.Node,
    dirty         : bool,
    pending_ready : [dynamic]core.Node_ID,
}

// ------------------------------------------------------------------
//  Init / Destroy
// ------------------------------------------------------------------

tree_init :: proc(t: ^Scene_Tree) {
    t.nodes         = make(map[core.Node_ID]^core.Node)
    t.root_ids      = make([dynamic]core.Node_ID)
    t.sorted_nodes  = make([dynamic]^core.Node)
    t.pending_ready = make([dynamic]core.Node_ID)
    t.dirty = true
    log.info("[Tree] Initialized")
}

tree_destroy :: proc(t: ^Scene_Tree) {
    for _, node in t.nodes { core.node_destroy(node) }
    delete(t.nodes)
    delete(t.root_ids)
    delete(t.sorted_nodes)
    delete(t.pending_ready)
    log.info("[Tree] Destroyed")
}

// ------------------------------------------------------------------
//  Node Management
// ------------------------------------------------------------------

tree_add_node :: proc(t: ^Scene_Tree, node: ^core.Node, parent_id: core.Node_ID = core.NULL_ID) {
    assert(node != nil)

    node.parent_id = parent_id
    node.in_tree   = true
    t.nodes[node.id] = node

    if parent_id == core.NULL_ID {
        append(&t.root_ids, node.id)
    } else {
        parent, ok := tree_get_node(t, parent_id)
        if ok {
            append(&parent.children, node.id)
        } else {
            log.warnf("[Tree] parent_id=%v not found; adding '%s' as root", parent_id, node.name)
            append(&t.root_ids, node.id)
            node.parent_id = core.NULL_ID
        }
    }

    t.dirty = true
    log.debugf("[Tree] + '%s' (id=%v) parent=%v", node.name, node.id, parent_id)
}

tree_remove_node :: proc(t: ^Scene_Tree, id: core.Node_ID) {
    node, ok := tree_get_node(t, id)
    if !ok { return }

    child_ids := slice.clone(node.children[:])
    defer delete(child_ids)
    for cid in child_ids { tree_remove_node(t, cid) }

    if node.parent_id != core.NULL_ID {
        parent, pok := tree_get_node(t, node.parent_id)
        if pok { _remove_id(&parent.children, id) }
    } else {
        _remove_id(&t.root_ids, id)
    }

    node.in_tree = false
    delete_key(&t.nodes, id)
    core.node_destroy(node)
    t.dirty = true
    log.debugf("[Tree] - id=%v", id)
}

tree_reparent :: proc(t: ^Scene_Tree, child_id: core.Node_ID, new_parent_id: core.Node_ID) {
    child, ok := tree_get_node(t, child_id)
    if !ok { return }

    if child.parent_id != core.NULL_ID {
        old_p, pok := tree_get_node(t, child.parent_id)
        if pok { _remove_id(&old_p.children, child_id) }
    } else {
        _remove_id(&t.root_ids, child_id)
    }

    child.parent_id = new_parent_id
    if new_parent_id != core.NULL_ID {
        new_p, pok := tree_get_node(t, new_parent_id)
        if pok { append(&new_p.children, child_id) }
    } else {
        append(&t.root_ids, child_id)
    }
    t.dirty = true
}

tree_get_node :: proc(t: ^Scene_Tree, id: core.Node_ID) -> (^core.Node, bool) {
    return t.nodes[id]
}

tree_find_by_name :: proc(t: ^Scene_Tree, name: string) -> ^core.Node {
    for _, node in t.nodes { if node.name == name { return node } }
    return nil
}

tree_find_by_tag :: proc(t: ^Scene_Tree, tag: string, out: ^[dynamic]^core.Node) {
    for _, node in t.nodes { if node.tag == tag { append(out, node) } }
}

// Return all active nodes that possess ALL requested component flags.
tree_query :: proc(t: ^Scene_Tree, required: core.Component_Flags, out: ^[dynamic]^core.Node) {
    clear(out)
    for _, node in t.nodes {
        if node.active && (node.components & required) == required {
            append(out, node)
        }
    }
}

// ------------------------------------------------------------------
//  Per-Frame Update
//  Call order: transform propagation → on_ready → on_update
// ------------------------------------------------------------------

tree_update :: proc(t: ^Scene_Tree, delta: f32) {
    if t.dirty {
        _rebuild_sorted(t)
        t.dirty = false
    }

    // 1. Propagate global transforms top-down (sorted = depth-first)
    for node in t.sorted_nodes {
        if !node.active { continue }
        if node.parent_id == core.NULL_ID {
            node.global = node.local
        } else {
            parent, ok := tree_get_node(t, node.parent_id)
            if ok {
                node.global = core.transform_compose(parent.global, node.local)
            } else {
                node.global = node.local
            }
        }
    }

    // 2. on_ready — fire bottom-up (leaves first) so a parent fires only
    //    after all its children have already fired.
    for i := len(t.sorted_nodes) - 1; i >= 0; i -= 1 {
        node := t.sorted_nodes[i]
        if node.ready_fired { continue }
        if _all_children_ready(t, node) {
            node.ready_fired = true
            if .Script in node.components &&
               node.script.vtable != nil &&
               node.script.vtable.on_ready != nil {
                node.script.vtable.on_ready(node)
            }
            log.debugf("[Tree] on_ready '%s'", node.name)
        }
    }

    // 3. on_update — scripted nodes only
    for node in t.sorted_nodes {
        if !node.active { continue }
        if .Script not_in node.components { continue }
        if node.script.vtable == nil { continue }
        if node.script.vtable.on_update == nil { continue }
        node.script.vtable.on_update(node, delta)
    }
}

// ------------------------------------------------------------------
//  Private
// ------------------------------------------------------------------

@(private)
_rebuild_sorted :: proc(t: ^Scene_Tree) {
    clear(&t.sorted_nodes)
    for rid in t.root_ids {
        root, ok := tree_get_node(t, rid)
        if ok { _dfs(t, root) }
    }
}

@(private)
_dfs :: proc(t: ^Scene_Tree, node: ^core.Node) {
    append(&t.sorted_nodes, node)
    for cid in node.children {
        child, ok := tree_get_node(t, cid)
        if ok { _dfs(t, child) }
    }
}

@(private)
_all_children_ready :: proc(t: ^Scene_Tree, node: ^core.Node) -> bool {
    for cid in node.children {
        child, ok := tree_get_node(t, cid)
        if !ok { continue }
        if !child.ready_fired { return false }
    }
    return true
}

@(private)
_remove_id :: proc(arr: ^[dynamic]core.Node_ID, id: core.Node_ID) {
    for i in 0..<len(arr) {
        if arr[i] == id { ordered_remove(arr, i); return }
    }
}

// ------------------------------------------------------------------
//  Physics Helpers (to satisfy physics.odin)
// ------------------------------------------------------------------

tree_query_component :: proc(t: ^Scene_Tree, required: core.Component_Flag, out: ^[dynamic]^core.Node) {
    clear(out)
    for _, node in t.nodes {
        if node.active && required in node.components {
            append(out, node)
        }
    }
}

tree_update_transforms :: proc(t: ^Scene_Tree) {
    if t.dirty {
        _rebuild_sorted(t)
        t.dirty = false
    }
    for node in t.sorted_nodes {
        if !node.active { continue }
        if node.parent_id == core.NULL_ID {
            node.global = node.local
        } else {
            parent, ok := tree_get_node(t, node.parent_id)
            if ok {
                node.global = core.transform_compose(parent.global, node.local)
            } else {
                node.global = node.local
            }
        }
    }
}