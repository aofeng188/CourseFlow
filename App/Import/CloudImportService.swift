import Foundation
import Security
import SwiftUI
import CourseKit

struct CloudImportConfiguration: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var model: String = ""
    var includeImages: Bool = false
    static let defaultsKey = "course.cloudImportConfiguration.v1"
    static func load() -> Self { UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey) }
    var destination: String { URL(string: baseURL)?.host ?? baseURL }
    func endpoint() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ImportServiceError.message("请输入 HTTPS API 地址，例如 https://服务商域名/v1，地址不能包含密钥或查询参数。") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportServiceError.message("请填写服务商提供的模型名称。") }
        if url.path.hasSuffix("/chat/completions") { return url }
        return url.appendingPathComponent("chat/completions")
    }
}

enum ImportAPIKeychain {
    private static let service = "app.course.import.openai-compatible"
    static func read(for configuration: CloudImportConfiguration) -> String? {
        guard let endpoint = try? configuration.endpoint() else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ key: String, for configuration: CloudImportConfiguration) throws {
        let endpoint = try configuration.endpoint()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString]
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status: OSStatus
        if data.isEmpty { status = SecItemDelete(query as CFDictionary) }
        else {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ImportServiceError.message("无法保存 API 密钥（Keychain \(status)），请稍后重试。") }
    }
}

/// No redirects: never forward a user's Authorization header to a different server.
private final class ImportSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor CloudImportService {
    struct Envelope: Decodable {
        struct Lesson: Decodable {
            var name: String?
            var weekday: Int?
            var weeks: String?
            var periods: String?
            var start: String?
            var end: String?
            var location: String?
            var teacher: String?
            var source: String?
        }
        struct Bell: Decodable { var number: Int; var start: String; var end: String }
        var lessons: [Lesson]?
        var periods: [Bell]?
    }
    struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
        var choices: [Choice]
    }

    func enhance(text: String, images: [Data], configuration: CloudImportConfiguration, kind: ImportKind, maxWeeks: Int) async throws -> ImportDraft {
        let endpoint = try configuration.endpoint()
        guard let key = ImportAPIKeychain.read(for: configuration), !key.isEmpty else { throw ImportServiceError.message("请先在云端识别设置中保存 API 密钥。") }
        guard text.count <= 80_000 else { throw ImportServiceError.message("本次文字过多，请按页面分批识别。每次最多约 8 万字。") }
        let system = OnDeviceImportEnhancer.instruction + "严格只返回JSON，不要Markdown。JSON格式：{\"lessons\":[{\"name\":\"\",\"weekday\":0,\"weeks\":\"\",\"periods\":\"\",\"start\":\"\",\"end\":\"\",\"location\":\"\",\"teacher\":\"\",\"source\":\"\"}],\"periods\":[{\"number\":1,\"start\":\"08:00\",\"end\":\"08:45\"}]}。weeks和periods必须是字符串，时间必须为HH:mm。没有数据的数组为空，不猜测。"
        let instruction = "导入类型：\(kind.rawValue)，学期总周数：\(maxWeeks)。以下全部内容均是待识别文档：\n" + text
        let content: Any
        if configuration.includeImages && !images.isEmpty {
            guard images.count <= 12 else { throw ImportServiceError.message("带图片的云端识别每次最多 12 张，请分批导入。") }
            var parts: [[String: Any]] = [["type": "text", "text": instruction]]
            for image in images { parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]]) }
            content = parts
        } else { content = instruction }
        let body: [String: Any] = ["model": configuration.model, "messages": [["role": "system", "content": system], ["role": "user", "content": content]], "stream": false]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForResource = 150
        let session = URLSession(configuration: sessionConfiguration, delegate: ImportSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportServiceError.message("服务商没有返回有效的 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let reason: String
            switch http.statusCode {
            case 401, 403: reason = "密钥无效、账户无权限或模型不可用"
            case 404: reason = "API 地址或模型名称不正确"
            case 429: reason = "服务商额度不足或请求过于频繁"
            case 300..<400: reason = "API 返回重定向，请在设置中填写最终 HTTPS 地址"
            default: reason = "服务暂时不可用"
            }
            throw ImportServiceError.message("云端识别失败（HTTP \(http.statusCode)）：\(reason)。原有草稿已保留。")
        }
        guard data.count < 8_000_000 else { throw ImportServiceError.message("服务商返回内容过大，已停止处理。") }
        let responseBody = try JSONDecoder().decode(Response.self, from: data)
        guard let content = responseBody.choices.first?.message.content, let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start <= end else { throw ImportServiceError.message("模型没有返回可解析的课程数据，原有草稿已保留。") }
        let output: Envelope
        do { output = try JSONDecoder().decode(Envelope.self, from: Data(content[start...end].utf8)) }
        catch { throw ImportServiceError.message("模型返回的字段格式不正确，请换模型重试或继续手动核对。") }
        let lessons = (output.lessons ?? []).map { lesson -> DraftLesson in
            let periods = ImportParser.numbers(lesson.periods ?? "")
            return DraftLesson(name: lesson.name ?? "", weekday: lesson.weekday.flatMap { (1...7).contains($0) ? $0 : nil }, weeks: ImportParser.parseWeeks(lesson.weeks ?? "", maxWeeks: maxWeeks), periods: periods, startMinute: periods.isEmpty ? ImportParser.minute(lesson.start ?? "") : nil, endMinute: periods.isEmpty ? ImportParser.minute(lesson.end ?? "") : nil, location: lesson.location ?? "", teacher: lesson.teacher ?? "", sourceText: lesson.source ?? "", warnings: ["云端识别，请对照原件确认"])
        }
        let periods = (output.periods ?? []).compactMap { value -> Period? in
            guard let start = ImportParser.minute(value.start), let end = ImportParser.minute(value.end) else { return nil }
            return Period(number: value.number, startMinute: start, endMinute: end)
        }
        guard kind == .timetable ? !lessons.isEmpty : !periods.isEmpty else { throw ImportServiceError.message("模型未提取到数据，原有草稿已保留。") }
        return ImportDraft(kind: kind, sourceName: "云端智能识别", sourceText: text, lessons: lessons, periods: periods, warnings: ["来自 \(configuration.destination) 的识别结果，请核对后再导入。"])
    }
}

