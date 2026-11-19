import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct PromptHotKeyPlanTests {
    private static let jumpTarget = JumpTarget(
        terminalApp: "Ghostty",
        workspaceName: "project",
        paneTitle: "codex"
    )

    private static func session(
        id: String,
        phase: SessionPhase,
        questionPrompt: QuestionPrompt? = nil,
        jumpTarget: JumpTarget? = Self.jumpTarget
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: "Codex · project",
            tool: .codex,
            attachmentState: .attached,
            phase: phase,
            summary: "",
            updatedAt: .now,
            permissionRequest: phase == .waitingForApproval
                ? PermissionRequest(title: "Approve", summary: "Allow edit?", affectedPath: "/tmp/a.swift")
                : nil,
            questionPrompt: questionPrompt,
            jumpTarget: jumpTarget
        )
    }

    private static func plan(
        enabled: Bool = true,
        status: NotchStatus = .opened,
        pointerOver: Bool = true,
        surface: String? = nil,
        list: [AgentSession]? = nil,
        _ sessions: [AgentSession]
    ) -> PromptHotKeyPlan? {
        PromptHotKeyPlan.make(
            isEnabled: enabled,
            notchStatus: status,
            isPointerOverIsland: pointerOver,
            surfaceSessionID: surface,
            state: SessionState(sessions: sessions),
            listSessions: list ?? sessions
        )
    }

    @Test
    func approvalCardBindsAllowDenyAndJump() {
        let plan = Self.plan(surface: "a", [Self.session(id: "a", phase: .waitingForApproval)])
        #expect(plan == PromptHotKeyPlan(sessionID: "a", actions: [.approve, .deny, .jump]))
    }

    @Test
    func nothingIsRegisteredWhileTheIslandIsClosedOrDisabled() {
        let sessions = [Self.session(id: "a", phase: .waitingForApproval)]
        #expect(Self.plan(status: .closed, surface: "a", sessions) == nil)
        #expect(Self.plan(status: .popping, surface: "a", sessions) == nil)
        #expect(Self.plan(enabled: false, surface: "a", sessions) == nil)
    }

    @Test
    func autoOpenedCardHoldsNoShortcutsUntilThePointerIsOnIt() {
        let sessions = [Self.session(id: "a", phase: .waitingForApproval)]
        #expect(Self.plan(pointerOver: false, surface: "a", sessions) == nil)
        #expect(Self.plan(pointerOver: true, surface: "a", sessions) != nil)
    }

    @Test
    func cardActsOnlyOnItsOwnSession() {
        let card = Self.session(id: "card", phase: .completed)
        let pending = Self.session(id: "pending", phase: .waitingForApproval)
        #expect(Self.plan(surface: "card", list: [pending], [card, pending])
            == PromptHotKeyPlan(sessionID: "card", actions: [.jump]))
        #expect(Self.plan(surface: "gone", [pending]) == nil)
    }

    @Test
    func hoverOpenedListTargetsFirstSessionNeedingAttention() {
        let sessions = [
            Self.session(id: "done", phase: .completed),
            Self.session(id: "ask", phase: .waitingForAnswer, questionPrompt: QuestionPrompt(title: "Env?", options: ["Prod", "Staging"])),
        ]
        let plan = Self.plan(sessions)
        #expect(plan == PromptHotKeyPlan(sessionID: "ask", actions: [.selectOption(0), .selectOption(1), .jump]))
    }

    @Test
    func listWithoutPromptsRegistersNothing() {
        #expect(Self.plan([Self.session(id: "done", phase: .completed)]) == nil)
    }

    @Test
    func completionCardBindsOnlyJump() {
        let plan = Self.plan(surface: "done", [Self.session(id: "done", phase: .completed)])
        #expect(plan == PromptHotKeyPlan(sessionID: "done", actions: [.jump]))
        #expect(Self.plan(surface: "done", [Self.session(id: "done", phase: .completed, jumpTarget: nil)]) == nil)
    }

    @Test
    func freeformAndOverflowOptionsGetNoDigit() {
        var options = (1...10).map { QuestionOption(label: "Option \($0)") }
        options[1] = QuestionOption(label: "Other", allowsFreeform: true)
        let prompt = QuestionPrompt(
            title: "Pick",
            questions: [QuestionPromptItem(question: "Pick one", header: "Pick", options: options)]
        )
        #expect(PromptHotKeyPlan.optionIndices(for: prompt) == [0, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test
    func multiSelectAndMultiQuestionPromptsNeedTheCard() {
        let option = QuestionOption(label: "A")
        let multiSelect = QuestionPrompt(
            title: "Pick",
            questions: [QuestionPromptItem(question: "Pick", header: "P", options: [option], multiSelect: true)]
        )
        let twoQuestions = QuestionPrompt(
            title: "Pick",
            questions: [
                QuestionPromptItem(question: "One", header: "1", options: [option]),
                QuestionPromptItem(question: "Two", header: "2", options: [option]),
            ]
        )
        #expect(PromptHotKeyPlan.optionIndices(for: multiSelect).isEmpty)
        #expect(PromptHotKeyPlan.optionIndices(for: twoQuestions).isEmpty)
    }

    @Test
    func selectingAnOptionAnswersItsQuestion() {
        let structured = QuestionPrompt(
            title: "Auth",
            questions: [QuestionPromptItem(
                question: "Which auth?",
                header: "Auth",
                options: [QuestionOption(label: "JWT"), QuestionOption(label: "OAuth")]
            )]
        )
        #expect(PromptHotKeyPlan.answer(selecting: 1, in: structured)
            == QuestionPromptResponse(rawAnswer: "OAuth", answers: ["Which auth?": "OAuth"]))

        let legacy = QuestionPrompt(title: "Env?", options: ["Prod", "Staging"])
        #expect(PromptHotKeyPlan.answer(selecting: 0, in: legacy)
            == QuestionPromptResponse(rawAnswer: "Prod", answers: ["Env?": "Prod"]))
        #expect(PromptHotKeyPlan.answer(selecting: 5, in: legacy) == nil)
        #expect(PromptHotKeyPlan.answer(selecting: 5, in: structured) == nil)
    }

    @Test
    func allowAndDenyMapToTheirPermissionDecision() {
        let approval = Self.session(id: "a", phase: .waitingForApproval)
        #expect(PromptHotKeyPlan.effect(of: .approve, on: approval) == .permission(allow: true))
        #expect(PromptHotKeyPlan.effect(of: .deny, on: approval) == .permission(allow: false))
        #expect(PromptHotKeyPlan.effect(of: .jump, on: approval) == .jump)
        #expect(PromptHotKeyPlan.effect(of: .selectOption(0), on: approval) == nil)
    }

    @Test
    func resolvedPromptsIgnoreTheirKeys() {
        let done = Self.session(id: "a", phase: .completed)
        #expect(PromptHotKeyPlan.effect(of: .approve, on: done) == nil)
        #expect(PromptHotKeyPlan.effect(of: .deny, on: done) == nil)
        #expect(PromptHotKeyPlan.effect(of: .selectOption(0), on: done) == nil)

        let question = Self.session(
            id: "q",
            phase: .waitingForAnswer,
            questionPrompt: QuestionPrompt(title: "Env?", options: ["Prod", "Staging"])
        )
        #expect(PromptHotKeyPlan.effect(of: .selectOption(1), on: question)
            == .answer(QuestionPromptResponse(rawAnswer: "Staging", answers: ["Env?": "Staging"])))
        #expect(PromptHotKeyPlan.effect(of: .approve, on: question) == nil)
    }

    @Test
    func cardOpenedUnderTheRestingPointerArmsOnlyAfterThePointerReenters() {
        var presence = IslandPointerPresence()
        presence.opened(byNotification: true, pointerInside: true)
        #expect(!presence.isOver)
        presence.moved(inside: true)
        #expect(!presence.isOver)
        presence.moved(inside: false)
        #expect(!presence.isOver)
        presence.moved(inside: true)
        #expect(presence.isOver)
        presence.closed()
        #expect(!presence.isOver)
    }

    @Test
    func userOpenedIslandArmsWhileThePointerIsOnIt() {
        var presence = IslandPointerPresence()
        presence.opened(byNotification: false, pointerInside: true)
        #expect(presence.isOver)
        presence.moved(inside: false)
        #expect(!presence.isOver)

        presence.opened(byNotification: true, pointerInside: false)
        #expect(!presence.isOver)
        presence.moved(inside: true)
        #expect(presence.isOver)
    }
}
