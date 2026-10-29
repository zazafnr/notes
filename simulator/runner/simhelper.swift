// simhelper: kleines Hilfsprogramm auf dem Cloud-Mac, gebaut gegen die Frameworks von AXe
// (FBSimulatorControl). Kann, was die AXe-Befehle nicht anbieten:
//
//   simhelper stream --udid U --src-width W --src-height H [--fps 24] [--scale 0.5] [--quality 0.7]
//       Video-Strom des Simulator-Bildschirms (direkt aus dem Bildspeicher) im Minicap-Format auf
//       stdout: 24-Byte-Kopf, dann je geändertem Bild 4 Byte Länge (little endian) + JPEG.
//
//   simhelper hid --udid U
//       Liest JSON-Zeilen von stdin und antwortet je Zeile mit {"ok":true} oder {"error":"…"}:
//       {"op":"orientation","value":"portrait|portraitUpsideDown|landscapeLeft|landscapeRight"}
//       {"op":"two","dir":"down|up","x1":…,"y1":…,"x2":…,"y2":…}   (zwei Finger, Punkte im Hochformat)
//       {"op":"pinch","x":…,"y":…,"scale":…,"duration":…,"radius":…}
//       {"op":"shake"}

import Foundation
import CoreGraphics
import ImageIO
import FBControlCore
import FBSimulatorControl

@objc final class QuietReporter: NSObject, FBEventReporter {
    var metadata: [String: String] = [:]
    func report(_ subject: FBEventReporterSubject) {}
    func addMetadata(_ metadata: [String: String]) {}
}

struct HelperError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("simhelper: \(message)\n".utf8))
}

@MainActor
func findSimulator(udid: String, logger: FBControlCoreLogger) throws -> FBSimulator {
    try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
    FBControlCoreGlobalConfiguration.defaultLogger = logger
    let configuration = FBSimulatorControlConfiguration(deviceSetPath: nil, logger: logger, reporter: QuietReporter())
    let control = try FBSimulatorControl.withConfiguration(configuration)
    guard let simulator = control.set.allSimulators.first(where: { $0.udid == udid }) else {
        throw HelperError("Simulator \(udid) nicht gefunden")
    }
    return simulator
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

// Nimmt rohe BGRA-Bilder vom Framework entgegen (ohne Hardware-Encoder, den die Cloud-Macs nicht
// haben), kodiert sie selbst als JPEG und schreibt sie im Minicap-Format auf stdout.
final class JPEGFrameWriter: NSObject, FBDataConsumer {
    let width: Int
    let height: Int
    let quality: Double
    private var last: Data?
    private var headerWritten = false
    private var warned = false
    private let out = FileHandle.standardOutput

    init(width: Int, height: Int, quality: Double) {
        self.width = width
        self.height = height
        self.quality = quality
    }

    func consumeData(_ data: Data) {
        if let last, last == data { return } // unverändert: nichts senden
        last = data
        // Zeilenlänge: IOSurface-Puffer runden auf 64 Byte auf
        var bytesPerRow = (width * 4 + 63) / 64 * 64
        if bytesPerRow * height > data.count { bytesPerRow = data.count / height }
        guard bytesPerRow >= width * 4, let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            if !warned { log("Bild passt nicht: \(data.count) Bytes für \(width)×\(height)"); warned = true }
            return
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }

        if !headerWritten {
            var header = [UInt8](repeating: 0, count: 24)
            header[0] = 1
            header[1] = 24
            withUnsafeBytes(of: UInt32(width).littleEndian) { header.replaceSubrange(6..<10, with: $0) }
            withUnsafeBytes(of: UInt32(height).littleEndian) { header.replaceSubrange(10..<14, with: $0) }
            out.write(Data(header))
            headerWritten = true
        }
        var length = UInt32(jpeg.length).littleEndian
        out.write(Data(bytes: &length, count: 4))
        out.write(jpeg as Data)
    }

    func consumeEndOfFile() {}
}

