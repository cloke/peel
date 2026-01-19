//
//  WorktreeService.swift
//  KitchenSync
//
//  Created on 1/10/26.
//
//  Service for managing git worktrees for agent chains.
//  Each chain gets an isolated worktree to work in, preventing conflicts
//  when multiple chains run on the same project.
//

import Foundation

@available(*, deprecated, renamed: "AgentWorkspaceService")
public typealias WorktreeService = AgentWorkspaceService
