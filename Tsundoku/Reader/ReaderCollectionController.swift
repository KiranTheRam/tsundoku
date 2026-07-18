import UIKit

@MainActor
final class ReaderCollectionController: UICollectionViewController, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private let units: [ReaderDisplayUnit]
    private let pages: [BookPage]
    private let book: Book
    private let client: ServerClient?
    private let loader: PageLoader
    private let preferences: ReaderPreferences
    private let initialPage: Int
    private var lastNavigationRequestID: Int
    private var pageReportingState = ReaderPageReportingState()
    private var preloadTask: Task<Void, Never>?
    private var lastPreloadedDisplayIndex: Int?
    private var hasPositionedInitially = false
    var onPageChanged: ((Int) -> Void)?
    var onPageSettled: ((Int) -> Void)?
    var onToggleChrome: (() -> Void)?

    init(
        units: [ReaderDisplayUnit],
        pages: [BookPage],
        book: Book,
        client: ServerClient?,
        loader: PageLoader,
        preferences: ReaderPreferences,
        initialPage: Int,
        initialNavigationRequestID: Int
    ) {
        self.units = ReaderCollectionOrder.displayUnits(units, mode: preferences.mode)
        self.pages = pages
        self.book = book
        self.client = client
        self.loader = loader
        self.preferences = preferences
        self.initialPage = initialPage
        lastNavigationRequestID = initialNavigationRequestID
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = preferences.mode == .verticalContinuous ? .vertical : .horizontal
        layout.minimumLineSpacing = preferences.mode == .verticalContinuous ? preferences.pageGap : 0
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = preferences.mode != .verticalContinuous
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = preferences.mode == .verticalContinuous
        collectionView.delaysContentTouches = false
        collectionView.register(ReaderPageCell.self, forCellWithReuseIdentifier: ReaderPageCell.reuseIdentifier)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        collectionView.addGestureRecognizer(tapGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasPositionedInitially,
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0,
              let index = ReaderInitialPosition.displayIndex(for: initialPage, in: units) else { return }
        // RTL display order starts with the final page at content offset zero.
        // Suppress every visibility callback until layout exists and the
        // collection is physically positioned at the server checkpoint.
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: preferences.mode == .verticalContinuous ? .top : .centeredHorizontally, animated: false)
        collectionView.layoutIfNeeded()
        hasPositionedInitially = true
        // Restoring the server checkpoint is not a reading action. Update the
        // visible-page UI, but don't emit a settled checkpoint (and therefore
        // don't write progress or show a sync toast) until the user navigates.
        report(page: initialPage, settled: false)
        preload(aroundDisplayIndex: index)
    }

    deinit { preloadTask?.cancel() }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { await loader.purgeMemory() }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Previous page", action: #selector(previousUnit), input: UIKeyCommand.inputLeftArrow, modifierFlags: []),
            UIKeyCommand(title: "Next page", action: #selector(nextUnit), input: UIKeyCommand.inputRightArrow, modifierFlags: []),
            UIKeyCommand(title: "Next page", action: #selector(nextUnit), input: " ", modifierFlags: [])
        ]
    }

    func navigate(toPage page: Int, animated: Bool) {
        guard let index = units.firstIndex(where: { $0.segments.contains(where: { $0.pageIndex == page }) }) else { return }
        let visible = collectionView.indexPathsForVisibleItems.contains(IndexPath(item: index, section: 0))
        guard !visible else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: preferences.mode == .verticalContinuous ? .top : .centeredHorizontally,
            animated: animated
        )
    }

    func handleNavigationRequest(id: Int, page: Int) {
        guard id != lastNavigationRequestID else { return }
        lastNavigationRequestID = id
        navigate(toPage: page, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { units.count }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ReaderPageCell.reuseIdentifier, for: indexPath) as! ReaderPageCell
        cell.configure(unit: units[indexPath.item], book: book, client: client, loader: loader, preferences: preferences)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard preferences.mode == .verticalContinuous, let segment = units[indexPath.item].segments.first, pages.indices.contains(segment.pageIndex) else { return collectionView.bounds.size }
        let page = pages[segment.pageIndex]
        let width = collectionView.bounds.width
        return CGSize(width: width, height: max(120, width / max(0.1, page.aspectRatio)))
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasPositionedInitially else { return }
        reportVisiblePage(settled: false)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportVisiblePage(settled: true) }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportVisiblePage(settled: true)
    }

    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportVisiblePage(settled: true)
    }

    private func reportVisiblePage(settled: Bool) {
        let reference = ReaderVisiblePageReference.point(
            bounds: collectionView.bounds,
            contentOffset: collectionView.contentOffset,
            mode: preferences.mode
        )
        let directIndex = collectionView.indexPathForItem(at: reference)?.item
        let nearestIndex = collectionView.indexPathsForVisibleItems.min { lhs, rhs in
            distanceFromReference(for: lhs, reference: reference) < distanceFromReference(for: rhs, reference: reference)
        }?.item
        guard let index = directIndex ?? nearestIndex, units.indices.contains(index) else { return }
        let page = units[index].firstPage
        preload(aroundDisplayIndex: index)

        report(page: page, settled: settled)
    }

    private func report(page: Int, settled: Bool) {
        let changes = pageReportingState.changes(for: page, settled: settled)
        if let visiblePage = changes.visible { onPageChanged?(visiblePage) }
        if let settledPage = changes.settled { onPageSettled?(settledPage) }
    }

    private func distanceFromReference(for indexPath: IndexPath, reference: CGPoint) -> CGFloat {
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath) else {
            return .greatestFiniteMagnitude
        }
        return preferences.mode == .verticalContinuous
            ? abs(attributes.frame.midY - reference.y)
            : abs(attributes.frame.midX - reference.x)
    }

    private func preload(aroundDisplayIndex index: Int) {
        guard index != lastPreloadedDisplayIndex else { return }
        lastPreloadedDisplayIndex = index
        let indexes = ReaderPreloadPlanner.displayIndexes(
            around: index,
            unitCount: units.count,
            mode: preferences.mode
        )
        preloadTask?.cancel()
        let cropPolicy = preferences.cropPolicy
        preloadTask = Task(priority: .utility) { [book, client, loader, units, cropPolicy] in
            let jobs = indexes.enumerated().flatMap { offset, displayIndex -> [(segment: PageSegment, decode: Bool)] in
                guard units.indices.contains(displayIndex) else { return [] }
                return units[displayIndex].segments.map { ($0, offset < 2) }
            }
            await withTaskGroup(of: Void.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<min(3, jobs.count) {
                    guard let job = iterator.next() else { break }
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        if job.decode {
                            _ = try? await loader.image(
                                for: book,
                                segment: job.segment,
                                cropPolicy: cropPolicy,
                                client: client,
                                priority: .prefetch
                            )
                        } else {
                            _ = try? await loader.data(
                                for: book,
                                zeroBasedPage: job.segment.pageIndex,
                                client: client,
                                priority: .prefetch
                            )
                        }
                    }
                }
                while await group.next() != nil {
                    guard let job = iterator.next(), !Task.isCancelled else { continue }
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        if job.decode {
                            _ = try? await loader.image(
                                for: book,
                                segment: job.segment,
                                cropPolicy: cropPolicy,
                                client: client,
                                priority: .prefetch
                            )
                        } else {
                            _ = try? await loader.data(
                                for: book,
                                zeroBasedPage: job.segment.pageIndex,
                                client: client,
                                priority: .prefetch
                            )
                        }
                    }
                }
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let contentX = gesture.location(in: collectionView).x
        let action = ReaderTapNavigation.action(
            mode: preferences.mode,
            x: ReaderTapNavigation.viewportX(contentX: contentX, boundsMinX: collectionView.bounds.minX),
            width: collectionView.bounds.width
        )
        switch action {
        case .previousPage: previousUnit()
        case .nextPage: nextUnit()
        case .toggleChrome: onToggleChrome?()
        }
    }

    @objc private func nextUnit() { moveUnit(by: preferences.mode == .pagedRightToLeft ? -1 : 1) }
    @objc private func previousUnit() { moveUnit(by: preferences.mode == .pagedRightToLeft ? 1 : -1) }

    private func moveUnit(by delta: Int) {
        let current = collectionView.indexPathsForVisibleItems.sorted().first?.item ?? 0
        let destination = min(max(0, current + delta), max(0, units.count - 1))
        collectionView.scrollToItem(at: IndexPath(item: destination, section: 0), at: preferences.mode == .verticalContinuous ? .top : .centeredHorizontally, animated: true)
    }
}

