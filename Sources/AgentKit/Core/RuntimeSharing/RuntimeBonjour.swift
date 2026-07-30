//
//  RuntimeBonjour.swift
//  AgentKit
//

import Foundation
import Observation

public struct RuntimeDiscoveredSharedServer: Identifiable, Sendable, Equatable {
    public var id: String { "\(serviceName).\(domain)" }
    public let serviceName: String
    public let domain: String
    public let host: String
    public let port: Int
    public let serverID: String?
    public let displayName: String?

    public var endpoint: URL? {
        URL(string: "https://\(host):\(port)")
    }
}

final class RuntimeBonjourAdvertiser: NSObject, NetServiceDelegate,
    @unchecked Sendable {
    static let serviceType = "_talkify-agent._tcp."

    private var service: NetService?

    func start(
        serviceName: String,
        port: Int,
        serverID: String,
        displayName: String
    ) {
        stop()
        let service = NetService(
            domain: "local.",
            type: Self.serviceType,
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "schema": Data("talkify-runtime-share/v1".utf8),
            "server_id": Data(serverID.utf8),
            "display_name": Data(displayName.utf8),
            "wire_major": Data("1".utf8),
        ]))
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
    }
}

private final class RuntimeBonjourBrowserDelegate:
    NSObject,
    NetServiceBrowserDelegate,
    NetServiceDelegate,
    @unchecked Sendable
{
    var onResolved: (@Sendable (RuntimeDiscoveredSharedServer) -> Void)?
    var onRemoved: (@Sendable (String, String) -> Void)?
    private var services: [String: NetService] = [:]

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.domain)"
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.domain)"
        services.removeValue(forKey: key)
        onRemoved?(service.name, service.domain)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:))
        func text(_ key: String) -> String? {
            txt?[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        onResolved?(RuntimeDiscoveredSharedServer(
            serviceName: sender.name,
            domain: sender.domain,
            host: host.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            port: sender.port,
            serverID: text("server_id"),
            displayName: text("display_name")
        ))
    }
}

@MainActor
@Observable
public final class RuntimeBonjourBrowser {
    public private(set) var servers: [RuntimeDiscoveredSharedServer] = []
    public private(set) var isBrowsing = false

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private let delegate = RuntimeBonjourBrowserDelegate()

    public init() {
        delegate.onResolved = { [weak self] server in
            Task { @MainActor in
                guard let self else { return }
                if let index = self.servers.firstIndex(where: {
                    $0.id == server.id
                }) {
                    self.servers[index] = server
                } else {
                    self.servers.append(server)
                }
                self.servers.sort { $0.serviceName < $1.serviceName }
            }
        }
        delegate.onRemoved = { [weak self] name, domain in
            Task { @MainActor in
                self?.servers.removeAll {
                    $0.serviceName == name && $0.domain == domain
                }
            }
        }
        browser.delegate = delegate
    }

    public func start() {
        guard !isBrowsing else { return }
        servers = []
        isBrowsing = true
        browser.searchForServices(
            ofType: RuntimeBonjourAdvertiser.serviceType,
            inDomain: "local."
        )
    }

    public func stop() {
        browser.stop()
        isBrowsing = false
    }
}
