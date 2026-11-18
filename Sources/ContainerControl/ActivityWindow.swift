import ControlCore
import SwiftUI

struct ActivityWindow: View {
    static let id = "activity"

    @Environment(AppModel.self) private var model
    @State private var onlyAgents = false

    private var entries: [ActivityEntry] {
        model.activity.reversed().filter { !onlyAgents || $0.isAgent }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    onlyAgents ? "No agent has done anything yet" : "No activity yet",
                    systemImage: "clock",
                    description: Text("Here you will see who starts, stops or changes each project: you, the terminal or an AI agent.")
                )
            } else {
                List(entries.indices, id: \.self) { i in
                    ActivityRow(entry: entries[i])
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Picker("Show", selection: $onlyAgents) {
                Text("All").tag(false)
                Text("Agents only").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 460, minHeight: 320)
        .dockPresence()
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: ActivityEntry
    var showProject = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.ok ? (entry.isAgent ? Color.purple : .secondary) : .red)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.describe(entry, includeProject: showProject))
                if let message = entry.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(entry.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(entry.date.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if !entry.ok { return "exclamationmark.triangle.fill" }
        if entry.isAgent { return "sparkles" }
        return entry.actor == Actor.app.name ? "macwindow" : "terminal"
    }
}
