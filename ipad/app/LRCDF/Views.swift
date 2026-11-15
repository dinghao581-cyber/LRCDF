import PhotosUI
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var studio: Studio
    @Binding var picks: [PhotosPickerItem]
    @Binding var showFiles: Bool

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    if studio.photos.count > 1 { strip }
                    PictureView()
                }
                Panel(picks: $picks, showFiles: $showFiles, columns: wide ? 2 : 4)
                    .frame(width: wide ? 340 : nil, height: wide ? nil : 440)
                    .background(Palette.panel)
            }
        }
        .onChange(of: studio.look) { _, _ in studio.refresh() }
        .onChange(of: studio.tweak) { _, _ in studio.refresh() }
        .onChange(of: studio.showOriginal) { _, _ in studio.refresh() }
        .onChange(of: studio.beauty) { _, _ in studio.refresh() }
    }

    private var strip: some View {
        Scrolling(axis: .horizontal) {
            HStack(spacing: 8) {
                ForEach(studio.photos) { p in
                    Button { studio.select(p.id) } label: {
                        Group {
                            if let t = p.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() }
                            else { ProgressView() }
                        }
                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.id == studio.current ? Palette.glow : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }.padding(10)
        }
    }
}

/// The photo, large. Hold a finger on it to see the original.
struct PictureView: View {
    @EnvironmentObject var studio: Studio
    var body: some View {
        ZStack {
            if let pic = studio.picture {
                Image(decorative: pic, scale: 1).resizable().scaledToFit().padding(16)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !studio.showOriginal { studio.showOriginal = true } }
                        .onEnded { _ in studio.showOriginal = false })
            } else { ProgressView("正在准备…") }
            VStack {
                Spacer()
                Text(studio.showOriginal ? "原图" : "按住照片看原图")
                    .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55))).padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Panel: View {
    @EnvironmentObject var studio: Studio
    @Binding var picks: [PhotosPickerItem]
    @Binding var showFiles: Bool
    var columns = 2

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                Text("选一个风格").font(.system(size: 15, weight: .semibold))
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<(Look.all.count + columns - 1) / columns, id: \.self) { row in
                        GridRow {
                            ForEach(Look.all[(row * columns)..<min(row * columns + columns, Look.all.count)]) { l in LookCard(look: l) }
                        }
                    }
                }
                if !(studio.currentPhoto?.faces.isEmpty ?? true) {
                    Text("美颜").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                    HStack(spacing: 8) { ForEach(BeautyLevel.allCases) { BeautyCard(level: $0) } }
                }
                Text("微调").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                VStack(spacing: 10) {
                    StepRow(low: "暗", high: "亮", value: $studio.tweak.bright)
                    StepRow(low: "冷", high: "暖", value: $studio.tweak.warm)
                    StepRow(low: "淡", high: "浓", value: $studio.tweak.rich)
                }
                exportButton.padding(.top, 6)
                HStack(spacing: 16) {
                    PhotosPicker(selection: $picks, matching: .images, preferredItemEncoding: .current) {
                        Label("再加照片", systemImage: "plus").font(.system(size: 13))
                    }
                    Button { showFiles = true } label: { Label("从文件", systemImage: "folder").font(.system(size: 13)) }
                }.foregroundStyle(Palette.soft)
                UpdateRow()
            }
            .padding(20)
        }
    }

    @ViewBuilder private var exportButton: some View {
        switch studio.stage {
        case .exporting(let i, let n):
            HStack { ProgressView(); Text("正在保存 \(i + 1)/\(n)…") }.frame(maxWidth: .infinity)
        case .working(let s):
            HStack { ProgressView(); Text(s) }.frame(maxWidth: .infinity)
        default:
            VStack(spacing: 8) {
                Button { studio.exportAll() } label: {
                    Text(studio.photos.count > 1 ? "全部存进相册（\(studio.photos.count) 张）" : "存进相册")
                        .frame(maxWidth: .infinity).bigButton(primary: true)
                }.buttonStyle(.plain)
                if case .done(let n) = studio.stage {
                    Text("已存好 \(n) 张，在相册里能看到。").font(.system(size: 13)).foregroundStyle(Palette.glow)
                }
            }
        }
    }
}

struct LookCard: View {
    @EnvironmentObject var studio: Studio
    let look: Look
    var body: some View {
        let on = studio.look == look.id
        Button { studio.look = look.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                Color.white.opacity(0.05).frame(height: 92)
                    .overlay { if let c = studio.cards[look.id] { Image(decorative: c, scale: 1).resizable().scaledToFill() } }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(look.title).font(.system(size: 14, weight: .semibold))
                Text(look.note).font(.system(size: 11)).foregroundStyle(Palette.soft).lineLimit(1)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.glow.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Palette.glow : Palette.line, lineWidth: on ? 2 : 1))
        }.buttonStyle(.plain)
    }
}

/// One beauty level, shown on the photo's main face.
struct BeautyCard: View {
    @EnvironmentObject var studio: Studio
    let level: BeautyLevel
    var body: some View {
        let on = studio.beauty == level
        Button { studio.beauty = level } label: {
            VStack(spacing: 5) {
                Color.white.opacity(0.05).aspectRatio(1, contentMode: .fit)
                    .overlay { if let c = studio.faceCards[level] { Image(decorative: c, scale: 1).resizable().scaledToFill() } }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(level.title).font(.system(size: 14, weight: .semibold))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.glow.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Palette.glow : Palette.line, lineWidth: on ? 2 : 1))
        }.buttonStyle(.plain)
    }
}

/// Five dots between two words; tap a dot or a word. No slider.
struct StepRow: View {
    let low: String
    let high: String
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 10) {
            Button { if value > -2 { value -= 1 } } label: { word(low) }.buttonStyle(.plain)
            HStack(spacing: 0) {
                ForEach(-2...2, id: \.self) { step in
                    Button { value = step } label: {
                        Circle().fill(step == value ? Palette.glow : (step == 0 ? Color.white.opacity(0.35) : Color.white.opacity(0.15)))
                            .frame(width: step == value ? 18 : 12, height: step == value ? 18 : 12)
                            .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Button { if value < 2 { value += 1 } } label: { word(high) }.buttonStyle(.plain)
        }
    }
    private func word(_ s: String) -> some View {
        Text(s).font(.system(size: 15, weight: .medium)).frame(width: 40, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }
}

/// A scroll view, except in snapshot tests (ImageRenderer draws nothing inside a ScrollView).
struct Scrolling<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder let content: Content
    var body: some View {
        if SelfTest.flat { if axis == .vertical { content.frame(maxHeight: .infinity, alignment: .top) } else { content } }
        else { ScrollView(axis, showsIndicators: false) { content } }
    }
}
