import Foundation

public enum MotasConfiguration {
    public static let snapshotFilename = SnapshotStore.defaultFilename

    public static let settingsFilename = "settings.json"
    public static let defaultAutomaticRefreshInterval: TimeInterval = 300
    public static let minimumAutomaticRefreshInterval: TimeInterval = 60

    public static let keychainService = "dev.motas.app.connectors"
}
