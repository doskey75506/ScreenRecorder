import SwiftUI
import RecorderCore

struct CropOverlay: View {
    let size: CGSize
    @Binding var crop: CropMargins
    @State private var dragOrigin: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, size.width), geometry.size.height / max(1, size.height))
            let frame = CGRect(x: (geometry.size.width - size.width * scale) / 2,
                               y: (geometry.size.height - size.height * scale) / 2,
                               width: size.width * scale, height: size.height * scale)
            let source = (try? crop.rect(in: size)) ?? CGRect(origin: .zero, size: size)
            let selection = CGRect(x: frame.minX + source.minX * scale, y: frame.minY + source.minY * scale,
                                   width: source.width * scale, height: source.height * scale)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        let a = CGPoint(x: (value.startLocation.x - frame.minX) / scale,
                                        y: (value.startLocation.y - frame.minY) / scale)
                        let b = CGPoint(x: (value.location.x - frame.minX) / scale,
                                        y: (value.location.y - frame.minY) / scale)
                        apply(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                    })
                Path { path in
                    path.addRect(frame)
                    path.addRect(selection)
                }.fill(.black.opacity(0.45), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .overlay(Rectangle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .gesture(DragGesture().onChanged { value in
                        if dragOrigin == nil { dragOrigin = source }
                        guard let original = dragOrigin else { return }
                        let x = min(max(0, original.minX + value.translation.width / scale), size.width - original.width)
                        let y = min(max(0, original.minY + value.translation.height / scale), size.height - original.height)
                        apply(CGRect(x: x, y: y, width: original.width, height: original.height))
                    }.onEnded { _ in dragOrigin = nil })
                ForEach(0..<4) { corner in
                    let right = corner % 2 == 1
                    let bottom = corner >= 2
                    RoundedRectangle(cornerRadius: 3).fill(.white)
                        .frame(width: 12, height: 12)
                        .position(x: right ? selection.maxX : selection.minX, y: bottom ? selection.maxY : selection.minY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragOrigin == nil { dragOrigin = source }
                            guard let original = dragOrigin else { return }
                            let dx = value.translation.width / scale
                            let dy = value.translation.height / scale
                            let left = right ? original.minX : min(original.maxX - 2, max(0, original.minX + dx))
                            let top = bottom ? original.minY : min(original.maxY - 2, max(0, original.minY + dy))
                            let maxX = right ? max(left + 2, min(size.width, original.maxX + dx)) : original.maxX
                            let maxY = bottom ? max(top + 2, min(size.height, original.maxY + dy)) : original.maxY
                            apply(CGRect(x: left, y: top, width: maxX - left, height: maxY - top))
                        }.onEnded { _ in dragOrigin = nil })
                }
            }
        }
    }

    private func apply(_ rect: CGRect) {
        let bounded = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !bounded.isNull, bounded.width >= 2, bounded.height >= 2 else { return }
        crop = CropMargins.from(rect: bounded, in: size)
    }
}
