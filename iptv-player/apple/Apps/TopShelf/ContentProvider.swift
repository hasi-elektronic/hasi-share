import Foundation
import os
import TVServices

/// tvOS Top Shelf (Build 17, docs/SCREENS.md §2 TV): "Continue watching" (posters with progress) and "Recently watched"
/// channels (logos). The app writes the content as `TopShelfSnapshot` JSON into the shared Keychain item
/// (`TopShelfStore`) and calls `topShelfContentDidChange()`; selecting or playing an item opens its `novaplayer://`
/// deep link in the app. Nothing stored → nil (the static Top Shelf image of the asset catalog).
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(Self.content())   // one small Keychain read: synchronous
    }

    private static let log = Logger(subsystem: "io.iptvplayer", category: "topshelf")

    static func content() -> (any TVTopShelfContent)? {
        guard let data = TopShelfStore(accessGroup: TopShelfStore.bundleAccessGroup()).read() else {
            log.info("top shelf: no snapshot")
            return nil
        }
        guard let snapshot = TopShelfSnapshot.decode(data), !snapshot.isEmpty else {
            log.info("top shelf: empty snapshot")
            return nil
        }
        log.info("top shelf: \(snapshot.sections.map(\.items.count), privacy: .public) items")
        let sections = snapshot.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = section.items.compactMap(Self.shelfItem)
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func shelfItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem? {
        guard let link = URL(string: item.link) else { return nil }
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = item.title
        switch item.shape {
        case .poster: shelf.imageShape = .poster
        case .square: shelf.imageShape = .square
        case .hdtv: shelf.imageShape = .hdtv
        }
        if let image = item.imageURL.flatMap(URL.init(string:)) {
            shelf.setImageURL(image, for: .screenScale1x)
            shelf.setImageURL(image, for: .screenScale2x)
        }
        if let progress = item.progress { shelf.playbackProgress = progress }
        // Select and Play both open the item in the player (resumed where it was left).
        shelf.displayAction = TVTopShelfAction(url: link)
        shelf.playAction = TVTopShelfAction(url: link)
        return shelf
    }
}
