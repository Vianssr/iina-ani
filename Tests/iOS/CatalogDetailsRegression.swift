import Foundation

private actor DetailResponseGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func result() async -> String {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ value: String) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

enum CatalogDetailsRegression {
    private static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Accepted incorrect detail identity or pagination") } catch {}
    }

    @MainActor static func run() async throws {
        let oldFixture = try JSONDecoder().decode(Anime.self, from: Data(#"{"id":42,"name":"Original"}"#.utf8))
        precondition(oldFixture.platform == nil)
        let withPlatform = try JSONDecoder().decode(Anime.self, from: Data(#"{"id":42,"name":"Original","platform":"TV"}"#.utf8))
        precondition(withPlatform.platform == "TV")
        precondition(Anime(id: 42, name: "Original").platform == nil)
        let person = try JSONDecoder().decode(MobilePersonDetail.self, from: Data(#"{"id":7,"name":"Character","summary":"Real introduction","infobox":[{"key":"别名","value":[{"k":"English","v":"Name"}]},{"key":"Unknown","value":false}]}"#.utf8))
        precondition(person.summary == "Real introduction")
        precondition(person.infobox?.map { $0.value.text } == ["English: Name", ""])
        let relations = try JSONDecoder().decode([MobileRelatedWork].self, from: Data(#"[{"id":9,"name":"Next","type":2,"relation":"续集"}]"#.utf8))
        precondition(relations[0].anime.id == 9 && relations[0].anime.title == "Next")
        let people = try JSONDecoder().decode([MobileCatalogPerson].self, from: Data(#"[{"id":7,"name":"Character","relation":"主角","actors":[{"id":8,"name":"Actor"}]}]"#.utf8))
        precondition(people[0].actors?.first?.id == 8 && people[0].id == 7)

        let html = """
        <div id="headerSubject"><h1><a href="/subject/42">Work</a></h1></div>
        <div id="comment_box">
          <div class="item"><div class="text"><a class="l" href="/user/alice">Alice</a>
          <small class="grey">@ Today</small><span class="starlight stars8"></span>
          <p class="comment">First &amp; readable</p><div class="likes_grid" id="likes_grid_123"></div></div></div>
          <div class="item"><div class="text"><a class="l" href="/user/alice">Alice</a>
          <p class="comment">Duplicate</p><div class="likes_grid" id="likes_grid_123"></div></div></div>
        </div>
        <div class="page_inner"><span class="p_cur">1</span>
          <a class="p" href="?page=2">Next</a><a class="p" href="?page=9">Last</a>
          <a class="p" href="?page=2&amp;interest_type=collections">Filtered</a>
          <a class="p" href="/subject/99/comments?page=2">Wrong work</a>
        </div>
        """
        let first = try MobileCatalogDetailClient.parseComments(html, subjectID: 42, page: 1)
        precondition(first.data.count == 1 && first.data[0].id == "42:likes_grid_123")
        precondition(first.data[0].rating == 8 && first.data[0].text == "First & readable")
        precondition(first.nextPage == 2)
        rejects { _ = try MobileCatalogDetailClient.parseComments(html, subjectID: 99, page: 1) }
        rejects { _ = try MobileCatalogDetailClient.parseComments(html, subjectID: 42, page: 2) }
        rejects { _ = try MobileCatalogDetailClient.parseComments("<form id='challenge-form'></form>", subjectID: 42, page: 1) }
        rejects { _ = try MobileCatalogDetailClient.parseComments("<div id='comment_box'><div class='item'></div></div>", subjectID: 42, page: 1) }
        let emptyHTML = "<div id='headerSubject'><h1><a href='/subject/42'>Work</a></h1></div><div id='comment_box'></div><div class='page_inner'><a class='p' href='?page=2'>Next</a></div>"
        let empty = try MobileCatalogDetailClient.parseComments(emptyHTML, subjectID: 42, page: 1)
        rejects { _ = try MobileCatalogDetailClient.parseComments(emptyHTML, subjectID: 42, page: 2) }
        precondition(empty.data.isEmpty && empty.nextPage == nil)
        let feed = try MobileCommentFeed.appending(first, to: nil, requestedPage: 1)
        let new = MobileCatalogComment(id: "42:new", author: "Bob", text: "Second", dateText: "", rating: nil)
        let second = MobileCatalogCommentPage(data: first.data + [new], page: 2, nextPage: nil)
        let complete = try MobileCommentFeed.appending(second, to: feed, requestedPage: 2)
        precondition(complete.comments.count == 2 && complete.nextPage == nil)
        rejects { _ = try MobileCommentFeed.appending(second, to: feed, requestedPage: 1) }
        rejects { _ = try MobileCommentFeed.appending(second, to: nil, requestedPage: 2) }
        rejects { _ = try MobileCommentFeed.appending(MobileCatalogCommentPage(data: [], page: 2, nextPage: 5), to: feed, requestedPage: 2) }

        let resource = MobileDetailResource<String>()
        let gate = DetailResponseGate()
        let obsolete = resource.load { await gate.result() }
        await gate.waitUntilRequested()
        let current = resource.load { "Current work" }
        await current.value
        await gate.release("Old work")
        await obsolete.value
        precondition(resource.value == "Current work" && !resource.loading && !resource.failed)

        let failed = resource.load { throw URLError(.notConnectedToInternet) }
        await failed.value
        precondition(resource.failed && resource.value == "Current work")
        let retry = resource.load { "Retried" }
        await retry.value
        precondition(resource.value == "Retried" && !resource.failed)

        let lateFailureGate = DetailResponseGate()
        let cancelled = resource.load {
            _ = await lateFailureGate.result()
            throw URLError(.timedOut)
        }
        await lateFailureGate.waitUntilRequested()
        resource.cancel()
        precondition(resource.cancelled && !resource.loading)
        await lateFailureGate.release("ignored")
        await cancelled.value
        precondition(resource.cancelled && !resource.failed && resource.value == "Retried")
        print("iOS detail decoding, public comments, pagination, retry and cancellation regressions passed")
    }
}
