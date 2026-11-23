import Observation

/// Caches a value derived from SwiftData models (e.g. decoded JSON blobs) so that a view does not recompute
/// it on every render. The value is recomputed lazily after any model property that `compute` read changes,
/// or when `key` changes.
///
///     @State private var cache = DerivedValue<Summary>()
///     … let summary = cache.value(key: model.id) { Summary(model) }
@MainActor
@Observable
final class DerivedValue<Value> {
    @ObservationIgnored private var stored: Value?
    @ObservationIgnored private var storedKey: AnyHashable?
    /// Read by views through `value`, so that they re-render after an invalidation.
    private var generation = 0

    nonisolated init() {}

    func value(key: AnyHashable = 0, _ compute: () -> Value) -> Value {
        _ = generation
        if let stored, storedKey == key { return stored }
        let computed = withObservationTracking {
            compute()
        } onChange: { [weak self] in
            // Fires before the change is applied; the hop to the main actor lets it finish first.
            Task { @MainActor in self?.invalidate() }
        }
        stored = computed
        storedKey = key
        return computed
    }

    private func invalidate() {
        stored = nil
        generation += 1
    }
}
