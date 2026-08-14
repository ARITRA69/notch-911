# dmgbuild recipe for the release DMG. Driven by scripts/release.sh:
#
#   dmgbuild -s scripts/dmg-settings.py -D app=<path> -D background=<tiff> \
#            "notch-911 X.Y.Z" dist/notch-911-X.Y.Z.dmg
#
# dmgbuild writes the volume's .DS_Store itself, so the layout below needs no
# Finder and no Apple Events. The one thing it cannot do is the backdrop: macOS
# 26's Finder ignores a background image referenced by an alias it did not write
# itself, so release.sh re-applies that through Finder afterwards. Everything
# here still lands on a CI runner with no login session; only the backdrop needs
# the second pass.

import os.path

application = defines["app"]
appname = os.path.basename(application)

# Read-write on purpose: Finder has to be able to write the volume's .DS_Store
# in the backdrop pass. release.sh compresses to UDZO afterwards.
format = "UDRW"

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]

background = defines["background"]

# Frame size, not content size: Finder stores the whole window rect here, and
# the 32pt title bar eats into it. The backdrop covers only the content area, so
# it has to be the 660x420 that make-dmg-background.swift draws, plus the bar —
# without the allowance the caption gets cropped off the bottom.
window_rect = ((180, 140), (660, 420 + 32))

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128

# Icon centres. Keep these in step with the two centres in
# make-dmg-background.swift, or the icons drift off the card.
icon_locations = {
    appname: (196, 210),
    "Applications": (464, 210),
}