struct ReaderPageReportingState {
    private var lastVisiblePage: Int?
    private var lastSettledPage: Int?

    mutating func changes(for page: Int, settled: Bool) -> (visible: Int?, settled: Int?) {
        let visibleChange = page == lastVisiblePage ? nil : page
        if visibleChange != nil { lastVisiblePage = page }

        let settledChange = settled && page != lastSettledPage ? page : nil
        if settledChange != nil { lastSettledPage = page }
        return (visibleChange, settledChange)
    }
}

enum ReaderTapAction: Equatable {
    case previousPage
    case nextPage
    case toggleChrome
}

enum ReaderTapNavigation {
    static func viewportX(contentX: CGFloat, boundsMinX: CGFloat) -> CGFloat {
        contentX - boundsMinX
    }

    static func action(mode: ReaderMode, x: CGFloat, width: CGFloat) -> ReaderTapAction {
        guard mode != .verticalContinuous, width > 0 else { return .toggleChrome }
        let edgeWidth = min(64, max(44, width * 0.15))
        if x <= edgeWidth {
            return mode == .pagedRightToLeft ? .nextPage : .previousPage
        }
        if x >= width - edgeWidth {
            return mode == .pagedRightToLeft ? .previousPage : .nextPage
        }
        return .toggleChrome
    }
}

enum ReaderCollectionOrder {
    static func displayUnits(_ units: [ReaderDisplayUnit], mode: ReaderMode) -> [ReaderDisplayUnit] {
        mode == .pagedRightToLeft ? Array(units.reversed()) : units
    }
}

