import AppKit

// ssh runs this executable as SSH_ASKPASS to ask for passwords.
if Askpass.isRequested { Askpass.run() }

let app = NSApplication.shared
// The first NSDocumentController instantiated becomes the shared one.
_ = DocumentController()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
