# xamine

A menu-bar app for macOS that inspects any app's UI hierarchy and generates XCUITest queries for it.

- **⌘⇧X** (or *Inspect Application…* in the menu bar) starts a ⌘⇧5-style window picker.
- The inspector shows the window screenshot, the element hierarchy, and two queries for the selected element — by identifier/label and by hierarchy position. Click a query (or an element in the screenshot) to copy it.
- Picking the iOS Simulator window inspects the running iOS app.

## Build

```sh
brew install xcodegen
xcodegen generate
open Xamine.xcodeproj
```

xamine needs **Accessibility** and **Screen Recording** permission; it walks you through granting them on first launch. It can't be sandboxed, because the Accessibility API can't read other apps from inside the sandbox.
