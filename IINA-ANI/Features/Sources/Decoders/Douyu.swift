//
//  Douyu.swift
//  IINA+
//
//  Created by xjbeta on 4/22/22.
//  Copyright © 2022 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal
import CryptoSwift


actor Douyu: SupportSiteProtocol {
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        try await SiteAccounts.shared.withSource(sourceID: "douyu") {
            let rid = try await getDouyuHtml(url).roomId
            let id = Int(rid) ?? -1
            return try await douyuBetard(id)
        }
    }
    
    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        try await SiteAccounts.shared.withSource(sourceID: "douyu") {
            await renewSessionIfNeeded()
            let html = try await getDouyuHtml(url)
            guard let rid = Int(html.roomId) else { throw VideoGetError.douyuNotFoundRoomId }
            let info = try await douyuBetard(rid)
            let urls = try await getDouyuUrl(rid)
            var yougetJson = YouGetJSON(rawUrl: url)
            yougetJson.id = rid
            yougetJson.title = info.title
            urls.forEach { yougetJson.streams[$0.0] = $0.1 }
            return yougetJson
        }
    }
	
    
    // Butterfly event/topic pages identify their page data with a numeric page id
    // and a topic name (`window.zhtId` / `window.zhtName`). Sub rooms are listed
    // with the page id only, so remember the topic names seen while parsing a page.
    // See https://butterfly.douyucdn.cn/api/page/loadPage.
    private var eventTopicNames: [String: String] = [:]
    
    func getDouyuHtml(_ url: String) async throws -> (roomId: String, roomIds: [String], isLiving: Bool, pageId: String) {
        
		let text = try await AccountHTTP.request(url).serializingString().value
		
        guard let jsonText = Self.roomInfoJSON(in: text),
              let jsonData = jsonText.data(using: .utf8) else {
            throw VideoGetError.douyuNotFoundRoomId
        }
        
        let json: JSONObject = try JSONParser.JSONObjectWithData(jsonData)
        let roomId: Int = try json.value(for: "room.room_id")
        let isLiving: Bool = try json.value(for: "room.show_status") == 1
        
        // Event/topic pages (e.g. https://www.douyu.com/100) also list their sub
        // rooms and butterfly page id inline; ordinary rooms have neither.
        let roomIds = Self.eventRoomIds(in: text)
        let pageId = Self.eventPageId(in: text)
        if !pageId.isEmpty, let topicName = Self.eventTopicName(in: text) {
            eventTopicNames[pageId] = topicName
        }
        
		return ("\(roomId)", roomIds, isLiving, pageId)
    }
    
    /// Extracts the `roomInfo` JSON object from a Douyu room page.
    ///
    /// The object is embedded in an inline `<script>` string, so its quotes are
    /// backslash escaped and string values may themselves contain braces (for
    /// example `room.can_send_gift` holds a nested JSON string); the JS escapes
    /// are decoded while matching braces, so neither ends the object early.
    private static func roomInfoJSON(in input: String) -> String? {
        guard let marker = input.range(of: "\\\"roomInfo\\\""),
              let open = input[marker.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        return escapedJSONObject(in: input, from: open)
    }
    
    /// Decodes the JS string escapes of `input` while matching JSON braces from
    /// `open`, returning the complete object.
    private static func escapedJSONObject(in input: String, from open: String.Index) -> String? {
        var result = ""
        var depth = 0
        var inString = false
        var escapePending = false
        var index = open
        
        while index < input.endIndex {
            let character = input[index]
            var token = character
            var next = input.index(after: index)
            
            if character == "\\" {
                guard next < input.endIndex else { return nil }
                let escaped = input[next]
                let afterEscape = input.index(after: next)
                if escaped == "u" {
                    guard let hexEnd = input.index(afterEscape, offsetBy: 4, limitedBy: input.endIndex),
                          UInt32(input[afterEscape..<hexEnd], radix: 16) != nil else {
                        return nil
                    }
                    result.append(contentsOf: input[index..<hexEnd])
                    index = hexEnd
                    escapePending = false
                    continue
                } else {
                    switch escaped {
                    case "\\": token = "\\"
                    case "\"": token = "\""
                    case "/": token = "/"
                    case "b": token = "\u{8}"
                    case "f": token = "\u{c}"
                    case "n": token = "\n"
                    case "r": token = "\r"
                    case "t": token = "\t"
                    default: token = escaped
                    }
                    next = afterEscape
                }
            }
            index = next
            
            if inString {
                if escapePending {
                    escapePending = false
                } else if token == "\\" {
                    escapePending = true
                } else if token == "\"" {
                    inString = false
                }
                result.append(token)
            } else if token == "\"" {
                inString = true
                result.append(token)
            } else if token == "{" {
                depth += 1
                result.append(token)
            } else if token == "}" {
                depth -= 1
                result.append(token)
                if depth == 0 {
                    return result
                }
            } else {
                result.append(token)
            }
        }
        
        return nil
    }
    
    /// Room ids listed by an event/topic page:
    /// `window.room_ids = (function(v) { ... })(["100", "5818871", ...]);`
    private static func eventRoomIds(in input: String) -> [String] {
        guard let marker = input.range(of: "window.room_ids"),
              let invocation = input.range(of: ")(", range: marker.upperBound..<input.endIndex),
              let open = input[invocation.upperBound...].firstIndex(of: "[") else {
            return []
        }
        
        var depth = 0
        var index = open
        while index < input.endIndex {
            let character = input[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return input[input.index(after: open)..<index]
                        .split(separator: ",")
                        .map { $0.filter(\.isNumber) }
                        .filter { !$0.isEmpty }
                }
            }
            index = input.index(after: index)
        }
        return []
    }
    
    /// Butterfly page id of an event/topic page (`window.zhtId = 58596;`), with
    /// the page config's `"pageId":58596` as a fallback.
    private static func eventPageId(in input: String) -> String {
        if let marker = input.range(of: "window.zhtId"),
           let pageId = number(in: input, after: marker.upperBound) {
            return pageId
        }
        for pattern in ["\"pageId\":", "\\\"pageId\\\":"] {
            if let marker = input.range(of: pattern),
               let pageId = number(in: input, after: marker.upperBound) {
                return pageId
            }
        }
        return ""
    }
    
    /// Topic name of an event/topic page (`window.zhtName = 'PUBGYLSJS';`).
    private static func eventTopicName(in input: String) -> String? {
        guard let marker = input.range(of: "window.zhtName") else { return nil }
        let rest = input[marker.upperBound...]
        guard let quote = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let start = rest.index(after: quote)
        guard let end = rest[start...].firstIndex(of: rest[quote]) else { return nil }
        let name = String(rest[start..<end])
        return name.isEmpty ? nil : name
    }
    
    /// Reads the digits following `index`, allowing the separators used by the
    /// inline assignments (`=`, `:`, whitespace and quotes).
    private static func number(in input: String, after index: String.Index) -> String? {
        var index = index
        while index < input.endIndex, !input[index].isNumber {
            switch input[index] {
            case " ", "=", ":", "\"", "'": break
            default: return nil
            }
            index = input.index(after: index)
        }
        var value = ""
        while index < input.endIndex, input[index].isNumber {
            value.append(input[index])
            index = input.index(after: index)
        }
        return value.isEmpty ? nil : value
    }
    
    func douyuBetard(_ rid: Int) async throws -> DouyuInfo {
		let data = try await AccountHTTP.request("https://www.douyu.com/betard/\(rid)").serializingData().value
		let json: JSONObject = try JSONParser.JSONObjectWithData(data)
		return try DouyuInfo(object: json)
    }
    
    
