import Foundation
import MotasCore
import MotasUI

// `motas proxy …`, `help` and `version` run as a command; anything else launches
// the app from Motas.app, and prints help elsewhere (the Homebrew `motas` symlink).
if let code = MotasCLI.run(CommandLine.arguments, env: .live) { exit(code) }
MotasApp.main()
