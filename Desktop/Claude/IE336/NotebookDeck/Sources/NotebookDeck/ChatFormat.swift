import Foundation

/// Sets the chat format of a GGUF file just imported into Ollama.
///
/// A FROM-only import under Ollama 0.33.3 (the bundled version) stores the file's own Jinja
/// template (`tokenizer.chat_template`) and no system message, while the course models carry
/// Ollama's Go template for Qwen2.5 and Qwen's default system message (the `template` and
/// `system` files of their repos). So whenever the file's chat template is ChatML (the
/// `<|im_start|>` markers of Qwen and many fine-tunes), the model is given that Go template
/// and, when the file's template contains it, the Qwen system message, unless /api/show
/// already reports both. /api/chat then lays a conversation out as the model was trained:
/// the system message (21 tokens for Qwen's), then the ChatML turns. In the tests of this
/// code, Ollama 0.33.3 rendered the imported Jinja template to the same token count, so the
/// change fixes the format in the model rather than relying on the server's Jinja support.
enum ChatFormat {
    /// Qwen2.5's default system message, which its chat template inserts when a conversation has none.
    static let qwenSystem = "You are Qwen, created by Alibaba Cloud. You are a helpful assistant."

    static let noFormatNote = "Ollama found no chat format in this file. Chat requests may not behave as intended; raw prompts are unaffected."

    /// Sets the ChatML template (and the Qwen system message) on `model`, just imported from
    /// `source`, when the file's chat template is ChatML. For any other file, the model is left
    /// as imported, with a note when Ollama reports no template for it. Returns a note for the
    /// Models window, or nil when there is nothing to report. Throws when Ollama cannot show
    /// the model at all.
    static func applyAfterImport(model: String, source: URL) async throws -> String? {
        let shown = try await OllamaServer.show(model)

        let fileTemplate: String?
        do {
            fileTemplate = try await Task.detached { try GGUF.chatTemplate(in: source) }.value
        } catch {
            AppLog.write("chat format: could not read the header of \(source.path): \(error.localizedDescription)")
            fileTemplate = nil
        }
        guard let fileTemplate, fileTemplate.contains("<|im_start|>") else {
            let kind = fileTemplate == nil ? "absent" : "not ChatML"
            let current = (shown["template"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || current == "{{ .Prompt }}" {
                AppLog.write("chat format: \(model): the file's chat template is \(kind) and Ollama reports none; left unchanged")
                return noFormatNote
            }
            AppLog.write("chat format: \(model): the file's chat template is \(kind); Ollama's template left unchanged")
            return nil
        }

        let system = fileTemplate.contains(qwenSystem) ? qwenSystem : nil
        let what = "the ChatML (Qwen2.5) template" + (system == nil ? "" : " and the Qwen system message")
        if hasFormat(shown, system: system) {
            AppLog.write("chat format: \(model) already has \(what); left unchanged")
            return nil
        }
        do {
            try await OllamaServer.create(model: model, from: model, template: chatMLTemplate, system: system)
            guard hasFormat(try await OllamaServer.show(model), system: system) else {
                throw OllamaError.server("Ollama did not keep the new template")
            }
            AppLog.write("chat format: \(model) set to \(what)")
            return "Its chat format was set to Ollama's ChatML template for Qwen2.5"
                + (system == nil ? "" : ", with the default Qwen system message")
                + ", the layout of the file's own chat template."
        } catch {
            AppLog.write("chat format: setting \(what) on \(model) failed: \(error.localizedDescription)")
            return "Setting its ChatML chat format failed (\(error.localizedDescription)). Chat requests may not be laid out as the model was trained; raw prompts are unaffected."
        }
    }

    /// True when /api/show reports exactly the ChatML template and, if `system` is given, that
    /// system message.
    private static func hasFormat(_ shown: [String: Any], system: String?) -> Bool {
        shown["template"] as? String == chatMLTemplate && (system == nil || shown["system"] as? String == system)
    }

    /// ChatML with tool calls. Source: Ollama's own template for qwen2.5, the `template` layer of
    /// registry.ollama.ai/library/qwen2.5, byte for byte as /api/show returns it for qwen2.5:3b
    /// under Ollama 0.33.3 (also the `template` file of the purdue-ie336/qwen2.5-3b-irreducibility-GGUF
    /// repo). Do not re-indent or reflow it: the text must stay byte-identical.
    static let chatMLTemplate = #"""
{{- if .Messages }}
{{- if or .System .Tools }}<|im_start|>system
{{- if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
{{- end }}<|im_end|>
{{ end }}
{{- range $i, $_ := .Messages }}
{{- $last := eq (len (slice $.Messages $i)) 1 -}}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ if .Content }}{{ .Content }}
{{- else if .ToolCalls }}<tool_call>
{{ range .ToolCalls }}{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
{{ end }}</tool_call>
{{- end }}{{ if not $last }}<|im_end|>
{{ end }}
{{- else if eq .Role "tool" }}<|im_start|>user
<tool_response>
{{ .Content }}
</tool_response><|im_end|>
{{ end }}
{{- if and (ne .Role "assistant") $last }}<|im_start|>assistant
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ end }}{{ .Response }}{{ if .Response }}<|im_end|>{{ end }}
"""#
}
