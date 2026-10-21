import AppKit

@MainActor
private final class FeedItems: NSObject, NSCollectionViewDataSource {
    var count = 24
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: .init("card"), for: indexPath)
    }
}

@MainActor
private final class FeedCard: NSCollectionViewItem {
    override func loadView() { view = NSView() }
}

@MainActor
private final class FeedDocument: NSView {
    override var isFlipped: Bool { true }
}

@main
struct WorkspaceFeedGridRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 776, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        window.contentView!.addSubview(scroll)
        let document = FeedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let cards = NSCollectionView()
        cards.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cards)
        let height = cards.heightAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cards.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            cards.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            cards.topAnchor.constraint(equalTo: document.topAnchor, constant: 100),
            cards.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -40), height,
        ])
        let source = FeedItems()
        let layout = WorkspaceFeedGridLayout(density: 0)
        cards.collectionViewLayout = layout
        cards.register(FeedCard.self, forItemWithIdentifier: .init("card"))
        cards.dataSource = source
        window.contentView!.layoutSubtreeIfNeeded()

        func settle() {
            window.contentView!.layoutSubtreeIfNeeded()
            layout.prepare()
            height.constant = layout.collectionViewContentSize.height
            window.contentView!.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        func frames(_ count: Int) -> [NSRect] {
            (0..<count).map { layout.layoutAttributesForItem(at: .init(item: $0, section: 0))!.frame }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        cards.reloadData()
        settle()
        let initial = frames(24)
        expect(initial[4].maxX == cards.bounds.width - 15, "Full row must retain the trailing inset")
        expect(initial[5].minX == 0 && initial[5].minY > initial[4].minY, "Items must wrap at the collection width")
        // Outer clip width is 20 pt wider. Scrolling previously redistributed every row by up to 20 pt.
        for count in [24, 48, 72] {
            source.count = count
            cards.reloadData()
            settle()
            for y in [300.0, 0.0, 600.0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle()
                expect(frames(24) == initial, "Scroll or pagination moved existing cards")
                let last = layout.layoutAttributesForItem(at: .init(item: count - 1, section: 0))!.frame
                expect(last.maxY == layout.collectionViewContentSize.height, "Content height must include the last partial row")
            }
        }
        let query = NSRect(x: 0, y: 197, width: 756, height: 190)
        let visible = layout.layoutAttributesForElements(in: query)
        expect(visible.compactMap { $0.indexPath?.item } == Array(5..<10), "Visible rect must return only intersecting cards")
        expect(layout.layoutAttributesForElements(in: NSRect(x: 0, y: -100, width: 756, height: 50)).isEmpty,
            "Rect above content must be empty")
        expect(layout.layoutAttributesForElements(in: .infinite).count == source.count,
            "Unbounded queries must include every card without overflowing row indices")

        window.setContentSize(NSSize(width: 1096, height: 600))
        settle()
        expect(frames(24)[0].width != initial[0].width, "Real width changes must update card widths")
        expect(frames(24)[7].maxX == cards.bounds.width - 15, "Resized full row must retain trailing inset")
        expect(frames(24)[8].minX == 0, "Resize must update the column count")
        let resized = frames(24)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        expect(frames(24) == resized, "Resized grid must remain stable on scroll")

        let dense = WorkspaceFeedGridLayout(density: 1)
        cards.collectionViewLayout = dense
        cards.reloadData()
        window.contentView!.layoutSubtreeIfNeeded()
        dense.prepare()
        expect(dense.layoutAttributesForItem(at: .init(item: 0, section: 0))!.frame.height == 216,
            "Density change must update card height")
        source.count = 0
        cards.reloadData()
        dense.prepare()
        expect(dense.layoutAttributesForElements(in: cards.bounds).isEmpty, "Empty data must not retain old cards")
        expect(dense.collectionViewContentSize.height == 120, "Empty feed must retain its minimum height")
        window.orderOut(nil)
        print("PASS: shared-scroll pagination, partial rows, visible ranges, resize, density and empty feed")
    }
}
