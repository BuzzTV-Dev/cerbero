# Building GStreamer for Android

Produces a drop-in replacement for the official
`gstreamer-1.0-android-universal-<version>.tar.xz`, so the Android app links a
GStreamer we control and can patch instead of the prebuilt one from
gstreamer.freedesktop.org.

Based on cerbero `1.28` (`CERBERO_VERSION` in `cerbero/enums.py`), which builds
the `1.28` branch of the gstreamer monorepo.

## Prerequisites

`bootstrap` below installs the host packages itself, from the list in
`cerbero/bootstrap/linux.py`. Pass `--system=no` instead if your distribution is
already set up and you would rather cerbero did not touch it.

One requirement is not in that list: **autoconf 2.71 or newer** on the host, plus
the automake and autopoint that come with it. `recipes/zvbi.recipe` generates its
`configure` with the host autotools because zvbi requires 2.71 while cerbero's
build tools pin 2.69 -- see the zvbi section below. The recipe fails with a clear
message if what it finds is older.

Everything else -- NDK r29, the Rust toolchains, the build tools -- cerbero
downloads itself.

## Configuration

Two config files, used together with the upstream universal Android config:

```sh
CB="./cerbero-uninstalled -c config/cross-android-universal.cbc \
                          -c config/buzztv-gstreamer-branch.cbc \
                          -c config/buzztv-android.cbc"
```

The order matters, and so does the fact that only one of those file names
contains `universal`: cerbero resolves the per-arch `.cbc` paths in
`buzztv-android.cbc` relative to the directory of whichever `-c` file has
`universal` in its name.

`config/buzztv-android.cbc` limits the build to arm64 and armv7, the ABIs the app
ships; x86 and x86_64 are in the upstream universal tarball but nothing links
them. `config/buzztv-gstreamer-branch.cbc` pins the monorepo to a pre-patched
branch, explained under the baseparse backport below.

This build wants tens of gigabytes. To put the build tree somewhere other than
cerbero's default of `~/cerbero`, add one more `-c` file that sets `home_dir`
rather than editing a committed one, so no local path ends up in the repository.

## Build

```sh
$CB bootstrap --assume-yes
$CB fetch gstreamer-1.0                        # creates the monorepo clone
./tools/buzztv-prepare-gstreamer-branch.sh     # builds the buzztv-1.28 branch
$CB package -f -o <output-dir> gstreamer-1.0-buzztv-android
```

`package` writes two tarballs; the app needs the one without the `-runtime`
suffix, which carries the static archives, the `.la` files, the pkgconfig files
and `share/gst-android/ndk-build`. Re-run
`buzztv-prepare-gstreamer-branch.sh` whenever a patch is added under
`recipes/gstreamer-1.0/` or upstream `1.28` moves; `-f` lets `package` overwrite
an existing tarball.

## Local changes against upstream cerbero

### 1. `recipes/openssl.recipe`: hardware AES on 32-bit Android

`aes_v8_set_encrypt_key` is mis-assembled for 32-bit Android. The `adr
$ptr,.Lrcon` that sets up the round-constant pointer is emitted only when the
perlasm flavour name matches `/32/`, and `android-arm` in OpenSSL's
`Configurations/15-android.conf` uses flavour `void`. The register still holds
the -2 bad-key-size sentinel when the first `vld1.32` reads through it, so every
AES operation reaching the ARMv8 crypto-extension path faults on armv7.

The patch tests `!~ /64/` instead, which is what every other 32-bit-only block in
that file already does. Verify on the built archive:

```sh
llvm-objdump -d --disassemble-symbols=aes_v8_set_encrypt_key <prefix>/armv7/lib/libcrypto.a
```

There must be an `adr` between the `tst`/`bne` argument checks and the first
`veor q0, q0, q0`. The official prebuilt has none; this build does. An app
working around the defect by setting `OPENSSL_armcap=0` -- which disables
hardware crypto on every 32-bit device -- can stop doing so, after a check on
hardware.

