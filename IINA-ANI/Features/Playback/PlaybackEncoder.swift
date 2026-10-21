import Foundation

enum PluginOptionsType: Int {
    case ws, xmlFile, none
}

struct DanmakuPluginOptions: Encodable {
    let rawUrl: String
    let mpvScript: String
    let port: Int
	let urls: [String]
    var type: Int = PluginOptionsType.none.rawValue
    
    let qualitys: [String]
    let lines: [String]
    let currentQuality: Int
    let currentLine: Int
    
    var xmlPath: String?
	
	var edl: String?
    
    init(rawUrl: String,
         mpvScript: String,
		 urls: [String],
         qualitys: [String],
         lines: [String],
         currentQuality: Int,
         currentLine: Int,
         port: Int) {
        self.rawUrl = rawUrl
        self.mpvScript = mpvScript
		self.urls = urls
        self.qualitys = qualitys
        self.lines = lines
        self.currentQuality = currentQuality
        self.currentLine = currentLine
        
        self.port = port
    }
}

struct PlaybackEncodingContext: Sendable {
    let endpoint: HTTPServerEndpoint?
    let enableDanmaku: Bool
    let danmakuFile: String?
    var playlistURLs: [String: String] = [:]
    var playerOptions: [String] = []
}

/// Encodes the existing player/plugin wire format from an explicit prepared snapshot.
struct PlaybackEncoder {
    let media: YouGetJSON
    let context: PlaybackEncodingContext
	var mpvDashOptions: [String] {
		var args = mpvOptions
		switch media.site {
		case .bilibili, .bangumi:
			args.removeAll {
				$0.starts(with: MPVOption.ProgramBehavior.ytdl)
				|| $0.starts(with: MPVOption.Audio.audioFile)
			}
			args.append("\(MPVOption.ProgramBehavior.ytdl)=yes")
		default:
			break
		}
		return args
	}
    
    var mpvOptions: [String] {
		// Fix title
		let t = media.title.replacingOccurrences(of: "\"", with: "''")
		var args = ["\(MPVOption.Miscellaneous.forceMediaTitle)=\(t)"]
		switch media.site {
		case .bilibili, .bangumi:
			args.append(contentsOf: [
				"\(MPVOption.ProgramBehavior.ytdl)=no",
				"\(MPVOption.Network.referrer)=https://www.bilibili.com/"
			])
			if media.audio != "" {
				args.append("\(MPVOption.Audio.audioFile)=\(media.audio)")
			}
		case .biliLive:
			args.append(contentsOf: [
				"\(MPVOption.ProgramBehavior.ytdl)=no",
				"\(MPVOption.Network.referrer)=https://live.bilibili.com/"
			])
		case .huya:
			// Huya goes through the local HuyaProxy; no referrer/UA/reconnect needed
			args.append("\(MPVOption.ProgramBehavior.ytdl)=no")
		default:
			args.append(contentsOf: ["\(MPVOption.ProgramBehavior.ytdl)=no"])
		}
        
        // reconnect
        // https://github.com/mpv-player/mpv/issues/8779#issuecomment-1011066498
        if media.site != .huya {
            args.append("\(MPVOption.Miscellaneous.streamLavfO)=reconnect_streamed=yes")
        }
        
        args.append(contentsOf: context.playerOptions)
        return args
    }
    func iinaURLScheme(_ key: String, type: IINAUrlType) -> String? {
        switch type {
		case .plugin:
			return iinaPluginUrl(key)
		case .normal:
			return iinaDefaultUrl(key)
        case .danmaku:
            return danmakuUrl(key)
		case .none:
			return nil
        }
    }
    
