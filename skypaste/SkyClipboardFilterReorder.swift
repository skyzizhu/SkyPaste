import SwiftUI

struct ClipboardFilterDropDelegate: DropDelegate {
    let destinationFilter: ClipboardFilter
    @Binding var displayedFilters: [ClipboardFilter]
    @Binding var draggedFilter: ClipboardFilter?
    let onCommit: ([ClipboardFilter]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedFilter,
              draggedFilter != destinationFilter,
              draggedFilter.isUserReorderable,
              destinationFilter.isUserReorderable,
              let sourceIndex = displayedFilters.firstIndex(of: draggedFilter),
              let targetIndex = displayedFilters.firstIndex(of: destinationFilter) else { return }

        var updated = displayedFilters
        let moving = updated.remove(at: sourceIndex)
        updated.insert(moving, at: targetIndex)
        guard updated != displayedFilters else { return }
        displayedFilters = updated
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedFilter = nil
        onCommit(displayedFilters)
        return true
    }
}
