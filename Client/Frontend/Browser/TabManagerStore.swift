/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Storage
import Shared
import XCGLogger

private let log = Logger.browserLogger
class TabManagerStore: FeatureFlagsProtocol {
    fileprivate var lockedForReading = false
    fileprivate let imageStore: DiskImageStore?
    fileprivate var fileManager = FileManager.default
    fileprivate let prefs: Prefs
    fileprivate let serialQueue = DispatchQueue(label: "tab-manager-write-queue")
    fileprivate var writeOperation = DispatchWorkItem {}

    // Init this at startup with the tabs on disk, and then on each save, update the in-memory tab state.
    fileprivate lazy var archivedStartupTabs = {
        return SiteArchiver.tabsToRestore(tabsStateArchivePath: tabsStateArchivePath())
    }()

    init(imageStore: DiskImageStore?, _ fileManager: FileManager = FileManager.default, prefs: Prefs) {
        self.fileManager = fileManager
        self.imageStore = imageStore
        self.prefs = prefs
    }

    var isRestoringTabs: Bool {
        return lockedForReading
    }
    
    var shouldOpenHome: Bool {
        let isColdLaunch = NSUserDefaultsPrefs(prefix: "profile").boolForKey("isColdLaunch")
        guard let coldLaunch = isColdLaunch, featureFlags.isFeatureActive(.startAtHome) else { return false }
        
        let lastActiveTimestamp = UserDefaults.standard.object(forKey: "LastActiveTimestamp") as? Date ?? Date()
        let dateComponents = Calendar.current.dateComponents([.hour], from: lastActiveTimestamp, to: Date())
        let hours = dateComponents.hour ?? 0
        
        return hours > 4 || coldLaunch
    }

    var hasTabsToRestoreAtStartup: Bool {
        return archivedStartupTabs.0.count > 0
    }

    fileprivate func tabsStateArchivePath() -> String? {
        let profilePath: String?
        if  AppConstants.IsRunningTest || AppConstants.IsRunningPerfTest {      profilePath = (UIApplication.shared.delegate as? TestAppDelegate)?.dirForTestProfile
        } else {
            profilePath = fileManager.containerURL( forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier)?.appendingPathComponent("profile.profile").path
        }
        guard let path = profilePath else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("tabsState.archive").path
    }

    fileprivate func prepareSavedTabs(fromTabs tabs: [Tab], selectedTab: Tab?) -> [SavedTab]? {
        var savedTabs = [SavedTab]()
        var savedUUIDs = Set<String>()
        for tab in tabs {
            tab.tabUUID = tab.tabUUID.isEmpty ? UUID().uuidString : tab.tabUUID
            tab.screenshotUUID = tab.screenshotUUID ?? UUID()
            tab.firstCreatedTime = tab.firstCreatedTime ?? tab.sessionData?.lastUsedTime ?? Date.now()
            if let savedTab = SavedTab(tab: tab, isSelected: tab == selectedTab) {
                savedTabs.append(savedTab)
                if let uuidString = tab.screenshotUUID?.uuidString {
                    savedUUIDs.insert(uuidString)
                }
            }
        }
        
        // Clean up any screenshots that are no longer associated with a tab.
        _ = imageStore?.clearExcluding(savedUUIDs)
        return savedTabs.isEmpty ? nil : savedTabs
    }

    func preserveScreenshot(forTab tab: Tab?) {
        if let tab = tab, let screenshot = tab.screenshot, let uuidString = tab.screenshotUUID?.uuidString {
            imageStore?.put(uuidString, image: screenshot)
        }
    }
    
