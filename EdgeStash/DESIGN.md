---
name: EdgeStash Settings
description: Native macOS settings with system accent, semantic controls, and a live indicator preview.
spacing:
  compact: "8pt"
  row: "12pt"
  inset: "16pt"
---

# Design System: EdgeStash Settings

## Overview

**Creative North Star: "Native macOS Settings"**

The Settings window follows the user's macOS appearance and accent. SwiftUI and AppKit supply the visual language: a native sidebar, grouped forms, semantic text, and familiar controls. This records the completed Settings refinement; it does not prescribe a new identity for other EdgeStash surfaces.

The interface keeps explanations available at the relevant setting, while the Appearance pane shows the actual indicator renderer. Standard controls own their platform appearance rather than inheriting a hand-drawn imitation. Release builds must record the current linked SDK while preserving the macOS 13 deployment minimum; the build script checks this so newer macOS styling is enabled.

**Key Characteristics:**
- System accent and semantic foregrounds.
- Grouped native controls with contextual help.
- Native material in navigation and popovers; an accurate indicator preview.

## Colors

### Primary

The macOS accent comes from the system. Settings does not install a fixed tint or force an appearance. A blue accent in a screenshot is an environment value, not an EdgeStash color token.

### Neutral

Primary labels use the standard foreground. Supporting text and information icons use SwiftUI's secondary foreground; the AppKit preview uses `secondaryLabelColor`. Form, sidebar, group-box, and popover backgrounds remain platform-owned.

Required access uses semantic orange with a status label. Shortcut validation uses semantic red with an error icon and text. Meaning is not carried by color alone.

**The System Accent Rule.** Follow macOS accent and appearance; indicator color preferences do not become the Settings accent.

## Typography

The system UI font is the sole type family. SwiftUI semantic roles supply platform sizes and metrics; there is no custom display face or fixed typography scale.

- **Headline:** contextual-help titles.
- **Body:** form content and contextual explanations.
- **Callout:** measurement values, preview label, and sidebar identity; identity uses medium weight.
- **Caption:** version and access status.

Numeric measurements use monospaced digits. The AppKit preview's sample caption uses the system font at 14 points, medium weight; this is a preview detail rather than a reusable typography token.

## Layout

The window uses a balanced `NavigationSplitView`. Its sidebar contains Stash, Shortcuts, and Appearance; the selected pane's title appears in the native navigation area. Sidebar width ranges from 180 to 230 points, with an ideal width of 195 points.

The initial content size is 820 × 680 points and the minimum is 740 × 560 points. The saved window frame can override the initial size. Settings rows align labels and contextual-help buttons at the leading edge and controls at the trailing edge. Reused spacing tokens describe explicit content spacing; native form row metrics remain owned by SwiftUI.

Each pane uses `Form` with grouped styling. In Appearance, the preview is a sibling above the scrolling Form, so it stays visible as controls scroll. The preview has a 95-point content height, with 20-point horizontal outer insets. These dimensions describe this surface, not a global layout grid.

## Elevation & Depth

Native sidebar, navigation, popover, and grouped-control rendering supplies depth. Settings adds no custom shadow stack or glass overlay to the Form. Standard system components adapt with the operating system, consistent with [Apple's Liquid Glass adoption guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).

The indicator is a separate material preference. Its existing AppKit renderer uses untinted regular `NSGlassEffectView` on macOS 26 or later and an `NSVisualEffectView` HUD material fallback on macOS 13–15. Turning glass off restores the chosen indicator colors. The preview reuses that renderer.

**The Material Boundary Rule.** Let native navigation and popovers own their material; keep grouped Forms free of added glass decoration.

## Shapes

Native controls, sections, and the preview's GroupBox retain their platform shapes. Settings defines no replacement card-radius scale. Indicator rounding is user-adjustable and applies to its inward corners, while its outer edge remains square against the display edge.

## Components

### Navigation

A sidebar-style List uses SF Symbols and native selection. The sidebar footer presents the app name and version using semantic type. No custom selection pill or fixed selection color replaces the system treatment.

### Form controls

Use native switches, sliders, pickers, color pickers, buttons, and labeled content. Sliders display a right-aligned formatted value; dependent controls use the standard disabled state. Preserve control accessibility labels and values when visible labels are hidden for alignment.

### Contextual help

An `info.circle` borderless button has a 22 × 22-point target and an accessible label. A native popover presents a headline and selectable body text in a 300-point-wide content area with the inset spacing token.

Hovering opens help after a short delay. Crossing from the icon into the help content keeps it readable. Clicking or activating the button by keyboard pins it; a second activation, Escape, or the native outside dismissal closes it. Leaving an unpinned icon and popover dismisses help after a short grace period.

### Shortcut recording

Native buttons show the current key combination or recording prompt. Clear buttons use SF Symbols and accessible labels. Recording instructions and validation errors occupy the same grouped form area. Preserve the visible error and cancellation states.

### Indicator preview

A native GroupBox contains the actual AppKit indicator view, updated from current preferences. It stays above the scrolling Appearance controls. Glass and solid-color modes preview the indicator's real material and shape rather than a separate illustration.

## Do's and Don'ts

### Do:
- **Do** inherit macOS accent, appearance, semantic type, and standard control states.
- **Do** preserve contextual explanations and keyboard-accessible actions.
- **Do** use the actual indicator renderer for preview fidelity.
- **Do** retain the macOS 26 availability guard and earlier-system material fallback.

### Don't:
- **Don't** turn indicator color preferences into a fixed Settings tint.
- **Don't** add decorative glass layers to the grouped Settings Forms.
- **Don't** replace native controls with custom visual replicas for this surface.
- **Don't** infer fixed system colors, radii, or font metrics from a screenshot.
