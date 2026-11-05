import Carbon.HIToolbox
import Foundation
import Observation
import OpenIslandCore
import os

private let promptHotKeyLog = Logger(subsystem: "app.openisland", category: "hotkeys")

enum PromptHotKeyAction: Equatable, Hashable, Sendable {
    case approve
    case deny
    case selectOption(Int)
    case jump

    var keyCode: UInt32 {
        switch self {
        case .approve: UInt32(kVK_ANSI_Y)
        case .deny: UInt32(kVK_ANSI_N)
        case .jump: UInt32(kVK_ANSI_J)
        case let .selectOption(index): Self.digitKeyCodes[index]
        }
    }

    static let maxOptionCount = 9

    private static let digitKeyCodes: [UInt32] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ].map(UInt32.init)
}

/// The ⌘-shortcuts to hold while the opened island shows a prompt, and the
/// session they act on. Hotkeys are registered system-wide only while a plan
/// exists, so they never shadow other apps' shortcuts while the island is
/// closed.
struct PromptHotKeyPlan: Equatable {
    var sessionID: String
    var actions: [PromptHotKeyAction]

    static func make(
        isEnabled: Bool,
        notchStatus: NotchStatus,
        surfaceSessionID: String?,
        sessions: [AgentSession]
    ) -> PromptHotKeyPlan? {
        guard isEnabled, notchStatus == .opened else { return nil }

        let target = surfaceSessionID.flatMap { id in sessions.first { $0.id == id } }
            ?? sessions.first { $0.phase.requiresAttention }
        guard let target else { return nil }

        var actions: [PromptHotKeyAction] = []
        switch target.phase {
        case .waitingForApproval:
            actions = [.approve, .deny]
        case .waitingForAnswer:
            actions = optionIndices(for: target.questionPrompt).map(PromptHotKeyAction.selectOption)
        case .running, .completed:
            break
        }
        if target.jumpTarget != nil {
            actions.append(.jump)
        }

        return actions.isEmpty ? nil : PromptHotKeyPlan(sessionID: target.id, actions: actions)
    }

    /// Option indices that one keypress can answer: a single single-select
    /// question, minus free-form options that need typed input.
    static func optionIndices(for prompt: QuestionPrompt?) -> [Int] {
        guard let prompt else { return [] }
        let options: [QuestionOption]
        if prompt.questions.isEmpty {
            options = prompt.options.map { QuestionOption(label: $0) }
        } else if prompt.questions.count == 1, let question = prompt.questions.first, !question.multiSelect {
            options = question.options
        } else {
            return []
        }
        return options.indices
            .filter { $0 < PromptHotKeyAction.maxOptionCount && !options[$0].allowsFreeform }
    }

    static func answer(selecting index: Int, in prompt: QuestionPrompt) -> QuestionPromptResponse? {
        if prompt.questions.isEmpty {
            guard prompt.options.indices.contains(index) else { return nil }
            let label = prompt.options[index]
            return QuestionPromptResponse(rawAnswer: label, answers: [prompt.title: label])
        }
        guard let question = prompt.questions.first,
              question.options.indices.contains(index) else { return nil }
        let label = question.options[index].label
        return QuestionPromptResponse(rawAnswer: label, answers: [question.question: label])
    }
}

@MainActor
final class PromptHotKeyCoordinator {
    private weak var model: AppModel?
    private let registrar = GlobalHotKeyRegistrar()
    private var appliedPlan: PromptHotKeyPlan?
    private var isObserving = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        refresh()
    }

    private func refresh() {
        guard let model else { return }
        let plan = withObservationTracking {
            PromptHotKeyPlan.make(
                isEnabled: model.promptHotKeysEnabled,
                notchStatus: model.notchStatus,
                surfaceSessionID: model.islandSurface.sessionID,
                sessions: model.islandListSessions
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        apply(plan)
    }

    private func apply(_ plan: PromptHotKeyPlan?) {
        guard plan != appliedPlan else { return }
        appliedPlan = plan
        registrar.unregisterAll()
        guard let plan else {
            promptHotKeyLog.info("Prompt hotkeys released")
            return
        }

        for action in plan.actions {
            let sessionID = plan.sessionID
            registrar.register(keyCode: action.keyCode, modifiers: UInt32(cmdKey)) { [weak self] in
                self?.perform(action, sessionID: sessionID)
            }
        }
        promptHotKeyLog.info("Registered \(self.registrar.count) prompt hotkeys for session \(plan.sessionID, privacy: .public)")
    }

    private func perform(_ action: PromptHotKeyAction, sessionID: String) {
        guard let model, let session = model.state.session(id: sessionID) else { return }
        promptHotKeyLog.info("Prompt hotkey \(String(describing: action), privacy: .public) for session \(sessionID, privacy: .public)")

        switch action {
        case .approve:
            guard session.phase == .waitingForApproval else { return }
            model.approvePermission(for: sessionID, action: .allowOnce)
        case .deny:
            guard session.phase == .waitingForApproval else { return }
            model.approvePermission(for: sessionID, action: .deny)
        case let .selectOption(index):
            guard session.phase == .waitingForAnswer,
                  let prompt = session.questionPrompt,
                  let response = PromptHotKeyPlan.answer(selecting: index, in: prompt) else { return }
            model.answerQuestion(for: sessionID, answer: response)
        case .jump:
            model.jumpToSession(session)
        }
    }
}

/// Thin wrapper over Carbon `RegisterEventHotKey`, which delivers key
/// combos to this app regardless of which app is frontmost and needs no
/// Accessibility permission.
@MainActor
final class GlobalHotKeyRegistrar {
    private static let signature: OSType = 0x4F49_484B

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            promptHotKeyLog.error("RegisterEventHotKey failed for keyCode \(keyCode) status \(status)")
            return
        }
        hotKeyRefs.append(ref)
        actions[id] = action
    }

    var count: Int { hotKeyRefs.count }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        guard let action = actions[id] else { return }
        Task { @MainActor in action() }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                MainActor.assumeIsolated {
                    registrar.fire(id: id)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
