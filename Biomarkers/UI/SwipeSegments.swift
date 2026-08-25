import SwiftUI

/// Lets a horizontal swipe move between the cases of a segmented selection,
/// so any segment control in the app can be switched by swiping left/right
/// (left = next segment, right = previous).
extension View {
    func swipeSegments<T: CaseIterable & Equatable>(_ selection: Binding<T>) -> some View
    where T.AllCases == [T] {
        highPriorityHorizontalSwipe { forward in
            let all = T.allCases
            guard let i = all.firstIndex(of: selection.wrappedValue) else { return }
            let next = forward ? i + 1 : i - 1
            guard all.indices.contains(next) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { selection.wrappedValue = all[next] }
        }
    }

    private func highPriorityHorizontalSwipe(_ action: @escaping (_ forward: Bool) -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    // Only act on a clearly horizontal swipe so vertical
                    // scrolling still works.
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                          abs(value.translation.width) > 60 else { return }
                    action(value.translation.width < 0)
                }
        )
    }
}
