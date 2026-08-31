//
//  AnsiColorMapper.swift
//  SwiftTerm
//
//  Host-supplied remapping of resolved foreground/background color pairs.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
/// The platform's native color type, as used by SwiftTerm's rendering hooks.
public typealias TerminalNativeColor = NSColor
#else
import UIKit
/// The platform's native color type, as used by SwiftTerm's rendering hooks.
public typealias TerminalNativeColor = UIColor
#endif

/// A host-supplied remapping of the foreground/background color pair SwiftTerm
/// resolved for a cell.
///
/// Set an implementation on ``TerminalView/ansiColorPairMapper`` to enable the
/// feature; the default of `nil` leaves rendering unchanged. The mapper is
/// consulted once per distinct ``Attribute`` per render context, after the
/// palette lookup, after the `inverse` swap, and after the `dim` blend — so it
/// sees the exact pair that would otherwise be drawn, and a mapper that returns
/// `nil` is indistinguishable from having no mapper at all.
///
/// Seeing both colors together is the point: contrast fixes, theme overrides
/// and accessibility adjustments all need to know what the foreground is being
/// drawn *against*, which a per-color hook cannot express.
///
/// Implementations must be thread-safe: the render pipeline may call them from
/// a dedicated render thread. They must also be pure with respect to their
/// inputs — results are cached per attribute for as long as ``generation`` and
/// the surrounding render context are unchanged, so a mapper that varies its
/// answer for equal inputs will appear to apply intermittently.
public protocol TerminalAnsiColorPairMapper: AnyObject, Sendable {
    /// The replacement pair for `attribute`, or `nil` to keep the resolved
    /// colors. `foreground` and `background` are the fully resolved native
    /// colors, inverse and dim already applied.
    func mapColorPair (attribute: Attribute,
                       foreground: TerminalNativeColor,
                       background: TerminalNativeColor)
        -> (foreground: TerminalNativeColor, background: TerminalNativeColor)?

    /// Bump this when the mapping changes. It is hashed into the render cache
    /// identities together with the mapper's object identity, so stale colors
    /// cannot survive a change.
    var generation: UInt64 { get }
}

extension TerminalAnsiColorPairMapper {
    /// A value that changes whenever the mapper instance or its data changes;
    /// 0 is reserved for "no mapper".
    var cacheIdentity: UInt64 {
        UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue)) &+ generation
    }
}
#endif
