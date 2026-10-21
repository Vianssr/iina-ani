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
	
	func bilibiliDynamicCardsContains(_ bvid: String) -> Bool
	
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
        
        guard let delegate = delegate else { return }
		
		let uuid = UUID().uuidString
		
        await delegate.bilibiliDynamicStatusChanged(true)
		
        defer {
            let cancelled = Task.isCancelled
            Task {
                guard !cancelled, self.delegate === delegate else { return }
                await delegate.bilibiliDynamicStatusChanged(false)
            }
        }
        
		var dynamicID = -1
		
        let bilibiliCards = await delegate.bilibiliDynamicCards()
		
		switch action {
		case .history:
            if historyDate != nil, historyDate!.secondsSinceNow < 1 {
//                Log("\(uuid), ignore, \(action)")
                return
            }
			dynamicID = bilibiliCards.last?.dynamicId ?? -1
		case .new:
            if newDate != nil, newDate!.secondsSinceNow < 5 {
//                Log("\(uuid), ignore, \(action)")
                return
            }
			dynamicID = bilibiliCards.first?.dynamicId ?? -1
        case .init😅:
            if initDate != nil, initDate!.secondsSinceNow < 15 {
//                Log("\(uuid), ignore, \(action)")
                return
            }
		}
		
		Log("\(uuid), start, \(action), \(dynamicID)")
		
        let requestedDynamicID = dynamicID
		do {
            let cards = try await SiteAccounts.shared.withSource(sourceID: "bilibili") {
                let uid = try await Bilibili.shared.getUid()
                return try await Bilibili.shared.dynamicList(uid, action, requestedDynamicID)
            }
            try Task.checkCancellation()
			
			switch action {
			case .init😅:
                await delegate.bilibiliDynamicInitCards(cards)
                self.initDate = Date()
			case .history:
				let appends = await withTaskGroup(of: BilibiliCard?.self) { group -> [BilibiliCard] in
					for card in cards {
						group.addTask {
                            if await delegate.bilibiliDynamicCardsContains(card.bvid) {
								return nil
							} else {
								return card
							}
						}
					}
					
					var results = [BilibiliCard]()
					for await result in group {
						if let result {
							results.append(result)
						}
					}
					return results
				}
                try Task.checkCancellation()
                await delegate.bilibiliDynamicAppendCards(appends)
                self.historyDate = Date()
			case .new:
                
				let appends = await withTaskGroup(of: BilibiliCard?.self) { group -> [BilibiliCard] in
					for card in cards {
						group.addTask {
                            if await delegate.bilibiliDynamicCardsContains(card.bvid) {
								return nil
							} else {
								return card
							}
						}
					}
					
					var results = [BilibiliCard]()
					for await result in group {
						if let result {
							results.append(result)
						}
					}
					return results
				}
                try Task.checkCancellation()
				if appends.count > 0 {
                    await delegate.bilibiliDynamicInsertCards(appends)
				}
                self.newDate = Date()
			}
        } catch is CancellationError {
        } catch let error {
            await delegate.bilibiliDynamicFailed(error.localizedDescription)
            Log("Get bilibili dynamicList error: \(error)")
		}
		
		Log("\(uuid), finish, \(dynamicID)")
	}
	
}
