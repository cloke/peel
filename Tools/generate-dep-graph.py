#!/usr/bin/env python3
"""
generate-dep-graph.py — Extract dependency graph from Peel RAG SQLite → JSON for D3 visualization.

Generates two levels of graph data:
  1. Module-level: high-level view showing how tio-employee, tio-admin, addons flow
  2. File-level: detailed view within a selected module

Usage:
  python3 generate-dep-graph.py [--repo tio-front-end] [--output graph-data.json]
"""

import json
import sqlite3
import sys
import os
from pathlib import Path
from collections import defaultdict

DB_PATH = os.path.expanduser("~/Library/Application Support/Peel/RAG/rag.sqlite")

def get_module(path: str) -> str:
    """Map a file path to its logical module."""
    parts = path.split("/")
    if len(parts) >= 2 and parts[0] == "addons":
        return f"addons/{parts[1]}"
    if len(parts) >= 1:
        return parts[0]
    return "root"

def get_submodule(path: str) -> str:
    """Map a file path to its submodule (2nd-level directory)."""
    parts = path.split("/")
    if len(parts) >= 2 and parts[0] == "addons":
        if len(parts) >= 4:
            return "/".join(parts[:4])  # addons/tio-common/src/components
        return "/".join(parts[:3])
    if len(parts) >= 3:
        return "/".join(parts[:3])  # tio-employee/app/components
    if len(parts) >= 2:
        return "/".join(parts[:2])
    return parts[0]

def build_graph(repo_name: str = "tio-front-end"):
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    # Get repo id
    repo = conn.execute("SELECT id FROM repos WHERE name = ?", (repo_name,)).fetchone()
    if not repo:
        print(f"Error: repo '{repo_name}' not found", file=sys.stderr)
        sys.exit(1)
    repo_id = repo["id"]

    # --- File-level data ---
    files = conn.execute("""
        SELECT id, path, language FROM files 
        WHERE repo_id = ? AND path NOT LIKE '%node_modules%'
    """, (repo_id,)).fetchall()

    file_map = {f["id"]: dict(f) for f in files}

    deps = conn.execute("""
        SELECT source_file_id, target_file_id, dependency_type, raw_import
        FROM dependencies 
        WHERE repo_id = ? AND target_file_id IS NOT NULL
    """, (repo_id,)).fetchall()

    # --- Module-level graph ---
    module_edges = defaultdict(lambda: defaultdict(lambda: {"import": 0, "inherit": 0}))
    module_files = defaultdict(set)
    module_langs = defaultdict(lambda: defaultdict(int))

    for f in files:
        mod = get_module(f["path"])
        module_files[mod].add(f["id"])
        module_langs[mod][f["language"] or "Unknown"] += 1

    for d in deps:
        src_file = file_map.get(d["source_file_id"])
        tgt_file = file_map.get(d["target_file_id"])
        if not src_file or not tgt_file:
            continue
        src_mod = get_module(src_file["path"])
        tgt_mod = get_module(tgt_file["path"])
        dep_type = d["dependency_type"]
        module_edges[src_mod][tgt_mod][dep_type] = module_edges[src_mod][tgt_mod].get(dep_type, 0) + 1

    # Build module nodes
    module_nodes = []
    for mod, fids in module_files.items():
        langs = dict(module_langs[mod])
        top_lang = max(langs, key=langs.get) if langs else "Unknown"
        module_nodes.append({
            "id": mod,
            "label": mod,
            "fileCount": len(fids),
            "topLanguage": top_lang,
            "languages": langs,
        })

    # Build module edges
    module_links = []
    for src, targets in module_edges.items():
        for tgt, types in targets.items():
            if src == tgt:
                continue  # skip self-links at module level
            total = sum(types.values())
            module_links.append({
                "source": src,
                "target": tgt,
                "weight": total,
                "types": dict(types),
            })

    # --- Submodule-level graph (within each module) ---
    submod_edges = defaultdict(lambda: defaultdict(int))
    submod_files = defaultdict(set)

    for f in files:
        sm = get_submodule(f["path"])
        submod_files[sm].add(f["id"])

    for d in deps:
        src_file = file_map.get(d["source_file_id"])
        tgt_file = file_map.get(d["target_file_id"])
        if not src_file or not tgt_file:
            continue
        src_sm = get_submodule(src_file["path"])
        tgt_sm = get_submodule(tgt_file["path"])
        if src_sm != tgt_sm:
            submod_edges[src_sm][tgt_sm] += 1

    submod_nodes = []
    for sm, fids in submod_files.items():
        parent_mod = get_module(list(file_map.get(fid, {}).get("path", "") for fid in fids).__iter__().__next__())
        submod_nodes.append({
            "id": sm,
            "label": sm.split("/")[-1] if "/" in sm else sm,
            "module": parent_mod,
            "fileCount": len(fids),
        })

    submod_links = []
    for src, targets in submod_edges.items():
        for tgt, count in targets.items():
            submod_links.append({
                "source": src,
                "target": tgt,
                "weight": count,
            })

    # --- File-level detail for a focused view ---
    # Group files by directory
    dir_files = defaultdict(list)
    for f in files:
        d = "/".join(f["path"].split("/")[:-1])
        dir_files[d].append({"id": f["id"], "path": f["path"], "language": f["language"]})

    # --- Chunk stats ---
    chunk_stats = conn.execute("""
        SELECT 
            f.path,
            COUNT(*) as chunk_count,
            GROUP_CONCAT(DISTINCT c.construct_type) as construct_types
        FROM chunks c
        JOIN files f ON c.file_id = f.id
        WHERE f.repo_id = ?
        GROUP BY f.id
    """, (repo_id,)).fetchall()

    file_chunk_info = {}
    for cs in chunk_stats:
        file_chunk_info[cs["path"]] = {
            "chunks": cs["chunk_count"],
            "types": cs["construct_types"],
        }

    conn.close()

    # --- Assemble final JSON ---
    graph_data = {
        "repo": repo_name,
        "stats": {
            "totalFiles": len(files),
            "totalDependencies": len(deps),
            "totalModules": len(module_nodes),
        },
        "moduleGraph": {
            "nodes": sorted(module_nodes, key=lambda n: -n["fileCount"]),
            "links": sorted(module_links, key=lambda l: -l["weight"]),
        },
        "submoduleGraph": {
            "nodes": sorted(submod_nodes, key=lambda n: -n["fileCount"]),
            "links": sorted(submod_links, key=lambda l: -l["weight"]),
        },
    }

    return graph_data


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Generate dependency graph JSON from Peel RAG")
    parser.add_argument("--repo", default="tio-front-end", help="Repository name")
    parser.add_argument("--output", default=None, help="Output file (default: stdout)")
    args = parser.parse_args()

    data = build_graph(args.repo)

    if args.output:
        with open(args.output, "w") as f:
            json.dump(data, f, indent=2)
        print(f"Wrote {args.output} ({len(json.dumps(data))} bytes)")
    else:
        print(json.dumps(data, indent=2))
