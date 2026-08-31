//
//  AnsiColorPairMapperTests.swift
//  SwiftTermTests
//
//  Covers the host color-pair remapping hook: that it sees the fully resolved
//  pair (inverse and dim already applied), that returning nil is inert, and
//  that its identity participates in the attribute-cache key.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

/// Records what it was handed and returns a configurable replacement.
private final class MockPairMapper: TerminalAnsiColorPairMapper, @unchecked Sendable {
    struct Seen {
        let foreground: NSColor
        let background: NSColor
    }

    var generation: UInt64 = 1
    var replacement: (foreground: NSColor, background: NSColor)?
    private(set) var seen: [Seen] = []

    init (replacing replacement: (foreground: NSColor, background: NSColor)? = nil) {
        self.replacement = replacement
    }

    func mapColorPair (attribute: Attribute,
                       foreground: NSColor,
                       background: NSColor)
        -> (foreground: NSColor, background: NSColor)?
    {
        seen.append(Seen(foreground: foreground, background: background))
        return replacement
    }
}

@Suite("AnsiColorPairMapper")
@MainActor
struct AnsiColorPairMapperTests {
    private func makeView (cols: Int = 12, rows: Int = 4) -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: cols, rows: rows, scrollback: 20))
    }

    private func renderFirstRow (_ view: TerminalView) throws -> ViewLineInfo {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection),
                                 deferBidiTypesetting: false)
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        return view.textBuilder.buildAttributedString(row: row,
                                                      absoluteRow: snapshot.firstRow,
                                                      context: context)
    }

    private func attributes (at index: Int, in info: ViewLineInfo)
        -> [NSAttributedString.Key: Any]
    {
        let joined = NSMutableAttributedString()
        for segment in info.segments {
            joined.append(segment.attributedString)
        }
        return joined.attributes(at: index, effectiveRange: nil)
    }

    // MARK: Application

    @Test func mapperReplacesTheRenderedPair() throws {
        let view = makeView()
        let mapper = MockPairMapper(replacing: (foreground: .systemPink,
                                                background: .systemTeal))
        view.ansiColorPairMapper = mapper
        view.feed(text: "A")

        let attrs = attributes(at: 0, in: try renderFirstRow(view))
        #expect(attrs[.foregroundColor] as? NSColor == NSColor.systemPink)
        #expect(attrs[.backgroundColor] as? NSColor == NSColor.systemTeal)
        #expect(!mapper.seen.isEmpty)
    }

    @Test func returningNilLeavesRenderingUnchanged() throws {
        let view = makeView()
        view.feed(text: "A")
        let baseline = attributes(at: 0, in: try renderFirstRow(view))

        let inert = MockPairMapper(replacing: nil)
        view.ansiColorPairMapper = inert
        let withMapper = attributes(at: 0, in: try renderFirstRow(view))

        #expect(withMapper[.foregroundColor] as? NSColor
                == baseline[.foregroundColor] as? NSColor)
        #expect(withMapper[.backgroundColor] as? NSColor
                == baseline[.backgroundColor] as? NSColor)
        // It was consulted; it simply declined.
        #expect(!inert.seen.isEmpty)
    }

    @Test func mapperSeesThePairAfterTheInverseSwap() throws {
        let view = makeView()
        let plain = MockPairMapper(replacing: nil)
        view.ansiColorPairMapper = plain
        view.feed(text: "A")
        _ = try renderFirstRow(view)
        let normal = try #require(plain.seen.first)

        let inverted = MockPairMapper(replacing: nil)
        let view2 = makeView()
        view2.ansiColorPairMapper = inverted
        // SGR 7 = inverse.
        view2.feed(text: "\u{1b}[7mA")
        _ = try renderFirstRow(view2)
        let swapped = try #require(inverted.seen.first)

        // The hook runs after the swap, so the pair it sees is reversed
        // relative to the un-inverted cell rather than identical to it.
        #expect(swapped.foreground == normal.background)
        #expect(swapped.background == normal.foreground)
    }

    @Test func mapperSeesTheDimmedForeground() throws {
        let view = makeView()
        let plain = MockPairMapper(replacing: nil)
        view.ansiColorPairMapper = plain
        view.feed(text: "A")
        _ = try renderFirstRow(view)
        let normal = try #require(plain.seen.first)

        let dimmed = MockPairMapper(replacing: nil)
        let view2 = makeView()
        view2.ansiColorPairMapper = dimmed
        // SGR 2 = dim/faint.
        view2.feed(text: "\u{1b}[2mA")
        _ = try renderFirstRow(view2)
        let faint = try #require(dimmed.seen.first)

        // Dim blends the foreground toward the background before the hook, so
        // the hook cannot be handed the undimmed color.
        #expect(faint.foreground != normal.foreground)
        #expect(faint.background == normal.background)
    }

    // MARK: Cache identity

    @Test func mapperIdentityParticipatesInTheRenderContextIdentity() {
        let view = makeView()
        let bare = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                         style: .empty,
                                         ansiColors: view.withTerminal { $0.ansiColors },
                                         cols: 80)

        let mapper = MockPairMapper(replacing: nil)
        view.ansiColorPairMapper = mapper
        let withMapper = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                               style: .empty,
                                               ansiColors: view.withTerminal { $0.ansiColors },
                                               cols: 80)
        #expect(bare.identity != withMapper.identity)

        // Bumping the generation must invalidate too, otherwise a mapper that
        // changes its mapping in place would keep serving cached colors.
        mapper.generation += 1
        let bumped = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                           style: .empty,
                                           ansiColors: view.withTerminal { $0.ansiColors },
                                           cols: 80)
        #expect(withMapper.identity != bumped.identity)
    }

    @Test func changingTheMapperInvalidatesCachedAttributes() throws {
        let view = makeView()
        view.feed(text: "A")
        let mapper = MockPairMapper(replacing: (foreground: .systemPink,
                                                background: .systemTeal))
        view.ansiColorPairMapper = mapper
        let first = attributes(at: 0, in: try renderFirstRow(view))
        #expect(first[.foregroundColor] as? NSColor == NSColor.systemPink)

        // Same mapper instance, new mapping, new generation: the cached
        // dictionary from the previous render must not be reused.
        mapper.replacement = (foreground: .systemBrown, background: .systemTeal)
        mapper.generation = 2
        let second = attributes(at: 0, in: try renderFirstRow(view))
        #expect(second[.foregroundColor] as? NSColor == NSColor.systemBrown)
    }
}
#endif
