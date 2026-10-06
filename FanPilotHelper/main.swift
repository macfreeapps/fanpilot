import Foundation
import FanCore

guard geteuid() == 0 else {
    fputs("FanPilotHelper must run as root. Install it from FanPilot.app.\n", stderr)
    exit(EXIT_FAILURE)
}

let service = RootHelperService()
let listener = NSXPCListener(machServiceName: "com.fanpilot.helper")
listener.delegate = service
listener.resume()
RunLoop.current.run()
