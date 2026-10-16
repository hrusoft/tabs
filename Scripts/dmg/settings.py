# dmgbuild's settings for the Tabs dmg. Scripts/make-dmg.sh runs it and passes the paths:
# -D app=… readme=… icon=… background=…
#
# Finder reads what this writes when the dmg mounts: an icon view in a window of a fixed size (dmgbuild's defaults
# hide the toolbar, sidebar, path bar and status bar), over the background, each item where the background expects
# it. Locations are the centres of the 128 pt icons, in points from the top left of the window's content:
# Artwork/dmg-background.svg is drawn around the same points.

format = "ULFO"  # lzfse

# No hide_extensions: its flag is Finder info on the bundle, which codesign --strict refuses. Finder shows an app
# without ".app" anyway.
files = [(defines["app"], "Tabs.app"), (defines["readme"], "Read Me.txt")]
symlinks = {"Applications": "/Applications"}

icon = defines["icon"]
# With background@2x.png beside it: dmgbuild packs the two into one Retina TIFF.
background = defines["background"]

# The frame: 460 pt of content under a 28 pt title bar. The art runs 40 pt below the content, so a window that
# comes out taller shows more of it, never an edge.
window_rect = ((200, 120), (660, 488))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    "Tabs.app": (165, 146),
    "Applications": (495, 146),
    "Read Me.txt": (220, 330),
}
