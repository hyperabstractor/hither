import Shared

func testWindowPolicy() throws {
    let main = WindowCandidate(id: 10, app: "Example", bundle: "dev.example", title: "Document", area: 1_000_000)
    let panel = WindowCandidate(id: 11, app: "Example", bundle: "dev.example", title: "Comment", area: 100_000)

    do {
        try expectEqual(WindowCandidate.select(from: [main, panel], app: "dev.example", title: nil, id: 11), 11)
        try expectNil(WindowCandidate.select(from: [main], app: "dev.example", title: nil, id: 11))
    }

    do {
        try expectEqual(WindowCandidate.select(from: [main], app: "dev.example", title: "Old title", id: 10), 10)
        try expectNil(WindowCandidate.select(from: [main], app: "dev.other", title: nil, id: 10))
    }

    do {
        try expectEqual(WindowCandidate.select(from: [panel, main], app: "example", title: nil, id: 0), 10)
        try expectEqual(WindowCandidate.select(from: [panel, main], app: "dev.example", title: "comment", id: 0), 11)
    }

    do {
        try expectFalse(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: false, resizable: false, hasContainingWindow: true).isIndependent)
        try expectFalse(WindowTraits(standard: true, parentIsWindow: true, hasWindowControls: true, resizable: true).isIndependent)
        try expectFalse(WindowTraits(standard: false, parentIsWindow: false, hasWindowControls: true, resizable: false).isIndependent)
    }

    do {
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: true, resizable: false).isIndependent)
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: false, resizable: true).isIndependent)
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: nil, resizable: false).isIndependent)
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: false, resizable: nil).isIndependent)
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: false, resizable: false).isIndependent)
        try expectTrue(WindowTraits(standard: true, parentIsWindow: false, hasWindowControls: true, resizable: false, hasContainingWindow: true).isIndependent)
    }
}