    // Async write of the tab state. In most cases, code doesn't care about performing an operation
    // after this completes. Deferred completion is called always, regardless of Data.write return value.
    // Write failures (i.e. due to read locks) are considered inconsequential, as preserveTabs will be called frequently.
    @discardableResult func preserveTabs(_ tabs: [Tab], selectedTab: Tab?) -> Success {
        assert(Thread.isMainThread)
        print("preserve tabs!, existing tabs: \(tabs.count)")
        guard let savedTabs = prepareSavedTabs(fromTabs: tabs, selectedTab: selectedTab),
            let path = tabsStateArchivePath() else {
                clearArchive()
                return succeed()
        }

        writeOperation.cancel()

        let tabStateData = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWith: tabStateData)

        archiver.encode(savedTabs, forKey: "tabs")
        archiver.finishEncoding()
        
        let simpleTabs = SimpleTab.convertToSimpleTabs(savedTabs)
        

        let result = Success()
        writeOperation = DispatchWorkItem {
            let written = tabStateData.write(toFile: path, atomically: true)
            
            SimpleTab.saveSimpleTab(tabs: simpleTabs)
            // Ignore write failure (could be restoring).
            log.debug("PreserveTabs write ok: \(written), bytes: \(tabStateData.length)")
            result.fill(Maybe(success: ()))
        }

        // Delay by 100ms to debounce repeated calls to preserveTabs in quick succession.
        // Notice above that a repeated 'preserveTabs' call will 'cancel()' a pending write operation.
        serialQueue.asyncAfter(deadline: .now() + 0.100, execute: writeOperation)

        return result
    }

    func restoreStartupTabs(clearPrivateTabs: Bool, tabManager: TabManager) -> Tab? {
        let selectedTab = restoreTabs(savedTabs: archivedStartupTabs.0, clearPrivateTabs: clearPrivateTabs, tabManager: tabManager)
        return selectedTab
    }

    func restoreTabs(savedTabs: [SavedTab], clearPrivateTabs: Bool, tabManager: TabManager) -> Tab? {
        assertIsMainThread("Restoration is a main-only operation")
        guard !lockedForReading, savedTabs.count > 0 else { return nil }
        lockedForReading = true
        defer {
            lockedForReading = false
        }
        var savedTabs = savedTabs
        // Make sure to wipe the private tabs if the user has the pref turned on
        if clearPrivateTabs {
            savedTabs = savedTabs.filter { !$0.isPrivate }
        }

        var tabToSelect: Tab?
        var fxHomeTab: Tab?
        var customHomeTab: Tab?
        
        for savedTab in savedTabs {
            // Provide an empty request to prevent a new tab from loading the home screen
            var tab = tabManager.addTab(flushToDisk: false, zombie: true, isPrivate: savedTab.isPrivate)
            tab = savedTab.configureSavedTabUsing(tab, imageStore: imageStore)
            if savedTab.isSelected {
                tabToSelect = tab
            }
            
            fxHomeTab = tab.isFxHomeTab ? tab : nil
            customHomeTab = tab.isCustomHomeTab ? tab : nil
        }

        if tabToSelect == nil {
            tabToSelect = tabManager.tabs.first(where: { $0.isPrivate == false })
        }
        
        if shouldOpenHome {
            let page = NewTabAccessors.getHomePage(prefs)
            let customUrl = HomeButtonHomePageAccessors.getHomePage(prefs)
            let homeUrl = URL(string: "internal://local/about/home")
            
            if page == .homePage, let customUrl = customUrl {
                return customHomeTab ?? tabManager.addTab(URLRequest(url: customUrl))
            } else if page == .topSites, let homeUrl = homeUrl {
                let home = fxHomeTab ?? tabManager.addTab()
                home.loadRequest(PrivilegedRequest(url: homeUrl) as URLRequest)
                home.url = homeUrl
                return home
            }
            else {
                tabToSelect = tabManager.addTab()
            }
        }
        
        return tabToSelect
    }

    func clearArchive() {
        if let path = tabsStateArchivePath() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// Functions for testing
extension TabManagerStore {
    func testTabCountOnDisk() -> Int {
        assert(AppConstants.IsRunningTest)
        return SiteArchiver.tabsToRestore(tabsStateArchivePath: tabsStateArchivePath()).0.count
    }
}