//    https://butterfly.douyucdn.cn/api/page/loadPage?name=pageData1&pageId=58596&view=0&topicName=PUBGYLSJS
    func getDouyuEventRoomNames(_ pageId: String) async throws -> [DouyuEventRoom] {
        
        guard let topicName = eventTopicNames[pageId],
              let encoded = topicName.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else {
            throw VideoGetError.douyuNotFoundSubRooms
        }
        
		let url = "https://butterfly.douyucdn.cn/api/page/loadPage?name=pageData1&pageId=\(pageId)&view=0&topicName=\(encoded)"
		
		let string = try await AccountHTTP.request(url).serializingString().value
		
		guard let data = self.douyuRoomJsonFormatter(string)?.data(using: .utf8) else {
			throw VideoGetError.douyuNotFoundSubRooms
		}
		
		let json: JSONObject = try JSONParser.JSONObjectWithData(data)
		return (try json.value(for: "children")).filter {
			$0.roomId != ""
		}
    }
    
    func getDouyuEventRoomOnlineStatus(_ pageId: String) async throws -> [String: Bool] {
        
        struct RoomOnlineStatus: Decodable {
            let data: [String: Bool]
        }
        
		let url = "https://www.douyu.com/japi/carnival/c/roomActivity/getRoomOnlineStatus?pageId=\(pageId)"
		return try await AccountHTTP.request(url).serializingDecodable(RoomOnlineStatus.self).value.data
    }
    
    func getDouyuUrl(_ roomID: Int, rate: Int = 0) async throws -> [(String, Stream)] {
        let time = Int(Date().timeIntervalSince1970)
        let didStr: String = {
            let time = UInt32(NSDate().timeIntervalSinceReferenceDate)
            srand48(Int(time))
            let random = "\(drand48())"
            return random.md5()
        }()
        
        let enc = try await getEncryption(didStr)
        
        
        let auth = enc.auth("\(roomID)", ts: time)
        
        let pars = ["enc_data": enc.encData,
                     "tt": "\(time)",
                     "did": didStr,
                     "auth": auth,
                     "cdn": "",
                     "rate": "\(rate)",
                     "hevc": "1",
                     "fa": "0",
                     "ive": "0"]
        
        
		let url = "https://www.douyu.com/lapi/live/getH5PlayV1/\(roomID)"
		let data = try await AccountHTTP.request(url, method: .post, parameters: pars).serializingData().value
        
		let json: JSONObject = try JSONParser.JSONObjectWithData(data)
		
		var play = try DouyuH5Play(object: json)
		play = try await douyuCDNs(play)
		
		return play.multirates.map { r -> (String, Stream) in
			var s = Stream(url: "")
			s.quality = r.bit
			s.rate = r.rate
			
			var urls = play.p2pUrls
			urls.append(play.flvUrl)
			
			// Server only issues the stream matching data.rate; rate 0 (original) falls back to that stream when the room has Blu-ray 4M.
			let hasUrl = r.rate == play.rate || r.rate == rate
			if hasUrl, urls.count > 0 {
				s.url = urls.removeFirst()
				s.src = urls
			}
			return (r.name, s)
		}
    }
    
    func getEncryption(_ did: String) async throws -> DouyuEncryption {
        let url = "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption?did=\(did)"
        let data = try await AccountHTTP.request(url).serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        
        let error: Int = try json.value(for: "error")
        guard error == 0 else {
            throw VideoGetError.douyuSignError
        }
        
        let enc = try DouyuEncryption(object: json)
        return enc
    }
    
    func douyuCDNs(_ info: DouyuH5Play) async throws -> DouyuH5Play {
        guard let url = info.cdnUrl else {
            return info
        }
        
		let data = try await AccountHTTP.request(url).serializingData().value
		let json: JSONObject = try JSONParser.JSONObjectWithData(data)
		
		let sugs: [String] = try json.value(for: "sug")
		let baks: [String] = try json.value(for: "bak")
		var info = info
		info.initP2pUrls(sugs + baks)
		return info
    }
    
    // MARK: - Login
    
    func isLogin() async throws -> (Bool, String) {
        let accounts = SiteAccounts.shared
        guard let account = try await accounts.currentAccount(sourceID: "douyu"), account.enabled else { return (false, "") }
        if AccountHTTP.context?.accountID == account.id { return (account.status == .valid, account.displayName) }
        do {
            let refreshed = try await accounts.refreshStatus(accountID: account.id)
            return (true, refreshed.displayName)
        } catch SiteAccountError.disabled {
            return (false, account.displayName)
        } catch SiteAccountError.expired {
            return (false, account.displayName)
        } catch SiteAccountError.needsLogin {
            return (false, account.displayName)
        }
    }

    func logout() async throws {
        guard let account = try await SiteAccounts.shared.currentAccount(sourceID: "douyu") else { return }
        try await SiteAccounts.shared.signOut(accountID: account.id)
    }

    // Renew the current Douyu account only; it never chooses or rotates identities.
    func renewSessionIfNeeded() async {
        guard AccountHTTP.context?.accountID != nil,
              let url = URL(string: "https://www.douyu.com/"),
              let dyAuth = AccountHTTP.cookies(for: url).first(where: { $0.name == "dy_auth" }),
              let expires = dyAuth.expiresDate,
              expires.timeIntervalSinceNow < 3 * 86_400 else { return }
        do {
            _ = try await AccountHTTP.request("https://passport.douyu.com/index/login?client_id=1")
                .serializingData().value
            try await SiteAccounts.shared.storeCurrentCookies()
        } catch {
            return
        }
    }
    
    func douyuRoomJsonFormatter(_ text: String) -> String? {
        Self.jsonObject(containing: #""NewPcBasicSwitchRoomAdvance""#, in: text)
    }
    
    /// Returns the JSON object that encloses `marker` in a JSON document, without
    /// being confused by braces inside string values or by multi-byte characters.
    private static func jsonObject(containing marker: String, in input: String) -> String? {
        guard let markerRange = input.range(of: marker) else {
            return nil
        }
        
        // Walk up to the marker to find the innermost object that is still open.
        var stack: [String.Index] = []
        var inString = false
        var escaped = false
        var index = input.startIndex
        while index < markerRange.lowerBound {
            let character = input[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                stack.append(index)
            } else if character == "}" {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            }
            index = input.index(after: index)
        }
        
        guard let open = stack.last else {
            return nil
        }
        
        // Then walk to its matching closing brace.
        var depth = 0
        inString = false
        escaped = false
        index = open
        while index < input.endIndex {
            let character = input[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(input[open...index])
                }
            }
            index = input.index(after: index)
        }
        
        return nil
    }
}

