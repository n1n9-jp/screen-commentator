import Foundation
import SwiftUI
import AppKit
import CoreGraphics

@MainActor
final class CommentViewModel: ObservableObject {
    @Published var activeComments: [Comment] = []
    @Published var isRunning = false
    @Published var statusMessage = ""
    @Published var commentCount = 0
    @Published var isScreenRecordingPermissionGranted = ScreenCaptureService.hasScreenRecordingPermission

    // Provider & model selection
    @Published var aiCommentsEnabled: Bool = UserDefaults.standard.object(forKey: "aiCommentsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiCommentsEnabled, forKey: "aiCommentsEnabled") }
    }
    @Published var selectedProvider: CommentProvider = .ollama {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }
    @Published var selectedOllamaModel: OllamaModel = .qwen25vl_3b {
        didSet { UserDefaults.standard.set(selectedOllamaModel.rawValue, forKey: "selectedOllamaModel") }
    }
    @Published var selectedGeminiModel: GeminiModel = .flash25Lite {
        didSet { UserDefaults.standard.set(selectedGeminiModel.rawValue, forKey: "selectedGeminiModel") }
    }
    @Published var geminiApiKey: String = "" {
        didSet { UserDefaults.standard.set(geminiApiKey, forKey: "geminiApiKey") }
    }

    // Pipeline mode
    @Published var pipelineMode: PipelineMode = .basic {
        didSet { UserDefaults.standard.set(pipelineMode.rawValue, forKey: "pipelineMode") }
    }

    // Persona
    @Published var personaEnabled: [Persona: Bool] = [
        .standard: true,
        .meme: true,
        .critic: false,
        .instructor: false,
        .barrage: false,
    ]
    @Published var personaWeights: [Persona: Double] = [
        .standard: 0.6,
        .meme: 0.3,
        .critic: 0.1,
        .instructor: 0.3,
        .barrage: 0.2,
    ]

    // Blacklist
    @Published var blacklistEnabled: Bool = false {
        didSet {
            guard isRunning else { return }
            if blacklistEnabled {
                activeAppMonitor.startMonitoring()
            } else {
                activeAppMonitor.stopMonitoring()
                isBlacklistTriggered = false
            }
        }
    }
    @Published var isBlacklistTriggered: Bool = false
    let activeAppMonitor = ActiveAppMonitor()
    let blacklistManager = BlacklistManager()

    // Generation
    @Published var baseCommentCount: Int = 5

    // Text style
    @Published var fontSize: CGFloat = 40
    @Published var textOpacity: Double = 1.0
    @Published var fontWeightBold: Bool = true
    @Published var scrollDuration: Double = 6.0

    // Remote posting
    @Published var remotePostingEnabled: Bool = UserDefaults.standard.bool(forKey: "remotePostingEnabled") {
        didSet {
            UserDefaults.standard.set(remotePostingEnabled, forKey: "remotePostingEnabled")
            guard isRunning else { return }
            if remotePostingEnabled {
                startRemotePolling()
            } else {
                stopRemotePolling()
            }
        }
    }
    @Published var remoteSupabaseURL: String = UserDefaults.standard.string(forKey: "remoteSupabaseURL") ?? "" {
        didSet { UserDefaults.standard.set(remoteSupabaseURL, forKey: "remoteSupabaseURL") }
    }
    @Published var remoteSupabaseAnonKey: String = UserDefaults.standard.string(forKey: "remoteSupabaseAnonKey") ?? "" {
        didSet { UserDefaults.standard.set(remoteSupabaseAnonKey, forKey: "remoteSupabaseAnonKey") }
    }
    @Published var remoteWebBaseURL: String = UserDefaults.standard.string(forKey: "remoteWebBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(Self.normalizedRemoteWebBaseURL(remoteWebBaseURL), forKey: "remoteWebBaseURL") }
    }
    @Published var remoteRoomCode: String = UserDefaults.standard.string(forKey: "remoteRoomCode") ?? "" {
        didSet { UserDefaults.standard.set(remoteRoomCode, forKey: "remoteRoomCode") }
    }
    @Published var remoteHostAdminToken: String = "" {
        didSet { KeychainStore.set(remoteHostAdminToken, for: "hostAdminToken") }
    }
    @Published var remoteHostToken: String = "" {
        didSet { KeychainStore.set(remoteHostToken, for: "hostToken") }
    }
    @Published var remoteStatusMessage: String = ""
    @Published var isSourceRevealActive: Bool = false

