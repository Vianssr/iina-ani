import AppKit

/// The collection is inset inside a shared document, not the scroll view's document itself.
/// Flow layout can redistribute columns using the enclosing clip width on scroll/reload.
/// Keep both item positions and content height in this collection's coordinate system.
@MainActor
final class WorkspaceFeedGridLayout: NSCollectionViewLayout {
    private let density: Int
    private var width: CGFloat = 0
    private var columns = 1
    private var itemSize = NSSize(width: 1, height: 192)
    private var columnStride: CGFloat = 0
    private let spacing: CGFloat = 4
    private let trailingInset: CGFloat = 15

    init(density: Int) {
        self.density = density
        super.init()
        itemSize.height = CGFloat(192 + density * 24)
    }

    required init?(coder: NSCoder) { nil }

    override func prepare() {
        super.prepare()
        guard let newWidth = collectionView?.bounds.width, newWidth > 0, newWidth != width else { return }
        width = newWidth
        let available = max(1, width - trailingInset)
        columns = max(1, Int(available / CGFloat(132 + density * 20)))
        itemSize.width = floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        columnStride = columns > 1 ? (available - itemSize.width) / CGFloat(columns - 1) : 0
    }

    private var itemCount: Int {
        guard let collectionView, collectionView.numberOfSections > 0 else { return 0 }
        return collectionView.numberOfItems(inSection: 0)
    }

    override var collectionViewContentSize: NSSize {
        let rows = (itemCount + columns - 1) / columns
        return NSSize(width: width, height: max(120, CGFloat(rows) * (itemSize.height + spacing) - spacing))
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < itemCount else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = NSRect(
            x: CGFloat(indexPath.item % columns) * columnStride,
            y: CGFloat(indexPath.item / columns) * (itemSize.height + spacing),
            width: itemSize.width, height: itemSize.height)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let count = itemCount
        guard count > 0, !rect.isEmpty, !rect.isNull, rect.maxY > 0 else { return [] }
        let stride = itemSize.height + spacing
        let rows = CGFloat((count + columns - 1) / columns)
        let first = min(count, Int(max(0, min(rows, floor(rect.minY / stride)))) * columns)
        let end = min(count, Int(max(0, min(rows, ceil(rect.maxY / stride)))) * columns)
        guard first < end else { return [] }
        return (first..<end).compactMap { index in
            guard let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
                  attributes.frame.intersects(rect) else { return nil }
            return attributes
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        // An enclosing scroll can pass its wider clip bounds; prepare always uses our own width.
        newBounds.width != width
    }
}

