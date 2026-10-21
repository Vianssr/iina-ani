//
//  YouGetJSON.swift
//  iina+
//
//  Created by xjbeta on 2018/7/5.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Foundation
import Marshal


enum IINAUrlType: String {
    case normal, danmaku, plugin, none
}

struct YouGetJSON: Unmarshaling, Codable, Sendable {
    var rawUrl: String = ""
    var selection: PlayableSelection?
    
    
    let uuid = UUID().uuidString
    var bvid = ""
    
    var title: String = ""
    var streams: [String: Stream] = [:]
    var audio = ""
    var id = -1
    var duration = -1
    
    
    var videos: [(key: String, value: Stream)] {
        get {
            return streams.sorted {
                // huya: menu order = server vMultiStreamInfo order
                if $0.value.qualityIndex >= 0, $1.value.qualityIndex >= 0,
                   $0.value.qualityIndex != $1.value.qualityIndex {
                    return $0.value.qualityIndex < $1.value.qualityIndex
                }
                return $0.value.quality > $1.value.quality
            }
        }
    }

    var site: SupportSites = .unsupported
	
    
    enum CodingKeys: String, CodingKey {
        case title, streams, audio, id, duration
    }

    init(object: MarshaledObject) throws {
        let titleStr: String? = try? object.value(for: "title")
        title = titleStr ?? ""
        streams = try object.value(for: "streams")
    }
    
    init(rawUrl: String) {
        streams = [:]
        self.rawUrl = rawUrl
        self.site = SupportSites(url: rawUrl)
    }
    
    init(url: String) {
        streams = ["url": Stream(url: url)]
    }
    
}

struct Stream: Unmarshaling, Codable, Sendable {
    var quality: Int = -1
    /// Menu order (huya server list position); -1 = sort by quality only
    var qualityIndex: Int = -1
    var rate: Int = -1
    var url: String?
    var videoProfile: String?
    var size: Int64?
    var src: [String] = []
	
	var dashContent: String?
	var dashUrl: String?
	
    init(object: MarshaledObject) throws {
        let srcArray: [String]? = try? object.value(for: "src")
        src = srcArray ?? []
        url = try? object.value(for: "url")
        videoProfile = try? object.value(for: "video_profile")
        size = try? object.value(for: "size")
    }
    
    init(url: String) {
        self.url = url
    }
}
