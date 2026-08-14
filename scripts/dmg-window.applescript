-- Applies the drag-to-install window to a mounted, read-write DMG volume.
--
--   osascript scripts/dmg-window.applescript "<volume name>" "<background path>"
--
-- dmgbuild writes every one of these settings into the volume's .DS_Store
-- already, and macOS 26's Finder honours all of them except the backdrop: it
-- ignores a background image referenced by an alias it did not write itself.
-- Re-applying through Finder is the only way to register one it will draw.
-- Twice, because a single pass does not reliably stick.
--
-- The image is drawn one point per pixel, anchored bottom-left, so it must be
-- exactly the content size — 660x420. A 2x asset renders at double size with
-- three quarters of it off-window; macOS 26 ignores both HiDPI TIFFs and DPI
-- metadata, so a Retina-sharp backdrop is not currently possible.

on run argv
    set volumeName to item 1 of argv
    -- Has to be a *visible* file: Finder refuses to coerce a dot-prefixed one to
    -- an alias unless it is displaying hidden files, so release.sh un-hides the
    -- backdrop around this call and renames it back afterwards.
    set bgFile to (POSIX file (item 2 of argv)) as alias
    with timeout of 600 seconds
        tell application "Finder"
            repeat 2 times
                tell disk volumeName
                    open
                    set current view of container window to icon view
                    set toolbar visible of container window to false
                    set statusbar visible of container window to false
                    set the bounds of container window to {180, 140, 840, 592}
                    set viewOptions to the icon view options of container window
                    set arrangement of viewOptions to not arranged
                    set icon size of viewOptions to 128
                    set text size of viewOptions to 13
                    set background picture of viewOptions to bgFile
                    set position of item "notch-911.app" of container window to {196, 210}
                    set position of item "Applications" of container window to {464, 210}
                    update without registering applications
                    close
                end tell
                delay 2
            end repeat
        end tell
    end timeout
    return "finder pass done"
end run
