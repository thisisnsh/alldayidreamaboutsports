import Foundation

private final class ResponseStub: URLProtocol, @unchecked Sendable {
    static var payload = Data()
    static var advertisedLength: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers: [String: String] = [:]
        if let length = Self.advertisedLength { headers["Content-Length"] = length }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct RemoteDataTests {
    static func main() async throws {
        let hosts: Set<String> = ["media.api-sports.io"]
        for raw in ["http://media.api-sports.io/a", "file:///etc/passwd", "https://127.0.0.1/a",
                    "https://media.api-sports.io.attacker.invalid/a", "https://user@media.api-sports.io/a",
                    "https://media.api-sports.io:8443/a"] {
            precondition(!RemoteData.permits(URL(string: raw), hosts: hosts), raw)
        }
        let request = URLRequest(url: URL(string: "https://media.api-sports.io/a")!)
        precondition(RemoteData.permits(request.url, hosts: hosts))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        ResponseStub.payload = Data(repeating: 65, count: 10)
        let (data, _) = try await RemoteData.load(request, maxBytes: 10, hosts: hosts, session: session)
        precondition(data == ResponseStub.payload)
        // Actual streaming limit must work without Content-Length.
        ResponseStub.payload = Data(repeating: 65, count: 11)
        do {
            _ = try await RemoteData.load(request, maxBytes: 10, hosts: hosts, session: session)
            preconditionFailure("oversized streaming body accepted")
        } catch RemoteData.Failure.tooLarge {}
        ResponseStub.payload = Data()
        ResponseStub.advertisedLength = "999999"
        do {
            _ = try await RemoteData.load(request, maxBytes: 10, hosts: hosts, session: session)
            preconditionFailure("oversized Content-Length accepted")
        } catch RemoteData.Failure.tooLarge {}

        let league = League(id: 39, name: "League", logo: "", country: nil, active: true, scheduled: true, season: 2026, ended: false)
        do {
            _ = try Catalog(leagues: [league, league], teams: [:]).validated()
            preconditionFailure("duplicate league accepted")
        } catch Catalog.ValidationError.duplicateLeague {}
        let team = Team(id: 1, name: "Team", code: nil, logo: "", leagueId: 39)
        do {
            _ = try Catalog(leagues: [league], teams: ["39": [team, team]]).validated()
            preconditionFailure("duplicate team accepted")
        } catch Catalog.ValidationError.duplicateTeam {}
        _ = try Catalog(leagues: [league], teams: ["39": [team]]).validated()
        do {
            _ = try Catalog(leagues: Array(repeating: league, count: 101), teams: [:]).validated()
            preconditionFailure("oversized catalog accepted")
        } catch Catalog.ValidationError.excessiveRows {}
        print("Remote data checks passed: URL policy, byte limits, and catalog validation")
    }
}
