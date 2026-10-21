//
//  DataManager.swift
//  iina+
//
//  Created by xjbeta on 2018/7/27.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

@MainActor
class DataManager: NSObject {
    
    let context: NSManagedObjectContext
    private let favorites: FavoriteLibrary
    private let decoder: VideoDecoder

    init(context: NSManagedObjectContext, favorites: FavoriteLibrary, decoder: VideoDecoder) {
        self.context = context
        self.favorites = favorites
        self.decoder = decoder
    }
	
    private var bookmarkReloadDate = [NSManagedObjectID: TimeInterval]()
    
    func requestData() -> [Bookmark] {
        do { return try favorites.linkObjects().compactMap { $0 as? Bookmark } }
        catch { NSApp.presentError(error); return [] }
    }
    
    func reloadAllBookmark() async {
        await withTaskGroup(of: Void.self) { group in
            for bookmark in requestData() {
                let id = bookmark.objectID
                group.addTask { await self.reloadBookmark(id) }
            }
        }
    }
    
    private func reloadBookmark(_ id: NSManagedObjectID) async {
        guard !Task.isCancelled, let obj = try? context.existingObject(with: id) as? Bookmark,
              !obj.isDeleted else { return }
        let site = SupportSites(url: obj.url)
        if site == .unsupported {
            obj.state = LiveState.none.raw
            save()
            return
        }
        
        let refreshInterval: CGFloat = [.bangumi, .bilibili, .xiFan, .girigiri, .jibi, .eacg, .senfun, .kanba, .haixing, .yinghua, .unsupported].contains(site) ? 300 : 20
        
        if let timestamp = bookmarkReloadDate[id],
           timestamp == -1 || Date(timeIntervalSince1970: timestamp).secondsSinceNow < refreshInterval { return }
        bookmarkReloadDate[id] = -1
        defer {
            if Task.isCancelled { bookmarkReloadDate.removeValue(forKey: id) }
            else { bookmarkReloadDate[id] = Date().timeIntervalSince1970 }
        }
        
        do {
            let info = try await decoder.liveInfo(obj.url)
            try Task.checkCancellation()
            guard !obj.isDeleted else { return }
            await obj.setInfo(info)
        } catch is CancellationError {
            return
        } catch let error {
            guard !Task.isCancelled, !obj.isDeleted else { return }
            obj.setInfoError(error)
        }

        save()
    }
    

    private func save() {
        do { if context.hasChanges { try context.save() } }
        catch { NSApp.presentError(error) }
    }
}
