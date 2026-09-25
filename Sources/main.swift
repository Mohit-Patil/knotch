import AppKit

let application = NSApplication.shared
let coordinator = AppCoordinator()
application.delegate = coordinator
application.run()
