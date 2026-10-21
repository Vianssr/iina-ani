//
//  Bilibili.swift
//  iina+
//
//  Created by xjbeta on 2018/8/6.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Foundation
import Alamofire
import Marshal
import CommonCrypto
import CryptoSwift

actor Bilibili {
    
    static let shared = Bilibili()
    lazy var bangumi = BiliBangumi()
    lazy var live = BiliLive()
    lazy var video = BiliVideo()
    
    let bangumiUA = "Mozilla/5.0 (X11; Linux x86_64; rv:38.0) Gecko/20100101 Firefox/38.0 Iceweasel/38.2.1"
    let bilibiliUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5.1 Safari/605.1.15"
    
    private var wbiKeys: [String: (img: String, sub: String)] = [:]
    private var wbiRefreshDates: [String: Date] = [:]
    
    enum BilibiliApiError: Error {
        case biliCSRFNotFound
    }
    
    enum BilibiliFnval: Int {
        case flv = 0
        case mp4 = 1
        case dashH265 = 16
        case hdr = 64
        case dash4K = 128
        case dolbyAudio = 256
        case dolbyVideo = 512
        case dash8K = 1024
        case dashAV1 = 2048
    }
    
    func setBilibiliQuality() {
        let properties: [HTTPCookiePropertyKey: String] = [
            .name: "CURRENT_QUALITY", .value: "125", .domain: ".bilibili.com", .path: "/"
        ]
        guard let cookie = HTTPCookie(properties: properties),
              let jar = AccountHTTP.context?.cookieStorage else { return }
        jar.setCookie(cookie)
    }
    
    func bilibiliPlayUrl(yougetJson: YouGetJSON,
                         _ isBangumi: Bool = false,
                         _ qn: Int = 132) async throws -> YouGetJSON {
        var yougetJson = yougetJson
        let cid = yougetJson.id
        
        let allowFlv = true
        let dashSymbol = true
        let inner = false
        
        let fnval = allowFlv ? dashSymbol ? inner ? BilibiliFnval.dashH265.rawValue : BilibiliFnval.dashAV1.rawValue + BilibiliFnval.dash8K.rawValue + BilibiliFnval.dolbyVideo.rawValue + BilibiliFnval.dolbyAudio.rawValue + BilibiliFnval.dash4K.rawValue + BilibiliFnval.hdr.rawValue + BilibiliFnval.dashH265.rawValue : BilibiliFnval.flv.rawValue : BilibiliFnval.mp4.rawValue
        
        
        var u = isBangumi ?
        "https://api.bilibili.com/pgc/player/web/playurl?" :
        "https://api.bilibili.com/x/player/playurl?"
        
        u += "cid=\(cid)&bvid=\(yougetJson.bvid)&qn=\(qn)&fnver=0&fnval=\(fnval)&fourk=1"
        
        let headers = HTTPHeaders(["Referer": "https://www.bilibili.com/",
                                   "User-Agent": isBangumi ? bangumiUA : bilibiliUA])
        
        
        let data = try await AccountHTTP.request(u, headers: headers).serializingData().value
        
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        
        let code: Int = try json.value(for: "code")
        if code == -10403 {
            throw VideoGetError.needVip
        }
        
        let key = isBangumi ? "result" : "data"
        
        
        do {
            let info: BilibiliPlayInfo = try json.value(for: key)
            yougetJson = info.write(to: yougetJson)
        } catch {
            Log("Bilibili fallback simple play info \(error)")
            let info: BilibiliSimplePlayInfo = try json.value(for: key)
            yougetJson = info.write(to: yougetJson)
        }
        
        return yougetJson
    }
    
    
    // https://github.com/SocialSisterYi/bilibili-API-collect/blob/f1001353f83e12e018ae6bc42fa73654986eb544/docs/misc/sign/wbi.md#swift
    
    func biliWbiSign(param: String, wbiImg: String, wbiSub: String) -> String {
        func getMixinKey(orig: String) -> String {
            String(mixinKeyEncTab.map { orig[orig.index(orig.startIndex, offsetBy: $0)] }.prefix(32))
        }
        
        func encWbi(params: [String: Any], imgKey: String, subKey: String) -> [String: Any] {
            var params = params
            let mixinKey = getMixinKey(orig: imgKey + subKey)
            let currTime = Int(Date().timeIntervalSince1970)
            params["wts"] = currTime
            
            let query = params.sorted {
                $0.key < $1.key
            }.map { (key, value) -> String in
                let stringValue: String
                
                if let doubleValue = value as? Double, doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                    stringValue = String(Int(doubleValue))
                } else {
                    stringValue = String(describing: value)
                }
                
                let filteredValue = stringValue.filter { !"!'()*".contains($0) }
                
                return "\(key)=\(filteredValue)"
            }.joined(separator: "&")
            
            let wbiSign = (query + mixinKey).md5()
            params["w_rid"] = wbiSign
            
            return params
        }
        
        let mixinKeyEncTab = [
            46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
            33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
            61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
            36, 20, 34, 44, 52
        ]
        
        let spdParam = param.components(separatedBy: "&")
        var spdDicParam = [String: String]()
        for pair in spdParam {
            let components = pair.components(separatedBy: "=")
            if components.count == 2 {
                spdDicParam[components[0]] = components[1]
            }
        }
        
        let signedParams = encWbi(params: spdDicParam, imgKey: wbiImg, subKey: wbiSub)
        return signedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
    
    // MARK: - Account
    
    func isLogin() async throws -> (Bool, String) {
        let accounts = SiteAccounts.shared
        var status = (false, "")
        if let account = try await accounts.currentAccount(sourceID: "bilibili"), account.enabled {
            do {
                if AccountHTTP.context?.accountID == account.id {
                    status = (account.status == .valid, account.displayName)
                } else {
                    let refreshed = try await accounts.refreshStatus(accountID: account.id)
                    status = (true, refreshed.displayName)
                }
            } catch SiteAccountError.expired {
                status = (false, account.displayName)
            } catch SiteAccountError.needsLogin {
                status = (false, account.displayName)
            } catch SiteAccountError.disabled {
                status = (false, account.displayName)
            }
        }
        return status
    }

    private func readNavigation() async throws -> (isLogin: Bool, name: String, keys: (img: String, sub: String)?) {
        let data = try await AccountHTTP.request("https://api.bilibili.com/x/web-interface/nav").serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        let loggedIn: Bool = try json.value(for: "data.isLogin")
        let name: String = (try? json.value(for: "data.uname")) ?? ""
        let image: String? = try? json.value(for: "data.wbi_img.img_url")
        let sub: String? = try? json.value(for: "data.wbi_img.sub_url")
        let keys: (img: String, sub: String)? = {
            guard let image, let sub,
                  let imgKey = URL(string: image)?.deletingPathExtension().lastPathComponent,
                  let subKey = URL(string: sub)?.deletingPathExtension().lastPathComponent else { return nil }
            return (imgKey, subKey)
        }()
        return (loggedIn, name, keys)
    }

    func logout() async throws {
        guard let account = try await SiteAccounts.shared.currentAccount(sourceID: "bilibili") else { return }
        try await SiteAccounts.shared.signOut(accountID: account.id)
    }

    func getUid() async throws -> Int {
        let data = try await AccountHTTP.request("https://api.bilibili.com/x/web-interface/nav").serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        return try json.value(for: "data.mid")
    }

    func wbiSign(_ param: String) async throws -> String {
        if AccountHTTP.context != nil { return try await wbiSignInCurrentSession(param) }
        return try await SiteAccounts.shared.withSource(sourceID: "bilibili-live") {
            try await self.wbiSignInCurrentSession(param)
        }
    }

    private func wbiSignInCurrentSession(_ param: String) async throws -> String {
        let identity = AccountHTTP.context?.accountID?.uuidString ?? "guest"
        let now = Date()
        var needsRefresh = wbiKeys[identity] == nil
        if let lastRefresh = wbiRefreshDates[identity] {
            var calendar = Calendar.current
            if let timezone = TimeZone(identifier: "Asia/Shanghai") { calendar.timeZone = timezone }
            needsRefresh = !calendar.isDate(lastRefresh, inSameDayAs: now)
        }
        if needsRefresh {
            let navigation = try await readNavigation()
            if let keys = navigation.keys {
                wbiKeys[identity] = keys
                wbiRefreshDates[identity] = now
            }
        }
        guard let keys = wbiKeys[identity] else { return "" }
        return biliWbiSign(param: param, wbiImg: keys.img, wbiSub: keys.sub)
    }
    
    func dynamicList(_ uid: Int,
                     _ action: BilibiliDynamicAction = .init😅,
                     _ dynamicID: Int = -1) async throws -> [BilibiliCard] {
        
        var http: DataRequest
        let headers = HTTPHeaders(["referer": "https://www.bilibili.com/"])
        
        
        switch action {
        case .init😅:
            http = AccountHTTP.request("https://api.vc.bilibili.com/dynamic_svr/v1/dynamic_svr/dynamic_new?uid=\(uid)&type=8", headers: headers)
        case .history:
            http = AccountHTTP.request("https://api.vc.bilibili.com/dynamic_svr/v1/dynamic_svr/dynamic_history?uid=\(uid)&offset_dynamic_id=\(dynamicID)&type=8", headers: headers)
        case .new:
            http = AccountHTTP.request("https://api.vc.bilibili.com/dynamic_svr/v1/dynamic_svr/dynamic_new?uid=\(uid)&current_dynamic_id=\(dynamicID)&type=8", headers: headers)
        }
        
        let data = try await http.serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        let cards: [BilibiliCard]? = try? json.value(for: "data.cards")
        return cards ?? []
    }
    
    func getPvideo(_ aid: Int) async throws -> BilibiliPvideo {
        let data = try await AccountHTTP.request("https://api.bilibili.com/x/player/videoshot?aid=\(aid)&index=1").serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)
        return try BilibiliPvideo(object: json)
    }
}

