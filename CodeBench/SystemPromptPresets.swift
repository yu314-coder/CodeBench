import Foundation

struct SystemPromptPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var prompt: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, icon: String, prompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }
}

final class SystemPromptPresetsManager {
    static let shared = SystemPromptPresetsManager()

    private let selectedIdKey = "systemPrompt.selectedPresetId"
    private let customPresetsKey = "systemPrompt.customPresets"
    private let customTextKey = "systemPrompt.customText"

    static let builtInPresets: [SystemPromptPreset] = [
        SystemPromptPreset(name: "Default", icon: "bubble.left.fill", prompt: "You are a helpful assistant.", isBuiltIn: true),
        SystemPromptPreset(name: "Coder", icon: "chevron.left.forwardslash.chevron.right", prompt: "You are an expert software engineer. Write clean, efficient, well-documented code. Explain your reasoning and suggest best practices. When debugging, think step by step.", isBuiltIn: true),
        SystemPromptPreset(name: "Tutor", icon: "graduationcap.fill", prompt: "You are a patient and encouraging tutor. Explain concepts clearly with examples. Ask guiding questions to help the student discover answers. Adapt your explanations to the student's level.", isBuiltIn: true),
        SystemPromptPreset(name: "Writer", icon: "pencil.line", prompt: "You are a skilled creative writer. Help craft compelling narratives, improve prose, and offer constructive feedback. Be creative and expressive while maintaining clarity.", isBuiltIn: true),
        SystemPromptPreset(name: "Translator", icon: "globe", prompt: "You are a professional translator fluent in all major languages. Provide accurate translations while preserving tone, idioms, and cultural nuance. When ambiguous, offer alternatives.", isBuiltIn: true),
        SystemPromptPreset(name: "Analyst", icon: "chart.bar.fill", prompt: "You are a data analyst and critical thinker. Break down complex problems with structured reasoning. Use data-driven insights, consider multiple perspectives, and present conclusions clearly.", isBuiltIn: true),
        SystemPromptPreset(name: "Creative", icon: "sparkles", prompt: "You are a boundlessly creative AI. Think outside the box, brainstorm freely, and propose imaginative solutions. Embrace unconventional ideas and explore possibilities without limits.", isBuiltIn: true),
        SystemPromptPreset(name: "Concise", icon: "text.alignleft", prompt: "You are a concise assistant. Give brief, direct answers. Avoid unnecessary elaboration. Use bullet points when listing items. Keep responses under 3 sentences unless more detail is explicitly requested.", isBuiltIn: true)
    ]

    var allPresets: [SystemPromptPreset] {
        Self.builtInPresets + loadCustomPresets()
    }

    var selectedPresetId: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: selectedIdKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: selectedIdKey)
        }
    }

    var customPromptText: String {
        get { UserDefaults.standard.string(forKey: customTextKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customTextKey) }
    }

    var activePrompt: String {
        // If custom text is set and no preset selected, use custom
        if let id = selectedPresetId {
            if let preset = allPresets.first(where: { $0.id == id }) {
                return preset.prompt
            }
        }
        let custom = customPromptText
        if !custom.isEmpty { return custom }
        return Self.builtInPresets[0].prompt
    }

    var activePresetName: String {
        if let id = selectedPresetId, let preset = allPresets.first(where: { $0.id == id }) {
            return preset.name
        }
        if !customPromptText.isEmpty { return "Custom" }
        return "Default"
    }

    func selectPreset(_ preset: SystemPromptPreset) {
        selectedPresetId = preset.id
        customPromptText = ""
    }

    func setCustomPrompt(_ text: String) {
        selectedPresetId = nil
        customPromptText = text
    }

    func addCustomPreset(name: String, icon: String, prompt: String) {
        var customs = loadCustomPresets()
        customs.append(SystemPromptPreset(name: name, icon: icon, prompt: prompt, isBuiltIn: false))
        saveCustomPresets(customs)
    }

    func removeCustomPreset(id: UUID) {
        var customs = loadCustomPresets()
        customs.removeAll { $0.id == id }
        saveCustomPresets(customs)
        if selectedPresetId == id { selectedPresetId = nil }
    }

    private func loadCustomPresets() -> [SystemPromptPreset] {
        guard let data = UserDefaults.standard.data(forKey: customPresetsKey) else { return [] }
        return (try? JSONDecoder().decode([SystemPromptPreset].self, from: data)) ?? []
    }

    private func saveCustomPresets(_ presets: [SystemPromptPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: customPresetsKey)
        }
    }

    private init() {}
}
