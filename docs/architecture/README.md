# Contributor map

The README diagram is a hand-curated overview. `graph.json` is a file-level projection of the existing local Graphify graph, checked against the public source tree on 2026-10-05. It includes 76 source files and 91 cross-file relationships labeled EXTRACTED in that graph. The graph can lag source changes; it is not a complete call graph.

**[Download the interactive explorer](https://github.com/nickgaiski/grok-desk/raw/refs/heads/main/docs/architecture/explorer.html)** and open it locally. It works offline, has no external scripts, and supports search and selecting a file to highlight its observed neighbors. GitHub displays HTML as source, so download it to interact. Machine-readable version: [graph.json](graph.json).

| Area | Start here |
|---|---|
| App shell, sidebar, composer | [GrokDeskApp.swift](../../Sources/GrokDesk/GrokDeskApp.swift), [ComposerInput.swift](../../Sources/GrokDesk/ComposerInput.swift) |
| Sessions, agent transport, queues | [DeskModel.swift](../../Sources/GrokDeskCore/DeskModel.swift), [AgentClient.swift](../../Sources/GrokDeskCore/AgentClient.swift), [SessionRuntime.swift](../../Sources/GrokDeskCore/SessionRuntime.swift), [QueuedPrompt.swift](../../Sources/GrokDeskCore/QueuedPrompt.swift) |
| Agent activity | [AgentDashboard.swift](../../Sources/GrokDesk/AgentDashboard.swift), [AgentActivity.swift](../../Sources/GrokDeskCore/AgentActivity.swift) |
| Cinema Studio | [ImagineStudio.swift](../../Sources/GrokDesk/ImagineStudio.swift), [ImagineClient.swift](../../Sources/GrokDeskCore/ImagineClient.swift), [StudioAgentCanvas.swift](../../Sources/GrokDesk/StudioAgentCanvas.swift) |
| Media and shot controls | [StudioMediaPicker.swift](../../Sources/GrokDesk/StudioMediaPicker.swift), [CameraPresets.swift](../../Sources/GrokDeskCore/CameraPresets.swift), [VideoAudio.swift](../../Sources/GrokDeskCore/VideoAudio.swift) |
| Browser, files, terminal | [ChatWebPane.swift](../../Sources/GrokDesk/ChatWebPane.swift), [WorkspaceFilesPanel.swift](../../Sources/GrokDesk/WorkspaceFilesPanel.swift), [EmbeddedTerminal.swift](../../Sources/GrokDesk/EmbeddedTerminal.swift) |
| Git and worktrees | [Repository.swift](../../Sources/GrokDeskCore/Repository.swift), [WorktreeService.swift](../../Sources/GrokDeskCore/WorktreeService.swift) |
| Routines and helper | [RoutineScheduler.swift](../../Sources/GrokDeskCore/RoutineScheduler.swift), [RoutineExecutor.swift](../../Sources/GrokDeskCore/RoutineExecutor.swift), [RoutineLaunchAgent.swift](../../Sources/GrokDeskCore/RoutineLaunchAgent.swift) |
| Configuration, rules, plugins | [ConfigurationEditor.swift](../../Sources/GrokDesk/ConfigurationEditor.swift), [ProjectRulesEditor.swift](../../Sources/GrokDesk/ProjectRulesEditor.swift), [PluginCatalog.swift](../../Sources/GrokDeskCore/PluginCatalog.swift), [ConnectionHealth.swift](../../Sources/GrokDeskCore/ConnectionHealth.swift) |
| Glass, motion, controls | [LiquidGlass.swift](../../Sources/GrokDesk/LiquidGlass.swift), [Glass.metal](../../Shaders/Glass.metal), [Motion.swift](../../Sources/GrokDesk/Motion.swift), [GlassSlider.swift](../../Sources/GrokDesk/GlassSlider.swift) |

Graph edges count observed relationships aggregated between source files; do not interpret their count as runtime frequency. New public files absent from the old graph still appear as isolated nodes. Source code and tests are authoritative.