struct DouyuInfo: Unmarshaling, LiveInfo {
    var title: String = ""
    var name: String = ""
    var avatar: String
    var isLiving = false
    var cover: String = ""
    var site: SupportSites = .douyu
    
    init(object: MarshaledObject) throws {
        title = try object.value(for: "room.room_name")
        name = try object.value(for: "room.nickname")
        avatar = try object.value(for: "room.avatar.big")
        isLiving = "\(try object.any(for: "room.show_status"))" == "1"
//        isLiving = try object.value(for: "room.show_status") == 1 && object.value(for: "room.videoLoop") != 0
        
        cover = try object.value(for: "room.room_pic")
    }
}

struct DouyuEncryption: Unmarshaling {
    let key: String
    let randStr: String
    let encTime: Int
    let expireAt: Int
    let encData: String
    let isSpecial: Int
    
    init(object: MarshaledObject) throws {
        key = try object.value(for: "data.key")
        randStr = try object.value(for: "data.rand_str")
        encTime = try object.value(for: "data.enc_time")
        expireAt = try object.value(for: "data.expire_at")
        encData = try object.value(for: "data.enc_data")
        isSpecial = try object.value(for: "data.is_special")
    }
    
    func auth(_ rid: String, ts: Int) -> String {
        var u = randStr
        
        for _ in 0..<encTime {
            u = (u + key).md5()
        }
        
        let o = (isSpecial == 1) ? "" : "\(rid)\(ts)"
        
        return (u + key + o).md5()
    }
}

