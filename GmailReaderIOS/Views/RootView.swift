import SwiftUI

struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactPath = NavigationPath()

    var body: some View {
        ZStack(alignment: .bottom) {
            if accounts.selectedAccount == nil {
                NavigationStack { EmptyAccountView() }
            } else if horizontalSizeClass == .compact {
                NavigationStack(path: $compactPath) {
                    SidebarView { mailbox in
                        model.selectMailbox(mailbox)
                        compactPath.append(CompactRoute.messageList)
                    }
                    .navigationDestination(for: CompactRoute.self) { route in
                        switch route {
                        case .messageList:
                            MessageListView()
                        }
                    }
                    .navigationDestination(for: MailSummary.self) { summary in
                        MessageDetailView()
                            .onAppear {
                                if model.selectedSummary?.id != summary.id || model.selectedMessage?.id != summary.id {
                                    model.open(summary)
                                }
                            }
                    }
                }
                .task {
                    // iPhone 竖屏启动后直接显示收件箱，用户仍可通过返回按钮打开侧边栏。
                    if compactPath.count == 0 {
                        compactPath.append(CompactRoute.messageList)
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } content: {
                    MessageListView()
                } detail: {
                    MessageDetailView()
                }
                .navigationSplitViewStyle(.balanced)
            }
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(Color(red: 0.10, green: 0.42, blue: 0.90))
        .sheet(isPresented: $model.showingAccounts) { AccountManagerView() }
        .sheet(isPresented: $model.showingCompose) { ComposeView() }
        .alert("Gmail Reader", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private enum CompactRoute: Hashable {
    case messageList
}

private struct EmptyAccountView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge.shield.leadinghalf.filled")
                .font(.system(size: 68))
                .foregroundStyle(.secondary)
            Text("添加 Gmail 账号").font(.title2.bold())
            Text("使用 Google 应用专用密码连接。密码只保存在这台设备的钥匙串中。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("添加账号") { model.showingAccounts = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .navigationTitle("Gmail")
    }
}