    func danmakuUrl(_ key: String) -> String? {
        guard let endpoint = context.endpoint, let url = videoUrl(key) else {
            return nil
        }
        
        let u = "iina://iina-plus.base64?"
        var args = mpvOptions.map {
            "mpv_" + $0
        }
        args.insert("url=\(url)", at: 0)
        
        
        let newUUID = [media.uuid, media.rawUrl].joined(separator: "👻").toHexString()
        
        if context.enableDanmaku {
            args.append("danmaku")
            args.append("uuid=\(newUUID)")
        }
        args.append("dmPort=\(endpoint.port)")
        args.append("directly")
        args.append("new_window=1")
        
        let str = args.joined(separator: "👻")
        let base64Str = str.data(using: .utf8)?.base64EncodedString() ?? ""
        return u + base64Str
    }
    
	func iinaPluginUrl(_ key: String) -> String? {
		guard let endpoint = context.endpoint, let argsStr = iinaPlusArgsString(key) else {
			return nil
		}
		
		let u = "iina://open?"
        let port = endpoint.port
		var args = [
			"new_window=1",
            // mpv retains this identity when the load hook redirects to the media URL.
            "url=http://127.0.0.1:\(port)/video.mp4?session=\(media.uuid)",
            "mpv_\(MPVOption.PlaybackControl.start)=\(context.playerOptions.first(where: { $0.hasPrefix("start=") }).map { String($0.dropFirst(6)) } ?? "0")",
            "mpv_\(MPVOption.Network.referrer)=\(argsStr)"
		]
        args.append(contentsOf: context.playerOptions.filter { !$0.hasPrefix("start=") }.map { "mpv_" + $0 })
		args = args.compactMap { kvs -> String? in
			let kv = kvs.split(separator: "=", maxSplits: 1).map(String.init)
			guard kv.count == 2 else {
				return kvs
			}
			
			guard let v = kv[1].addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
			let k = kv[0]
			return "\(k)=\(v)"
		}
        
        guard args.count == 4 + context.playerOptions.filter({ !$0.hasPrefix("start=") }).count else { return nil }
        
		return u + args.joined(separator: "&")
	}
	
    func iinaDefaultUrl(_ key: String) -> String? {
        guard let url = videoUrl(key, forDash: true),
			  let argsStr = iinaPlusArgsString(key) else {
            return nil
        }
        
        let u = "iina://open?"
		let opts = url.contains(".mpd") ? mpvDashOptions : mpvOptions
        var args = opts.map {
            "mpv_" + $0
        }
        args.insert("url=\(url)", at: 0)
        args.append("new_window=1")
		args.append("mpv_\(MPVOption.Network.referrer)=\(argsStr)")
		
        args = args.compactMap { kvs -> String? in
            let kv = kvs.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else {
                return kvs
            }
            
            guard let v = kv[1].addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
            let k = kv[0]
            return "\(k)=\(v)"
        }
        
        return u + args.joined(separator: "&")
    }
    
	func videoUrl(_ key: String, forDash: Bool = false) -> String? {
        if media.selection?.qualityID == key, let id = media.selection?.lineID,
           let line = Int(id), line > 0 {
            guard let stream = media.streams[key], stream.src.indices.contains(line - 1) else { return nil }
            return stream.src[line - 1]
        }
        switch media.site {
		case .bilibili where forDash, .bangumi where forDash:
            return media.streams[key]?.dashUrl ?? media.streams[key]?.url
        case .configured(_), .bilibili, .bangumi, .biliLive, .xiFan, .girigiri, .didahd, .jibi, .eacg, .senfun, .kanba, .haixing, .yinghua, .dilidili, .youknow, .hanime1, .wedm, .fengche, .rebo:
            return media.streams[key]?.url
        case .huya:
            return media.streams[key]?.url
        case .local:
            return media.streams.first?.value.url
        default:
            return context.playlistURLs[key]
        }
        
        return nil
    }
    