This is an upstream OpenSSL bug affecting any 32-bit Android build, and worth
reporting there.

### 2. `recipes/gst-plugins-rs.recipe`: the workspace library, and trimming it

Two changes.

**`libgstrsworkspace.la`.** The melded workspace archive is installed as
`lib/libgstrsworkspace.a`, but `gstrsworkspace.pc` advertised
`-L${libdir}/gstreamer-1.0` -- the wrong directory -- and no `.la` was generated
at all, while every Rust plugin's `.la` lists `libgstrsworkspace.la` in
`dependency_libs`. `libtool-find-lib` in `share/gst-android/ndk-build/tools.mk`
searches the `-L` paths for `lib<name>.la`, finds nothing, falls back to a bare
`-lgstrsworkspace`, and the link fails. That is why `rsclosedcaption`, and with
it `cea608tojson`, cannot be linked from the official prebuilt. Both halves are
fixed; this is an upstream cerbero bug, reproducible in the shipped tarball.

**`ANDROID_CARGO_PACKAGES`.** On Android the workspace is trimmed to the plugins
the app links -- `closedcaption` today. `cargo_packages` is the single source of
truth for what is compiled *and* for what is packaged, since the recipe only
enables a plugin whose cargo package is listed, so trimming it trims the whole
build. Two things had to be handled for that to work:

* The `gst<component>/v1_22` features exist to raise the minimum GStreamer API
  version, and a `dep/feature` is only valid when `dep` is a dependency of a
  package being built. A trimmed workspace does not have most of them and cargo
  fails rather than ignoring them, so `prune_unavailable_features()` derives the
  set from the enabled packages' manifests. It stays correct when
  `ANDROID_CARGO_PACKAGES` changes.
* dragonfire moves object files that appear in *more than one* plugin archive
  into the workspace library. With a single plugin nothing is shared, so it
  writes no archive at all -- while the `.pc`, the `.la` and the file lists all
  still name one. The recipe now creates an empty archive in that case, which
  links as a no-op, rather than making all of that conditional.

### 3. `recipes/gstreamer-1.0/0001-baseparse-*.patch`, via the `buzztv-1.28` branch

Backport of gstreamer!12032, which landed after the 1.28 branch and first ships
in 1.30. Without it the video parsers let `GstBaseParse` interpolate duplicated
PTS and HEVC frames come out reordered.

This patch is **not** in a recipe `patches` list, and must not be: all GStreamer
recipes share one checkout of the monorepo (`recipes/custom.py`), and cerbero
applies patches with `git am`, which commits. HEAD then no longer equals the
recipe commit, so the next patch-less sibling recipe -- `gst-plugins-base-1.0`,
`gst-plugins-bad-1.0`, ... -- takes the `shutil.rmtree(src_dir)` branch of
`Git.extract_impl()` and re-checks-out a clean tree. The patch survives for
`gstreamer-1.0` alone and is silently gone for everything built after it.

Instead `tools/buzztv-prepare-gstreamer-branch.sh` commits the patches onto a
`buzztv-1.28` branch in the source clone and `config/buzztv-gstreamer-branch.cbc`
pins `recipes_commits`. `custom.GStreamer` propagates that commit to every
gstreamer recipe, so all subprojects build from one consistent, pre-patched tree
and no recipe has a reason to re-extract.

Verify (the API is `duplicat**ed**`, not `duplicate`):

```sh
llvm-nm --defined-only <prefix>/arm64/lib/libgstbase-1.0.a | grep gst_base_parse_set_allow_duplicated_pts
llvm-nm --undefined-only <prefix>/arm64/lib/gstreamer-1.0/libgstvideoparsersbad.a | grep -c gst_base_parse_set_allow_duplicated_pts
```

One definition, and a non-zero count -- 12 here, one per parser that opts in.

