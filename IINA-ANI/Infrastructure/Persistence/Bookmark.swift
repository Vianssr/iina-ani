//
//  Bookmark+CoreDataClass.swift
//  iina+
//
//  Created by xjbeta on 2018/7/19.
//  Copyright © 2018 xjbeta. All rights reserved.
//
//

import Cocoa
import Foundation
import CoreData
import SDWebImage

//@objc(Bookmark)
public class Bookmark: NSManagedObject {

    var site: SupportSites {
        SupportSites(url: url)
    }
    
    @objc dynamic var image: NSImage?
    
    @MainActor
    func setInfo(_ info: LiveInfo) async {
        liveTitle = info.title
        liveName = info.name
        
        let isLiveSite = ![.bangumi, .bilibili, .xiFan, .girigiri, .jibi, .eacg, .senfun, .kanba, .haixing, .yinghua].contains(site)

        cover = isLiveSite ? info.avatar : info.cover
        if site != .xiFan && site != .girigiri && site != .jibi && site != .eacg && site != .senfun && site != .kanba && site != .haixing && site != .yinghua {
            cover?.coverUrlFormatter(site: isLiveSite ? site : .biliLive)
        }

        await updateImage()
        
        if info.site == .bangumi {
            liveName = "Bangumi"
        }
        
        if isLiveSite {
            state = (info.isLiving ? LiveState.living : LiveState.offline).raw
        } else if info.site == .xiFan || info.site == .girigiri || info.site == .jibi || info.site == .eacg || info.site == .senfun || info.site == .kanba || info.site == .haixing || info.site == .yinghua {
            state = (info.isLiving ? LiveState.video : LiveState.offline).raw
        } else if info.site == .bangumi || info.site == .bilibili {
            state = LiveState.video.raw
        } else {
            state = LiveState.none.raw
        }
    }
    
    @MainActor
	func setInfoError(_ error: any Error) {
		let s = "Get live status error: \(error) \n - \(url)"
		Log(s)
		liveTitle = url
		state = LiveState.none.raw
	}
    
    @MainActor
    private func updateImage() async {
        image = nil
        guard let c = cover else { return }
        let img = await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: .init(string: c),
                progress: nil) { image, _, _, _, _, url in
                    continuation.resume(returning: image?.sd_imageData())
            }
        }
        guard let img else { return }
        image = NSImage(data: img)
    }
}