    static let laneHeight: CGFloat = 44
    static let topMargin: CGFloat = 30

    private let captureService = ScreenCaptureService()
    private let ollamaService = OllamaService()
    private let geminiService = GeminiService()
    private let userInputMonitor = UserInputMonitor()
    private let remoteCommentService = RemoteCommentService()
    private let sourceRevealHotkeyMonitor = SourceRevealHotkeyMonitor()
    private let captureInterval: TimeInterval = 4.0
    private let scrollCommentDuration: TimeInterval = 7.0
    private let fixedCommentDuration: TimeInterval = 4.0
    private let maxActiveComments = 30

    var laneCount: Int {
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        return max(1, Int((screenHeight - Self.topMargin) / Self.laneHeight))
    }

    private var scheduledReleases: [(
        text: String,
        style: CommentStyle,
        color: CommentColor,
        speedMultiplier: Double,
        releaseAt: Date,
        source: CommentSource
    )] = []
    private var releaseTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var remotePollTask: Task<Void, Never>?
    private var lastRemoteCommentID: Int64 = 0
    private var lastRemoteEmptyPollStatusAt: Date?

    // State tracking
    private var changeLevel: Double = 0.05
    private var lastMood: String = "general"
    private var lastExcitement: Int = 5
    private var previousThumbnail: [UInt8]?
    private var cachedOCRText: String?
    private var recentCommentTexts: [String] = []
    private var lastUsedLanes: [Int] = []
    private var nextAIGenerationAllowedAt: Date?
    private var generationErrorCount = 0

    init() {
        if let rawProvider = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = CommentProvider(rawValue: rawProvider) {
            self.selectedProvider = provider
        }
        if let rawModel = UserDefaults.standard.string(forKey: "selectedOllamaModel"),
           let model = OllamaModel(rawValue: rawModel) {
            self.selectedOllamaModel = model
        }
        if let rawModel = UserDefaults.standard.string(forKey: "selectedGeminiModel"),
           let model = GeminiModel(rawValue: rawModel) {
            self.selectedGeminiModel = model
        }
        if let rawMode = UserDefaults.standard.string(forKey: "pipelineMode"),
           let mode = PipelineMode(rawValue: rawMode) {
            self.pipelineMode = mode
        }

        self.geminiApiKey = UserDefaults.standard.string(forKey: "geminiApiKey") ?? ""
        self.remoteHostAdminToken = KeychainStore.string(for: "hostAdminToken")
        self.remoteHostToken = KeychainStore.string(for: "hostToken")

        let normalizedWebBaseURL = Self.normalizedRemoteWebBaseURL(remoteWebBaseURL)
        if normalizedWebBaseURL != remoteWebBaseURL {
            remoteWebBaseURL = normalizedWebBaseURL
        }
    }

