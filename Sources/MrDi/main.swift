import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // без иконки в доке: приложение живёт в меню-баре
    objc_setAssociatedObject(app, "mrdi.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
