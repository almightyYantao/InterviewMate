import Foundation

// 与 Python 端 schemas.py 对应；JSON 用 snake_case，解码时自动转换。

struct Requirement: Codable, Hashable, Identifiable {
    var id: String
    var category: String
    var text: String
    var level: String
    var weight: Int
    var emphasized: Bool
}

struct JDStruct: Codable, Hashable {
    var position: String?
    var location: String?
    var requirements: [Requirement]?
    var error: String?
}

struct Position: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var jdRaw: String
    var jdStruct: JDStruct?
    var companyCtx: String?
    var interviewMinutes: Int?
}

struct Candidate: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var status: String
    var error: String?
    var progress: String?
    var createdAt: String?
    var score: Double?
    var decision: String?
    var high: Int?
    var interviewed: Bool?
    var interviewDecision: String?
    var interviewedAt: String?

    var scoreSort: Double { score ?? -1 }
    var highSort: Int { high ?? -1 }
    var nameSort: String { name ?? "" }
    var decisionSort: String { decision ?? "" }
}

struct Evidence: Codable, Hashable {
    var line: Int
    var quote: String
}

struct Flag: Codable, Hashable {
    var code: String
    var severity: String
    var message: String
}

struct MatchItem: Codable, Hashable, Identifiable {
    var reqId: String
    var verdict: String
    var evidence: [Evidence]
    var reason: String
    var interviewFocus: Bool
    var id: String { reqId }
}

struct Doubt: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var severity: String
    var title: String
    var evidence: [Evidence]
    var verifyQuestion: String
    var source: String
}

struct QSource: Codable, Hashable {
    var type: String
    var lines: [Int]
    var quote: String
}

struct Rubric: Codable, Hashable {
    var excellent: String
    var pass: String
    var fail: String
}

struct Question: Codable, Hashable, Identifiable {
    var id: String
    var section: String
    var minutes: Int
    var question: String
    var source: QSource
    var linkedRequirements: [String]
    var linkedDoubts: [String]
    var answerPoints: [String]
    var keyPoints: [String]
    var followUps: [String]
    var redFlags: [String]
    var rubric: Rubric
}

struct Conclusion: Codable, Hashable {
    var summary: String
    var mustVerify: [String]
    var passSignals: [String]
    var failSignals: [String]
    var decision: String
    var score: Double
    var veto: [String]
}


struct Report: Codable, Hashable {
    var position: String
    var candidate: String
    var interviewMinutes: Int
    var jd: JDStruct
    var resume: ResumeStruct?
    var round: Int?
    var carryOver: [String]?
    var flags: [Flag]
    var match: [MatchItem]
    var doubts: [Doubt]
    var questions: [Question]
    var conclusion: Conclusion
    var validation: [String]
}

struct ScoreRow: Codable, Hashable {
    var questionId: String
    var score: String?
    var note: String?
}

struct EvaluationRow: Codable, Hashable {
    var round: Int?
    var decision: String
    var comment: String
}

struct ReportResponse: Codable {
    var id: String
    var version: Int
    var report: Report
    var resumeLines: [String]
    var scores: [ScoreRow]
    var evaluations: [EvaluationRow]
    var summary: InterviewSummary?
    var transcript: [Utterance]?
    var interviewedAt: String?
    var overallNote: String?
}

// MARK: - 显示用

enum Labels {
    static let decision = ["advance": "推进", "conditional": "有条件推进", "reject": "不推荐"].mapValues(L)
    static let severity = ["high": "高", "medium": "中", "low": "低"].mapValues(L)
    static let level = ["must": "必须", "plus": "加分", "duty": "职责"].mapValues(L)
    static let verdict = ["match": "具备", "partial": "部分", "missing": "缺失", "unknown": "无法判断"].mapValues(L)
    static let verdictSymbol = ["match": "checkmark.circle.fill", "partial": "exclamationmark.triangle.fill",
                                "missing": "xmark.circle.fill", "unknown": "questionmark.circle.fill"]
    static let score = ["excellent": "优秀", "pass": "合格", "fail": "不合格", "skip": "跳过"].mapValues(L)
    static let sections = ["背景核实", "项目深挖", "核心能力", "缺口场景", "软性要求"]
    static let sectionSymbol = ["背景核实": "person.text.rectangle", "项目深挖": "hammer",
                                "核心能力": "cpu", "缺口场景": "map", "软性要求": "bubble.left.and.bubble.right"]
}