@MainActor
func runStream(_ simulator: FBSimulator) async throws {
    let fps = Int(option("fps") ?? "") ?? 24
    let scale = Double(option("scale") ?? "") ?? 0.5
    let quality = Double(option("quality") ?? "") ?? 0.7
    guard let sourceWidth = Int(option("src-width") ?? ""), let sourceHeight = Int(option("src-height") ?? "") else {
        throw HelperError("--src-width und --src-height fehlen")
    }
    let scaled = scale > 0 && scale < 1
    let width = scaled ? Int((scale * Double(sourceWidth)).rounded(.down)) : sourceWidth
    let height = scaled ? Int((scale * Double(sourceHeight)).rounded(.down)) : sourceHeight
    let configuration = FBVideoStreamConfiguration(
        format: .bgra(),
        framesPerSecond: NSNumber(value: fps),
        rateControl: .quality(NSNumber(value: quality)),
        scaleFactor: scaled ? NSNumber(value: scale) : nil,
        keyFrameRate: nil
    )
    let writer = JPEGFrameWriter(width: width, height: height, quality: quality)
    let stream = try await simulator.createStream(configuration: configuration)
    try await stream.startStreamingAsync(writer)
    log("Stream läuft (\(fps) fps, \(width)×\(height), Qualität \(quality))")

    let flag = StopFlag()
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { flag.stop() }
        source.resume()
        sources.append(source)
    }
    while !flag.isStopped {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    try? await stream.stopStreamingAsync()
    sources.forEach { $0.cancel() }
}

func orientation(_ name: String) throws -> FBSimulatorHIDDeviceOrientation {
    switch name {
    case "portrait": return .portrait
    case "portraitUpsideDown": return .portraitUpsideDown
    case "landscapeLeft": return .landscapeLeft
    case "landscapeRight": return .landscapeRight
    default: throw HelperError("Unbekannte Ausrichtung \(name)")
    }
}

func number(_ dict: [String: Any], _ key: String) throws -> Double {
    if let value = dict[key] as? Double { return value }
    if let value = dict[key] as? Int { return Double(value) }
    throw HelperError("Wert \(key) fehlt")
}

@MainActor
func runHID(_ simulator: FBSimulator, logger: FBControlCoreLogger) async throws {
    let hid = try await simulator.connectToHID()
    log("HID verbunden (\(hid.transportType))")
    print("{\"ready\":true}")
    fflush(stdout)
    for try await line in FileHandle.standardInput.bytes.lines {
        var reply = "{\"ok\":true}"
        do {
            guard let data = line.data(using: .utf8),
                  let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = command["op"] as? String else {
                throw HelperError("Ungültige Anfrage")
            }
            let event: FBSimulatorHIDEvent
            switch op {
            case "orientation":
                event = .deviceOrientation(try orientation(command["value"] as? String ?? ""))
            case "two":
                let direction: FBSimulatorHIDDirection = (command["dir"] as? String) == "up" ? .up : .down
                event = .twoFingerTouch(
                    direction: direction,
                    finger1: CGPoint(x: try number(command, "x1"), y: try number(command, "y1")),
                    finger2: CGPoint(x: try number(command, "x2"), y: try number(command, "y2"))
                )
            case "pinch":
                event = .pinchAt(
                    x: try number(command, "x"),
                    y: try number(command, "y"),
                    scale: try number(command, "scale"),
                    duration: (try? number(command, "duration")) ?? 0.4,
                    radius: (try? number(command, "radius")) ?? 80
                )
            case "shake":
                event = .shake
            case "ping":
                event = .delay(0)
            default:
                throw HelperError("Unbekannter Befehl \(op)")
            }
            try await hid.send(event: event, logger: logger)
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            reply = "{\"error\":\"\(message)\"}"
        }
        print(reply)
        fflush(stdout)
    }
}

@main
struct SimHelper {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_DFL)
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        guard let udid = option("udid"), ["stream", "hid"].contains(mode) else {
            log("Aufruf: simhelper stream|hid --udid <UDID> [--fps N --scale S --quality Q]")
            exit(2)
        }
        let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
        do {
            let simulator = try findSimulator(udid: udid, logger: logger)
            if mode == "stream" {
                try await runStream(simulator)
            } else {
                try await runHID(simulator, logger: logger)
            }
            exit(0)
        } catch {
            log("Fehler: \(error.localizedDescription)")
            exit(1)
        }
    }
}
