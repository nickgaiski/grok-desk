import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GrokDeskCore

struct RoutinesView: View {
    private let store: RoutineStore
    private let executor: RoutineExecutor
    private let scheduler: RoutineScheduler
    private let helperManager: RoutineLaunchAgentManager
    private let helperURL: URL
    private let grokURL: URL
    private let openSession: (String, String) -> Void

    @State private var workspace: String
    @State private var routines: [Routine] = []
    @State private var history: [RoutineRun] = []
    @State private var selectedRoutineID: UUID?
    @State private var selectedRunID: UUID?
    @State private var editingRoutine: Routine?
    @State private var confirmDelete = false
    @State private var helperStatus: RoutineHelperStatus = .notInstalled
    @State private var helperLoaded: Bool?
    @State private var helperBusy = false
    @State private var runningIDs: Set<UUID> = []
    @State private var notice = ""

    init(
        workspace: String,
        openSession: @escaping (String, String) -> Void,
        store suppliedStore: RoutineStore? = nil,
        executor suppliedExecutor: RoutineExecutor? = nil,
        scheduler suppliedScheduler: RoutineScheduler? = nil,
        helperManager suppliedHelperManager: RoutineLaunchAgentManager? = nil,
        helperURL: URL = RoutineHelperPaths.bundledExecutable(),
        grokURL: URL = RoutineGrokCLI.discover()
    ) {
        let store = suppliedStore ?? (suppliedScheduler?.store ?? RoutineStore.applicationDefault())
        let executor: RoutineExecutor
        if let suppliedExecutor {
            executor = suppliedExecutor
        } else if let suppliedScheduler {
            executor = suppliedScheduler.executor
        } else if suppliedStore == nil && grokURL == RoutineGrokCLI.discover() {
            executor = RoutineScheduler.shared.executor
        } else {
            executor = RoutineExecutor(store: store, grokExecutableURL: grokURL)
        }
        let scheduler = suppliedScheduler ?? (suppliedStore == nil && suppliedExecutor == nil && grokURL == RoutineGrokCLI.discover()
            ? RoutineScheduler.shared
            : RoutineScheduler(store: store, executor: executor))

        self.store = store
        self.executor = executor
        self.scheduler = scheduler
        self.helperManager = suppliedHelperManager ?? .applicationDefault(storeURL: store.fileURL)
        self.helperURL = helperURL
        self.grokURL = grokURL
        self.openSession = openSession
        _workspace = State(initialValue: workspace)
    }

