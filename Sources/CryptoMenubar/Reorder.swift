import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop row reordering for the plain VStack lists (we don't use
// List, so there's no built-in .onMove). Each row is both a drag source and
// a drop target; when a dragged row enters another row, the store moves it
// there immediately, so the list re-flows live under the cursor.

struct ReorderDropDelegate: DropDelegate {
    let rowId: Int
    @Binding var draggingId: Int?
    let move: (_ dragged: Int, _ onto: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingId, dragged != rowId else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            move(dragged, rowId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

extension View {
    /// Makes a row draggable + a drop target for sibling rows.
    func reorderable(id: Int,
                     draggingId: Binding<Int?>,
                     move: @escaping (_ dragged: Int, _ onto: Int) -> Void) -> some View {
        self
            .opacity(draggingId.wrappedValue == id ? 0.35 : 1)
            .onDrag {
                draggingId.wrappedValue = id
                return NSItemProvider(object: String(id) as NSString)
            }
            .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(rowId: id, draggingId: draggingId, move: move))
    }
}

// MARK: - Sort menu (header ↕ button)

struct SortMenu: View {
    @Binding var selection: ListSort
    let options: [ListSort]

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(options) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: selection == .manual ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selection == .manual ? "Sort — currently manual order (drag rows to rearrange)" : "Sorted by \(selection.label)")
    }
}
