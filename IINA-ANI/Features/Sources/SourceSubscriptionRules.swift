import Foundation

/// Audited css1 identities and indexed row shapes shared by desktop and mobile.
/// A remote display name or host suffix never establishes a local source identity.
enum SourceSubscriptionRules {
    static let hosts: [String: Set<String>] = [
        "xifan": ["dm1.xfdm.pro"],
        "girigiri": ["ani.girigirilove.com"],
        "didahd": ["www.didahd.pro", "didahd.pro", "www.didahd.xyz", "didahd.xyz"],
        "jibi": ["www.jibi.cc", "jibi.cc"],
        "eacg": ["www.eacg1.com", "eacg1.com"],
        "senfun": ["senfun.in"],
        "fengche": ["www.dongmandaquan.vip", "dongmandaquan.vip"],
        "kanba": ["11kt.net", "www.11kt.net", "qkan8.com", "www.qkan8.com"],
        "haixing": ["www.haixingdmx.com", "haixingdmx.com"],
        "yinghua": ["www.yinghuabb.com", "yinghuabb.com", "www.yinghuaaa.com", "yinghuaaa.com", "www.yinghua2.com", "yinghua2.com"],
        "dilidili": ["dilidili.io", "www.dilidili.io"],
        "youknow": ["www.youknow.tv", "youknow.tv"],
        "fqdm": ["www.fqdm.cc", "fqdm.cc"],
        "hanime1": ["hanime1.me", "www.hanime1.me"],
        "wedm": ["www.vdm5.com", "vdm5.com"],
        "rebo": ["www.rebozj.cc", "rebozj.cc", "www.rebozj.pro", "rebozj.pro"]
    ]
    static let excludedHosts: Set<String> = ["www.hc34567.com", "hc34567.com"]
    static let indexedSelectors: [String: (names: String, links: String)] = [
        "xifan": ("body > .box-width .search-box .thumb-content > .thumb-txt", "body > .box-width .search-box .thumb-menu > a"),
        "girigiri": ("body > .box-width .vod-detail .detail-info .slide-info-title", "body > .box-width .vod-detail .detail-info > a"),
        "hanime1": ("#home-rows-wrapper > div.content-padding-new > div > div > div > div > a > div.title", "#home-rows-wrapper > div.content-padding-new > div > div > div > div > a")
    ]
}
