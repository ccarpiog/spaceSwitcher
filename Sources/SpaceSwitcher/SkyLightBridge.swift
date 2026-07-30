import Foundation

/// Thin, defensive wrapper over the private SkyLight functions used to *read*
/// the Spaces layout.
///
/// SkyLight ships only inside the dyld shared cache, so it cannot be linked
/// against — every symbol is resolved lazily with `dlsym`. Any symbol Apple
/// removes therefore degrades to `nil` here instead of failing to launch, which
/// is the whole point: this is private API and it can disappear in any release.
///
/// Nothing in this type *writes* Space state. `CGSManagedDisplaySetCurrentSpace`
/// is deliberately absent — see CLAUDE.md for why it must not be used.
final class SkyLightBridge {

    /// Shared instance; resolving the symbols once is enough for the process life.
    static let shared = SkyLightBridge()

    // MARK: - C function signatures

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    // MARK: - Resolved symbols

    private let handle: UnsafeMutableRawPointer?
    private let mainConnectionID: MainConnectionIDFn?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let getActiveSpace: GetActiveSpaceFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?

    /// The connection id every other call needs, resolved once at startup.
    let connection: Int32

    /// `true` when every symbol this app depends on was resolved. When `false`
    /// the UI shows an "unsupported macOS version" message rather than
    /// misbehaving.
    var isAvailable: Bool {
        mainConnectionID != nil
            && copyManagedDisplaySpaces != nil
            && getActiveSpace != nil
            && copySpacesForWindows != nil
    }

    /// Selector passed to `CGSCopySpacesForWindows` meaning "all Spaces".
    private static let allSpacesSelector: Int32 = 0x7

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    /// Opens SkyLight and resolves each symbol, tolerating any of them being
    /// missing on a future macOS.
    private init() {
        let library = dlopen(SkyLightBridge.frameworkPath, RTLD_NOW)
        handle = library

        /// Resolves one symbol and reinterprets it as the given C function type.
        ///
        /// Closes over the local `library` rather than the `handle` property:
        /// referencing a stored property here would capture a partially
        /// initialized `self`.
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let library, let ptr = dlsym(library, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }

        mainConnectionID = sym("CGSMainConnectionID", as: MainConnectionIDFn.self)
        copyManagedDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        getActiveSpace = sym("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
        copySpacesForWindows = sym("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)

        connection = mainConnectionID?() ?? 0
    } // End of init(), which opens SkyLight and resolves all private symbols

    // MARK: - Queries

    /// The id of the Space currently displayed.
    ///
    /// Used only to *confirm* that a switch driven by System Events actually
    /// landed. It must never be used to conclude that a private-API write
    /// succeeded — it reports bookkeeping, not what the compositor is showing.
    func activeSpaceID() -> UInt64 {
        getActiveSpace?(connection) ?? 0
    }

    /// The raw per-display Space configuration, one dictionary per display.
    ///
    /// Each entry carries a `"Display Identifier"` and an ordered `"Spaces"`
    /// array. The order matters: it is the order `Ctrl+←`/`Ctrl+→` walks.
    func managedDisplaySpaces() -> [[String: Any]] {
        guard let copyManagedDisplaySpaces,
              let raw = copyManagedDisplaySpaces(connection) as? [[String: Any]]
        else { return [] }
        return raw
    }

    /// The Spaces a given window occupies. A window on more than one Space is
    /// sticky (assigned to "all desktops"), which is why such windows are
    /// ignored when labelling Spaces — they say nothing distinguishing.
    func spaces(forWindowID windowID: Int) -> [UInt64] {
        guard let copySpacesForWindows,
              let raw = copySpacesForWindows(
                  connection,
                  SkyLightBridge.allSpacesSelector,
                  [windowID] as CFArray
              ) as? [UInt64]
        else { return [] }
        return raw
    }
}
