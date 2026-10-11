import Foundation

#if os(macOS)
import Darwin

let configuration: OmniXPCConfiguration
do {
    configuration = try OmniXPCConfiguration(bundle: .main)
    guard Bundle.main.bundleIdentifier == configuration.serviceIdentifier else {
        throw OmniXPCFailure.error(.configuration, "The XPC service bundle identifier is incompatible.")
    }
} catch {
    NSLog("Omni XPC service signing configuration is invalid.")
    exit(EXIT_FAILURE)
}
let delegate = OmniInferenceListenerDelegate(configuration: configuration)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
#endif
