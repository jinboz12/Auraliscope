# Shared public app/plugin release identity.
ABR_LABEL="2.0"
ABR_VERSION=2.0
ABR_BUILD=121
ABR_PLUGIN_BUNDLE_VERSION=2.0.121
ABR_AU_VERSION=$(( 2 * 65536 + 0 * 256 + 121 ))
# A caller may set ABR_DIST to build and test elsewhere (the delivered folder left as it is).
ABR_DIST="${ABR_DIST:-${PWD}/dist/2.0 ver/2.0 build 121}"
