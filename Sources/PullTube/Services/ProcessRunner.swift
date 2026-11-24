import Foundation

/// Runs a subprocess, streaming output line by line and collecting the rest.
final class ProcessRunner: @unchecked Sendable {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
        let wasTerminated: Bool
    }

    private let process = Process()
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var lineBuffer = Data()
    private var terminatedByUser = false

    func terminate() {
        lock.lock(); terminatedByUser = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// - Parameters:
    ///   - collectStdout: keep all stdout bytes (for JSON output).
    ///   - onLine: called on a background queue for each line of stdout and stderr.
    func run(
        executable: URL,
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        collectStdout: Bool = false,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        process.executableURL = executable
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extraPath + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env.merge(extraEnvironment) { _, new in new }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.handleStdout(d, collect: collectStdout, onLine: onLine)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.handleStderr(d, onLine: onLine)
        }

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { [self] p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !restOut.isEmpty { handleStdout(restOut, collect: collectStdout, onLine: onLine) }
                if !restErr.isEmpty { handleStderr(restErr, onLine: onLine) }

                lock.lock()
                let result = Output(
                    status: p.terminationStatus,
                    stdout: outData,
                    stderr: String(decoding: errData, as: UTF8.self),
                    wasTerminated: terminatedByUser
                )
                lock.unlock()
                cont.resume(returning: result)
            }
            // Cancelled before the process even started (e.g. while preparing arguments).
            lock.lock(); let cancelledEarly = terminatedByUser; lock.unlock()
            if cancelledEarly {
                cont.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func handleStdout(_ d: Data, collect: Bool, onLine: (@Sendable (String) -> Void)?) {
        lock.lock()
        if collect { outData.append(d) }
        var lines: [String] = []
        if onLine != nil {
            lineBuffer.append(d)
            while let nl = lineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    private func handleStderr(_ d: Data, onLine: (@Sendable (String) -> Void)?) {
        lock.lock()
        errData.append(d)
        lock.unlock()
        guard let onLine else { return }
        String(decoding: d, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .forEach { onLine(String($0)) }
    }
}