struct QuestionReview: Codable, Hashable {
    var questionId: String
    var covered: [String]
    var missed: [String]
    var redFlagsHit: [String]
    var suggestedScore: String
    var evidence: String
}

struct DoubtCheck: Codable, Hashable {
    var doubt: String
    var result: String
    var note: String
}

struct InterviewSummary: Codable, Hashable {
    var decision: String
    var comment: String
    var highlights: [String]
    var concerns: [String]
    var doubts: [DoubtCheck]
    var questions: [QuestionReview]
}

struct Weights: Codable, Equatable { var must: Int; var plus: Int; var duty: Int; var emphasis: Int }

struct ScoringRules: Codable, Equatable {
    var match: Double; var partial: Double; var missing: Double; var unknown: Double
    var vetoWeight: Int; var advance: Double; var reject: Double; var maxHighDoubts: Int
}

struct AppSettings: Codable, Equatable {
    var apiKeyHint: String = ""
    var baseUrl: String = ""
    var modelFast: String = ""
    var modelStrong: String = ""
    var defaultFast: String = ""
    var defaultStrong: String = ""
    var aiLanguage: String = "zh"
    var speechLocale: String = "zh-CN"
    var captureApp: String = ""
    var silenceSeconds: Double = 1.5
    var companyCtx: String = ""
    var interviewMinutes: Int = 60
    var weights = Weights(must: 3, plus: 1, duty: 2, emphasis: 2)
    var scoring = ScoringRules(match: 1, partial: 0.5, missing: 0, unknown: 0.3, vetoWeight: 5, advance: 7.5, reject: 5, maxHighDoubts: 1)
    var retentionDays: Int = 180
    var hibobUserId: String = ""
    var hibobTokenHint: String = ""
    var hibobSandbox: Bool = false
    var hibobEmail: String = ""
    var hibobEmployeeId: String = ""
    var calendarUrlHint: String = ""
    var larkWebhookHint: String = ""
    var remindMinutes: Int = 15
}

struct CalEvent: Codable, Identifiable, Hashable {
    var uid: String; var title: String; var start: String; var end: String; var meetingUrl: String
    var meetingApp: String? = nil; var meetingCode: String? = nil
    var meetings: [Meeting]? = nil
    var candidateId: String?; var candidateName: String?; var positionId: String?
    var id: String { uid + start }
    var startDate: Date? { ISO8601DateFormatter().date(from: start) }
    var endDate: Date? { ISO8601DateFormatter().date(from: end) }
}

/// PUT /settings 的请求体：apiKey 为 nil 时不改
struct AppSettingsIn: Encodable {
    var apiKey: String?
    var baseUrl, modelFast, modelStrong, aiLanguage, speechLocale, captureApp, companyCtx: String
    var silenceSeconds: Double
    var interviewMinutes, retentionDays: Int
    var weights: Weights
    var scoring: ScoringRules
    var hibobUserId, hibobEmail, hibobEmployeeId: String
    var hibobToken: String?
    var hibobSandbox: Bool
    var calendarIcsUrl: String?
    var larkWebhook: String?
    var larkSecret: String?
    var remindMinutes: Int

