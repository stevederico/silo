import SwiftUI

struct EmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack {
            Image(colorScheme == .dark ? "icon-white" : "icon-black")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
                .foregroundColor(colorScheme == .dark ? Color(.darkGray) : .black)
        }
    }
}
