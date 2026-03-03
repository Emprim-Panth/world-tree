import WidgetKit
import SwiftUI

// MARK: - Widget Bundle
//
// Entry point for the WorldTreeWidget extension.
// Contains:
//   - WorldTreeWidgetConfiguration: last-message snippet widget (TASK-063)
//   - WorldTreeLiveActivityWidget: streaming response Live Activity (TASK-058)

@main
struct WorldTreeWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorldTreeWidgetConfiguration()
        WorldTreeLiveActivityWidget()
    }
}
