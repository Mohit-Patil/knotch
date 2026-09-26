import Foundation

@main
struct FocusToolsTests {
    @MainActor
    static func main() {
        let suite = "dev.personal.Knotch.FocusToolsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Could not create test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = FocusToolsStore(defaults: defaults)
        let noteID = store.addNote()
        store.updateNote(noteID, text: "Meeting notes\nFollow up Tuesday")
        store.addTodo("  Send proposal  ")
        assert(store.todos.first?.title == "Send proposal")
        if let todoID = store.todos.first?.id { store.toggleTodo(todoID) }

        store.setTimerMode(.focus)
        store.startPauseTimer()
        let reloaded = FocusToolsStore(defaults: defaults)
        assert(reloaded.notes.first?.text == "Meeting notes\nFollow up Tuesday")
        assert(reloaded.todos.first?.isDone == true)
        assert(reloaded.timerIsRunning)
        let completionDate = Date().addingTimeInterval(25 * 60 + 1)
        assert(reloaded.timerRemaining(at: completionDate) == 0)
        reloaded.reconcileTimer(at: completionDate)
        reloaded.reconcileTimer(at: completionDate)
        assert(reloaded.completedFocusSessions == 1)
        reloaded.setTimerMode(.custom)
        reloaded.setCustomMinutes(2)
        assert(reloaded.timerRemaining() == 120)
        reloaded.startPauseTimer()
        assert(reloaded.timerIsRunning)
        reloaded.startPauseTimer()
        assert(!reloaded.timerIsRunning && reloaded.timerRemaining() > 0)
        reloaded.resetTimer()
        assert(reloaded.timerRemaining() == 120)

        reloaded.teleprompterText = "A short script"
        reloaded.playTeleprompter()
        let currentOffset = reloaded.teleprompterOffset()
        assert(reloaded.teleprompterOffset(at: Date().addingTimeInterval(2)) > currentOffset)
        reloaded.pauseTeleprompter()
        assert(!reloaded.teleprompterPlaying)
        reloaded.resetTeleprompter()
        assert(reloaded.teleprompterOffset() == 0)

        store.stop()
        reloaded.stop()
        print("Focus tools tests passed")
    }
}
