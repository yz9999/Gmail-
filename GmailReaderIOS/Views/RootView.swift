import SwiftUI

struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack(alignment: .bottom) {
            if accounts.selectedAccount == nil {
                NavigationStack { EmptyAccountView() }
            } else if horizontalSizeClass == .compact {
                PhoneMailContainer()
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
        .tint(GmailTheme.red)
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

enum GmailTheme {
    static let red = Color(red: 0.85, green: 0.18, blue: 0.16)
    static let compose = Color(red: 0.96, green: 0.84, blue: 0.82)
}

private struct PhoneMailContainer: View {
    @EnvironmentObject private var model: MailboxViewModel
    @State private var path = NavigationPath()
    @State private var showingSidebar = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                NavigationStack(path: $path) {
                    PhoneMessageListView(
                        openSidebar: {
                            withAnimation(.easeOut(duration: 0.22)) { showingSidebar = true }
                        },
                        openMessage: { summary in
                            model.open(summary)
                            path.append(summary)
                        }
                    )
                    .navigationDestination(for: MailSummary.self) { summary in
                        MessageDetailView()
                            .onAppear {
                                if model.selectedSummary?.id != summary.id || model.selectedMessage?.id != summary.id {
                                    model.open(summary)
                                }
                            }
                    }
                }
                .allowsHitTesting(!showingSidebar)

                if showingSidebar {
                    Color.black.opacity(0.34)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeIn(duration: 0.18)) { showingSidebar = false }
                        }
                        .transition(.opacity)
                        .zIndex(1)

                    PhoneSidebarDrawer {
                        withAnimation(.easeIn(duration: 0.18)) { showingSidebar = false }
                    }
                    .frame(width: min(proxy.size.width * 0.88, 380))
                    .background(Color(uiColor: .systemBackground))
                    .transition(.move(edge: .leading))
                    .zIndex(2)
                }
            }
        }
    }
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