struct DouyuEventRoom: Unmarshaling {
    let roomId: String
    let text: String
    init(object: MarshaledObject) throws {
        if let rid: String = try? object.value(for: "props.onlineRoomId") {
            roomId = rid
        } else if let rid: String = try? object.value(for: "props.liveRoomId") {
            roomId = rid
        } else {
            roomId = ""
            text = ""
            return
        }
        
        text = try object.value(for: "props.text")
    }
}

struct DouyuH5Play: Unmarshaling {
    let roomId: Int
    let rtmpUrl: String
    let rtmpLive: String
    let rate: Int
    let multirates: [Rate]
    
    let flvUrl: String
    let xsString: String?
    let cdnUrl: String?
    
    var p2pUrls = [String]()
    
    struct Rate: Unmarshaling {
        let name: String
        let rate: Int
        let highBit: Int
        let bit: Int
        
        init(object: MarshaledObject) throws {
            name = try object.value(for: "name")
            rate = try object.value(for: "rate")
            highBit = try object.value(for: "highBit")
            bit = try object.value(for: "bit")
        }
    }
    
    struct P2pMeta: Unmarshaling {
        let domain: String
        let delay: Int
        let secret: String
        let time: String
        
        init(object: MarshaledObject) throws {
            domain = try object.value(for: "xp2p_domain")
            delay = try object.value(for: "xp2p_txDelay")
            secret = try object.value(for: "xp2p_txSecret")
            time = try object.value(for: "xp2p_txTime")
        }
    }
    
    init(object: MarshaledObject) throws {
        roomId = try object.value(for: "data.room_id")
        rtmpUrl = try object.value(for: "data.rtmp_url")
        rtmpLive = try object.value(for: "data.rtmp_live")
        multirates = try object.value(for: "data.multirates")
        rate = try object.value(for: "data.rate")
        
        flvUrl = rtmpUrl + "/" + rtmpLive
        
        guard let meta: P2pMeta = try? object.value(for: "data.p2pMeta") else {
            xsString = nil
            cdnUrl = nil
            return
        }
        
        var newRL = rtmpLive.replacingOccurrences(of: "flv", with: "xs").split(separator: "&").map(String.init)
        
        newRL.append(contentsOf: [
            "delay=\(meta.delay)",
            "txSecret=\(meta.secret)",
            "txTime=\(meta.time)",
//            "playid=1646460800000-3082600000",
            "uuid=\(UUID().uuidString)"
        ])
        
        xsString = "\(meta.domain)/live/" + newRL.joined(separator: "&")
        cdnUrl = "https://\(meta.domain)/\(rtmpLive.subString(to: ".")).xs"
    }
    
    mutating func initP2pUrls(_ urls: [String]) {
        guard let str = xsString else { return }
        p2pUrls = urls.map {
            "https://\($0)/" + str
        }
    }
}

