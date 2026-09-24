import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lets a second launch ask the running copy to open its ring instead of
    /// starting a duplicate menu-bar item.
    static let openRingNotification = Notification.Name("local.chakra.openRing")

    /// `--demo` writes a ring full of apps, so it gets its own defaults domain
    /// rather than overwriting one the user has arranged.
    static let demoSuite = "local.chakra.demo"

    private let isDemo: Bool
    private let settings: Settings
    private let outer: OuterRing
    private let recents: Recents
    private let wheel: WheelController
    private let onboarding: OnboardingController
    /// The file shelf, or nil if its folder could not be resolved.
    ///
    /// Resolved once at launch and held for the process. Nil is survivable on purpose: the launcher
    /// is the app and the shelf is a feature of it, so a shelf that cannot be set up must not stop
    /// Chakra running.
    private let shelf: Shelf?

    private var status: StatusItemController?
    private var settingsWindow: SettingsController?
    private var orb: OrbController?
    private var hotkey: HotKey?
    /// Whether the shortcut is registered. False means another app holds it.
    /// Why the shortcut is not working, or nil when it is.
    private var hotkeyFailure: HotKey.Failure?

    override init() {
        let isDemo = CommandLine.arguments.contains("--demo")
        let defaults = (isDemo ? UserDefaults(suiteName: Self.demoSuite) : nil) ?? .standard
        let outer = OuterRing(defaults: defaults)
        let recents = Recents(defaults: defaults, selfPath: Bundle.main.bundleURL.path)
        let settings = Settings(defaults: defaults)
        self.isDemo = isDemo
        self.settings = settings
        self.outer = outer
        self.recents = recents
        // Resolved once. `defaultRoot()` is not a pure getter — it passes `create: true`, so it may
        // create `~/Library/Application Support` — but it stops there; the `local.chakra/Shelf` pair
        // is `ensureExists()`'s job, on first intake, not at launch.
        shelf = (try? Shelf.defaultRoot()).map { Shelf(root: $0) }
        wheel = WheelController(outer: outer, recents: recents, settings: settings, shelf: shelf)
        onboarding = OnboardingController(outer: outer, recents: recents, settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Chakra lives in the menu bar, but a Dock icon is one of the things the
        // user can ask for, and Info.plist's LSUIElement cannot be conditional.
        DockPresence.apply(settings.showInDock)
        installMainMenu()

        let status = StatusItemController(outer: outer, wheel: wheel, settings: settings)
        status.onSetUpRing = { [weak self] in self?.presentSetUp() }
        status.onOpenSettings = { [weak self] in self?.showSettings() }
        self.status = status

        onboarding.onOpenSettings = { [weak self] in self?.showSettings() }

        installOrb()

        if let shelf {
            // Litter from a *crash*, not from an error: every error path in `copyIn` cleans up after
            // itself, but a crash cannot. One minute is the age gate that stops this deleting a copy
            // still in flight in another instance — two Chakra builds can run at once in development.
            shelf.sweepIncoming(olderThan: 60)
            // The originals still exist wherever they came from, so the shelf is scratch space.
            // Spotlight indexing is deliberately kept; only Time Machine is opted out of.
            shelf.excludeFromBackup()
            shelf.onChange = { [weak self] in
                guard let self, let shelf = self.shelf else { return }
                // One scan, handed to both readers, rather than each of them scanning.
                self.orb?.shelfChanged(loaded: shelf.total().count > 0)
                self.wheel.refresh()
            }
            shelf.startWatching()
        }

        // The orb hides while the wheel is up: the wheel opens at the centre of the
        // screen and the orb would sit on top of it. Registered once and reading
        // `self.orb` when it fires, rather than capturing a particular controller,
        // because the controller is thrown away and rebuilt whenever the setting is
        // switched off and on again.
        wheel.observeVisibility { [weak self] visible in
            self?.orb?.setSuppressed(visible)
        }

        // Start listening before anything else, so an app the user switches to
        // during onboarding still counts as recent.
        recents.startTracking()
        installHotkey()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openRingRemotely),
            name: Self.openRingNotification, object: nil)

        // The orb is switched on and off from the settings window, which has no
        // reference to the app delegate.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChangeNotification, object: nil)

        if isDemo {
            startDemo()
            return
        }

        // A ring that was set up before the recents list existed, or one whose
        // history was cleared, would show an empty inner circle until the user had
        // switched apps five times. Spotlight already knows the answer; asking it
        // off the main thread keeps launch instant.
        recents.seedIfEmptyInBackground { [weak self] in self?.wheel.refresh() }

        let isFirstRun = !settings.didOnboard
        onboarding.presentIfNeeded { [weak self] in
            guard let self, isFirstRun else { return }
            // Show the result of the choice they just made.
            self.wheel.show(atCursor: false)
        }
    }

    /// A menu bar of Chakra's own, so ⌘, and ⌘Q work while the settings window is
    /// focused and the app behaves like an app when it is shown in the Dock.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chakra",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let ringItem = NSMenuItem(title: "Open Ring", action: #selector(openRingFromMenu),
                                  keyEquivalent: "")
        ringItem.target = self
        appMenu.addItem(ringItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chakra", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chakra", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimise",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")

        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openRingFromMenu() { wheel.show(atCursor: false) }

    @objc private func showSettings() {
        let controller = settingsWindow
            ?? SettingsController(outer: outer, settings: settings, wheel: wheel)
        if settingsWindow == nil {
            controller.onHotkeyChanged = { [weak self] in self?.installHotkey() }
            controller.onSetUpRing = { [weak self] in self?.presentSetUp() }
            controller.onRecentreOrb = { [weak self] in self?.orb?.recentre() }
            settingsWindow = controller
        }
        controller.hotkeyStateChanged(failure: hotkeyFailure)
        controller.show()
    }

    private func presentSetUp() {
        onboarding.present { [weak self] in self?.wheel.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.invalidate()
        hotkey = nil
        orb = nil
        DistributedNotificationCenter.default().removeObserver(self)
        // Removes only the app delegate's own observations. StatusItemController,
        // WheelController and OrbController each manage their own lifetimes.
        NotificationCenter.default.removeObserver(self)
    }

    /// Launching an already-running app sends this instead of starting a second
    /// process, so it is the natural place to open the ring.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        wheel.show(atCursor: false)
        return false
    }

    @objc private func openRingRemotely() {
        wheel.show(atCursor: false)
    }

    /// Creates the orb if the user has asked for one. Called again whenever the
    /// setting changes, so it is also the teardown path.
    private func installOrb() {
        guard settings.showOrb else {
            orb?.hide()
            orb = nil
            return
        }
        if orb == nil {
            let controller = OrbController(outer: outer, settings: settings, shelf: shelf)
            controller.onClick = { [weak self] in
                self?.wheel.toggle(atCursor: false, ignoringRecentHide: true)
            }
            controller.onRightClick = { [weak self] event, view in
                self?.status?.showMenu(with: event, relativeTo: view)
            }
            controller.onDropPaths = { [weak self] paths in self?.status?.add(paths) }
            controller.onDropURLs = { [weak self] urls in self?.shelveDropped(urls) }
            orb = controller
        }
        orb?.settingsDidChange()
    }

    /// Puts dropped files on the shelf and says what happened.
    ///
    /// The wheel is opened either way, for the same reason dropping an app on the menu-bar icon
    /// opens it: the user has to be able to see the result, and a refusal that nobody sees is the
    /// same as a silent failure.
    private func shelveDropped(_ urls: [URL]) {
        guard let shelf else { return }
        let outcome = shelf.add(urls)
        orb?.shelfChanged(loaded: shelf.total().count > 0)
        wheel.show(atCursor: false, message: ShelfMessage.summary(outcome, shelf: shelf))
    }

    @objc private func settingsChanged() {
        // `installOrb` already ends with `settingsDidChange()`, so calling it again
        // here would reposition the panel and restart its fade a second time for
        // every setting the user touches.
        installOrb()
    }

    /// Claims the shortcut the user chose. Called again whenever it changes, so an
    /// unavailable combination is recoverable by picking another one.
    private func installHotkey() {
        hotkey?.invalidate()
        hotkey = nil
        // A disabled shortcut is not a failed one: only a combination that could not
        // be registered counts.
        var failure: HotKey.Failure?
        if settings.hotkeyEnabled {
            // Both values are clamped on the way out of Settings, so the
            // conversions cannot trap.
            hotkey = HotKey(keyCode: UInt32(settings.hotkeyKeyCode),
                            modifiers: UInt32(settings.hotkeyModifiers),
                            failure: &failure,
                            action: { [weak self] in self?.wheel.toggle(atCursor: true) })
        }
        hotkeyFailure = failure
        status?.hotkeyFailure = failure
        settingsWindow?.hotkeyStateChanged(failure: failure)
    }

    /// `--demo` exists so the ring can be screenshotted with a full set of apps
    /// without touching a ring the user has already arranged.
    private func startDemo() {
        let candidates = ["/Applications/Slack.app",
                          "/Applications/Microsoft Teams.app",
                          "/Applications/Microsoft Outlook.app",
                          "/System/Applications/Utilities/Terminal.app",
                          "/Applications/Google Chrome.app",
                          "/System/Applications/System Settings.app"]
        if outer.occupiedPaths.isEmpty {
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                _ = outer.addToFirstEmpty(path)
            }
        }
        recents.seedFromSpotlight()
        settings.didOnboard = true
        wheel.show(atCursor: false, message: "Demo ring")
    }
}

// A second copy would install a second menu-bar item and fight over the
// shortcut. Hand the request to the copy that is already running instead.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.openRingNotification, object: nil, userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
