import CLibMoonlight
import Foundation
import XMLCoder

struct App: Sendable, Equatable, Codable {
    let isHdrSupported: Bool
    let title: String
    let uuid: String
    let idx: Int
    let id: Int

    enum CodingKeys: String, CodingKey {
        case isHdrSupported = "IsHdrSupported"
        case title = "AppTitle"
        case uuid = "UUID"
        case idx = "IDX"
        case id = "ID"
    }
}

struct AppList: Sendable, Equatable, Codable {
    let statusCode: Int
    let apps: [App]

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case apps = "App"
    }
}

struct LaunchAppResponse: Sendable, Equatable, Codable {
    let sessionUrl0: String

    enum CodingKeys: String, CodingKey {
        case sessionUrl0 = "sessionUrl0"
    }
}

struct LaunchAppInfo: Sendable, Equatable {
    let aesKey: Data
    let aesIV: Data
    let sessionUrl: String
}

struct ServerInfo: Sendable, Equatable, Codable {
    let statusCode: String?
    let hostname: String
    let appversion: String
    let gfeVersion: String
    let uniqueId: String
    let httpsPort: UInt16
    let externalPort: UInt16
    let maxLumaPixelsHEVC: UInt64
    let mac: String
    let serverCommand: String
    let permission: UInt64
    let virtualDisplayCapable: Bool
    let virtualDisplayDriverReady: Bool
    let localIP: String
    let serverCodecModeSupport: Int32
    let pairStatus: UInt8
    let currentGame: UInt32
    let currentGameUuid: String?
    let state: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case hostname
        case appversion
        case gfeVersion = "GfeVersion"
        case uniqueId = "uniqueid"
        case httpsPort = "HttpsPort"
        case externalPort = "ExternalPort"
        case maxLumaPixelsHEVC = "MaxLumaPixelsHEVC"
        case mac
        case serverCommand = "ServerCommand"
        case permission = "Permission"
        case virtualDisplayCapable = "VirtualDisplayCapable"
        case virtualDisplayDriverReady = "VirtualDisplayDriverReady"
        case localIP = "LocalIP"
        case serverCodecModeSupport = "ServerCodecModeSupport"
        case pairStatus = "PairStatus"
        case currentGame = "currentgame"
        case currentGameUuid = "currentgameuuid"
        case state
    }
}
