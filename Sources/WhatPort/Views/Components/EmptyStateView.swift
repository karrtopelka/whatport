import SwiftUI

struct EmptyStateView: View {
    var filter: ListFilter
    var hasSearch: Bool
    var hiddenCount: Int
    var scanError: String?
    var showAll: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if hiddenCount > 0 && filter != .all {
                Button("Show all \(hiddenCount) listening processes", action: showAll)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        if scanError != nil { return "exclamationmark.triangle" }
        if hasSearch { return "magnifyingglass" }
        switch filter {
        case .development: return "moon.zzz"
        case .all: return "antenna.radiowaves.left.and.right.slash"
        case .managed: return "star"
        }
    }

    private var title: String {
        if scanError != nil { return "Scan failed" }
        if hasSearch { return "No matches" }
        switch filter {
        case .development: return "No dev servers running"
        case .all: return "Nothing is listening"
        case .managed: return "No managed projects yet"
        }
    }

    private var message: String {
        if let scanError { return scanError }
        if hasSearch { return "Try a project name, port or PID." }
        switch filter {
        case .development: return "Start a dev server and it will show up here, grouped by project."
        case .all: return "No TCP listeners were found for your user. WhatPort cannot see other users' processes without root."
        case .managed: return "Open a running server's details and save its launch command to start, stop and restart it from here."
        }
    }
}
