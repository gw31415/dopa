import AppKit
import DopaUIModel
import SwiftUI

extension EnvironmentValues {
  @Entry var clearTimeFieldFocus: () -> Void = {}
}

@available(macOS 26.0, *)
struct DopaPanel: View {
  @Bindable var model: AppModel
  @Binding var selection: Int
  @State private var showingNotice = false
  @ScaledMetric(relativeTo: .body) private var panelWidth = 380
  @ScaledMetric(relativeTo: .body) private var headerHeight = 28

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("Dopa").font(.title2.bold())
        Spacer()
        Label("ディスプレイオフ防止", systemImage: "display")
          .font(.callout)
          .foregroundStyle(.secondary)
          .opacity(model.displaySleepPrevented == true ? 1 : 0)
          .accessibilityHidden(model.displaySleepPrevented != true)
          .allowsHitTesting(model.displaySleepPrevented == true)
          .accessibilityIdentifier("display-sleep-prevented")
          .help("ディスプレイがオフにならないようにしています")
        statusControl
      }
      .frame(height: headerHeight)
      .lineLimit(1)
      .popover(isPresented: $showingNotice) {
        VStack(alignment: .leading, spacing: 12) {
          Text(model.message ?? "dopa-daemonのインストールと起動を確認してください。")
          Button("閉じる") {
            showingNotice = false
            if model.connectionState == .connected { model.message = nil }
          }
          .buttonStyle(.glass)
        }
        .padding()
        .frame(idealWidth: 320)
      }
      GlassScopeBar(selection: $selection)
      // The form provides the intrinsic size for both tabs. The list overlays
      // that space instead of feeding measured geometry back into layout state.
      OwnSessionView(model: model)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(selection == 0 ? 1 : 0)
        .disabled(selection != 0)
        .accessibilityHidden(selection != 0)
        .overlay {
          if selection == 1 { SessionsView(model: model) }
        }
    }
    .padding()
    .frame(width: panelWidth)
  }

  private var hasNotice: Bool {
    model.connectionState != .connected || model.message != nil
  }

  @ViewBuilder
  private var statusControl: some View {
    if hasNotice {
      Button { showingNotice = true } label: { statusLabel }
        .buttonStyle(.plain)
        .help("状態の詳細を表示")
        .accessibilityIdentifier("power-status")
    } else {
      statusLabel.accessibilityIdentifier("power-status")
    }
  }

  private var statusLabel: some View {
    HStack(spacing: 6) {
      if model.busy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: hasNotice ? "info.circle" : model.statusSymbol)
      }
      Text(model.busy ? "処理中" : model.status)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }


}

@available(macOS 26.0, *)
private struct GlassScopeBar: View {
  @Binding var selection: Int

