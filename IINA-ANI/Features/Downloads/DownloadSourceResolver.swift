import Foundation

/// Resolves only the saved episode/quality/line, never a replacement or default account.
struct DownloadSourceResolver: Sendable {
    let decoder: VideoDecoder
    let registry: SourceRegistry
    let accounts: SiteAccounts


    init(decoder: VideoDecoder) {
        self.decoder = decoder
        self.registry = decoder.registry
        self.accounts = decoder.accounts
    }
    func validate(_ selection: PlayableSelection) throws {
        guard selection.classification.kind != .live else { throw DownloadFailure.unsupportedMedia }
        let ref = selection.episode ?? selection.item
        guard let descriptor = registry.descriptor(for: ref.sourceID),
              descriptor.capabilities.contains(.download) else { throw DownloadFailure.unsupportedSource }
        guard ref.sourceID == selection.item.sourceID, [.episode, .video].contains(ref.kind),
              let quality = selection.qualityID, !quality.isEmpty,
              let page = URL(string: ref.pageURL), page.user == nil, page.password == nil else {
            throw DownloadFailure.invalidSelection
        }
        let normalized = try registry.item(for: ref.pageURL)
        guard normalized.sourceID == ref.sourceID, normalized.kind == ref.kind else { throw DownloadFailure.invalidSelection }
    }

    func resolve(_ selection: PlayableSelection) async throws -> DownloadResource {
        try validate(selection)
        return try await accounts.withSource(sourceID: selection.item.sourceID,
                                             accountID: selection.accountID, useDefaultAccount: false) {
            let result = try await decoder.resolve(selection)
            guard let key = selection.qualityID, let stream = result.streams[key], result.audio.isEmpty else {
                throw DownloadFailure.unsupportedMedia
            }
            let line: Int
            if let rawLine = selection.lineID {
                guard let parsed = Int(rawLine) else { throw DownloadFailure.invalidSelection }
                line = parsed
            } else { line = 0 }
            guard line >= 0, line <= stream.src.count else { throw DownloadFailure.invalidSelection }
            let raw = line == 0 ? stream.url : stream.src[line - 1]
            guard let raw, let url = URL(string: raw), url.host != nil, url.user == nil,
                  url.password == nil else { throw DownloadFailure.unsupportedMedia }
            let isOwnedProxy: Bool
            if selection.item.sourceID == "didahd" {
                isOwnedProxy = await DidahdProxy.shared.ownsPlaylist(url)
            } else { isOwnedProxy = false }
            guard url.scheme?.lowercased() == "https" || isOwnedProxy else { throw DownloadFailure.unsupportedMedia }
            let ext = url.pathExtension.lowercased()
            guard ["m3u8", "mp4", "m4v", "mov", "mkv", "webm", "flv"].contains(ext) else {
                throw DownloadFailure.unsupportedMedia
            }
            var context = DownloadRequestContext()
            context.headers["Referer"] = (selection.episode ?? selection.item).pageURL
            context.headers["User-Agent"] = "Mozilla/5.0 IINA-ANI"
            if isOwnedProxy {
                context.allowedHosts = ["127.0.0.1"]
                context.allowLoopbackHTTP = true
                return DownloadResource(url: url, format: .hls, context: context, fileExtension: "mkv")
            }
            if let configuration = registry.source(for: selection.item.sourceID) {
                context.allowedHosts = configuration.anonymousExternalHTTPSMedia ? nil :
                    Set(configuration.hosts + configuration.mediaHosts)
                context.credentialHosts = Set(configuration.credentialHosts)
                try validateConfiguredSourceAccountContext(configuration: configuration,
                                                          sourceID: AccountHTTP.context?.sourceID)
            } else {
                context.credentialHosts = Set(SupportSites(url: selection.item.pageURL).hosts)
            }
            context.cookies = AccountHTTP.context?.cookieStorage.cookies ?? []
            return DownloadResource(url: url, format: ext == "m3u8" ? .hls : .direct,
                                    context: context, fileExtension: ext == "m3u8" ? "mkv" : ext)
        }
    }
}