struct BilibiliCard: Unmarshaling, Sendable, Hashable {
    var aid: Int = 0
    var bvid: String = ""
    var dynamicId: Int = 0
    var title: String = ""
    var picUrl: String = ""
    var name: String = ""
    var duration: TimeInterval = 0
    var views: Int = 0
    var videos: Int = 0
    
    init(object: any Marshal.MarshaledObject) throws {
        dynamicId = try object.value(for: "desc.dynamic_id")
        bvid = try object.value(for: "desc.bvid")
        let jsonStr: String = try object.value(for: "card")
        if let data = jsonStr.data(using: .utf8) {
            let json: JSONObject = try JSONParser.JSONObjectWithData(data)
            aid = try json.value(for: "aid")
            title = try json.value(for: "title")
            let picUrl: String = try json.value(for: "pic")
            self.picUrl = picUrl.https()
            duration = try json.value(for: "duration")
            name = try json.value(for: "owner.name")
            views = try json.value(for: "stat.view")
            videos = try json.value(for: "videos")
        }
    }
}

enum BilibiliDynamicAction {
    case init😅, new, history
}

struct BilibiliPvideo: Unmarshaling, Sendable, Hashable {
    var images: [String] = []
    var xLen: Int = 0
    var yLen: Int = 0
    var xSize: Int = 0
    var ySize: Int = 0
    var imagesCount: Int = 0
    
