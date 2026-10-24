# Source and binary distribution

Auraliscope's original code is GPL-3.0-only. Official compiled packages may be paid downloads; users may also
compile the code and obtain or redistribute covered binaries from other sources under the GPL. Do not add a
purchase-to-use condition, a ban on third-party binary sharing, or a non-commercial-only condition to GPL copies.
The source repository is https://github.com/jinboz12/Auraliscope. The 2.0 RC changes are local until published.

For each binary download, whether free or paid:

1. Keep LICENSE, COPYRIGHT.md and the third-party notices with the app and plugins (the build scripts bundle them).
2. Offer the exact source for that build, including changes and build scripts, at no additional charge. Put a clear
   link beside the binary download, pointing to an immutable matching tag/commit and a source archive. A link to a
   moving default branch alone does not identify the source for an older installer.
3. Retain the SDK sources and their notices. Bridge/scripts/fetch-sdks.sh pins each SDK repository to a commit;
   scripts/package-source.py also vendors those pinned sources in the source archive for offline availability.
4. Keep docs/ASSET_RIGHTS.md. The normal archive includes the unchanged Pearl image under the owner's confirmed
   public redistribution permission and the Milk Frog image identified by the owner as public domain. The optional
   --without-supplied-artwork mode tests the existing gradient fallback; it is not the normal release source archive.
5. Keep corresponding source available for as long as the chosen GPL distribution method requires. For network
   distribution this project uses GPLv3 section 6(d), with equivalent source access and clear directions next to
   the binaries. A paid store must not add terms that curtail recipients' GPL rights.

No purchase URL, price, store agreement, Developer ID identity or notarization credential has been configured by
this RC preparation. Publishing the code and attaching source links are release-owner actions still to be completed.

## Build

Use macOS 13 or later, Xcode with Swift 6 and the macOS SDK. Current Icon Composer assets need an Xcode toolchain
with actool support for .icon documents (the RC was built with Xcode 27). The app targets macOS 13 on Apple silicon;
Bridge targets macOS 11 on arm64 and x86_64. Intel app execution is not part of this candidate.

```sh
Bridge/scripts/fetch-sdks.sh   # skip when the source archive already contains Bridge/ThirdParty
scripts/test.sh
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/build-tools.sh
Bridge/scripts/e2e-probe.sh
Bridge/scripts/package-installer.sh
Bridge/scripts/package-dist.sh
python3 scripts/package-source.py --output /absolute/path/to/source.tar.gz
```

Set ABR_DIST to an absolute output directory to keep builds separate. Build app and plugins from the same
Bridge/scripts/release-version.sh identity. The shared DSP source lives in Sources/AnalysisCore and
Sources/AnalysisKernels; plugins compile the same code. Build scripts ad hoc sign locally and never install or upload.

GNU references: https://www.gnu.org/licenses/gpl-3.0.html (sections 4, 6 and 10),
https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney,
https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee.
