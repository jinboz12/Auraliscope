# Version of Auraliscope LABS (the test app with the DAW plugin source) and the Auraliscope Bridge plugins that ship
# with it, sourced by the Bridge build scripts. The app's own copy is in Bridge/App/Info.plist (its CFBundleVersion
# must equal ABR_BUILD); the release identity (Resources/Info.plist) is never read or written by these scripts.
# Build numbers continue the release sequence: 63 is the first after Auraliscope 1.2.2 (build 62).
ABR_LABEL=1.3dev
ABR_VERSION=1.3
ABR_BUILD=65
# The plugins' bundle and AU versions sit below any official release (0.<build>), so an official Auraliscope Bridge
# installer replaces these test plugins; the label above is what the plugin window and hosts show.
ABR_PLUGIN_BUNDLE_VERSION=0.${ABR_BUILD}
ABR_AU_VERSION=$(( 0 * 65536 + ABR_BUILD * 256 + 0 ))  # 0.<build>.0 packed as major.minor.bugfix
ABR_DIST="${PWD}/experimental-dist/Auraliscope LABS ${ABR_LABEL} build ${ABR_BUILD}"
