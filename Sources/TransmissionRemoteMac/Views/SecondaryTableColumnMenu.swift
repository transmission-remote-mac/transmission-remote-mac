// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

extension SecondaryTableSortDirection {
    init(_ sortOrder: SortOrder) {
        self = sortOrder == .reverse ? .descending : .ascending
    }

    var sortOrder: SortOrder {
        self == .descending ? .reverse : .forward
    }
}

struct SecondaryTableColumnOption: Identifiable {
    var id: String
    var title: String
    var isRequired = false
}

struct SecondaryTableColumnMenu<RowValue: Identifiable>: View {
    var title: String
    var table: SecondaryTableKind
    @Binding var customization: TableColumnCustomization<RowValue>
    @Binding var layoutPreference: SecondaryTableLayoutPreference
    var columns: [SecondaryTableColumnOption]
    var restoreDefaultColumns: () -> Void
    var restoreDefaultSort: () -> Void

    var body: some View {
        Menu {
            ForEach(orderedColumns) { column in
                Toggle(
                    column.isRequired ? "\(column.title) (Always Shown)" : column.title,
                    isOn: visibilityBinding(for: column)
                )
                .disabled(column.isRequired)
            }

            Divider()

            Button("Restore Default Columns") {
                restoreDefaultColumns()
                layoutPreference = layoutPreference.restoringColumns(for: table)
            }

            Button("Restore Default Sort") {
                layoutPreference = layoutPreference.restoringSort(for: table)
                restoreDefaultSort()
            }
        } label: {
            Label("Columns", systemImage: "rectangle.3.group")
        }
        .help("Show, hide, or restore \(title.lowercased()). Drag table headers to reorder columns.")
    }

    private var orderedColumns: [SecondaryTableColumnOption] {
        // SwiftUI persists dragged header order in TableColumnCustomization.
        // The app-owned preference intentionally covers visibility and sort only.
        columns
    }

    private func visibilityBinding(for column: SecondaryTableColumnOption) -> Binding<Bool> {
        Binding(
            get: {
                column.isRequired || layoutPreference.isColumnVisible(column.id, for: table)
            },
            set: { isVisible in
                guard !column.isRequired else { return }
                customization[visibility: column.id] = isVisible ? .visible : .hidden
                layoutPreference = layoutPreference.settingColumnVisibility(
                    isVisible,
                    columnID: column.id,
                    for: table
                )
            }
        )
    }
}