### 4. `recipes/zvbi.recipe` (new) and `teletext` enabled in `gst-plugins-bad`

`teletextdec` is the only teletext decoder in GStreamer and needs libzvbi, which
upstream cerbero has no recipe for. The blocker was never technical: zvbi's
`COPYING.md` opens with `License: GPL-2+`, which would make
`libgstreamer_android.so` -- and anything linking it -- a GPL work.

The same file then says **all files in `src/*`, the library, are LGPL-2+**, and
names the exceptions: `src/pdc.*` and `src/packet-830.*` are GPL-2 (also
`src/ure.*` MIT, the DVB headers and `strptime.*` LGPL-2.1+, `videodev2k.h`
GPL-2+ or BSD-3-Clause). Exactly two references reach the GPL-2 units from LGPL
code, both in `packet.c`; `vbi_decode_vps_pdc`, called from the same file, is
defined in the LGPL-2+ `vps.c`. So `0001` drops those two translation units and
both calls:

```sh
llvm-nm --defined-only <prefix>/armv7/lib/libzvbi.a \
  | grep -cE ' (T|t) (vbi_pil_|vbi_pty_validity|vbi_decode_teletext_830|_vbi_pil_)'
llvm-nm --undefined-only <prefix>/armv7/lib/libzvbi.a | grep -c 'vbi_pil_'
```

Both must print 0, and `vbi_fetch_vt_page` -- the teletext page decoder -- must be
present. What is lost is PDC and packet 8/30 local time:
`VBI_EVENT_LOCAL_TIME` and `VBI_EVENT_PROG_ID` never fire. Network
identification (`parse_bsd`) is unaffected. `pdc.h` stays in `LIBZVBI_HDRS`
because `event.h` and `vps.h` use `vbi_program_id` and `vbi_pil` in their own
public declarations; headers emit no object code, so the archive is clean either
way.

**This rests on a legal reading -- that the `src/*` clause governs those files --
which is a decision for a human, not a build setting.**

The other zvbi patches are Android cross-build fixes with no licensing content:
bionic has pthread in libc and ships no libpthread (and the existing fallback
probe calls `pthread_create()` with no arguments, which clang under C23
rejects); `nl_langinfo` is declared only from API 26 while `<langinfo.h>` exists
at every level; `AC_FUNC_MALLOC`/`AC_FUNC_REALLOC` assume non-GNU behaviour when
cross compiling, which `config/windows.config` already works around the same way;
and gettext's `lib-link.m4` links iconv by absolute path, which `post_install()`
rewrites to the `-liconv` / `libiconv.la` form the rest of cerbero uses. `0004`
ships a `LICENSING-NOTE.md` next to `COPYING.md`, because the license folder
would otherwise show only the GPL-2+ headline.

The plugin name for a `GSTREAMER_PLUGINS` list is `teletext`; the element is
`teletextdec` and the entry point `gst_plugin_teletext_register`. Its only
external symbols are `g*`, `gst*` and `vbi_*` -- no pango -- so an app that sets
`GSTREAMER_INCLUDE_FONTS := no` is unaffected. It outputs RGBA video or
`text/x-raw` (utf-8 or pango-markup).

### 5. No SVG overlay on Android

`gst-plugins-bad`'s `rsvg` plugin, and the librsvg it needs, are skipped for
Android: 297 MB of static archive on arm64 and one of the longest Rust builds in
the tree, for a plugin an Android app has no use for. This touches
`recipes/gst-plugins-bad-1.0.recipe` and `packages/base-system-1.0.package`,
which is what shipped the library.

### 6. `packages/gstreamer-1.0-buzztv-android`

The subset of the SDK the app's plugin list resolves to, rather than every
sub-package. The package file lists the categories and what each contributes.

### 7. `recipes/gstreamer-1.0/0002-androidmedia-*.patch`: multichannel audio sinks

