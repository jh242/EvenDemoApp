import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        Group {
            if history.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(history.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            history.toggle(index: index)
                        } label: {
                            HistoryRow(
                                item: item,
                                isExpanded: history.selectedIndex == index
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                history.removeItem(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.items.isEmpty {
                Button(role: .destructive) {
                    history.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No History Yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Ask COGOS a question from your glasses. Completed responses will appear here so you can revisit them later.")
        }
    }
}

private struct HistoryRow: View {
    let item: EvenaiModel
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 2)

                Spacer(minLength: 12)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            Text(item.createdTime.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(item.content)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: isExpanded)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