    enum CropImagesError: Error {
        case zeroImagesCount
    }
    
    init(object: MarshaledObject) throws {
        let imageStrs: [String] = try object.value(for: "data.image")

        let indexs: [Int] = try object.value(for: "data.index")
        imagesCount = indexs.count
        // limit image count for performance
        if imagesCount > 100 {
            imagesCount = 100
        } else if imagesCount == 0 {
            throw CropImagesError.zeroImagesCount
        }

        if let imageStr = imageStrs.first {
            images = ["https:" + imageStr]
        }
        
        xLen = try object.value(for: "data.img_x_len")
        yLen = try object.value(for: "data.img_y_len")
        xSize = try object.value(for: "data.img_x_size")
        ySize = try object.value(for: "data.img_y_size")
    }
}

struct BilibiliUrl {
    var p = 1
    var id = ""
    var urlType = UrlType.unknown
    
    var fUrl: String {
        get {
            var u = "https://www.bilibili.com/"
            
            switch urlType {
            case .video:
                u += "video/\(id)"
            case .bangumi:
                u += "bangumi/play/\(id)"
            default:
                return ""
            }
            
            if p > 1 {
                u += "?p=\(p)"
            }
            return u
        }
    }
    
    enum UrlType: String {
        case video, bangumi, unknown
    }

