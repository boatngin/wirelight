import SwiftUI

/// A small list of strings with remove buttons and an "Add" field, validated per entry.
struct EditableList: View {
    let items: [String]
    let placeholder: String
    let icon: String
    let validate: (String) -> Bool
    let onChange: ([String]) -> Void

    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Image(systemName: icon).foregroundStyle(.secondary)
                    Text(item).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button { onChange(items.filter { $0 != item }) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(add)
                    .onChange(of: draft) { _ in invalid = false }
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                Text("That doesn't look valid. Check the format and try again.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return }
        guard validate(value) else { invalid = true; return }
        if !items.contains(value) { onChange(items + [value]) }
        draft = ""
    }
}
