import SwiftUI

struct WindowFrameView: View {
    let layout: WindowPaneLayout
    let thickness: Double

    var body: some View {
        GeometryReader { proxy in
            if layout != .off {
                let size = proxy.size
                let width = CGFloat(min(max(thickness, 6), 24))
                ZStack {
                    RoundedRectangle(cornerRadius: width * 0.45)
                        .strokeBorder(Color(red: 0.09, green: 0.105, blue: 0.115), lineWidth: width)
                    ForEach(1..<layout.columns, id: \.self) { column in
                        divider(width: width, length: size.height, vertical: true)
                            .position(x: size.width * CGFloat(column) / CGFloat(layout.columns), y: size.height / 2)
                    }
                    if layout.rows > 1 {
                        divider(width: width, length: size.width, vertical: false)
                            .position(x: size.width / 2, y: size.height / 2)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 3)
            }
        }
    }

    private func divider(width: CGFloat, length: CGFloat, vertical: Bool) -> some View {
        Rectangle()
            .fill(Color(red: 0.09, green: 0.105, blue: 0.115))
            .frame(width: vertical ? width : length, height: vertical ? length : width)
            .overlay(alignment: vertical ? .leading : .top) {
                Rectangle().fill(.white.opacity(0.16))
                    .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            }
    }
}
