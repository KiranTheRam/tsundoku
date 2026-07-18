import SwiftUI

struct ReaderHost: UIViewControllerRepresentable {
    let units: [ReaderDisplayUnit]
    let pages: [BookPage]
    let book: Book
    let client: ServerClient?
    let loader: PageLoader
    let preferences: ReaderPreferences
    let initialPage: Int
    let navigationRequestID: Int
    let onPageChanged: (Int) -> Void
    let onPageSettled: (Int) -> Void
    let onToggleChrome: () -> Void

    func makeUIViewController(context: Context) -> ReaderCollectionController {
        let controller = ReaderCollectionController(
            units: units,
            pages: pages,
            book: book,
            client: client,
            loader: loader,
            preferences: preferences,
            initialPage: initialPage,
            initialNavigationRequestID: navigationRequestID
        )
        controller.onPageChanged = onPageChanged
        controller.onPageSettled = onPageSettled
        controller.onToggleChrome = onToggleChrome
        return controller
    }

    func updateUIViewController(_ controller: ReaderCollectionController, context: Context) {
        controller.onPageChanged = onPageChanged
        controller.onPageSettled = onPageSettled
        controller.onToggleChrome = onToggleChrome
        controller.handleNavigationRequest(id: navigationRequestID, page: initialPage)
    }
}