enum ReaderInitialPosition {
    static func displayIndex(for page: Int, in units: [ReaderDisplayUnit]) -> Int? {
        units.firstIndex { unit in
            unit.segments.contains { $0.pageIndex == page }
        }
    }
}

enum ReaderVisiblePageReference {
    static func point(bounds: CGRect, contentOffset: CGPoint, mode: ReaderMode) -> CGPoint {
        let x = contentOffset.x + bounds.midX
        guard mode == .verticalContinuous else {
            return CGPoint(x: x, y: contentOffset.y + bounds.midY)
        }

        // Treat a page as current when it reaches a reading line near the top
        // of the viewport. Center-based sampling can skip several short pages
        // and makes a freshly restored checkpoint appear to jump forward.
        let readingLine = min(120, max(1, bounds.height * 0.15))
        return CGPoint(x: x, y: contentOffset.y + readingLine)
    }
}

enum ReaderPreloadPlanner {
    /// Keeps two pages behind and six pages in the direction the reader advances.
    /// Display units are reversed for RTL, so its forward direction is negative.
    static func displayIndexes(
        around current: Int,
        unitCount: Int,
        mode: ReaderMode,
        aheadCount: Int = 6,
        behindCount: Int = 2
    ) -> [Int] {
        guard unitCount > 0, (0..<unitCount).contains(current) else { return [] }
        let forward = mode == .pagedRightToLeft ? -1 : 1
        var result: [Int] = []
        if aheadCount > 0 {
            for distance in 1...aheadCount {
                let index = current + distance * forward
                if (0..<unitCount).contains(index) { result.append(index) }
            }
        }
        if behindCount > 0 {
            for distance in 1...behindCount {
                let index = current - distance * forward
                if (0..<unitCount).contains(index) { result.append(index) }
            }
        }
        return result
    }
}

@MainActor
private final class ReaderPageCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseIdentifier = "ReaderPageCell"
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var loadTasks: [Task<Void, Never>] = []
    fileprivate var configurationID = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        contentView.addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor), scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor), stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
        configurationID = UUID()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scrollView.zoomScale = 1
    }

    func configure(unit: ReaderDisplayUnit, book: Book, client: ServerClient?, loader: PageLoader, preferences: ReaderPreferences) {
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
        let configurationID = UUID()
        self.configurationID = configurationID
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let pageViews = unit.segments.map { _ -> ReaderPageImageView in
            let view = ReaderPageImageView()
            stack.addArrangedSubview(view)
            return view
        }
        loadTasks = zip(unit.segments, pageViews).map { segment, pageView in
            let progressRelay = ReaderPageProgressRelay(cell: self, pageView: pageView, configurationID: configurationID)
            return Task { [weak self, weak pageView] in
                do {
                    let image = try await loader.image(
                        for: book,
                        segment: segment,
                        cropPolicy: preferences.cropPolicy,
                        client: client,
                        priority: .visible,
                        progress: { fraction in progressRelay.update(fraction) }
                    )
                    guard !Task.isCancelled, self?.configurationID == configurationID else { return }
                    if let image { pageView?.show(image: image) }
                    else { pageView?.showFailure() }
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.configurationID == configurationID else { return }
                    pageView?.showFailure()
                }
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { stack }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 { scrollView.setZoomScale(1, animated: true); return }
        let point = gesture.location(in: stack)
        let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}

private final class ReaderPageProgressRelay: @unchecked Sendable {
    private weak var cell: ReaderPageCell?
    private weak var pageView: ReaderPageImageView?
    private let configurationID: UUID

    @MainActor
    init(cell: ReaderPageCell, pageView: ReaderPageImageView, configurationID: UUID) {
        self.cell = cell
        self.pageView = pageView
        self.configurationID = configurationID
    }

    nonisolated func update(_ fraction: Double?) {
        Task { @MainActor [self] in
            guard cell?.configurationID == configurationID else { return }
            pageView?.showProgress(fraction)
        }
    }
}

@MainActor
private final class ReaderPageImageView: UIView {
    private let imageView = UIImageView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        label.text = "Loading page…"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        progressView.progressTintColor = .white
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        [imageView, progressView, spinner, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 10),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Loading page"
        showProgress(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showProgress(_ fraction: Double?) {
        imageView.image = nil
        progressView.isHidden = fraction == nil
        if let fraction {
            spinner.stopAnimating()
            progressView.setProgress(Float(fraction), animated: true)
            let percentage = Int((fraction * 100).rounded())
            label.text = "Loading page… \(percentage)%"
            accessibilityValue = "\(percentage) percent"
        } else {
            spinner.startAnimating()
            label.text = "Loading page…"
            accessibilityValue = nil
        }
    }

    func show(image: UIImage) {
        imageView.image = image
        progressView.isHidden = true
        spinner.stopAnimating()
        label.isHidden = true
        isAccessibilityElement = false
    }

    func showFailure() {
        progressView.isHidden = true
        spinner.stopAnimating()
        label.isHidden = false
        label.text = "Page couldn't be loaded"
        accessibilityLabel = "Page couldn't be loaded"
        accessibilityValue = nil
    }
}
