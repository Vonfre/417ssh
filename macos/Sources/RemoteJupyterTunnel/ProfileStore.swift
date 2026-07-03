import Combine
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [SSHProfile]
    @Published var selectedProfileID: SSHProfile.ID?

    private let defaults: UserDefaults
    private let profilesKey = "profiles.v1"
    private let selectedProfileKey = "selectedProfileID.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if
            let data = defaults.data(forKey: profilesKey),
            let decodedProfiles = try? JSONDecoder().decode([SSHProfile].self, from: data),
            !decodedProfiles.isEmpty
        {
            profiles = decodedProfiles
        } else {
            profiles = [.sample]
        }

        if
            let selectedString = defaults.string(forKey: selectedProfileKey),
            let selectedID = UUID(uuidString: selectedString),
            profiles.contains(where: { $0.id == selectedID })
        {
            selectedProfileID = selectedID
        } else {
            selectedProfileID = profiles.first?.id
        }

        normalizeBuiltInSFTPWorkspaceName()
    }

    var selectedProfile: SSHProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID }
    }

    func profiles(for kind: WorkspaceKind) -> [SSHProfile] {
        let matchingProfiles = profiles.filter { $0.workspaceKind == kind }
        if kind == .sftp {
            return Array(matchingProfiles.prefix(1))
        }
        return matchingProfiles
    }

    func binding(for profile: SSHProfile) -> BindingBox<SSHProfile> {
        BindingBox(
            get: { [weak self] in
                self?.profiles.first(where: { $0.id == profile.id }) ?? profile
            },
            set: { [weak self] updatedProfile in
                self?.updateProfile(updatedProfile)
            }
        )
    }

    @discardableResult
    func addProfile(kind: WorkspaceKind = .jupyter) -> SSHProfile {
        if kind == .sftp, let existingSFTPWorkspace = profiles.first(where: { $0.workspaceKind == .sftp }) {
            selectedProfileID = existingSFTPWorkspace.id
            save()
            return existingSFTPWorkspace
        }

        let kindCount = profiles.filter { $0.workspaceKind == kind }.count
        var profile = SSHProfile.blank(number: kindCount + 1, kind: kind)
        profile.name = nextProfileName(base: profile.name)
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
        return profile
    }

    @discardableResult
    func addCustomSFTPProfile() -> SSHProfile {
        let kind: WorkspaceKind = .sftp
        let kindCount = profiles.filter { $0.workspaceKind == kind }.count
        var profile = SSHProfile.blank(number: kindCount + 1, kind: kind)
        profile.name = nextProfileName(base: "自定义 SFTP")
        profiles.append(profile)
        save()
        return profile
    }

    func duplicateSelectedProfile() {
        guard var profile = selectedProfile else { return }
        profile.id = UUID()
        profile.name = nextProfileName(base: "\(profile.name) 副本")
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func deleteSelectedProfile() {
        guard let selectedProfileID else { return }
        deleteProfile(id: selectedProfileID)
    }

    func deleteProfile(id profileID: SSHProfile.ID, fallbackSelectionID: SSHProfile.ID? = nil) {
        profiles.removeAll { $0.id == profileID }

        if profiles.isEmpty {
            profiles = [.sample]
        }

        if
            let fallbackSelectionID,
            profiles.contains(where: { $0.id == fallbackSelectionID })
        {
            selectedProfileID = fallbackSelectionID
        } else if
            let selectedProfileID,
            profiles.contains(where: { $0.id == selectedProfileID })
        {
            self.selectedProfileID = selectedProfileID
        } else {
            selectedProfileID = profiles.first?.id
        }

        save()
    }

    func updateProfile(_ profile: SSHProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    private func nextProfileName(base: String) -> String {
        var candidate = base
        var suffix = 2
        let existingNames = Set(profiles.map(\.name))

        while existingNames.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }

        return candidate
    }

    private func normalizeBuiltInSFTPWorkspaceName() {
        guard
            let index = profiles.firstIndex(where: { $0.workspaceKind == .sftp }),
            profiles[index].name == "新 SFTP" || profiles[index].name.hasPrefix("新 SFTP ")
        else {
            return
        }

        var existingNames = Set(profiles.map(\.name))
        existingNames.remove(profiles[index].name)
        var candidate = "SFTP"
        var suffix = 2
        while existingNames.contains(candidate) {
            candidate = "SFTP \(suffix)"
            suffix += 1
        }

        profiles[index].name = candidate
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }

        defaults.set(selectedProfileID?.uuidString, forKey: selectedProfileKey)
    }
}

struct BindingBox<Value> {
    var get: () -> Value
    var set: (Value) -> Void
}
