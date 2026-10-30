import AppKit
import AVFoundation
import CoreAudio

/// 用 Core Audio 进程监听（macOS 14.4+）只采会议软件发出的声音，权限是「仅系统录音」。
final class ProcessTap: @unchecked Sendable {
    /// 常见会议软件的 Bundle ID 前缀（含它们的 Helper 子进程）
    static let meetingApps: [(String, String)] = [
        ("com.electron.lark", "Lark"), ("com.bytedance.lark", "Lark"), ("com.bytedance.feishu", "飞书"),
        ("us.zoom.xos", "Zoom"), ("com.tencent.meeting", "腾讯会议"), ("com.microsoft.teams", "Microsoft Teams"),
        ("com.alibaba.DingTalkMac", "钉钉"), ("com.tencent.xinWeChat", "微信"), ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.google.Chrome", "Chrome"), ("com.microsoft.edgemac", "Edge"),
        ("com.apple.Safari", "Safari"), ("company.thebrowser.Browser", "Arc"), ("com.apple.FaceTime", "FaceTime"),
    ]

    struct AudioProcess { var id: AudioObjectID; var pid: pid_t; var bundleID: String; var playing: Bool }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "screener.process-tap")
    private(set) var targetName = ""

    // MARK: 进程列表

    static func audioProcesses() -> [AudioProcess] {
        guard let ids: [AudioObjectID] = try? read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.compactMap { id in
            let pid: pid_t = (try? readScalar(id, kAudioProcessPropertyPID)) ?? -1
            var bundle = (try? readString(id, kAudioProcessPropertyBundleID)) ?? ""
            if bundle.isEmpty { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            let running: UInt32 = (try? readScalar(id, kAudioProcessPropertyIsRunningOutput)) ?? 0
            return bundle.isEmpty ? nil : AudioProcess(id: id, pid: pid, bundleID: bundle, playing: running != 0)
        }
    }

    /// 选要监听的进程：指定了 Bundle ID 就用它；否则在会议软件里优先选正在出声的
    static func pick(preferred: String) -> (name: String, ids: [AudioObjectID])? {
        let ps = audioProcesses()
        if !preferred.isEmpty {
            let hit = ps.filter { $0.bundleID.hasPrefix(preferred) }
            return hit.isEmpty ? nil : (appName(preferred), hit.map(\.id))
        }
        for playingOnly in [true, false] {
            for (prefix, name) in meetingApps {
                let hit = ps.filter { $0.bundleID.hasPrefix(prefix) && (!playingOnly || $0.playing) }
                if !hit.isEmpty { return (name, ps.filter { $0.bundleID.hasPrefix(prefix) }.map(\.id)) }
            }
        }
        return nil
    }

    static func appName(_ bundleID: String) -> String {
        if let n = meetingApps.first(where: { bundleID.hasPrefix($0.0) })?.1 { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: 开始 / 停止

    /// 开始监听；onBuffer 在音频线程上回调
    func start(preferred: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let target = Self.pick(preferred: preferred) else { throw TapError.noTarget }
        targetName = target.name

        let desc = CATapDescription(stereoMixdownOfProcesses: target.ids)
        desc.uuid = UUID()
        desc.name = "面搭子 · 候选人声音"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "创建进程监听")

        let outputUID = try Self.defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ResumeScreenerTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "创建聚合设备")

        var asbd: AudioStreamBasicDescription = try Self.readScalar(tapID, kAudioTapPropertyFormat)
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw TapError.format }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, input, _, _, _ in
            guard let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: input, deallocator: nil),
                  src.frameLength > 0,
                  let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength) else { return }
            dst.frameLength = src.frameLength
            let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
            let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
            for i in 0..<min(s.count, d.count) {
                if let sp = s[i].mData, let dp = d[i].mData { memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize))) }
            }
            onBuffer(dst)
        }, "创建音频回调")
        try check(AudioDeviceStart(aggID, procID), "开始采集")
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    enum TapError: LocalizedError {
        case noTarget, format, os(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .noTarget: return L("没有找到正在运行的会议软件")
            case .format: return L("无法识别会议软件的音频格式")
            case .os(let step, let st): return "\(L(step))（\(st)）"
            }
        }
    }

    private func check(_ st: OSStatus, _ step: String) throws {
        if st != noErr { stop(); throw TapError.os(step, st) }
    }

    // MARK: Core Audio 属性读取

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func readScalar<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> T {
        var addr = address(sel)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p)
        guard st == noErr else { throw TapError.os("读取音频属性", st) }
        return p.pointee
    }

    static func read<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> [T] {
        var addr = address(sel)
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size)
        guard st == noErr else { throw TapError.os("读取音频属性", st) }
        var arr = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { _, n in n = Int(size) / MemoryLayout<T>.stride }
        st = arr.withUnsafeMutableBytes { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0.baseAddress!) }
        guard st == noErr else { throw TapError.os("读取音频属性", st) }
        return arr
    }

    static func readString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> String {
        let s: CFString = try readScalar(obj, sel)
        return s as String
    }

    static func defaultOutputUID() throws -> String {
        let dev: AudioObjectID = try readScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
        return try readString(dev, kAudioDevicePropertyDeviceUID)
    }
}