    func iinaPlusArgsString(_ key: String) -> String? {
        guard let endpoint = context.endpoint else { return nil }
        let urls: [String] = {
            var urls = [String]()
            if let u = media.streams[key]?.url {
                urls.append(u)
            }
            if let us = media.streams[key]?.src {
                urls.append(contentsOf: us)
            }
            return urls
        }()
        
        let qualitys = media.videos.map {
            $0.key
        }
        let lineCount: Int = urls.count
        
        var opts = DanmakuPluginOptions(
            rawUrl: media.rawUrl,
			mpvScript: mpvOptionsToScriptValue(mpvOptions),
			urls: urls,
            qualitys: qualitys,
            lines: (0..<lineCount).map {
                "Line \($0 + 1)"
            },
            currentQuality: qualitys.firstIndex(of: key) ?? 0,
            currentLine: media.selection?.qualityID == key ? Int(media.selection?.lineID ?? "0") ?? 0 : 0,
            port: endpoint.port)

//		opts.edl = edl(key: key)
		
        if context.enableDanmaku {
            opts.type = PluginOptionsType.ws.rawValue
        }
		
        if let dmPath = context.danmakuFile {
            opts.type = PluginOptionsType.xmlFile.rawValue
            opts.xmlPath = dmPath
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(opts) else {
            return nil
        }
        
        return data.toHexString()
    }
	
	func edl(key: String) -> String? {
//		mpv.set("stream-open-filename", opts.edl);
		guard let stream = media.streams[key],
			  stream.url != nil else { return nil }
		
		var edl = "edl://"
		
		func appendUrl(_ url: String) {
			edl += "!new_stream;!no_clip;!no_chapters;"
			edl += "%\(url.count)%"
			edl += url
			edl += ";"
		}
		
		appendUrl(stream.url!)
		
		if media.audio != "" {
			appendUrl(media.audio)
		}
		
		return edl
	}
    
    func m3uContent(key: String) -> Data? {
        guard let stream = media.streams[key],
              stream.url != nil else { return nil }
        
        var content = "#EXTM3U"
        
        content.append("\n#EXTINF:-1 ,\(media.title)\n")
        content.append(stream.url!)
        
        stream.src.enumerated().forEach {
            let tt = media.title + " - " + String(localized: "备用\($0.offset + 1)")
            content.append("\n#EXTINF:-1 ,\(tt)\n")
            content.append($0.element)
        }

        return content.data(using: .utf8)
    }
    
    func mpvOptionsToScriptValue(_ opts: [String]) -> String {
        
        var re = ""
        let args = opts.compactMap { kvs -> (String, String)? in
            let kv = kvs.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else {
                return nil
            }
            return (kv[0], kv[1])
        }
        args.enumerated().forEach {
            // force-media-title="xxx",ytdl="no",referrer="xxxx",audio-file="xxx"
            
            re += $0.element.0
            re += "="
            re += "\""
            re += $0.element.1
            re += "\""
            
            if $0.offset < (args.count - 1) {
                re += ","
            }
        }
        
        return re
    }
}

enum PlaybackPreparation {
    static func context(for media: YouGetJSON, key: String, endpoint: HTTPServerEndpoint?, enableDanmaku: Bool) throws -> PlaybackEncodingContext {
        let path = VideoDecoder.dmPath(media.uuid)
        let danmakuFile = path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        var context = PlaybackEncodingContext(endpoint: endpoint, enableDanmaku: enableDanmaku, danmakuFile: danmakuFile)
        switch media.site {
        case .configured, .bilibili, .bangumi, .biliLive, .xiFan, .girigiri, .didahd, .jibi, .eacg, .senfun, .kanba, .haixing, .yinghua, .dilidili, .youknow, .hanime1, .wedm, .fengche, .rebo, .huya, .local:
            return context
        default:
            let encoder = PlaybackEncoder(media: media, context: context)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IINA-PLUS", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = encoder.m3uContent(key: key) {
                let file = directory.appendingPathComponent("\(media.uuid).m3u")
                try data.write(to: file, options: .atomic)
                context.playlistURLs[key] = file.path
            }
            return context
        }
    }
}
