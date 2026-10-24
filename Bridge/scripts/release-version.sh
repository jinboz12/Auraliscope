# Shared public app/plugin release identity.
ABR_LABEL="2.0 rc 2"
ABR_VERSION=2.0
ABR_BUILD=118
ABR_PLUGIN_BUNDLE_VERSION=2.0.118
ABR_AU_VERSION=$(( 2 * 65536 + 0 * 256 + 118 ))
# A caller may set ABR_DIST to build and test elsewhere (the delivered folder left as it is).
ABR_DIST="${ABR_DIST:-${PWD}/dist/2.0 ver/2.0 rc 2 build 118}"
