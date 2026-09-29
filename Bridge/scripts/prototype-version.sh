# Version of Auraliscope Labs (the test app with the DAW Plugin source) and the Auraliscope Bridge plugins that ship
# with it, sourced by the Bridge build scripts. The app's own copy is in Bridge/App/Info.plist; the release identity
# (Resources/Info.plist) is never read or written by these scripts.
ABR_LABEL=1.3dev
ABR_VERSION=1.3
ABR_BUILD=2
ABR_AU_VERSION=$(( 1 * 65536 + 3 * 256 + 0 ))  # 1.3.0 packed as major.minor.bugfix
ABR_DIST="${PWD}/experimental-dist/Auraliscope Labs ${ABR_LABEL} build ${ABR_BUILD}"