    init(_ s: AppSettings, apiKey: String?, hibobToken: String? = nil) {
        hibobUserId = s.hibobUserId; hibobEmail = s.hibobEmail; hibobEmployeeId = s.hibobEmployeeId
        self.hibobToken = hibobToken; hibobSandbox = s.hibobSandbox
        calendarIcsUrl = nil; remindMinutes = s.remindMinutes
        self.apiKey = apiKey
        baseUrl = s.baseUrl; modelFast = s.modelFast; modelStrong = s.modelStrong
        aiLanguage = s.aiLanguage; speechLocale = s.speechLocale; captureApp = s.captureApp; companyCtx = s.companyCtx
        silenceSeconds = s.silenceSeconds; interviewMinutes = s.interviewMinutes; retentionDays = s.retentionDays
        weights = s.weights; scoring = s.scoring
    }
}

struct ClaimedYears: Codable, Hashable { var value: Double; var evidenceLine: Int }
struct ResumeBasic: Codable, Hashable {
    var name: String
    var birth: String?
    var claimedYears: [ClaimedYears]
    var phone: [String]
    var email: [String]
}
struct Education: Codable, Hashable { var school: String; var degree: String; var major: String; var start: String?; var end: String?; var line: Int }
struct Duty: Codable, Hashable { var text: String; var line: Int }
struct Job: Codable, Hashable { var company: String; var title: String; var start: String; var end: String?; var duties: [Duty]; var line: Int }
struct Project: Codable, Hashable { var name: String; var company: String?; var claimedRole: String; var details: [String]; var lines: [Int] }
struct ResumeStruct: Codable, Hashable {
    var basic: ResumeBasic
    var education: [Education]
    var jobs: [Job]
    var projects: [Project]
    var skills: [String]
    var certs: [String]
}
struct PageSize: Codable, Hashable { var width: Double; var height: Double }

struct HiBobOpening: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var status: String
    var department: String
    var jd: String
    var positionId: String?
}

struct HiBobInterview: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var status: String
    var startAt: String?
    var endAt: String?
    var jobOpeningId: String
    var candidateName: String
    var candidateEmail: String
    var jobTitle: String?
    var hasEvaluation: Bool
    var meetingUrl: String?
    var positionId: String?
    var candidateId: String?

    var start: Date? { startAt.flatMap { ISO8601DateFormatter().date(from: $0) ?? HiBobInterview.frac.date(from: $0) } }
    static let frac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}

struct BobApplicant: Codable, Identifiable, Hashable {
    var id: String; var name: String; var stage: String; var source: String; var applied: String; var url: String
    var status: String?; var statusLabel: String?
    var candidateId: String?
    var localDecision: String?      // 我在 App 里给的面试结论
    var active: Bool { (status ?? "in_progress") == "in_progress" }
}
struct BobOpening: Codable, Identifiable, Hashable {
    var id: String; var title: String; var department: String; var positionId: String?
    var applicants: [BobApplicant]
}

struct Meeting: Codable, Hashable { var app: String; var url: String; var code: String }

struct LiveHint: Codable, Hashable { var covered: [String]; var missing: [String]; var followUp: String; var flags: [String] }

struct CmpReq: Codable, Hashable { var id: String; var text: String; var level: String; var weight: Int }
struct CmpCandidate: Codable, Hashable, Identifiable {
    var id: String; var name: String; var score: Double; var decision: String; var summary: String; var highDoubts: Int
    var verdicts: [String: String]; var interviewDecision: String?; var interviewComment: String
    var scoreCounts: [String: Int]; var highlights: [String]; var concerns: [String]; var note: String
}
struct CmpPer: Codable, Hashable { var name: String; var strengths: [String]; var risks: [String] }
struct CmpAI: Codable, Hashable { var recommendation: String; var ranking: [String]; var perCandidate: [CmpPer] }
struct CompareData: Codable { var position: String; var requirements: [CmpReq]; var candidates: [CmpCandidate]; var ai: CmpAI? }

struct InsightSection: Codable, Hashable { var section: String; var asked: Int; var skipped: Int; var total: Int }
struct Insights: Codable {
    var interviewed: Int; var decisions: [String: Int]; var scoreDist: [String: Int]; var agree: [String: Int]
    var looserExamples: [String]; var stricterExamples: [String]; var sections: [InsightSection]
    var missedBySection: [String: Int]; var avgMinutes: Double?; var tips: [String]
}
