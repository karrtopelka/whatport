import Testing
@testable import WhatPort

@Suite("lsof field parser")
struct LsofFieldParserTests {
    let sample = """
    p8241
    cnode
    u501
    f23
    tIPv4
    PTCP
    n*:3000
    f24
    tIPv6
    PTCP
    n[::]:3000
    p9321
    cbun
    u501
    f12
    tIPv4
    PTCP
    n127.0.0.1:5173
    f13
    tIPv6
    PTCP
    n[::1]:5173
    f14
    tIPv4
    PTCP
    n127.0.0.1:5174
    p77
    crapportd
    u501
    f5
    tIPv4
    PTCP
    n*:49152
    f6
    tIPv4
    PUDP
    n*:5353
    """

    @Test func parsesProcessesAndSockets() {
        let sockets = LsofFieldParser.parse(sample)
        #expect(sockets.count == 6)
        #expect(sockets.filter { $0.pid == 8241 }.count == 2)
        #expect(sockets.filter { $0.pid == 9321 }.count == 3)
        #expect(sockets.first { $0.pid == 77 }?.port == 49152)
        #expect(sockets.first { $0.pid == 8241 }?.commandName == "node")
        #expect(sockets.first { $0.pid == 8241 }?.uid == 501)
    }

    @Test func ignoresUDP() {
        let sockets = LsofFieldParser.parse(sample)
        #expect(!sockets.contains { $0.port == 5353 })
    }

    @Test func extractsIPv4AndIPv6() {
        let sockets = LsofFieldParser.parse(sample)
        let node = sockets.filter { $0.pid == 8241 }
        #expect(node.contains { $0.family == .ipv4 && $0.address == "*" && $0.port == 3000 })
        #expect(node.contains { $0.family == .ipv6 && $0.address == "*" && $0.port == 3000 })
        let bun = sockets.filter { $0.pid == 9321 }
        #expect(bun.contains { $0.family == .ipv6 && $0.address == "::1" && $0.port == 5173 })
        #expect(bun.contains { $0.family == .ipv4 && $0.address == "127.0.0.1" && $0.port == 5173 })
    }

    @Test func mergesDuplicateListenersPerPort() {
        let sockets = LsofFieldParser.parse(sample).filter { $0.pid == 9321 }
        let ports = ListeningPort.merge(sockets)
        #expect(ports.map(\.port) == [5173, 5174])
        #expect(Set(ports[0].addresses) == ["127.0.0.1", "::1"])
        #expect(ports[0].preferredHost == "localhost")
        #expect(ports[0].localURL?.absoluteString == "http://localhost:5173")
    }

    @Test(arguments: [
        ("*:3000", "*", 3000),
        ("127.0.0.1:8080", "127.0.0.1", 8080),
        ("[::1]:5173", "::1", 5173),
        ("[::]:4000", "*", 4000),
        ("0.0.0.0:9000", "*", 9000),
        ("[fe80::1%lo0]:8443", "fe80::1%lo0", 8443),
    ])
    func parsesEndpoints(input: String, address: String, port: Int) {
        let parsed = LsofFieldParser.parseEndpoint(input)
        #expect(parsed?.address == address)
        #expect(parsed?.port == port)
    }

    @Test func rejectsMalformedEndpoints() {
        #expect(LsofFieldParser.parseEndpoint("nonsense") == nil)
        #expect(LsofFieldParser.parseEndpoint("*:abc") == nil)
        #expect(LsofFieldParser.parseEndpoint("*:70000") == nil)
        #expect(LsofFieldParser.parse("").isEmpty)
        #expect(LsofFieldParser.parse("garbage\nmore garbage\n").isEmpty)
    }

    @Test func toleratesMissingFields() {
        // No `t` line: family inferred from the address.
        let text = "p5\ncfoo\nf1\nPTCP\nn[::1]:81\nf2\nPTCP\nn10.0.0.2:82\n"
        let sockets = LsofFieldParser.parse(text)
        #expect(sockets.count == 2)
        #expect(sockets[0].family == .ipv6)
        #expect(sockets[1].family == .ipv4)
    }
}