    func episodeIndex(in leaves: [VideoTreeNode]) throws -> Int {
        guard urlType == .bangumi, !leaves.isEmpty else { throw VideoGetError.notFountData }
        if id.hasPrefix("ss") { return 0 } // Series URLs have no explicit episode choice.
        guard let index = leaves.firstIndex(where: { "ep" + $0.id == id }) else {
            throw VideoGetError.notFountData
        }
        return index
    }
    
    init?(url: String) {
        guard url != "",
              let comps = URLComponents(string: url),
              SupportSites.isBilibiliHost(comps.host),
              let uc = URLComponents(string: url) else {
                  return nil
              }
        
        let pcs = comps.path.split(separator: "/").map(String.init)
        
        guard let id = pcs.first(where: {
            $0.starts(with: "av")
            || $0.starts(with: "BV")
            || $0.starts(with: "ep")
            || $0.starts(with: "ss")
        }) else {
            return nil
        }
        self.id = id
        
        if pcs.contains(UrlType.video.rawValue) {
            urlType = .video
        } else if pcs.contains(UrlType.bangumi.rawValue) {
            urlType = .bangumi
        } else {
            urlType = .unknown
        }
        
        let pStr = uc.queryItems?.first {
            $0.name == "p"
        }?.value ?? "1"
        p = Int(pStr) ?? 1
    }
    
}

struct BilibiliPlayInfo: Unmarshaling {
    let dash: BilibiliDash
    var qualityDescription = [Int: String]()
    
    struct Durl: Unmarshaling {
        let url: String
        let backupUrls: [String]
        let length: Int
        init(object: MarshaledObject) throws {
            url = try object.value(for: "url")
            let urls: [String]? = try object.value(for: "backup_url")
            backupUrls = urls ?? []
            length = try object.value(for: "length")
        }
    }
    
    init(object: MarshaledObject) throws {
        dash = try object.value(for: "dash")
        
        let acceptQuality: [Int] = try object.value(for: "accept_quality")
        let acceptDescription: [String] = try object.value(for: "accept_description")
        
        var descriptionDic = [Int: String]()
        acceptQuality.enumerated().forEach {
            descriptionDic[$0.element] = acceptDescription[$0.offset]
        }
        
        qualityDescription = descriptionDic
    }
    
    func write(to yougetJson: YouGetJSON) -> YouGetJSON {
        var yougetJson = yougetJson
        yougetJson.duration = dash.duration
        yougetJson.audio = dash.preferAudio()?.url ?? ""
        
        qualityDescription.forEach {
            let id = $0.key
            guard let video = dash.preferVideo(id) else {
                var s = Stream(url: "")
                s.quality = id
                yougetJson.streams[$0.value] = s
                return
            }
            
            var stream = Stream(url: video.url)
            stream.src = video.backupUrl
            stream.quality = $0.key
            stream.dashContent = dash.dashContent($0.key)
            yougetJson.streams[$0.value] = stream
        }
        
        return yougetJson
    }
}

struct BilibiliSimplePlayInfo: Unmarshaling {
    let duration: Int
    let descriptions: [Int: String]
    let quality: Int
    let durl: [BilibiliPlayInfo.Durl]
    
    init(object: MarshaledObject) throws {
        let acceptQuality: [Int] = try object.value(for: "accept_quality")
        let acceptDescription: [String] = try object.value(for: "accept_description")
        
        var descriptionDic = [Int: String]()
        acceptQuality.enumerated().forEach {
            descriptionDic[$0.element] = acceptDescription[$0.offset]
        }
        descriptions = descriptionDic
        
        quality = try object.value(for: "quality")
        durl = try object.value(for: "durl")
        let timelength: Int = try object.value(for: "timelength")
        duration = Int(timelength / 1000)
    }
    
    func write(to yougetJson: YouGetJSON) -> YouGetJSON {
        var yougetJson = yougetJson
        yougetJson.duration = duration
        var dic = descriptions
        if yougetJson.streams.count == 0 {
            dic = dic.filter {
                $0.key <= quality
            }
        }
        
        dic.forEach {
            var stream = yougetJson.streams[$0.value] ?? Stream(url: "")
            if $0.key == quality,
                let durl = durl.first {
                var urls = durl.backupUrls
                urls.append(durl.url)
                urls = MBGA.update(urls)
                
                stream.url = urls.removeFirst()
                stream.src = urls
            }
            stream.quality = $0.key
            yougetJson.streams[$0.value] = stream
        }
        
        return yougetJson
    }
}
