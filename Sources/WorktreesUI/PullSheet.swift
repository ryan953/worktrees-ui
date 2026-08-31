import SwiftUI
import WorktreeKit

/// Confirms bringing a branch into the working copy.
///
/// The plan is worked out and shown before anything runs, including the exact git
/// commands. This touches a directory the user is probably not looking at, so it should
/// never be a surprise what happened there.
struct PullSheet: View {
    var worktree: Worktree
    var store: WorktreeStore

    @Environment(\.dismiss) private var dismiss
    @State private var mode: PullMode = .moveBranch
    @State private var plan: PullPlan?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pull \(worktree.name) into the working copy")
                    .font(.headline)
                Text(Format.path(worktree.repoRoot))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Picker("How", selection: $mode) {
                ForEach(PullMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(mode.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let plan {
                if !plan.blockers.isEmpty {
                    MessageList(
                        messages: plan.blockers,
                        symbol: "exclamationmark.octagon.fill",
                        tint: .red
                    )
                }
                if !plan.warnings.isEmpty {
                    MessageList(
                        messages: plan.warnings,
                        symbol: "info.circle.fill",
                        tint: .secondary
                    )
                }
                if plan.canProceed {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Runs").font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.steps, id: \.self) { step in
                            Text(step)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .moveBranch ? "Move Branch" : "Check Out") {
                    guard let plan else { return }
                    isWorking = true
                    Task {
                        await store.pull(worktree, plan: plan)
                        isWorking = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.canProceed != true || isWorking)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task(id: mode) {
            plan = nil
            plan = await store.plan(for: worktree, mode: mode)
        }
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView().controlSize(.large)
            }
        }
    }
}

private struct MessageList: View {
    var messages: [String]
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages, id: \.self) { message in
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
