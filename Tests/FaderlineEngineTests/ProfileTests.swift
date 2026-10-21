import XCTest
@testable import Faderline

final class MixerProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: MixerProfileStore!

    override func setUp() {
        super.setUp()
        suite = "FaderlineProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MixerProfileStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func configuration() -> MixerConfiguration {
        MixerConfiguration(
            inputs: [
                .init(deviceUID: "interface", leftChannelIndex: 1, rightChannelIndex: 1,
                      gainDB: -4, pan: 0.7, muted: true, routeToMain: false),
                .init(deviceUID: "microphone", leftChannelIndex: 0, rightChannelIndex: 0,
                      gainDB: -.infinity, pan: -0.25, routeToMain: true)
            ],
            mainOutput: .init(deviceUID: "speakers", gainDB: -.infinity),
            lowLatencyModeEnabled: true
        )
    }

    private func seed(_ configuration: MixerConfiguration) throws {
        defaults.set(try MixerConfiguration.makeEncoder().encode(configuration), forKey: MixerConfiguration.storageKey)
    }

    private func device(id: UInt32 = 10, uid: String = "interface", inputs: Int = 2, outputs: Int = 0) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: uid, inputChannelCount: inputs,
                    outputChannelCount: outputs, sampleRate: 48_000)
    }

    private func profiled(_ name: String = "Main") throws -> MixerProfileLibrary {
        var library = try store.load()
        try library.saveAs(name)
        return library
    }

    func testFirstRunStartsOnDefaultWithoutProfiles() throws {
        let library = try store.load()
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertNil(library.activeID)
        XCTAssertNil(library.active)
        XCTAssertFalse(library.isEdited)
        XCTAssertEqual(library.currentDraft, MixerSnapshot(configuration: .default))
        XCTAssertEqual(try store.load(), library)
    }

    func testMigrationPreservesCompleteMixAndLegacyBlob() throws {
        let config = configuration()
        try seed(config)
        let original = defaults.data(forKey: MixerConfiguration.storageKey)
        let library = try store.load()
        XCTAssertNil(library.activeID)
        XCTAssertEqual(library.currentDraft, MixerSnapshot(configuration: config))
        XCTAssertTrue(store.lowLatencyModeEnabled)
        XCTAssertEqual(defaults.data(forKey: MixerConfiguration.storageKey), original)
    }

    func testOldVolumeMigrationAlsoWorksWhenCreatingProfiles() throws {
        let json = """
        {"inputs":[{"deviceUID":"ssl","leftChannelIndex":0,"rightChannelIndex":1,"volume":0,"routeToMain":true},
        {"deviceUID":"","leftChannelIndex":0,"rightChannelIndex":1,"volume":1,"boostEnabled":true,"routeToMain":false}],
        "mainOutput":{"deviceUID":"speakers"}}
        """
        defaults.set(Data(json.utf8), forKey: MixerConfiguration.storageKey)
        let library = try store.load()
        XCTAssertEqual(library.currentDraft.inputs[0].gainDB, -.infinity)
        XCTAssertEqual(library.currentDraft.inputs[1].gainDB, FaderTaper.maxDB)
        XCTAssertEqual(library.currentDraft.mainOutput.gainDB, 0)
    }

    /// Builds version 1 JSON: a "Default" profile (whose draft is `defaultDraft`) plus "Calls".
    private func versionOneJSON(defaultActive: Bool, includeDefault: Bool = true,
                                defaultDraft: MixerSnapshot) throws -> (Data, UUID) {
        var library = MixerProfileLibrary(configuration: .default)
        try library.saveAs("Calls")
        let data = try MixerConfiguration.makeEncoder().encode(library)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        let callsID = try XCTUnwrap(library.activeID)
        let defaultID = UUID()
        if includeDefault {
            let draftJSON = try JSONSerialization.jsonObject(with: MixerConfiguration.makeEncoder().encode(defaultDraft))
            var legacy = profiles[0]
            legacy["id"] = defaultID.uuidString
            legacy["name"] = "Default"
            legacy["draft"] = draftJSON
            profiles.insert(legacy, at: 0)
        }
        json["profiles"] = profiles
        json["version"] = 1
        json["activeID"] = (defaultActive ? defaultID : callsID).uuidString
        json.removeValue(forKey: "defaultMix")
        return (try JSONSerialization.data(withJSONObject: json), callsID)
    }

    func testVersionOneDefaultProfileBecomesTheWorkingMix() throws {
        var draft = MixerSnapshot(configuration: .default)
        draft.mainOutput.gainDB = -7
        let (data, callsID) = try versionOneJSON(defaultActive: true, defaultDraft: draft)
        defaults.set(data, forKey: MixerProfileStore.storageKey)
        let library = try store.load()
        XCTAssertEqual(library.version, MixerProfileLibrary.currentVersion)
        XCTAssertEqual(library.profiles.map(\.id), [callsID])
        XCTAssertNil(library.activeID)
        XCTAssertEqual(library.currentDraft, draft)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)

        let (callsActive, activeCallsID) = try versionOneJSON(defaultActive: false, defaultDraft: draft)
        defaults.set(callsActive, forKey: MixerProfileStore.storageKey)
        let selected = try store.load()
        XCTAssertEqual(selected.activeID, activeCallsID)
        XCTAssertEqual(selected.defaultMix, draft)
    }

    func testVersionOneDuplicateIDsAreRejectedAndPreserved() throws {
        let (data, _) = try versionOneJSON(defaultActive: true, defaultDraft: MixerSnapshot(configuration: .default))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        profiles[1]["id"] = profiles[0]["id"]
        json["profiles"] = profiles
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        defaults.set(corrupt, forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertTrue(vm.profilesUnavailable)
        vm.setOutputGainDB(-5)
        XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), corrupt)
    }

    func testVersionOneWithoutDefaultProfileKeepsActiveProfile() throws {
        let (data, callsID) = try versionOneJSON(defaultActive: false, includeDefault: false,
                                                 defaultDraft: MixerSnapshot(configuration: .default))
        defaults.set(data, forKey: MixerProfileStore.storageKey)
        let library = try store.load()
        XCTAssertEqual(library.activeID, callsID)
        XCTAssertEqual(library.defaultMix, library.active?.draft)
    }

    func testDraftsAndActiveSelectionSurviveSwitchesAndRelaunch() throws {
        var library = try store.load()
        var defaultDraft = library.currentDraft
        defaultDraft.inputs[0].pan = 0.3
        try library.updateDraft(defaultDraft)
        XCTAssertFalse(library.isEdited)
        try library.saveAs("Calls")
        let callsID = library.activeID
        var callsDraft = defaultDraft
        callsDraft.mainOutput.gainDB = -10
        try library.updateDraft(callsDraft)
        XCTAssertTrue(library.isEdited)
        try library.select(nil)
        XCTAssertEqual(library.currentDraft, defaultDraft)
        XCTAssertFalse(library.isEdited)
        try library.select(callsID)
        try store.save(library)
        let restored = try store.load()
        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.active?.draft, callsDraft)
        XCTAssertTrue(restored.isEdited)
        XCTAssertEqual(restored.defaultMix, defaultDraft)
    }

    func testSaveRevertAndRenameOnlyChangeTheirIntendedState() throws {
        var library = try profiled()
        var draft = library.currentDraft
        draft.inputs[0].gainDB = -12
        try library.updateDraft(draft)
        let identity = library.activeID
        try library.rename("  Music  ")
        XCTAssertEqual(library.activeID, identity)
        XCTAssertEqual(library.active?.name, "Music")
        XCTAssertTrue(library.isEdited)
        try library.revert()
        XCTAssertFalse(library.isEdited)
        XCTAssertNotEqual(library.currentDraft, draft)
        try library.updateDraft(draft)
        try library.save()
        XCTAssertEqual(library.active?.saved, draft)
        XCTAssertFalse(library.isEdited)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
    }

    func testProfileOperationsRequireASelectedProfile() throws {
        var library = try store.load()
        XCTAssertThrowsError(try library.save())
        XCTAssertThrowsError(try library.revert())
        XCTAssertThrowsError(try library.rename("Name"))
        XCTAssertNil(library.activeID)
    }

    func testReturningControlsToSavedValuesClearsEdited() throws {
        var library = try profiled()
        let original = library.currentDraft
        var draft = original
        draft.mainOutput.gainDB = -12
        try library.updateDraft(draft)
        XCTAssertTrue(library.isEdited)
        try library.updateDraft(original)
        XCTAssertFalse(library.isEdited)
    }

    func testDeviceDisplayNamesDoNotMarkProfileEdited() throws {
        var library = try profiled()
        library.deviceNames["interface"] = "My USB interface"
        XCTAssertFalse(library.isEdited)
        try store.save(library)
        XCTAssertEqual(try store.load().deviceNames["interface"], "My USB interface")
    }

    func testNamesAreTrimmedDuplicatesAndDefaultRejected() throws {
        var library = try store.load()
        XCTAssertThrowsError(try library.saveAs(" \n "))
        XCTAssertThrowsError(try library.saveAs("default"))
        XCTAssertThrowsError(try library.saveAs(" DEFAULT "))
        try library.saveAs("  Calls  ")
        XCTAssertEqual(library.active?.name, "Calls")
        XCTAssertThrowsError(try library.saveAs("CALLS"))
        XCTAssertThrowsError(try library.rename("Default"))
        XCTAssertNoThrow(try library.rename("calls"))
    }

    func testDeleteInactiveLeavesActiveAndLastProfileCanBeDeleted() throws {
        var library = try profiled("A")
        let oldID = try XCTUnwrap(library.activeID)
        try library.saveAs("B")
        let active = library.active
        try library.delete(oldID)
        XCTAssertEqual(library.active, active)
        try library.delete(try XCTUnwrap(active?.id))
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertNil(library.activeID)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
    }

    func testDeleteActiveReturnsToDefaultMix() throws {
        var library = try store.load()
        var defaultDraft = library.currentDraft
        defaultDraft.inputs[0].muted = true
        try library.updateDraft(defaultDraft)
        try library.saveAs("Other")
        var otherDraft = defaultDraft
        otherDraft.mainOutput.gainDB = -20
        try library.updateDraft(otherDraft)
        try library.delete(try XCTUnwrap(library.activeID))
        XCTAssertNil(library.activeID)
        XCTAssertEqual(library.currentDraft, defaultDraft)
        XCTAssertFalse(library.isEdited)
        XCTAssertThrowsError(try library.select(UUID()))
        XCTAssertThrowsError(try library.delete(UUID()))
    }

    func testNegativeInfinityInputAndOutputRoundTrip() throws {
        let library = MixerProfileLibrary(configuration: configuration())
        try store.save(library)
        let restored = try store.load()
        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.currentDraft.inputs[1].gainDB, -.infinity)
        XCTAssertEqual(restored.currentDraft.mainOutput.gainDB, -.infinity)
    }

    func testCorruptAndFutureStorageIsNotOverwritten() throws {
        for data in [Data("not json".utf8), Data("{\"version\":999}".utf8)] {
            defaults.set(data, forKey: MixerProfileStore.storageKey)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), data)
        }
        var future = MixerProfileLibrary(configuration: .default)
        future.version = 999
        let futureData = try MixerConfiguration.makeEncoder().encode(future)
        defaults.set(futureData, forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), futureData)
        XCTAssertThrowsError(try store.save(future))
        XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), futureData)
    }

    func testUnreadableLegacyConfigurationDoesNotCreateDefaultLibrary() throws {
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: MixerConfiguration.storageKey)
        XCTAssertThrowsError(try store.load())
        XCTAssertNil(defaults.object(forKey: MixerProfileStore.storageKey))
        XCTAssertEqual(defaults.data(forKey: MixerConfiguration.storageKey), corrupt)
    }

    func testWrongStorageTypeDoesNotBecomeFirstRun() {
        defaults.set("not data", forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.string(forKey: MixerProfileStore.storageKey), "not data")
    }

    func testInvalidReferencesAndDuplicateIDsAreRejected() throws {
        let library = try profiled()
        let data = try MixerConfiguration.makeEncoder().encode(library)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["activeID"] = UUID().uuidString
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
        json["activeID"] = try XCTUnwrap(library.activeID).uuidString
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        json["profiles"] = profiles + profiles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
        json["profiles"] = profiles
        json.removeValue(forKey: "defaultMix")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: MixerProfileStore.storageKey)
        XCTAssertThrowsError(try store.load())
    }

    func testInvalidNumericValuesAndStripShapeAreRejectedBeforeWriting() throws {
        let original = try store.load()
        let originalData = defaults.data(forKey: MixerProfileStore.storageKey)
        for gain: Float in [.nan, .infinity, -61, 7] {
            var draft = original.currentDraft
            draft.mainOutput.gainDB = gain
            XCTAssertThrowsError(try draft.validate())
            draft = original.currentDraft
            draft.inputs[0].gainDB = gain
            XCTAssertThrowsError(try draft.validate())
        }
        for pan: Float in [.nan, .infinity, -1.1, 1.1] {
            var draft = original.currentDraft
            draft.inputs[0].pan = pan
            XCTAssertThrowsError(try draft.validate())
        }
        for channel in [-1, Int.max] {
            var draft = original.currentDraft
            draft.inputs[0].leftChannelIndex = channel
            XCTAssertThrowsError(try draft.validate())
        }
        var wrongShape = configuration()
        wrongShape.inputs.removeLast()
        XCTAssertThrowsError(try store.save(MixerProfileLibrary(configuration: wrongShape)))
        XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), originalData)
    }

    func testMissingAndWrongDirectionDevicesNeverSubstitute() {
        let snapshot = MixerSnapshot(configuration: configuration())
        let wrongInput = device(uid: "interface", inputs: 0, outputs: 2)
        let wrongOutput = device(uid: "speakers", inputs: 2, outputs: 0)
        let resolved = snapshot.resolve(inputDevices: [wrongInput, device(uid: "unrelated")],
                                        outputDevices: [wrongOutput])
        XCTAssertTrue(resolved.inputs.allSatisfy { $0 == .none })
        XCTAssertEqual(resolved.output, .none)
        XCTAssertEqual(snapshot.inputs[0].deviceUID, "interface")
        XCTAssertEqual(snapshot.mainOutput.deviceUID, "speakers")
    }

    func testReconnectUsesNewObjectIDWithoutChangingIntent() {
        let snapshot = MixerSnapshot(configuration: configuration())
        let first = snapshot.resolve(inputDevices: [device(id: 10)], outputDevices: [])
        let missing = snapshot.resolve(inputDevices: [], outputDevices: [])
        let reconnected = snapshot.resolve(inputDevices: [device(id: 25)], outputDevices: [])
        XCTAssertEqual(first.inputs[0].id, 10)
        XCTAssertEqual(missing.inputs[0], .none)
        XCTAssertEqual(reconnected.inputs[0].id, 25)
        XCTAssertEqual(snapshot, MixerSnapshot(configuration: configuration()))
    }

    func testUnavailableChannelsDisableInputWithoutClampingOrDirtying() {
        let library = MixerProfileLibrary(configuration: configuration())
        let snapshot = library.currentDraft
        let mono = snapshot.resolve(inputDevices: [device(inputs: 1)], outputDevices: [])
        XCTAssertEqual(mono.inputs[0], .none)
        XCTAssertEqual(snapshot.inputs[0].leftChannelIndex, 1)
        XCTAssertFalse(library.isEdited)
        let stereo = snapshot.resolve(inputDevices: [device(inputs: 2)], outputDevices: [])
        XCTAssertEqual(stereo.inputs[0].id, 10)
    }

    func testViewModelRecallRestoresAllFieldsAndTemporaryControlPolicy() throws {
        try seed(configuration())
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        let firstID = vm.profileLibrary.activeID
        XCTAssertNil(firstID)
        XCTAssertEqual(vm.windowTitle, "Faderline")
        XCTAssertEqual(vm.currentSnapshot, MixerSnapshot(configuration: configuration()))
        XCTAssertNotNil(vm.availabilityWarning)
        XCTAssertTrue(vm.saveProfileAs("Alternate"))
        vm.setGainDB(-20, forStrip: vm.inputStrips[0])
        vm.setPan(-0.4, forStrip: vm.inputStrips[0])
        vm.toggleMute(forStrip: vm.inputStrips[0])
        vm.toggleRouteToMain(forStrip: vm.inputStrips[0])
        vm.setOutputGainDB(-8)
        vm.setLeftChannel(0, forStrip: vm.inputStrips[0])
        let second = vm.currentSnapshot
        vm.toggleSolo(forStrip: vm.inputStrips[0])
        vm.toggleOutputMute()
        vm.inputStrips[0].meter.clipped = true
        let meterRevision = vm.inputStrips[0].meter.resetRevision
        vm.selectProfile(firstID)
        XCTAssertGreaterThan(vm.inputStrips[0].meter.resetRevision, meterRevision)
        XCTAssertEqual(vm.currentSnapshot, MixerSnapshot(configuration: configuration()))
        XCTAssertFalse(vm.anySolo)
        XCTAssertTrue(vm.mainOutput.muted)
        XCTAssertFalse(vm.inputStrips[0].meter.clipped)
        XCTAssertTrue(vm.lowLatencyModeEnabled)
        let secondID = try XCTUnwrap(vm.profileLibrary.profiles.first { $0.name == "Alternate" }?.id)
        vm.selectProfile(secondID)
        XCTAssertEqual(vm.currentSnapshot, second)
        XCTAssertTrue(vm.isProfileEdited)
        XCTAssertEqual(vm.windowTitle, "Faderline — Alternate — Edited")
        let restored = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertEqual(restored.currentSnapshot, second)
        XCTAssertEqual(restored.profileLibrary.activeID, secondID)
        XCTAssertFalse(restored.mainOutput.muted)
        XCTAssertFalse(restored.anySolo)
    }

    func testViewModelRetainsStripIdentityAndSameProfileSelectionIsNoOp() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        let strip = vm.inputStrips[0]
        let output = vm.mainOutput
        let firstID = vm.profileLibrary.activeID
        vm.toggleSolo(forStrip: strip)
        let revision = vm.profileRecallRevision
        vm.selectProfile(firstID)
        XCTAssertTrue(strip.soloed)
        XCTAssertEqual(vm.profileRecallRevision, revision)
        XCTAssertTrue(vm.saveProfileAs("Next"))
        vm.selectProfile(firstID)
        XCTAssertTrue(vm.inputStrips[0] === strip)
        XCTAssertTrue(vm.mainOutput === output)
        XCTAssertFalse(strip.soloed)
    }

    func testViewModelManagementEnabledStatesAndRevertPolicy() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertFalse(vm.hasActiveProfile)
        XCTAssertFalse(vm.isProfileEdited)
        XCTAssertFalse(vm.canRevertProfile)
        XCTAssertTrue(vm.canSaveProfile)
        vm.setOutputGainDB(-3)
        XCTAssertFalse(vm.isProfileEdited)
        XCTAssertEqual(vm.windowTitle, "Faderline")
        vm.saveProfile()
        XCTAssertEqual(vm.profileDialog, .saveAs)
        vm.profileDialog = nil
        XCTAssertNotNil(vm.profileNameError("Default", renaming: false))
        XCTAssertNotNil(vm.profileNameError("Default", renaming: true))
        XCTAssertTrue(vm.saveProfileAs("Second"))
        XCTAssertTrue(vm.hasActiveProfile)
        XCTAssertFalse(vm.canSaveProfile)
        XCTAssertEqual(vm.windowTitle, "Faderline — Second")
        vm.setOutputGainDB(-15)
        vm.toggleSolo(forStrip: vm.inputStrips[0])
        vm.toggleOutputMute()
        XCTAssertTrue(vm.canSaveProfile)
        XCTAssertEqual(vm.windowTitle, "Faderline — Second — Edited")
        vm.revertProfile()
        XCTAssertEqual(vm.mainOutput.gainDB, -3)
        XCTAssertFalse(vm.anySolo)
        XCTAssertTrue(vm.mainOutput.muted)
        XCTAssertFalse(vm.canSaveProfile)
        vm.setPan(0.7, forStrip: vm.inputStrips[0])
        vm.saveProfile()
        XCTAssertFalse(vm.canSaveProfile)
        XCTAssertEqual(vm.profileLibrary.active?.saved.inputs[0].pan, 0.7)
        XCTAssertTrue(vm.renameProfile("Renamed"))
        XCTAssertEqual(vm.windowTitle, "Faderline — Renamed")
        vm.deleteProfile(vm.profileLibrary.activeID!)
        XCTAssertFalse(vm.hasActiveProfile)
        XCTAssertEqual(vm.windowTitle, "Faderline")
        XCTAssertEqual(vm.mainOutput.gainDB, -3)
    }

    func testLatencyAndTransientControlsDoNotDirtyProfiles() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        vm.setLowLatencyModeEnabled(true)
        XCTAssertTrue(vm.saveProfileAs("Next"))
        vm.toggleSolo(forStrip: vm.inputStrips[0])
        vm.toggleOutputMute()
        XCTAssertFalse(vm.isProfileEdited)
        vm.setLowLatencyModeEnabled(false)
        vm.selectProfile(nil)
        vm.selectProfile(vm.profileLibrary.profiles[0].id)
        XCTAssertFalse(vm.lowLatencyModeEnabled)
        XCTAssertFalse(vm.isProfileEdited)
        XCTAssertFalse(store.lowLatencyModeEnabled)
    }

    func testViewModelPreservesMissingUIDsAcrossEditsSaveAndRelaunch() throws {
        try seed(configuration())
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertEqual(vm.inputStrips[0].selectedDevice.uid, "interface")
        XCTAssertFalse(vm.inputStrips[0].hasDevice)
        XCTAssertTrue(vm.inputStrips[0].selectedDevice.name.contains("Unavailable"))
        vm.setPan(0.2, forStrip: vm.inputStrips[0])
        XCTAssertTrue(vm.saveProfileAs("Missing"))
        let restored = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertEqual(restored.profileLibrary.active?.name, "Missing")
        XCTAssertEqual(restored.currentSnapshot.inputs[0].deviceUID, "interface")
        XCTAssertEqual(restored.currentSnapshot.inputs[0].leftChannelIndex, 1)
        XCTAssertEqual(restored.currentSnapshot.mainOutput.deviceUID, "speakers")
        XCTAssertFalse(restored.isProfileEdited)
    }

    func testLoadFailureBlocksWritesAndRetryCanRecover() throws {
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: MixerProfileStore.storageKey)
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        XCTAssertTrue(vm.profilesUnavailable)
        XCTAssertNotNil(vm.profileError)
        XCTAssertFalse(vm.saveProfileAs("Never written"))
        vm.setOutputGainDB(-10)
        vm.setPan(0.4, forStrip: vm.inputStrips[0])
        vm.retryProfileStorage()
        XCTAssertEqual(defaults.data(forKey: MixerProfileStore.storageKey), corrupt)
        XCTAssertEqual(vm.mainOutput.gainDB, -10)
        XCTAssertEqual(vm.inputStrips[0].pan, 0.4)
        let recovered = MixerProfileLibrary(configuration: configuration())
        try store.save(recovered)
        vm.retryProfileStorage()
        XCTAssertFalse(vm.profilesUnavailable)
        XCTAssertNil(vm.profileError)
        XCTAssertEqual(vm.currentSnapshot, recovered.currentDraft)
    }

    func testFailedNameOperationDoesNotDiscardDraftOrChangeSelection() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        vm.setOutputGainDB(-10)
        let before = vm.profileLibrary
        XCTAssertFalse(vm.saveProfileAs("Default"))
        XCTAssertEqual(vm.profileLibrary, before)
        XCTAssertNotNil(vm.profileError)
        XCTAssertTrue(vm.saveProfileAs("Valid"))
        XCTAssertNil(vm.profileError)
    }

    func testPendingTextEditEnablesSaveAndCommitsBeforeSnapshotIsSaved() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        vm.setPendingGainEdit(true, revision: vm.profileRecallRevision)
        XCTAssertFalse(vm.isProfileEdited)
        vm.setPendingGainEdit(false, revision: vm.profileRecallRevision)
        XCTAssertTrue(vm.saveProfileAs("Pending"))
        let revision = vm.profileRecallRevision
        vm.setPendingGainEdit(true, revision: revision)
        XCTAssertTrue(vm.canSaveProfile)
        XCTAssertTrue(vm.windowTitle.hasSuffix("— Edited"))
        let observer = NotificationCenter.default.addObserver(
            forName: MixerViewModel.commitPendingEditsNotification, object: nil, queue: nil
        ) { _ in
            vm.setOutputGainDB(-16)
            vm.setPendingGainEdit(false, revision: revision)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        vm.saveProfile()
        XCTAssertEqual(vm.profileLibrary.active?.saved.mainOutput.gainDB, -16)
        XCTAssertFalse(vm.canSaveProfile)
    }

    func testOldTextFieldCannotMarkNewProfileEditedAfterRecall() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        let first = vm.profileLibrary.activeID
        let oldRevision = vm.profileRecallRevision
        XCTAssertTrue(vm.saveProfileAs("Second"))
        vm.selectProfile(first)
        vm.setPendingGainEdit(true, revision: oldRevision)
        XCTAssertFalse(vm.hasPendingGainEdit)
        XCTAssertFalse(vm.isProfileEdited)
    }

    func testRapidRecallEndsAtLatestDraftAndOlderGenerationsAreSuperseded() {
        let vm = MixerViewModel(profileStore: store, startsAudio: false)
        let first = vm.profileLibrary.activeID
        XCTAssertTrue(vm.saveProfileAs("Second"))
        vm.setOutputGainDB(-9)
        let second = vm.profileLibrary.activeID
        for _ in 0..<20 {
            vm.selectProfile(first)
            vm.selectProfile(second)
        }
        XCTAssertEqual(vm.profileLibrary.activeID, second)
        XCTAssertEqual(vm.mainOutput.gainDB, -9)
        let generations = RebuildGeneration()
        let old = generations.next()
        let newest = generations.next()
        XCTAssertFalse(generations.isCurrent(old))
        XCTAssertTrue(generations.isCurrent(newest))
    }
}