`openslessink` takes S16LE/U8 stereo at most, so GStreamer on Android can't
output 5.1/7.1 PCM or compressed passthrough. The patch adds two elements to
the `androidmedia` plugin (which the app already links, so there's no new
`GSTREAMER_PLUGINS` entry). Upstream has no equivalent: as of 2026-09 there's no
AAudio or AudioTrack sink in gst-plugins-bad `main`, and no merge request or
issue for one. The patch goes in through the `buzztv-1.28` branch, like the
baseparse one in section 3.

Both sinks are registered at `GST_RANK_NONE`, so `autoaudiosink` and playbin's
default still pick `openslessink`. Create them by name.

| | `aaudiosink` | `audiotracksink` |
| --- | --- | --- |
| API | NDK AAudio, `libaaudio.so` loaded at runtime | `android.media.AudioTrack` over JNI |
| registered from | API 26 (the element doesn't exist when libaaudio is missing) | API 23 (`AudioTrack.Builder`) |
| PCM formats | F32LE, S16LE; plus S32LE, S24LE (packed) from API 31 | same |
| PCM channels | 1-2; 1-8 from API 32 (`AAudioStreamBuilder_setChannelMask`) | 1-8 |
| PCM rates | 8000-192000, resampled by the framework | same |
| IEC 61937 | API 34+ (`AAUDIO_FORMAT_IEC61937`), only with `passthrough=true` | API 24+ (`ENCODING_IEC61937`), only with `passthrough=true` |

**Channel layouts**, as GStreamer `channel-mask` → Android mask. These are the
layouts ExoPlayer's and mpv's AudioTrack outputs open:

| channels | `channel-mask` | Android |
| --- | --- | --- |
| 1 | none | `CHANNEL_OUT_MONO` |
| 2 | `0x3` | `STEREO` |
| 3 | `0x7` | `STEREO \| FRONT_CENTER` |
| 4 | `0x33` (rear), `0xc03` (side) | `QUAD` |
| 5 | `0x37` (rear), `0xc07` (side) | `QUAD \| FRONT_CENTER` |
| 6 | `0x3f` (5.1 rear), `0xc0f` (5.1 side) | `5POINT1` |
| 7 | `0x13f` | `5POINT1 \| BACK_CENTER` |
| 8 | `0xc3f` | `7POINT1_SURROUND` |

The side-surround variants map onto the back-surround Android layout with the
same channel count. AC-3 and AAC decoders emit either one, the two channels sit
in the same slots, and Android's "5.1" means back surround anyway. No layout in
the table needs reordering. Anything else is converted by an `audioconvert`
upstream of the sink.

**Passthrough** (`passthrough` property, default `false`). The sink payloads
the input as IEC 61937 with `gst_audio_iec61937_payload()` and plays it as
2-channel 16-bit:

| caps | IEC 61937 rate |
| --- | --- |
| `audio/x-ac3, framed=true`, 32/44.1/48 kHz | codec rate |
| `audio/x-eac3, framed=true, alignment=frame`, 32/44.1/48 kHz | 4 × codec rate (192 kHz for 48 kHz E-AC-3) |
| `audio/x-dts, framed=true, block-size={512,1024,2048}`, 32/44.1/48 kHz | codec rate |

The caps need a parser (`ac3parse`, `dcaparse`) in front of the sink. That's
also what makes decodebin/playbin skip the decoder once the sink advertises
them. TrueHD and DTS-HD aren't offered because GStreamer's payloader can't pack
them. E-AC-3 has to be frame-aligned: upstream's payloader refuses
`alignment=iec61937` (a check that has been inverted since it was written). So
E-AC-3 frames with fewer than six audio blocks aren't packed the way the
standard wants; broadcast E-AC-3 uses six. The IEC 61937 rate is never clamped
to the mixer's native rate. That clamp is what kept mpv from passing E-AC-3
through on the p6 (libmpv-android-video-build PR #5).

Which passthrough codecs each sink offers:

* `audiotracksink`, API 29+: the ones `AudioTrack.isDirectPlaybackSupported()`
  reports for the current output, probed at NULL→READY. That reflects what the
  HDMI sink (the AV receiver's EDID) accepts. It asks about `ENCODING_AC3` /
  `E_AC3` / `DTS` and then sends IEC 61937 regardless, as mpv does on these
  boxes.
* `audiotracksink`, API 24-28: all three. A track the output can't take fails
  to open, and the pipeline errors out.
* `aaudiosink`, API 34+: all three. AAudio has no capability query, so set
  `passthrough` only when the output is known to take them.

On API 32-33 (the p6 is 33) passthrough is `audiotracksink` only.

**Threads.** `audiotracksink` makes every JNI call on one thread it owns
(`audiotrack-jni`); the state-change, streaming and ring buffer threads only
queue work to it. This matters because attaching a thread the app created, such
as a tokio worker, to the VM has wedged MediaCodec in this app before. The
JavaVM comes from androidmedia's existing `gst_amc_jni_*` plumbing, i.e. the
app's `gst_android_get_java_vm` hook; there's no new JNI setup. Both sinks
write without blocking (AAudio with a 10 ms timeout, AudioTrack with
`WRITE_NON_BLOCKING`) and check the ring buffer state on every pass, so a pause
or flush never waits on a full device buffer. Both reopen the stream or track
when the output goes away (`AAUDIO_ERROR_DISCONNECTED`, `ERROR_DEAD_OBJECT`),
e.g. on HDMI replug.

`ci/buzztv/required-elements.txt` makes CI refuse to publish a tarball whose
`libgstandroidmedia.a` lacks either element, so a patch that stops applying
fails the build rather than the app.

**Switching the app** (iptv-flutter, a follow-up there): `create_audio_sink()`
in `coreapi/features/gstreamer_player/src/pipelines.rs` makes
`audiotracksink`, or `aaudiosink` for PCM only, instead of `openslessink`. Keep
`qos=true`, and keep an `audioconvert` in front of it. `channel_mix_filter`'s
stereo downmix (BuzzTV-Dev/BuzzTV#203) can then pass 5.1/7.1 through when the
Audio Output setting asks for them. `Android.mk` needs no change. Before
blaming a sink for stereo output, check whether the HDMI profile advertises
multichannel at all:

```sh
adb shell dumpsys media.audio_policy | grep -A30 -i hdmi   # the output's channel masks and encodings
adb shell dumpsys media.audio_flinger | grep -iE 'channel (count|mask)|format'   # what the track actually got
```

If the profile is stereo only, Android downmixes whatever the sink sends. The
p6 (rk3588, API 33) is such a box. Its only PCM mix port, `primary output`,
is PCM 16-bit, 44.1/48 kHz, mask `0x3`. Its HDMI `hdmi_bitstream` direct port
takes AC-3, E-AC-3 (JOC too), DTS, DTS-HD and IEC 61937 up to 192 kHz. So on
the p6 a 5.1 track opens with mask `0xfc` and is mixed down to stereo, and
passthrough through `audiotracksink` is the only way to get more than two
channels to a receiver.

## What the trimming is worth

Measured on this branch, both ABIs in one tarball:

| | tarball | plugins (arm64) |
| --- | --- | --- |
| `gstreamer-1.0`, the full SDK | 494 MiB | 248 |
| the subset package alone | 456 MiB | 242 |
| plus the Rust workspace trim | 320 MiB | 195 |
| plus dropping librsvg | **256 MiB** | 195 |

Note where the money was. The subset package on its own is worth ~8% and
**nothing** in build time: `gst-plugins-bad` and friends depend on x264, x265 and
the rest as build dependencies whether or not a package ships them, so the same
91 recipes get built either way. The two recipe-level changes are what pay,
because they stop work from happening at all -- the full Rust workspace and
librsvg are the two longest builds in an Android run.

Remaining candidates, in size order, none of them linked by the app:
`libwebrtc-audio-processing` (47 MiB, behind `webrtcdsp` in effects), `dav1d`
(named unconditionally by the codecs package), `libharfbuzz` and `libavcodec`
(the latter is needed -- the app uses `avdec_ac3`/`eac3`/`mp2`).

## CI: `.github/workflows/buzztv-android.yml`

Mirrors the GitLab job (`.gitlab-ci.yml`'s "cerbero cross-android universal":
bootstrap, fetch, package) with three differences:

* it builds `gstreamer-1.0-buzztv-android`, not the full SDK;
* it builds **one ABI per job** (`cross-android-arm64.cbc`,
  `cross-android-armv7.cbc`) rather than the universal config in one job, so each
  job fits inside a runner's 6 hour limit -- a hosted runner has far fewer cores
  than a workstation. `ci/buzztv/assemble-universal.sh` then puts the halves back
  into the `arm64/` + `armv7/` layout the app extracts, and refuses to publish a
  tree missing anything in `ci/buzztv/required-plugins.txt`;
* it publishes a **release asset**, because a workflow artifact needs a token and
  an API call to download while a build script wants a plain URL.

The committed configs are not used verbatim by CI: `config/buzztv-android.cbc`
lists `universal_archs`, which a per-ABI build does not want. The workflow writes
its own localconf and shares only `config/buzztv-gstreamer-branch.cbc`, which is
why that pin lives in its own file.

### Debug info on armv7

`config/cross-android-armv7.cbc` carries upstream's
`variants.override('nodebug')`, and whether it takes effect depends on how the
build is invoked: a universal build never applies it -- which is why the
official prebuilts, and any local universal build here, ship armv7 *with* debug
info -- while a per-ABI build does. Since CI builds one ABI per job, the first
release came out with armv7 stripped: `libavcodec.a` was 13 MiB against 72 MiB
on the other side of the same tarball.

The workflow therefore passes `-v debug` explicitly, for parity with the
prebuilt it replaces. The cost is roughly 70 MiB of download; the alternative is
no symbolication of GStreamer frames in armv7 crash reports, on the 32-bit
devices where they are most needed. The variant only adds `-g` --
`-Doptimization=s` and assertions are the same either way -- so this changes what
can be debugged, not what is executed.

Note that cerbero's Debian bootstrapper runs `apt-get install` without an
`apt-get update` first -- fine against the prepared images the GitLab CI uses,
but a runner's package index can be older than the mirrors it points at, and then
install fails with exit 100. The workflow refreshes the index first.

Trigger it with `workflow_dispatch` (tick `publish` to cut a release) or by
pushing an `android-*` tag. The published assets are the tarball and its
`.sha256`, at:

```
https://github.com/<owner>/<repo>/releases/download/<tag>/gstreamer-1.0-android-universal-<version>.tar.xz
```

## Using the result

The app consumes `<prebuilt-dir>/<version>/{arm64,armv7}/...`, with the version
pinned in its fetch script and in its gradle build; both must agree. Extract the
devel tarball into that layout under the built version number and point both pins
at it, with `GST_SHA256` set from the published `.sha256`.

Changing the plugin set is a decision on the app side: its `GSTREAMER_PLUGINS`
list and the runtime list that registers the static plugins must move together,
and `ci/buzztv/required-plugins.txt` here should follow.

## Not done

**`amcvideodec` rendering into an application-supplied `Surface`.**
`amcvideodec` always configures MediaCodec against its own `SurfaceTexture` and
outputs `GLMemory`, so the dataspace and the 10-bit depth an HDR display needs
are gone before any sink sees the frame -- no sink can recover them. Teaching it
to accept an application `Surface` and `releaseOutputBuffer(render=true)` is what
would make HDR work through GStreamer, and it is upstream-scale feature work
rather than a recipe change.