    private var selectedRoutine: Routine? { routines.first { $0.id == selectedRoutineID } }
    private var selectedRun: RoutineRun? { history.first { $0.id == selectedRunID } ?? history.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DeskColor.hairline)
            HStack(spacing: 0) {
                routineList.frame(minWidth: 230, idealWidth: 280, maxWidth: 330)
                Divider().overlay(DeskColor.hairline)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(DeskColor.ink)
        .background(DeskColor.window)
        .task {
            scheduler.start()
            reload()
            await refreshHelperStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                reload()
            }
        }
        .sheet(item: $editingRoutine) { routine in
            RoutineEditor(routine: routine) { saved in
                do {
                    try store.save(saved)
                    editingRoutine = nil
                    workspace = saved.cwd
                    selectedRoutineID = saved.id
                    notice = saved.enabled ? "Routine saved and enabled." : "Routine saved as paused."
                    reload()
                } catch { notice = error.localizedDescription }
            }
            .frame(minWidth: 620, minHeight: 660)
        }
        .confirmationDialog("Delete this routine and its run history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete routine and history", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting a routine also removes its saved run history. Grok sessions remain in Grok’s canonical session store.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Routines").font(.system(size: 22, weight: .semibold))
                Text("Scheduled runs use your signed-in Grok CLI while this Mac is awake and you are logged in.")
                    .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            }
            Spacer(minLength: 12)
            helperControl
            Button { beginCreate() } label: { Label("New routine", systemImage: "plus") }
                .buttonStyle(DeskButtonStyle(prominent: true))
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(DeskColor.sidebar.opacity(0.6))
    }

    private var helperControl: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(helperTitle).font(.system(size: 11, weight: .medium))
                Text(helperSubtitle).font(.system(size: 10)).foregroundStyle(DeskColor.muted)
            }
            if helperBusy {
                ProgressView().controlSize(.small).frame(width: 92)
            } else {
                helperButton
                    .disabled(!hasHelperConfiguration && !canInstallHelper)
                    .help(helperHelp)
            }
        }
    }

    @ViewBuilder
    private var helperButton: some View {
        switch helperStatus {
        case .installed:
            Button("Remove helper") { removeHelper() }.buttonStyle(QuietButton())
        case .repairRequired where canInstallHelper:
            Button("Repair helper") { installHelper() }.buttonStyle(DeskButtonStyle())
        case .repairRequired:
            Button("Remove helper") { removeHelper() }.buttonStyle(QuietButton())
        case .notInstalled:
            Button(helperButtonTitle) { installHelper() }.buttonStyle(DeskButtonStyle())
        }
    }

    private var routineList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("YOUR ROUTINES").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                Spacer()
                Text("\(routines.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(DeskColor.muted)
            }.foregroundStyle(DeskColor.muted).padding(.horizontal, 16).padding(.vertical, 13)

            if routines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "clock.badge.plus").font(.system(size: 20)).foregroundStyle(DeskColor.muted)
                    Text("No routines yet").font(.system(size: 13, weight: .medium))
                    Text("Create a schedule for a workspace and prompt. New routines stay paused until you enable them.")
                        .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                    Button("Create routine") { beginCreate() }.buttonStyle(DeskButtonStyle()).padding(.top, 3)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(routines) { routine in
                            routineRow(routine)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 10)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Label("No schedule runs while the Mac sleeps or you are logged out.", systemImage: "moon.zzz")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(DeskColor.muted)
                Text("Missed occurrences coalesce into one catch-up run or are skipped, as each routine specifies.")
                    .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(DeskColor.row.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
        }
        .background(DeskColor.sidebar.opacity(0.38))
    }

    private func routineRow(_ routine: Routine) -> some View {
        let isSelected = selectedRoutineID == routine.id
        return Button {
            selectedRoutineID = routine.id
            selectedRunID = nil
            loadHistory(for: routine.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(routine.enabled ? Color.green.opacity(0.8) : DeskColor.muted.opacity(0.6))
                    .frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(routine.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(routine.enabled ? "ON" : "PAUSED")
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(routine.enabled ? Color.green : DeskColor.muted)
                    }
                    Text(routine.cron).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeskColor.muted)
                    Text(routine.cwd).font(.system(size: 9)).foregroundStyle(DeskColor.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(isSelected ? DeskColor.select.opacity(0.13) : DeskColor.row.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? DeskColor.select.opacity(0.45) : .clear, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(routine.name), \(routine.enabled ? "enabled" : "paused"), \(routine.cron)")
    }

    @ViewBuilder
    private var detail: some View {
        if let routine = selectedRoutine {
            routineDetail(routine)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "clock").font(.system(size: 26)).foregroundStyle(DeskColor.muted)
                Text("Choose a routine").font(.system(size: 14, weight: .medium))
                Text("Review the schedule, run it now, or open its saved Grok session.")
                    .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func routineDetail(_ routine: Routine) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(routine.name).font(.system(size: 21, weight: .semibold))
                        Text("\(routine.cron)  ·  \(routine.timeZoneID)")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DeskColor.muted)
                        Text(nextRunText(for: routine)).font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                    }
                    Spacer(minLength: 4)
                    Button { runNow(routine) } label: {
                        if runningIDs.contains(routine.id) { ProgressView().controlSize(.small) }
                        else { Label("Run now", systemImage: "play.fill") }
                    }.buttonStyle(DeskButtonStyle(prominent: true)).disabled(runningIDs.contains(routine.id))
                    Button(routine.enabled ? "Pause" : "Resume") { setEnabled(!routine.enabled, for: routine) }
                        .buttonStyle(DeskButtonStyle()).disabled(runningIDs.contains(routine.id))
                    Menu {
                        Button("Edit routine", systemImage: "pencil") { editingRoutine = routine }
                        Button("Delete routine", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                        .menuStyle(.borderlessButton).fixedSize().buttonStyle(QuietButton())
                }

                if !notice.isEmpty {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DeskColor.row.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                }

                HStack(alignment: .top, spacing: 14) {
                    informationCard(title: "WORKSPACE", value: routine.cwd, symbol: "folder")
                    informationCard(title: "MAX TURNS", value: "\(routine.maxTurns) · 15-minute run limit", symbol: "number")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Permission profile", systemImage: "hand.raised")
                        .font(.system(size: 12, weight: .medium))
                    Text(RoutinePermissionProfile(rawValue: routine.permissionProfile)?.explanation ?? "Unsupported profile; edit this routine to choose a supported profile.")
                        .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeskColor.row.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Prompt", systemImage: "text.alignleft").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if !routine.modelID.isEmpty {
                            Text(routine.modelID).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeskColor.muted)
                        } else {
                            Text("Grok default model").font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                        }
                    }
                    Text(routine.prompt).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(DeskColor.composer.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                }

                runHistory(routine)
            }
            .padding(22)
        }
    }

    private func informationCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(DeskColor.muted)
            Text(value).font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(DeskColor.row.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))
    }

    private func runHistory(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Run history", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(history.count) saved").font(.system(size: 10)).foregroundStyle(DeskColor.muted)
            }
            if history.isEmpty {
                Text("No runs yet. Use Run now to create a canonical Grok session and verify this routine.")
                    .font(.system(size: 11)).foregroundStyle(DeskColor.muted).padding(.vertical, 7)
            } else {
                ForEach(history.prefix(50)) { run in
                    runRow(run, cwd: routine.cwd)
                }
            }
            if let selectedRun, !selectedRun.output.isEmpty || selectedRun.error != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(selectedRun.state.title).font(.system(size: 10, weight: .semibold))
                        Spacer()
                        if let sessionID = selectedRun.sessionID {
                            Button("Open Grok session") { openSession(sessionID, routine.cwd) }
                                .buttonStyle(QuietButton())
                        }
                    }
                    if let error = selectedRun.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(DeskColor.danger).textSelection(.enabled)
                    }
                    if !selectedRun.output.isEmpty {
                        Text(String(selectedRun.output.suffix(4_000))).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DeskColor.muted).textSelection(.enabled).lineLimit(8)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(DeskColor.row.opacity(0.34), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func runRow(_ run: RoutineRun, cwd: String) -> some View {
        HStack(spacing: 9) {
            Button {
                selectedRunID = run.id
            } label: {
            HStack(spacing: 9) {
                Image(systemName: run.state.symbol).foregroundStyle(run.state.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.state.title).font(.system(size: 11, weight: .medium))
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened) + " · \(run.trigger == .manual ? "Run now" : "Scheduled")")
                        .font(.system(size: 9)).foregroundStyle(DeskColor.muted)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selectedRunID == run.id ? DeskColor.select.opacity(0.10) : DeskColor.row.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            if let sessionID = run.sessionID {
                Button("Open session") { openSession(sessionID, cwd) }
                    .font(.system(size: 9, weight: .medium)).buttonStyle(QuietButton())
                    .padding(.trailing, 8)
            }
        }
        .contextMenu {
            if let sessionID = run.sessionID { Button("Open Grok session") { openSession(sessionID, cwd) } }
            Button("Copy session ID") { if let sessionID = run.sessionID { NSPasteboard.general.setString(sessionID, forType: .string) } }
        }
    }

    private var isHelperInstalled: Bool {
        if case .installed = helperStatus { return true }
        return false
    }

    private var hasHelperConfiguration: Bool {
        if case .notInstalled = helperStatus { return false }
        return true
    }

    private var canInstallHelper: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path) &&
            FileManager.default.isExecutableFile(atPath: grokURL.path)
    }

    private var helperTitle: String {
        if helperBusy { return "Updating helper…" }
        switch helperStatus {
        case .notInstalled: return "App-closed runs off"
        case .installed: return helperLoaded == true ? "Helper installed and loaded" : "Helper installed"
        case .repairRequired: return "Helper needs repair"
        }
    }

    private var helperSubtitle: String {
        switch helperStatus {
        case .notInstalled:
            return canInstallHelper ? "Optional LaunchAgent · 60-second checks" : "Available in a packaged app build"
        case .installed:
            return "Runs while logged in and Mac is awake"
        case .repairRequired:
            return canInstallHelper ? "The app or helper path changed" : "The packaged helper is unavailable"
        }
    }

    private var helperButtonTitle: String {
        switch helperStatus {
        case .notInstalled: return "Install helper"
        case .installed: return "Remove helper"
        case .repairRequired: return canInstallHelper ? "Repair helper" : "Remove helper"
        }
    }

    private var helperHelp: String {
        if case .installed = helperStatus { return "Remove only Grok Desk’s own LaunchAgent. The saved routines and run history remain." }
        if case .repairRequired = helperStatus, !canInstallHelper {
            return "The packaged helper or Grok CLI is unavailable. Remove only Grok Desk’s stale LaunchAgent; routines and run history remain."
        }
        return "Installs Grok Desk’s own LaunchAgent so due routines can run while the app is closed. macOS will not run it while the Mac is asleep or you are logged out. After wake and login, catch-up runs the latest missed time."
    }

    private func nextRunText(for routine: Routine) -> String {
        guard routine.enabled else { return "Paused · no next run" }
        guard let schedule = try? RoutineSchedule(cron: routine.cron),
              let next = try? schedule.nextRun(after: Date(), timeZoneID: routine.timeZoneID)
        else { return "Schedule needs attention" }
        return "Next run · " + next.formatted(date: .abbreviated, time: .shortened)
    }

    private func beginCreate() {
        let folder = workspace.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workspace
        editingRoutine = Routine(name: "", cwd: folder, prompt: "", enabled: false)
    }

    private func reload() {
        do {
            routines = try store.routines()
            if !routines.contains(where: { $0.id == selectedRoutineID }) { selectedRoutineID = routines.first?.id }
            if let selectedRoutineID { loadHistory(for: selectedRoutineID) }
        } catch { notice = error.localizedDescription }
    }

    private func loadHistory(for id: UUID) {
        do { history = try store.runs(for: id) }
        catch { notice = error.localizedDescription; history = [] }
    }

    private func setEnabled(_ enabled: Bool, for routine: Routine) {
        do {
            try store.setEnabled(enabled, routineID: routine.id)
            notice = enabled ? "Routine resumed." : "Routine paused. In-progress work may finish; future scheduled runs are held."
            reload()
        } catch { notice = error.localizedDescription }
    }

    private func deleteSelected() {
        guard let selectedRoutineID else { return }
        do {
            try executor.deleteRoutine(routineID: selectedRoutineID)
            self.selectedRoutineID = nil
            selectedRunID = nil
            history = []
            notice = "Routine and its saved run history were deleted. Grok sessions remain available."
            reload()
        } catch { notice = error.localizedDescription }
    }

    private func runNow(_ routine: Routine) {
        runningIDs.insert(routine.id)
        notice = "Starting a new Grok session for this routine…"
        Task.detached(priority: .utility) { [scheduler] in
            let result: Result<RoutineExecutionResult, Error>
            do { result = .success(try scheduler.runNow(routineID: routine.id)) }
            catch { result = .failure(error) }
            await MainActor.run {
                runningIDs.remove(routine.id)
                switch result {
                case .success(let value): notice = value.disposition.message
                case .failure(let error): notice = error.localizedDescription
                }
                reload()
            }
        }
    }

    private func refreshHelperStatus() async {
        let status = helperManager.status(expectedHelperURL: helperURL)
        helperStatus = status
        if case .installed = status {
            let loaded = await Task.detached(priority: .utility) { (try? helperManager.isLoaded()) ?? false }.value
            helperLoaded = loaded
        } else { helperLoaded = false }
    }

    private func installHelper() {
        helperBusy = true
        notice = "Installing Grok Desk’s app-closed helper…"
        Task.detached(priority: .utility) { [helperManager, helperURL, grokURL] in
            let result: Result<Void, Error>
            do { try helperManager.install(helperURL: helperURL, grokURL: grokURL); result = .success(()) }
            catch { result = .failure(error) }
            let loaded = (try? helperManager.isLoaded()) ?? false
            await MainActor.run {
                helperBusy = false
                switch result {
                case .success: notice = "Helper installed and launchd readback succeeded."
                case .failure(let error): notice = error.localizedDescription
                }
                helperStatus = helperManager.status(expectedHelperURL: helperURL)
                helperLoaded = loaded
            }
        }
    }

    private func removeHelper() {
        helperBusy = true
        Task.detached(priority: .utility) { [helperManager, helperURL] in
            let result: Result<Void, Error>
            do { try helperManager.remove(); result = .success(()) }
            catch { result = .failure(error) }
            await MainActor.run {
                helperBusy = false
                switch result {
                case .success: notice = "Helper removed. Saved routines and Grok sessions are unchanged."
                case .failure(let error): notice = error.localizedDescription
                }
                helperStatus = helperManager.status(expectedHelperURL: helperURL)
                helperLoaded = false
            }
        }
    }
}

private struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routine: Routine
    @State private var errorMessage = ""
    @State private var showFolderPicker = false
    let onSave: (Routine) -> Void

    init(routine: Routine, onSave: @escaping (Routine) -> Void) {
        _routine = State(initialValue: routine)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(routine.name.isEmpty ? "New routine" : "Edit routine")")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Schedules use the selected time zone and the installed Grok CLI.")
                        .font(.system(size: 11)).foregroundStyle(DeskColor.muted)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
            }.padding(18)
            Divider()
            Form {
                Section("Routine") {
                    TextField("Name", text: $routine.name)
                    HStack {
                        TextField("Workspace folder", text: $routine.cwd)
                        Button("Choose…") { showFolderPicker = true }.buttonStyle(QuietButton())
                    }
                    TextField("Model ID (blank uses Grok default)", text: $routine.modelID)
                    Stepper(value: $routine.maxTurns, in: 1...25) {
                        HStack { Text("Maximum turns"); Spacer(); Text("\(routine.maxTurns)").monospacedDigit().foregroundStyle(DeskColor.muted) }
                    }
                    Toggle("Enable this routine after saving", isOn: $routine.enabled)
                }

                Section("Schedule") {
                    HStack {
                        TextField("Five-field cron", text: $routine.cron)
                            .font(.system(size: 12, design: .monospaced))
                        Menu("Presets") {
                            ForEach(RoutineSchedule.presets) { preset in
                                Button(preset.title) { routine.cron = preset.cron }
                            }
                        }.menuStyle(.borderlessButton)
                    }
                    TextField("Time zone", text: $routine.timeZoneID)
                        .font(.system(size: 12, design: .monospaced))
                    LabeledContent("Next occurrence") { Text(schedulePreview).foregroundStyle(DeskColor.muted) }
                    Toggle("Run one catch-up after missed occurrences", isOn: $routine.catchUp)
                    Text(routine.catchUp
                        ? "Several missed schedule times coalesce into one run at the most recent occurrence. After the Mac wakes, that is the run that fires."
                        : "Occurrences missed by more than one minute are recorded as skipped.")
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    Text("The helper cannot run while the Mac is asleep or you are logged out. Sleep stops the machine. A login-session helper stops at logout. Catch-up covers the latest missed time once the Mac is awake and you are logged in.")
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                }

                Section("Prompt and permissions") {
                    Picker("Conversation", selection: $routine.continuity) {
                        ForEach(RoutineContinuity.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                    Text(RoutineContinuity(rawValue: routine.continuity)?.explanation ?? "")
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    Text("To use another chat, add a line: Hand off to session: title or session id")
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    TextEditor(text: $routine.prompt).font(.system(size: 12)).frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DeskColor.hairline, lineWidth: 0.6))
                    Picker("Permission profile", selection: $routine.permissionProfile) {
                        ForEach(RoutinePermissionProfile.allCases) { profile in Text(profile.title).tag(profile.rawValue) }
                    }
                    Text(RoutinePermissionProfile.needsInput.explanation)
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                    Text("Headless runs stop at unapproved tools. They never use Always approve and cannot wait for an interactive dialog.")
                        .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(DeskColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
            }
            HStack {
                Label("15-minute limit · up to 25 turns", systemImage: "hourglass")
                    .font(.system(size: 10)).foregroundStyle(DeskColor.muted)
                Spacer()
                Button("Save routine") { save() }.buttonStyle(DeskButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .foregroundStyle(DeskColor.ink)
        .deskPopup(radius: 22)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { routine.cwd = url.path }
        }
    }

    private var schedulePreview: String {
        guard let schedule = try? RoutineSchedule(cron: routine.cron),
              let next = try? schedule.nextRun(after: Date(), timeZoneID: routine.timeZoneID)
        else { return "Check cron and time zone" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    private func save() {
        do {
            try routine.validate()
            errorMessage = ""
            onSave(routine)
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension RoutineRunState {
    var title: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Needs input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
    var symbol: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .needsInput: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "forward.end.fill"
        }
    }
    var color: Color {
        switch self {
        case .running: DeskColor.select
        case .needsInput: .orange
        case .completed: .green
        case .failed: DeskColor.danger
        case .skipped: DeskColor.muted
        }
    }
}

private extension RoutineExecutionDisposition {
    var message: String {
        switch self {
        case .completed: "Routine completed. Its Grok session and output are in run history."
        case .needsInput: "Routine needs input. An unapproved tool was refused; no approval was granted."
        case .failed: "Routine failed. Review its run history for output and error details."
        case .skipped: "Missed occurrence skipped by this routine’s catch-up setting."
        case .alreadyRunning: "This routine already has a run in progress."
        case .alreadyClaimed: "This schedule occurrence has already been claimed."
        case .paused: "This routine is paused."
        case .scheduleChanged: "The schedule changed before this occurrence was claimed. The next tick will use the saved schedule."
        }
    }
}
