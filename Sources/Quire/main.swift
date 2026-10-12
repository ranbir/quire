import AppKit

// ssh runs this executable as SSH_ASKPASS to ask for passwords.
if Askpass.isRequested { Askpass.run() }

// quire --export html|pdf file.md: export without opening a window.
if CommandLine.arguments.contains("--export") { CLIExport.run(Array(CommandLine.arguments.dropFirst())) }

setvbuf(stdout, nil, _IOLBF, 0)   // log lines appear immediately when redirected
let app = NSApplication.shared
// The first NSDocumentController instantiated becomes the shared one.
_ = DocumentController()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
