# Version identity of the iPad development phase's plugin builds (Bridge/scripts/build-ipad-dev-plugin.sh): never the
# released Build 120 identity, never its output folder.
ABR_LABEL="2.1 iPad dev"
ABR_VERSION=2.1
ABR_BUILD=1
ABR_PLUGIN_BUNDLE_VERSION=2.1.1
ABR_AU_VERSION=$(( 2 * 65536 + 1 * 256 + 1 ))
ABR_DIST="${ABR_DIST:-${PWD}/.build/bridge/ipad-dev-dist}"