  var body: some View {
    GlassEffectContainer {
      HStack(spacing: 0) {
        scope("このアプリ", value: 0)
        scope("全体管理", value: 1)
      }
      .background(.quaternary, in: Capsule())
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("操作範囲")
    .onMoveCommand { direction in
      if direction == .left { select(0) }
      if direction == .right { select(1) }
    }
  }

  private func scope(_ title: String, value: Int) -> some View {
    Button { select(value) } label: {
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(selection == value ? .primary : .secondary)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(selection == value ? .regular.interactive() : .identity, in: Capsule())
    .accessibilityAddTraits(selection == value ? .isSelected : [])
  }

  private func select(_ value: Int) {
    selection = value
  }
}

@available(macOS 26.0, *)
private struct OwnSessionView: View {
  enum Field: Hashable { case duration, end, action }
  @Bindable var model: AppModel
  @State private var focus: Field?
  @State private var editingField: Field?
  @Environment(\.clearTimeFieldFocus) private var clearTimeFieldFocus
  @State private var errorField: Field?
  @State private var dismissedError: String?
  @ScaledMetric(relativeTo: .body) private var inputWidth = 220
  @ScaledMetric(relativeTo: .body) private var actionHeight = 28

  private var target: Date? { model.schedule.proposedTarget(now: model.now) ?? model.schedule.target(now: model.now) }
  private var unlimited: Bool { model.schedule.proposedIsUnlimited }
  private var durationText: String {
    guard !unlimited, let target else { return "" }
    return formatDuration(target.timeIntervalSince(model.now))
  }
  private var errorText: String? { model.schedule.validation(now: model.now)?.description }
  private var editing: Bool { model.schedule.running && model.schedule.draft != nil }
  private var durationLabel: String {
    model.schedule.running && !editing && !unlimited ? "残り時間" : "継続時間"
  }
  private var selectedEndDate: Date? {
    guard !unlimited else { return nil }
    return model.schedule.draft?.end ?? target
  }

  private func inputLabel(_ title: String, basis: Schedule.Basis) -> some View {
    HStack(spacing: 6) {
      Text(title)
      Spacer(minLength: 8)
      Image(systemName: "pin.fill")
        .font(.caption)
        .frame(width: 16)
        .foregroundStyle(.secondary)
        .opacity(!unlimited && model.schedule.basis == basis ? 1 : 0)
        .accessibilityHidden(true)
    }
    .help(!unlimited && model.schedule.basis == basis ? "固定中：この値を基準に計算します" : "編集し始めると、この入力を固定します")
  }

  var body: some View {
    VStack(spacing: 16) {
      GroupBox {
        VStack(spacing: 12) {
          Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
              inputLabel(durationLabel, basis: .duration)
                .frame(maxWidth: .infinity, alignment: .leading)
              durationField
            }
            GridRow {
              inputLabel("終了日時", basis: .end)
              endDateField
            }
          }
          Divider()
          ViewThatFits(in: .horizontal) {
            HStack { unlimitedToggle; Spacer(minLength: 12); increments }
            VStack(alignment: .leading) { unlimitedToggle; HStack { Spacer(); increments } }
          }
          Divider()
          HStack {
            Spacer()
            if editing {
              Button("キャンセル") { finishEditing(); model.cancelEdit() }
                .buttonStyle(.glass)
              if errorText == nil {
                Button("適用") { finishEditing(); model.applyEdit() }
                  .buttonStyle(.glassProminent)
                  .tint(.accentColor)
              }
            } else if model.ownSessionID != nil {
              Button("停止") { finishEditing(); Task { await model.stop() } }
                .buttonStyle(.glass)
            } else {
              Button("開始") { finishEditing(); Task { await model.start() } }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .disabled(!model.canStart)
            }
          }
          .frame(height: actionHeight)
        }
        .padding(8)
      }
      GroupBox {
        VStack(spacing: 12) {
          LabeledContent {
            Toggle("ディスプレイをオフにしない", isOn: Binding(
              get: { model.options.keepDisplayOn },
              set: { value in
                var next = model.options; next.keepDisplayOn = value
                Task { await model.setOptions(next) }
              })).labelsHidden()
          } label: {
            Text("ディスプレイをオフにしない").frame(maxWidth: .infinity, alignment: .leading)
          }
          Divider()
          LabeledContent {
            Toggle("ふたを閉じたら停止", isOn: Binding(
              get: { model.options.stopOnLidClose },
              set: { value in
                var next = model.options; next.stopOnLidClose = value
                Task { await model.setOptions(next) }
              })).labelsHidden()
          } label: {
            Text("ふたを閉じたら停止").frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .toggleStyle(.switch)
        .padding(8)
      }
    }
    .disabled(model.busy)
    .onChange(of: focus) { _, next in
      if next != nil { dismissedError = nil; updateError() }
    }
    .onChange(of: errorText) { _, _ in updateError() }
    .onChange(of: model.schedule.running) { _, running in
      if !running { finishEditing() }
    }
  }

  private var unlimitedToggle: some View {
    Toggle("無制限", isOn: Binding(get: { unlimited }, set: {
      model.setUnlimited($0); finishEditing()
    })).toggleStyle(.checkbox)
  }
  private var increments: some View {
    HStack(spacing: 6) {
      increment("＋15分", seconds: 900)
      increment("＋30分", seconds: 1800)
      increment("＋1時間", seconds: 3600)
    }
  }
  private func increment(_ title: String, seconds: Int) -> some View {
    Button(title) { model.addTime(seconds); finishEditing() }
      .buttonStyle(.glass)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .disabled(!model.schedule.canAddTime(seconds, now: model.now))
  }

  private var durationField: some View {
    NativeDurationField(text: Binding(
      get: {
        if unlimited { return "" }
        if let draft = model.schedule.draft, draft.kind == .duration { return draft.input }
        return durationText
      },
      set: { input in
        model.editDuration(input)
        dismissedError = nil
        updateError()
      }), accessibilityLabel: durationLabel + (!unlimited && model.schedule.basis == .duration ? "、固定中" : ""), onFocus: {
        focus = .duration
      }, onEdit: {
        model.beginEditingBasis(.duration)
      }, onEditingChanged: { active in
        if active { editingField = .duration }
        else if editingField == .duration { editingField = nil }
        updateError()
      })
      .frame(width: inputWidth)
      .disabled(unlimited)
      .accessibilityLabel(durationLabel + (!unlimited && model.schedule.basis == .duration ? "、固定中" : ""))
      .accessibilityIdentifier("duration-input")
      .help(errorText ?? "Enterで編集、左右キーで項目を移動、上下キーで増減、Tabで次の入力欄へ移動")
      .popover(isPresented: errorPresentation(for: .duration), arrowEdge: .bottom) {
        validationPopover(for: .duration)
      }
  }

  private var endDateField: some View {
    NativeDateTimeField(value: Binding(
      get: { selectedEndDate },
      set: { date in
        guard let date else { return }
        model.editEndDate(date)
        dismissedError = nil
        updateError()
      }), isFixed: model.schedule.basis == .end, onFocus: {
        focus = .end
      }, onEdit: {
        model.beginEditingBasis(.end)
      }, onEditingChanged: { active in
        if active { editingField = .end }
        else if editingField == .end { editingField = nil }
        updateError()
      })
      .frame(width: inputWidth)
      .disabled(unlimited)
      .accessibilityIdentifier("end-input")
      .help("Enterで日付と時刻を編集します。Tabで次の入力欄へ移動します。設定できる期間は24時間以内です。")
      .popover(isPresented: errorPresentation(for: .end), arrowEdge: .bottom) {
        validationPopover(for: .end)
      }
  }

  private func errorPresentation(for field: Field) -> Binding<Bool> {
    Binding(
      get: { errorField == field },
      set: { if !$0 { dismissedError = errorText; errorField = nil } })
  }

  private func validationPopover(for field: Field) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(field == .duration ? "時間を確認してください" : "終了日時を確認してください").font(.headline)
      Text(errorText ?? "入力を確認してください。")
      Button("閉じる") { dismissedError = errorText; errorField = nil }
        .buttonStyle(.glass)
        .keyboardShortcut(.cancelAction)
    }.padding().frame(idealWidth: 280)
      .presentationCompactAdaptation(.popover)
  }

