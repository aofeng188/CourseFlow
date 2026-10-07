import Foundation

enum BuildFeatures {
    /// Personal-signing builds keep the local app independent of provisioned extensions.
    static var isTrial: Bool { Bundle.main.object(forInfoDictionaryKey: "TrialBuild") as? Bool == true }
}
