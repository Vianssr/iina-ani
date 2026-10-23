//
//  BilibiliDynamicManger.swift
//  IINA+
//
//  Created by xjbeta on 2024/7/12.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Cocoa

@MainActor
protocol BilibiliDynamicMangerDelegate: AnyObject, Sendable {
	func bilibiliDynamicStatusChanged(_ isLoading: Bool)
    func bilibiliDynamicFailed(_ message: String)
	
	func bilibiliDynamicInitCards(_ cards: [BilibiliCard])
	func bilibiliDynamicAppendCards(_ cards: [BilibiliCard])
	func bilibiliDynamicInsertCards(_ cards: [BilibiliCard])
	
	func bilibiliDynamicCards() -> [BilibiliCard]
}

actor BilibiliDynamicManger {

    private let tokenBucket = TokenBucket(tokens: 1)
    
    private var initDate: Date?
    private var newDate: Date?
    private var historyDate: Date?
    private var historyOffset: String?
    private var hasMoreHistory = true
	
    private weak var delegate: (any BilibiliDynamicMangerDelegate)?
    private var loadTask: Task<Void, Never>?

    func setDelegate(_ newDelegate: (any BilibiliDynamicMangerDelegate)?) {
		delegate = newDelegate
	}
	
    func loadBilibiliCards(_ action: BilibiliDynamicAction = .init😅) {
        guard loadTask == nil else { return }
        loadTask = Task {
            await tokenBucket.withToken {
                guard !Task.isCancelled else { return }
                await loadCards(action)
            }
            loadTask = nil
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        delegate = nil
    }
    
    private func loadCards(_ action: BilibiliDynamicAction = .init😅) async {
        guard let delegate else { return }
        switch action {
        case .history:
            guard hasMoreHistory else { return }
            if let historyDate, historyDate.secondsSinceNow < 1 { return }
        case .new:
            if let newDate, newDate.secondsSinceNow < 5 { return }
        case .init😅:
            if let initDate, initDate.secondsSinceNow < 15 { return }
        }

        await delegate.bilibiliDynamicStatusChanged(true)
        do {
            let offset = action == .history ? historyOffset : nil
            let page = try await SiteAccounts.shared.withSource(sourceID: "bilibili") {
                try await Bilibili.shared.dynamicList(offset: offset)
            }
            try Task.checkCancellation()
            guard self.delegate === delegate else { return }

            switch action {
            case .init😅:
                await delegate.bilibiliDynamicInitCards(page.cards)
                historyOffset = page.offset
                hasMoreHistory = page.hasMore && !page.offset.isEmpty
                initDate = Date()
            case .history, .new:
                let existing = await delegate.bilibiliDynamicCards()
                var seen = Set(existing.map(\.bvid))
                let additions = page.cards.filter { seen.insert($0.bvid).inserted }
                if action == .history {
                    await delegate.bilibiliDynamicAppendCards(additions)
                    historyOffset = page.offset
                    hasMoreHistory = page.hasMore && !page.offset.isEmpty
                    historyDate = Date()
                } else {
                    await delegate.bilibiliDynamicInsertCards(additions)
                    // Refreshing the newest page must not reset the history cursor.
                    newDate = Date()
                }
            }
        } catch is CancellationError {
        } catch {
            guard self.delegate === delegate, !Task.isCancelled else { return }
            await delegate.bilibiliDynamicFailed(error.localizedDescription)
            Log("Get bilibili dynamicList error: \(error)")
        }
        guard self.delegate === delegate, !Task.isCancelled else { return }
        await delegate.bilibiliDynamicStatusChanged(false)
    }
	
}