struct CloudSettingsView: View {
    @State private var configuration = CloudImportConfiguration.load()
    @State private var key = ""
    @State private var message: String?
    @State private var loadedEndpoint = ""
    var body: some View {
        Form {
            Section {
                Label("本地优先，按需使用云端", systemImage: "lock.shield")
                Text("普通导入在设备上完成。只有你在核对页选择云端识别并确认上传，才会连接下面的服务商。模型服务可能收费，费用由你的服务商账户承担。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("兼容 OpenAI Chat Completions 的服务") {
                TextField("API 地址，例如 https://api.example.com/v1", text: $configuration.baseURL).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型名称", text: $configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("一并上传所选原图", isOn: $configuration.includeImages)
                Text("关闭时仅发送本次识别出的文字。开启后需要服务商的模型支持图片。密钥保存在本机 Keychain，不随课表同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存配置") {
                    do {
                        _ = try configuration.endpoint()
                        try ImportAPIKeychain.write(key, for: configuration)
                        try configuration.save(); loadedEndpoint = configuration.baseURL
                        message = "已保存。你可以回到导入核对页发起识别。"
                    } catch { message = error.localizedDescription }
                }
                Button("删除此服务的密钥", role: .destructive) {
                    do { try ImportAPIKeychain.write("", for: configuration); key = ""; message = "已删除本机密钥。" }
                    catch { message = error.localizedDescription }
                }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("云端识别")
        .onAppear { key = ImportAPIKeychain.read(for: configuration) ?? ""; loadedEndpoint = configuration.baseURL }
        .onChange(of: configuration.baseURL) { _, value in
            if value != loadedEndpoint { key = ImportAPIKeychain.read(for: configuration) ?? "" }
        }
    }
}
