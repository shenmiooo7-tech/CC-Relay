import Foundation

/// Newest local percent sample for one organization.
///
/// Reset times are not in this file. An unreadable or oversized file yields nothing.
enum PlanUsageHistory {
    static func reading(for profile: QuotaProfile) -> QuotaSnapshot? {
        guard let organization = QuotaText.nonEmpty(profile.organizationUUID) else { return nil }
        let url = profile.directory.appending(path: "plan-usage-history.json")
        guard let data = try? AtomicFile.read(url), data.count <= bodyCap else { return nil }
        guard let sample = newest(organization: organization, data: data) else { return nil }
        return QuotaSnapshot(
            folder: profile.folder,
            accountUUID: profile.accountUUID,
            organizationUUID: organization,
            channel: .unknown,
            fiveHour: QuotaWindow(usedPercent: sample.fiveHour),
            sevenDay: QuotaWindow(usedPercent: sample.sevenDay),
            fetchedAt: sample.at,
            source: .localHistory
        )
    }

    private struct Sample {
        var at: Date
        var fiveHour: Double?
        var sevenDay: Double?
    }

    private static func newest(organization: String, data: Data) -> Sample? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rows = root["samples"] as? [Any] else { return nil }
        var best: (stamp: Double, sample: Sample)?
        for row in rows {
            guard let object = row as? [String: Any] else { continue }
            guard let org = object["org"] as? String, org == organization else { continue }
            guard let stamp = JSONNumbers.finite(object["t"]) else { continue }
            let usage = object["u"] as? [String: Any]
            let fiveHour = usage.flatMap { percent($0["fh"]) }
            let sevenDay = usage.flatMap { percent($0["sd"]) }
            guard fiveHour != nil || sevenDay != nil else { continue }
            let sample = Sample(
                at: Date(timeIntervalSince1970: stamp / 1000),
                fiveHour: fiveHour,
                sevenDay: sevenDay
            )
            if best == nil || stamp >= best!.stamp {
                best = (stamp, sample)
            }
        }
        return best?.sample
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = JSONNumbers.finite(value) else { return nil }
        guard (0...100).contains(number) else { return nil }
        return number
    }

    private static let bodyCap = 2 * 1024 * 1024
}

enum QuotaText {
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