  private func updateError() {
    guard editingField == nil, let errorText, errorText != dismissedError else { errorField = nil; return }
    let isEnd = model.schedule.draft?.kind == .end
      || (model.schedule.draft == nil && model.schedule.config.endDate != nil)
    errorField = isEnd ? .end : .duration
  }
  private func finishEditing() {
    dismissedError = errorText
    errorField = nil
    clearTimeFieldFocus()
    focus = nil
    editingField = nil
    errorField = nil
  }
}

@available(macOS 26.0, *)
private struct SessionsView: View {
  @Bindable var model: AppModel
  @State private var confirmation: [DaemonSession] = []
  @State private var confirmingAll = false
  @FocusState private var focusedSession: String?

  var body: some View {
    VStack(spacing: 16) {
      List {
        if model.sessions.isEmpty {
          Text(model.connectionState == .connected ? "スリープ防止は実行されていません" : "サービスへの接続を確認してください")
            .foregroundStyle(.secondary)
        }
        ForEach(model.sessions) { session in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(session.id == model.ownSessionID ? "Dopa" : session.clientName)
                .lineLimit(1).truncationMode(.middle)
              Text(session.id == model.ownSessionID ? "このアプリ" : "PID \(String(session.peerPID))")
                .font(.caption).foregroundStyle(.secondary)
              Text("ディスプレイオフ防止 \(session.options.keepDisplayOn ? "オン" : "オフ") · ふたを閉じたら停止 \(session.options.stopOnLidClose ? "オン" : "オフ")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("session-options-\(session.id)")
            }
            Spacer()
            Button("停止") {
              if session.id == model.ownSessionID { stopOwn(session) }
              else { confirmingAll = false; confirmation = [session] }
            }
            .buttonStyle(.glass)
            .focused($focusedSession, equals: session.id)
            .disabled(model.busy || model.authorizing || !model.canStopSession(session))
            .accessibilityLabel("\(session.clientName)、PID \(String(session.peerPID))のスリープ防止を停止")
            .confirmationDialog("スリープ防止を停止しますか？", isPresented: Binding(
              get: { !confirmingAll && confirmation.first?.id == session.id },
              set: { if !$0 { confirmation = [] } }), titleVisibility: .visible) {
                Button("スリープ防止を停止", role: .destructive) { stopConfirmed() }
                Button("キャンセル", role: .cancel) { confirmation = [] }
              } message: { Text(confirmationMessage) }
          }.padding(.vertical, 4)
        }
      }
      .listStyle(.inset)
      .focused($focusedSession, equals: "__list")
      .accessibilityLabel("スリープ防止の一覧")
      if !model.canManage && !model.capabilities.contains("session.stopSessions") && model.connectionState == .connected,
        model.sessions.contains(where: { $0.id != model.ownSessionID }) {
        Text("デーモンの更新が必要です。")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack(alignment: .firstTextBaseline) {
        Text("\(model.sessions.count)件")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.leading, 16)
          .accessibilityIdentifier("session-count")
        Spacer()
        Button("すべて停止") { confirmingAll = true; confirmation = model.sessions }
          .buttonStyle(.glass)
          .disabled(model.busy || model.authorizing || !model.canStopAll)
          .confirmationDialog("\(confirmation.count)件のスリープ防止を停止しますか？", isPresented: Binding(
            get: { confirmingAll && !confirmation.isEmpty },
            set: { if !$0 { confirmation = [] } }), titleVisibility: .visible) {
              Button("すべて停止", role: .destructive) { stopConfirmed() }
              Button("キャンセル", role: .cancel) { confirmation = [] }
            } message: { Text(confirmationMessage) }
      }
    }
  }

  private var confirmationMessage: String {
    let targets = confirmation.map { session in
      session.id == model.ownSessionID ? "Dopa（このアプリ）" : "\(session.clientName)（PID \(String(session.peerPID))）"
    }.joined(separator: "\n")
    let ids = Set(confirmation.map(\.id))
    let remains = model.sessions.contains { !ids.contains($0.id) }
    let result = remains ? "ほかのアプリやCLIのスリープ防止は継続します。" : "停止すると、Dopaによるスリープ防止がすべて解除されます。"
    return "\(targets)\n\n\(result)"
  }
  private func stopConfirmed() {
    let ids = confirmation.map(\.id)
    let index = model.sessions.firstIndex { ids.contains($0.id) } ?? 0
    confirmation = []
    Task {
      await model.stopSessions(ids)
      let remaining = model.sessions
      focusedSession = remaining.isEmpty ? "__list" : remaining[min(index, remaining.count - 1)].id
    }
  }

  private func stopOwn(_ session: DaemonSession) {
    let index = model.sessions.firstIndex { $0.id == session.id } ?? 0
    Task {
      await model.stop()
      let remaining = model.sessions
      focusedSession = remaining.isEmpty ? "__list" : remaining[min(index, remaining.count - 1)].id
    }
  }
}