    var remotePostingURL: String? {
        let baseURL = Self.normalizedRemoteWebBaseURL(remoteWebBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let code = remoteRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !baseURL.isEmpty, !code.isEmpty else { return nil }
        return "\(baseURL)/r/\(code)"
    }

    // MARK: - Public

    func refreshScreenRecordingPermissionStatus() {
        isScreenRecordingPermissionGranted = ScreenCaptureService.hasScreenRecordingPermission
    }

    func requestScreenRecordingPermission() {
        _ = ScreenCaptureService.requestScreenRecordingPermission()
        refreshScreenRecordingPermissionStatus()
        if isScreenRecordingPermissionGranted {
            statusMessage = "Screen Recording permission is active"
        } else {
            statusMessage = "Enable ScreenCommentator in System Settings, then quit and run the app again"
            openScreenRecordingSettings()
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func start() async {
        guard !isRunning else { return }

        guard aiCommentsEnabled || remotePostingEnabled else {
            statusMessage = "Enable AI Comments or Remote Posting before starting"
            return
        }

        if aiCommentsEnabled {
            guard ScreenCaptureService.hasScreenRecordingPermission else {
                isScreenRecordingPermissionGranted = false
                _ = ScreenCaptureService.requestScreenRecordingPermission()
                openScreenRecordingSettings()
                statusMessage = "Screen Recording permission requested. Enable ScreenCommentator in System Settings, quit it, and open it again."
                return
            }
            isScreenRecordingPermissionGranted = true
        }

        isRunning = true
        commentCount = 0

        if aiCommentsEnabled {
            switch selectedProvider {
            case .ollama:
                statusMessage = "Connecting to Ollama..."
                let ready = await ollamaService.ensureRunning()
                guard ready else {
                    statusMessage = "Ollama not found. Install from ollama.com"
                    isRunning = false
                    return
                }
                guard await resolveSelectedOllamaModel() else {
                    isRunning = false
                    return
                }
            case .gemini:
                guard !geminiApiKey.isEmpty else {
                    statusMessage = "Gemini API key is required"
                    isRunning = false
                    return
                }
            }
        }

        statusMessage = aiCommentsEnabled ? "Starting screen capture..." : "Running - AI comments off"
        startReleaseTimer()
        startSourceRevealHotkeyMonitor()

        if aiCommentsEnabled, blacklistEnabled {
            activeAppMonitor.startMonitoring()
        }

        if aiCommentsEnabled {
            userInputMonitor.start()
        }

        if remotePostingEnabled {
            startRemotePolling()
        } else if hasRemotePostingConfiguration {
            remoteStatusMessage = "Remote posting is off. Turn Enable on to fetch web comments."
        }

        guard aiCommentsEnabled else {
            return
        }

        let provider = selectedProvider
        let ollamaModel = selectedOllamaModel
        let geminiModel = selectedGeminiModel
        let apiKey = geminiApiKey
        let pipeline = pipelineMode

        captureTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.captureService.startCapturing(interval: self.captureInterval)
                await MainActor.run { self.statusMessage = "Running - waiting for first capture..." }

                for await image in stream {
                    let isRunning = await self.isRunning
                    guard isRunning else { break }
                    await self.processCapture(
                        image,
                        provider: provider,
                        ollamaModel: ollamaModel,
                        geminiModel: geminiModel,
                        apiKey: apiKey,
                        pipeline: pipeline
                    )
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Capture error: \(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }

    private func resolveSelectedOllamaModel() async -> Bool {
        let installed = await ollamaService.installedModelNames()
        guard !installed.isEmpty else {
            statusMessage = "No Ollama models found. Install a vision model such as qwen2.5vl:32b"
            return false
        }

        if installed.contains(selectedOllamaModel.rawValue) {
            return true
        }

        let preferredFallbacks: [OllamaModel] = [
            .gemma4_e4b,
            .qwen25vl_32b,
            .gemma4_31b,
            .qwen25vl_3b,
            .qwen3_vl_8b,
            .gemma3_4b,
            .gemma3_12b,
        ]

        if let fallback = preferredFallbacks.first(where: { installed.contains($0.rawValue) }) {
            let previous = selectedOllamaModel.rawValue
            selectedOllamaModel = fallback
            statusMessage = "Ollama model \(previous) is not installed. Using \(fallback.rawValue)"
            return true
        }

        statusMessage = "Selected Ollama model is not installed. Install qwen2.5vl:32b or choose an installed vision model."
        return false
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        statusMessage = "Stopped"

        captureTask?.cancel()
        captureTask = nil
        captureService.stopCapturing()

        activeAppMonitor.stopMonitoring()
        isBlacklistTriggered = false

        userInputMonitor.stop()
        sourceRevealHotkeyMonitor.stop()
        isSourceRevealActive = false
        stopRemotePolling()

        releaseTimer?.invalidate()
        releaseTimer = nil

        activeComments.removeAll()
        scheduledReleases.removeAll()
        previousThumbnail = nil
        cachedOCRText = nil
        recentCommentTexts.removeAll()
        lastUsedLanes.removeAll()
        lastMood = "general"
        lastExcitement = 5
        changeLevel = 0.05
        lastRemoteCommentID = 0
        nextAIGenerationAllowedAt = nil
        generationErrorCount = 0
    }

    func addTestComment() {
        let texts = ["test", "8888", "www", "ktkr"]
        let text = texts.randomElement()!
        let comment = Comment(text: text, lane: Int.random(in: 0..<laneCount))
        activeComments.append(comment)
    }

    func createRemoteRoom() async {
        let supabaseURL = remoteSupabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = remoteSupabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = remoteHostAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !supabaseURL.isEmpty, !anonKey.isEmpty, !adminToken.isEmpty else {
            remoteStatusMessage = "Supabase URL, anon key, and host admin token are required"
            return
        }

        remoteStatusMessage = "Creating room..."
        do {
            let room = try await remoteCommentService.createRoom(
                supabaseURL: supabaseURL,
                anonKey: anonKey,
                adminToken: adminToken
            )
            remoteRoomCode = room.roomCode
            remoteHostToken = room.hostToken
            lastRemoteCommentID = 0
            remotePostingEnabled = true
            remoteStatusMessage = "Room \(room.roomCode) created. Remote posting enabled."

            if remotePostingEnabled, isRunning {
                startRemotePolling()
            }
        } catch {
            remoteStatusMessage = "Room creation failed: \(error.localizedDescription)"
        }
    }

    func fetchRemoteCommentsNow() {
        guard isRunning else {
            remoteStatusMessage = "Press Start before fetching web comments"
            return
        }
        Task {
            await pollRemoteComments(reportEmptyResult: true)
        }
    }

    // MARK: - Persona Selection

    func selectPersona() -> Persona {
        let enabled = Persona.allCases.filter { personaEnabled[$0] == true }
        guard !enabled.isEmpty else { return .standard }

        let totalWeight = enabled.reduce(0.0) { $0 + (personaWeights[$1] ?? 0) }
        guard totalWeight > 0 else { return enabled.randomElement()! }

        let roll = Double.random(in: 0..<totalWeight)
        var cumulative = 0.0
        for persona in enabled {
            cumulative += personaWeights[persona] ?? 0
            if roll < cumulative { return persona }
        }
        return enabled.last!
    }

    func enabledPersonasWithWeights() -> [(persona: Persona, weight: Double)] {
        let enabled = Persona.allCases.filter { personaEnabled[$0] == true }
        let totalWeight = enabled.reduce(0.0) { $0 + (personaWeights[$1] ?? 0) }
        guard totalWeight > 0 else { return enabled.map { ($0, 1.0 / Double(enabled.count)) } }
        return enabled.map { ($0, (personaWeights[$0] ?? 0) / totalWeight) }
    }

    // MARK: - Private

    private func processCapture(
        _ image: CGImage,
        provider: CommentProvider,
        ollamaModel: OllamaModel,
        geminiModel: GeminiModel,
        apiKey: String,
        pipeline: PipelineMode
    ) async {
        if let allowedAt = nextAIGenerationAllowedAt {
            let remaining = allowedAt.timeIntervalSinceNow
            if remaining > 0 {
                statusMessage = "Running - waiting \(Int(ceil(remaining)))s before next AI request"
                return
            }
            nextAIGenerationAllowedAt = nil
        }

        let thumbnail = createThumbnail(image)
        let change = computeChangeLevel(current: thumbnail)

        // Blacklist check
        let persona: Persona
        let blacklistTriggered: Bool
        if blacklistEnabled,
           let appInfo = activeAppMonitor.currentApp,
           blacklistManager.matches(app: appInfo) {
            persona = .roast
            blacklistTriggered = true
        } else {
            persona = selectPersona()
            blacklistTriggered = false
        }

        // Build context
        let inputSnapshot = userInputMonitor.snapshot()
        let appInfo = activeAppMonitor.currentApp

        // OCR (for ocrEnhanced mode)
        let ocrText: String
        if pipeline == .ocrEnhanced {
            if change < 0.01, let cached = cachedOCRText {
                ocrText = cached
            } else {
                let texts = await OCRService.recognizeText(from: image)
                ocrText = OCRService.formatForPrompt(texts)
                cachedOCRText = ocrText
            }
        } else {
            ocrText = ""
        }

        let personas: [(persona: Persona, weight: Double)]
        if blacklistTriggered {
            personas = [(.roast, 1.0)]
        } else {
            personas = enabledPersonasWithWeights()
        }

        let context = PromptContext(
            ocrText: ocrText,
            appName: appInfo?.appName,
            appURL: appInfo?.url,
            userActivity: inputSnapshot.promptDescription,
            enabledPersonas: personas,
            recentComments: recentCommentTexts
        )

        // Comment count
        let count: Int
        if pipeline == .smart {
            // Smart mode: use last excitement for count adjustment
            let multiplier = Double(lastExcitement) / 5.0
            let adjusted = max(1, Int(Double(baseCommentCount) * multiplier))
            switch persona {
            case .barrage: count = adjusted * 3
            case .roast: count = max(adjusted, 5)
            default: count = adjusted
            }
        } else {
            let excitement = computeExcitementScore(changeLevel: change, mood: lastMood)
            let baseCount = commentCountForExcitement(excitement)
            switch persona {
            case .barrage: count = baseCount * 3
            case .roast: count = max(baseCount, 5)
            default: count = baseCount
            }
        }

        changeLevel = change
        previousThumbnail = thumbnail
        isBlacklistTriggered = blacklistTriggered

        let modelName: String
        switch provider {
        case .ollama: modelName = ollamaModel.displayName
        case .gemini: modelName = geminiModel.displayName
        }

        statusMessage = "Generating \(count) comments (\(modelName), \(pipeline.displayName))..."

        do {
            let batch: CommentBatch
            let effectivePipeline = blacklistTriggered ? PipelineMode.basic : pipeline
            let imageForLLM: CGImage? = (effectivePipeline == .ocrEnhanced) ? nil : image

            switch provider {
            case .ollama:
                batch = try await ollamaService.generateComments(
                    from: imageForLLM, model: ollamaModel, persona: persona, count: count,
                    context: context, pipelineMode: effectivePipeline
                )
            case .gemini:
                batch = try await geminiService.generateComments(
                    from: imageForLLM, model: geminiModel, apiKey: apiKey, persona: persona,
                    count: count, context: context, pipelineMode: effectivePipeline
                )
            }

            lastMood = batch.mood
            lastExcitement = batch.excitement
            scheduleCommentRelease(batch.comments, persona: persona, mood: batch.mood)
            commentCount += batch.comments.count
            generationErrorCount = 0

            let cooldown = generationCooldownAfterSuccess(for: provider)
            if cooldown > 0 {
                nextAIGenerationAllowedAt = Date().addingTimeInterval(cooldown)
            }

            recentCommentTexts.append(contentsOf: batch.comments)
            if recentCommentTexts.count > 30 {
                recentCommentTexts.removeFirst(recentCommentTexts.count - 30)
            }
            statusMessage = "Running - \(modelName) | \(pipeline.displayName) | mood: \(batch.mood) (\(commentCount) comments)"

            print("[ScreenCommentator] Batch (\(batch.comments.count)): \(batch.comments) mood=\(batch.mood) excitement=\(batch.excitement) persona=\(persona.rawValue) pipeline=\(pipeline.rawValue)")
        } catch is CancellationError {
            print("[ScreenCommentator] Request cancelled")
        } catch {
            generationErrorCount += 1
            let delay = generationRetryDelay(for: error, provider: provider)
            nextAIGenerationAllowedAt = Date().addingTimeInterval(delay)
            let message = generationErrorStatusMessage(for: error)
            print("[ScreenCommentator] Generation failed: \(message)")
            statusMessage = "Running - \(message). Retrying in \(Int(delay))s"
        }
    }

    private func generationCooldownAfterSuccess(for provider: CommentProvider) -> TimeInterval {
        switch provider {
        case .gemini:
            return 15
        case .ollama:
            return 0
        }
    }

    private func generationRetryDelay(for error: Error, provider: CommentProvider) -> TimeInterval {
        if case GeminiError.rateLimited(_, let retryAfter) = error {
            return max(retryAfter ?? 60, 30)
        }

        let base: TimeInterval = provider == .gemini ? 15 : 8
        let multiplier = pow(2.0, Double(min(generationErrorCount - 1, 3)))
        return min(base * multiplier, 120)
    }

    private func generationErrorStatusMessage(for error: Error) -> String {
        let raw = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fallback = raw.isEmpty ? "AI generation failed" : raw
        if fallback.count <= 180 {
            return fallback
        }
        return String(fallback.prefix(177)) + "..."
    }

    // MARK: - Excitement

    private func computeExcitementScore(changeLevel: Double, mood: String) -> Double {
        let moodBonus: Double
        switch mood {
        case "excitement", "surprise": moodBonus = 0.15
        case "funny", "beautiful": moodBonus = 0.08
        case "general", "cute": moodBonus = 0.04
        case "boring": moodBonus = 0.0
        default: moodBonus = 0.04
        }
        return changeLevel * 0.6 + moodBonus * 0.4
    }

    private func commentCountForExcitement(_ score: Double) -> Int {
        let base = baseCommentCount
        let delta: Int
        if score < 0.02 {
            delta = -2
        } else if score < 0.05 {
            delta = -1
        } else if score < 0.10 {
            delta = 0
        } else if score < 0.15 {
            delta = 1
        } else {
            delta = 2
        }
        return max(1, base + delta)
    }

    // MARK: - Scheduled Release

    private func scheduleCommentRelease(
        _ comments: [String],
        persona: Persona,
        mood: String,
        source: CommentSource = .ai
    ) {
        guard !comments.isEmpty else { return }
        let now = Date()
        let instant = persona == .barrage

        let interval = instant ? 0.0 : captureInterval / Double(comments.count + 1)

        for (i, text) in comments.enumerated() {
            let style = assignStyle(persona: persona)
            let color = assignColor(persona: persona, mood: mood, style: style)
            let speed = Double.random(in: 0.6...1.5)

            let delay: Double
            if instant {
                delay = Double.random(in: 0...0.3)
            } else {
                let jitter = Double.random(in: -0.3...0.3) * interval
                delay = interval * Double(i + 1) + jitter
            }
            scheduledReleases.append((
                text: text,
                style: style,
                color: color,
                speedMultiplier: speed,
                releaseAt: now.addingTimeInterval(delay),
                source: source
            ))
        }

        scheduledReleases.sort { $0.releaseAt < $1.releaseAt }
    }

    private func startReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.releaseScheduled()
            }
        }
    }

    private func releaseScheduled() {
        let now = Date()
        activeComments.removeAll {
            let duration = $0.style == .scroll ? scrollCommentDuration : fixedCommentDuration
            return now.timeIntervalSince($0.timestamp) > duration
        }

        while !scheduledReleases.isEmpty,
              activeComments.count < maxActiveComments,
              scheduledReleases.first!.releaseAt <= now {
            let entry = scheduledReleases.removeFirst()
            let comment = Comment(
                text: entry.text,
                lane: assignLane(),
                style: entry.style,
                color: entry.color,
                speedMultiplier: entry.speedMultiplier,
                source: entry.source
            )
            activeComments.append(comment)
        }
    }

    // MARK: - Remote Posting

    private func startRemotePolling() {
        stopRemotePolling()

        let supabaseURL = remoteSupabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = remoteSupabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomCode = remoteRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hostToken = remoteHostToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !supabaseURL.isEmpty, !anonKey.isEmpty, !roomCode.isEmpty, !hostToken.isEmpty else {
            remoteStatusMessage = "Remote posting needs Supabase URL, anon key, room code, and host token"
            return
        }

        remoteStatusMessage = "Remote posting connected to room \(roomCode)"
        lastRemoteEmptyPollStatusAt = nil
        remotePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollRemoteComments(reportEmptyResult: false)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopRemotePolling() {
        remotePollTask?.cancel()
        remotePollTask = nil
    }

    private func pollRemoteComments(reportEmptyResult: Bool) async {
        let supabaseURL = remoteSupabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = remoteSupabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomCode = remoteRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hostToken = remoteHostToken.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let comments = try await remoteCommentService.fetchComments(
                supabaseURL: supabaseURL,
                anonKey: anonKey,
                roomCode: roomCode,
                hostToken: hostToken,
                afterID: lastRemoteCommentID
            )
            if comments.isEmpty {
                updateRemoteEmptyPollStatus(roomCode: roomCode, force: reportEmptyResult)
                return
            }

            lastRemoteCommentID = max(lastRemoteCommentID, comments.map(\.id).max() ?? lastRemoteCommentID)
            enqueueRemoteComments(comments.map(\.content))
            remoteStatusMessage = "Remote posting received \(comments.count) comment(s). Last id: \(lastRemoteCommentID)"
        } catch is CancellationError {
            return
        } catch {
            remoteStatusMessage = "Remote polling error: \(error.localizedDescription)"
        }
    }

    private var hasRemotePostingConfiguration: Bool {
        !remoteSupabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !remoteSupabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !remoteRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !remoteHostToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateRemoteEmptyPollStatus(roomCode: String, force: Bool) {
        let now = Date()
        if force ||
            lastRemoteEmptyPollStatusAt == nil ||
            now.timeIntervalSince(lastRemoteEmptyPollStatusAt!) >= 5 {
            remoteStatusMessage = "Remote polling room \(roomCode): no new comments. Last id: \(lastRemoteCommentID)"
            lastRemoteEmptyPollStatusAt = now
        }
    }

    private func enqueueRemoteComments(_ comments: [String]) {
        let cleaned = comments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        scheduleCommentRelease(cleaned, persona: .standard, mood: lastMood, source: .user)
        commentCount += cleaned.count

        recentCommentTexts.append(contentsOf: cleaned)
        if recentCommentTexts.count > 30 {
            recentCommentTexts.removeFirst(recentCommentTexts.count - 30)
        }
    }

    private func startSourceRevealHotkeyMonitor() {
        sourceRevealHotkeyMonitor.start { [weak self] active in
            Task { @MainActor [weak self] in
                self?.isSourceRevealActive = active
            }
        }
    }

    private func assignLane() -> Int {
        let total = laneCount
        let activeLanes = Set(activeComments.map(\.lane))
        let recentSet = Set(lastUsedLanes.suffix(min(total / 3, 5)))
        let avoid = activeLanes.union(recentSet)
        let available = (0..<total).filter { !avoid.contains($0) }

        let lane: Int
        if let picked = available.randomElement() {
            lane = picked
        } else {
            let fallback = (0..<total).filter { !activeLanes.contains($0) }
            lane = fallback.randomElement() ?? Int.random(in: 0..<total)
        }

        lastUsedLanes.append(lane)
        if lastUsedLanes.count > total {
            lastUsedLanes.removeFirst()
        }
        return lane
    }

    // MARK: - Style / Color Assignment

    private func assignStyle(persona: Persona) -> CommentStyle {
        switch persona {
        case .barrage:
            let r = Double.random(in: 0..<1)
            if r < 0.7 { return .scroll }
            else if r < 0.9 { return .top }
            else { return .bottom }
        case .roast:
            return Bool.random() ? .scroll : .top
        default:
            if lastExcitement >= 7 && Double.random(in: 0..<1) < 0.12 {
                return Bool.random() ? .top : .bottom
            }
            return .scroll
        }
    }

    private func assignColor(persona: Persona, mood: String, style: CommentStyle) -> CommentColor {
        guard style != .scroll else { return .white }
        switch persona {
        case .barrage:
            return CommentColor.allCases.randomElement()!
        case .roast:
            return [CommentColor.red, .orange, .pink].randomElement()!
        default:
            switch mood {
            case "excitement": return [.red, .orange, .yellow].randomElement()!
            case "funny": return [.green, .cyan, .yellow].randomElement()!
            case "beautiful": return [.cyan, .blue, .purple].randomElement()!
            case "cute": return [.pink, .purple].randomElement()!
            default: return .white
            }
        }
    }

    private static func normalizedRemoteWebBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let range = trimmed.range(
            of: #"https?://[^\s]+"#,
            options: .regularExpression
        ) {
            return String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Scene Change Detection

    private func createThumbnail(_ image: CGImage) -> [UInt8] {
        let size = 32
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return pixels
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        return pixels
    }

    private func computeChangeLevel(current: [UInt8]) -> Double {
        guard let previous = previousThumbnail, previous.count == current.count, !current.isEmpty else {
            return 0.05
        }

        var totalDiff: Int = 0
        let pixelCount = current.count / 4

        for i in 0..<pixelCount {
            let base = i * 4
            let dr = abs(Int(current[base]) - Int(previous[base]))
            let dg = abs(Int(current[base + 1]) - Int(previous[base + 1]))
            let db = abs(Int(current[base + 2]) - Int(previous[base + 2]))
            totalDiff += dr + dg + db
        }

        let maxDiff = pixelCount * 3 * 255
        return Double(totalDiff) / Double(maxDiff)
    }
}
