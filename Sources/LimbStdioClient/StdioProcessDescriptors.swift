#if os(macOS)
import Darwin
import Foundation

final class StdioDescriptor {
    private(set) var value: Int32

    init(_ value: Int32) { self.value = value }

    func close() {
        if value >= 0 {
            _ = Darwin.close(value)
            value = -1
        }
    }

    func prepareForParent() throws(StdioProcessError) {
        // File actions must still work when the caller started with a standard fd closed.
        if value <= STDERR_FILENO {
            let duplicate = fcntl(value, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate >= 0 else { throw .systemCall("fcntl(F_DUPFD_CLOEXEC)", errno) }
            close()
            value = duplicate
        } else if fcntl(value, F_SETFD, FD_CLOEXEC) < 0 {
            throw .systemCall("fcntl(F_SETFD)", errno)
        }
    }

    func makeNonblocking() throws(StdioProcessError) {
        let flags = fcntl(value, F_GETFL)
        guard flags >= 0, fcntl(value, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw .systemCall("fcntl(O_NONBLOCK)", errno)
        }
    }

    deinit { close() }
}

struct StdioPipe {
    let read: StdioDescriptor
    let write: StdioDescriptor

    init() throws(StdioProcessError) {
        var values: [Int32] = [-1, -1]
        guard pipe(&values) == 0 else { throw .systemCall("pipe", errno) }
        read = StdioDescriptor(values[0])
        write = StdioDescriptor(values[1])
        try read.prepareForParent()
        try write.prepareForParent()
    }
}

struct StdioChild {
    let pid: Int32
    let input: StdioDescriptor
    let output: StdioDescriptor
    let error: StdioDescriptor

    static func spawn(_ configuration: StdioProcessConfiguration) throws(StdioProcessError) -> Self {
        let input = try StdioPipe()
        let output = try StdioPipe()
        let error = try StdioPipe()
        try input.write.makeNonblocking()
        try output.read.makeNonblocking()
        try error.read.makeNonblocking()
        guard fcntl(input.write.value, F_SETNOSIGPIPE, 1) == 0 else {
            throw .systemCall("fcntl(F_SETNOSIGPIPE)", errno)
        }

        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, destination) in [(input.read, STDIN_FILENO), (output.write, STDOUT_FILENO), (error.write, STDERR_FILENO)] {
            try checkPOSIX(
                posix_spawn_file_actions_adddup2(&actions, source.value, destination),
                "posix_spawn_file_actions_adddup2")
        }
        if let directory = configuration.workingDirectory {
            try checkPOSIX(posix_spawn_file_actions_addchdir(&actions, directory), "posix_spawn_file_actions_addchdir")
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        sigaddset(&defaults, SIGTERM)
        try checkPOSIX(posix_spawnattr_setsigdefault(&attributes, &defaults), "posix_spawnattr_setsigdefault")
        var mask = sigset_t()
        sigemptyset(&mask)
        try checkPOSIX(posix_spawnattr_setsigmask(&attributes, &mask), "posix_spawnattr_setsigmask")
        // A new session gives the leader its own process group and no controlling terminal.
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try checkPOSIX(posix_spawnattr_setflags(&attributes, Int16(bitPattern: UInt16(flags))), "posix_spawnattr_setflags")

        let arguments = try StdioCStringArray([configuration.executable] + configuration.arguments)
        let environment = try StdioCStringArray(
            (configuration.environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" })
        var pid: Int32 = 0
        let result = withExtendedLifetime((arguments, environment)) {
            posix_spawn(&pid, configuration.executable, &actions, &attributes, arguments.pointers, environment.pointers)
        }
        try checkPOSIX(result, "posix_spawn")
        input.read.close()
        output.write.close()
        error.write.close()
        return Self(pid: pid, input: input.write, output: output.read, error: error.read)
    }
}

private final class StdioCStringArray {
    private(set) var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ strings: [String]) throws(StdioProcessError) {
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                for pointer in pointers { free(pointer) }
                pointers.removeAll()
                throw .systemCall("strdup", ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }
}

private func checkPOSIX(_ status: Int32, _ operation: String) throws(StdioProcessError) {
    guard status == 0 else { throw .systemCall(operation, status) }
}
#endif
