import Darwin
import Foundation
import JavaScriptCore

// sandbox.h is deprecated but remains the fail-closed OS boundary on the supported deployment target.
@_silgen_name("sandbox_init") private func sandbox_init(
    _ profile: UnsafePointer<CChar>, _ flags: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
@_silgen_name("sandbox_free_error") private func sandbox_free_error(
    _ error: UnsafeMutablePointer<CChar>?)

private let inputLimit = 262_144
private let sourceLimit = 131_072
private let outputLimit = 1_048_576
private let memoryLimit: UInt64 = 134_217_728
private let profile =
    "(version 1) (deny default) (allow sysctl-read) (allow file-read* (subpath \"/System/Library/Frameworks\") (subpath \"/System/Library/PrivateFrameworks\") (subpath \"/usr/lib\") (subpath \"/usr/share/icu\"))"

private func fail(_ code: Int32, _ message: String) -> Never {
    let bytes = Data((String(message.prefix(1024)) + "\n").utf8)
    bytes.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
    _exit(code)
}
private func installSandbox() {
    var error: UnsafeMutablePointer<CChar>?
    guard sandbox_init(profile, 0, &error) == 0 else {
        let message = error.map { String(cString: $0) } ?? "unknown"
        sandbox_free_error(error)
        fail(5, "sandbox initialization failed: \(message)")
    }
}
private func watchdog(deadline: UInt64) -> Never {
    while true {
        if DispatchTime.now().uptimeNanoseconds >= deadline { fail(6, "wall-clock limit") }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { fail(5, "memory accounting unavailable") }
        if info.phys_footprint > memoryLimit { fail(4, "physical-memory limit") }
        usleep(5_000)
    }
}
private func readInput() -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while data.count <= inputLimit {
        let count = read(STDIN_FILENO, &buffer, min(buffer.count, inputLimit + 1 - data.count))
        if count == 0 { return data }
        if count < 0 {
            if errno == EINTR { continue }
            fail(2, "stdin read failed")
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    fail(2, "input exceeds 256 KiB")
}
private func jsString(_ text: String) -> JSStringRef {
    // UTF-16 construction preserves embedded NUL instead of silently truncating author source.
    let units = Array(text.utf16)
    return units.withUnsafeBufferPointer { JSStringCreateWithCharacters($0.baseAddress, $0.count)! }
}
private func property(
    _ context: JSContextRef, _ object: JSObjectRef, _ name: String, _ exception: inout JSValueRef?
) -> JSValueRef? {
    let key = jsString(name)
    defer { JSStringRelease(key) }
    return JSObjectGetProperty(context, object, key, &exception)
}
private func reportException(_ context: JSContextRef, _ exception: JSValueRef?) -> Never {
    guard let exception else { fail(3, "layout.js: JavaScript execution failed") }
    var secondary: JSValueRef?
    guard let text = JSValueToStringCopy(context, exception, &secondary), secondary == nil else {
        fail(3, "layout.js: exception could not be formatted")
    }
    defer { JSStringRelease(text) }
    var buffer = [CChar](repeating: 0, count: 2048)
    _ = JSStringGetUTF8CString(text, &buffer, buffer.count)
    var location = "layout.js"
    if JSValueIsObject(context, exception), let object = JSValueToObject(context, exception, nil),
        let line = property(context, object, "line", &secondary), secondary == nil,
        JSValueIsNumber(context, line)
    {
        let number = JSValueToNumber(context, line, nil)
        if number.isFinite && number >= 0 && number < 1_000_000 { location += ":\(Int(number))" }
    }
    let message = String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    fail(3, "\(location): \(message)")
}
private func mainJS(source: String, configuration: [String: Any]) -> Data {
    guard let context = JSGlobalContextCreate(nil) else {
        fail(3, "JavaScriptCore initialization failed")
    }
    defer { JSGlobalContextRelease(context) }
    let script = jsString(source)
    let url = jsString("layout.js")
    defer {
        JSStringRelease(script)
        JSStringRelease(url)
    }
    var exception: JSValueRef?
    _ = JSEvaluateScript(context, script, nil, url, 1, &exception)
    if exception != nil { reportException(context, exception) }
    // Resolve the binding separately: supports function declarations and top-level const/let.
    let lookup = jsString("buildLayout")
    defer { JSStringRelease(lookup) }
    guard let functionValue = JSEvaluateScript(context, lookup, nil, url, 1, &exception),
        exception == nil,
        JSValueIsObject(context, functionValue),
        let function = JSValueToObject(context, functionValue, &exception),
        JSObjectIsFunction(context, function)
    else {
        if exception != nil { reportException(context, exception) }
        fail(3, "layout.js: buildLayout(context) function required")
    }
    guard let input = try? JSONSerialization.data(withJSONObject: configuration),
        let inputText = String(data: input, encoding: .utf8)
    else { fail(2, "invalid context") }
    let inputString = jsString(inputText)
    defer { JSStringRelease(inputString) }
    guard let argument = JSValueMakeFromJSONString(context, inputString) else {
        fail(2, "invalid context JSON")
    }
    var arguments: [JSValueRef?] = [argument]
    guard let result = JSObjectCallAsFunction(context, function, nil, 1, &arguments, &exception),
        exception == nil
    else {
        reportException(context, exception)
    }
    guard let output = JSValueCreateJSONString(context, result, 0, &exception), exception == nil
    else {
        if exception != nil { reportException(context, exception) }
        fail(3, "layout.js: buildLayout must return a JSON-serializable value")
    }
    defer { JSStringRelease(output) }
    // UTF-8 is never shorter than the UTF-16 unit count; cap allocation before conversion.
    guard JSStringGetLength(output) <= outputLimit else { fail(7, "output exceeds 1 MiB") }
    let capacity = JSStringGetMaximumUTF8CStringSize(output)
    var buffer = [CChar](repeating: 0, count: capacity)
    let length = JSStringGetUTF8CString(output, &buffer, capacity)
    guard length > 0, length - 1 <= outputLimit else { fail(7, "output exceeds 1 MiB") }
    return Data(bytes: buffer, count: length - 1)
}

#if LAYOUT_HELPER_PROBES
    @_silgen_name("fork") private func nativeFork() -> pid_t
    @_silgen_name("bootstrap_look_up") private func bootstrapLookup(
        _ port: mach_port_t, _ name: UnsafePointer<CChar>,
        _ result: UnsafeMutablePointer<mach_port_t>
    ) -> kern_return_t
    private func probes() {
        // Positive controls run BEFORE installing the very same production sandbox.
        let file = open("/etc/passwd", O_RDONLY)
        guard file >= 0 else { fail(90, "read control failed") }
        close(file)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { fail(90, "socket control failed") }
        close(socketFD)
        var bootstrap: mach_port_t = 0
        var service: mach_port_t = 0
        guard
            task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS
        else {
            fail(90, "bootstrap control failed")
        }
        guard
            "com.apple.SecurityServer".withCString({ bootstrapLookup(bootstrap, $0, &service) })
                == KERN_SUCCESS
        else {
            fail(90, "securityd positive control failed")
        }
        mach_port_deallocate(mach_task_self_, service)
        installSandbox()
        func denied(_ label: String, _ operation: () -> Int32) {
            errno = 0
            guard operation() == -1 && (errno == EPERM || errno == EACCES) else {
                fail(90, "not an OS denial: \(label), errno=\(errno)")
            }
            print("denied: \(label)")
        }
        denied("file-read") { open("/etc/passwd", O_RDONLY) }
        denied("file-write") {
            open("/tmp/layout-script-probe-\(getpid())", O_CREAT | O_EXCL | O_WRONLY, 0600)
        }
        denied("network") {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { return -1 }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        denied("fork") {
            let pid = nativeFork()
            if pid == 0 { _exit(90) }
            return pid
        }
        denied("exec") {
            let executable = strdup("/usr/bin/true")!
            defer { free(executable) }
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
            return execv(executable, &arguments)
        }
        let status = "com.apple.SecurityServer".withCString {
            bootstrapLookup(bootstrap, $0, &service)
        }
        guard status == 1100 else {
            fail(90, "securityd lookup not BOOTSTRAP_NOT_PRIVILEGED: \(status)")
        }
        print("denied: keychain-mach")
    }
#endif

func main() {
    for descriptor in 3..<getdtablesize() { close(descriptor) }
    setenv("JSC_useJIT", "false", 1)
    var core = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &core) == 0 else { fail(5, "cannot disable core dumps") }
    #if LAYOUT_HELPER_PROBES
        probes()
    #else
        installSandbox()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        DispatchQueue.global(qos: .userInitiated).async { watchdog(deadline: deadline) }
        let raw = readInput()
        guard let request = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            Set(request.keys) == ["source", "context"], let source = request["source"] as? String,
            let context = request["context"] as? [String: Any]
        else { fail(2, "expected {source:string,context:object}") }
        guard source.utf8.count <= sourceLimit else { fail(2, "source exceeds 128 KiB") }
        let output = mainJS(source: source, configuration: context)
        FileHandle.standardOutput.write(output)
    #endif
}
main()
