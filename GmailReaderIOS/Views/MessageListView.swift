import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        Group {
            if model.isLoading && model.messages.isEmpty {
                ProgressView("正在获取邮件…")
            } else if model.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.activeSearch.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                    Text(model.activeSearch.isEmpty ? "这里没有邮件" : "没有搜索结果")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(selection: $model.selectedSummary) {
                    ForEach(model.messages) { message in
                        NavigationLink(value: message) {
                            MessageRow(message: message)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                model.toggleStar(message)
                            } label: {
                                Label(message.isStarred ? "取消星标" : "星标", systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { model.reload() }
                .onChange(of: model.selectedSummary) { value in
                    if let value, model.selectedMessage?.id != value.id { model.open(value) }
                }
            }
        }
        .navigationTitle(model.activeSearch.isEmpty ? model.mailbox.title : "搜索结果")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索所有邮件")
        .onSubmit(of: .search) { model.submitSearch() }
        .onChange(of: model.searchText) { value in
            if value.isEmpty, !model.activeSearch.isEmpty { model.clearSearch() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button { model.markAllRead() } label: {
                        Label("将所有会话标记为已读", systemImage: "envelope.open")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Text(model.rangeText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page <= 1 || model.isLoading)
                Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page >= model.pageCount || model.isLoading)
            }
        }
        .overlay(alignment: .top) {
            if model.isLoading && !model.messages.isEmpty { ProgressView().progressViewStyle(.linear) }
        }
    }
}

private struct MessageRow: View {
    let message: MailSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.isStarred ? "star.fill" : "star")
                .foregroundColor(message.isStarred ? .yellow : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.senderDisplay)
                        .font(.subheadline.weight(message.isRead ? .regular : .bold))
                        .lineLimit(1)
                    Spacer()
                    Text(displayDate(message.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline.weight(message.isRead ? .regular : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month().day())
    }
}
