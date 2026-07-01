# OpenVK for legacy VK iPad — project handoff

## Goal and current target

This workspace adapts the App Store build of VK for iPad 2.0.4 to OpenVK by
injecting a rootful Theos tweak. The target app is `VkHdAppstore` with bundle
identifier `com.vk.vkhd`; the test device runs iOS 8.4.1. The production API
host is `api.openvk.org`.

The active implementation is `OpenVKiPadBridge/Tweak.xm`. Package metadata is
in `OpenVKiPadBridge/control`, and the current package version is **0.34.0**.
The iPhone/rootless experiment in `OpenVKiPhoneBridge` is separate and is not
the current target.

Version 0.34.0 fixes notification freshness: `iPadFeedbackViewController`
calls `update` shortly after every `viewDidAppear:`, so a notification received
before the controller installed its observer is visible on the first opening.
Foreground notification pings use OpenVK's `notifications.fetch(last_id)`
Redis-stream cursor every 10 seconds (the same cadence as OpenVK Web). The
first response only synchronizes the cursor and does not replay old events.
Do not pass OpenVK `/nim` events into the legacy client: that endpoint is the
message long-poll and its modern event shape previously caused delayed crashes.

## What already works

- OAuth/password login and the OpenVK application tag (`iPhone`).
- Personal and global feed compatibility, walls, profiles, groups and members.
- Friends, friend requests and actions, comments, photos and album previews.
- Feedback notifications, including likes, comments, reposts and gifts.
- High-resolution/Retina images and profile avatars.
- Native video playback from OpenVK CDN MP4 URLs; there is no runtime LAN proxy
  dependency as of 0.28.0.
- Lists of up to 5000 friends/groups.
- Modern OpenVK geotags are removed from wall posts because the old `VKGeo`
  model crashes while decoding them.

Version 0.29.0 additionally fixes:

- the avatar hook now intercepts only `bigAvatarTap:`; the broad `avatarTap:`
  hook was removed because it captured unrelated profile controls after the
  first presentation;
- the avatar viewer requests `photos.get(owner_id, album_id=-6)` and provides a
  paged gallery with lazy loading of the current and adjacent images;
- Global News selection is tracked at the picker delegate because the legacy
  `setCurrentFeed:` remaps list indices to its built-in filters;
- the Friends/My Photos segmented control is hidden and forced to My Photos;
- the Groups selector is built with a scoped `UIActionSheet` hook which omits
  the Events option; event data-source arrays remain cleared as a second guard.

Version 0.28.0 additionally fixed:

- crash-safe `copy_history` access in the `newsfeedGet` execute script, preventing
  type errors when OpenVK returns `copy_history=null` for non-reposted wall posts
  (fixes news feed loading);
- avatar taps bypass the legacy photo-by-ID path and open the best profile URL
  in a small native full-screen zoomable viewer; this avoids the "Bless to
  you" error caused by absent/zero OpenVK profile-photo IDs;
- `iPadNewsViewController.loadUserLists` now creates exactly two feeds, `My
  news` and `Global news`; the request bridge selects `newsfeed.get` or
  `newsfeed.getGlobal` without changing the normal feed request shape;
- group event arrays are cleared before `updateDataSources`, hiding Events at
  the correct layer, while management requests normalize compound legacy
  filters to OpenVK's exact `filter=admin`;
- OpenVK CDN MP4 URLs are passed directly to AVPlayer. `OVKProxyVideoURL` is a
  compatibility no-op and returns its input unchanged;
- null guards for `parent` and `feedback` fields in `notifications.get`.

Earlier compatibility work includes:

- requesting the `verified` field for users/groups shown in feeds and profiles;
- lazy duration discovery with `AVURLAsset` when an old OpenVK video has
  `duration=0`;
- removal of the Favorites/Bookmarks row from the sidebar's private section
  structure.

## Architecture

The tweak has four main layers:

1. `NSURL` rewrites old VK API/OAuth hosts to `api.openvk.org`.
2. `OVKEmulateLegacyMethod` turns unsupported legacy methods into OpenVK
   `execute` scripts. Most response-shape compatibility belongs here.
3. `NSJSONSerialization` runs all API JSON through `OVKNormalizeJSON`. It
   supplies old field aliases, safe null values, image URLs, notification
   shapes, video URLs and other model-level compatibility.
4. Small class hooks repair behavior that cannot be expressed in JSON, such as
   requests-cell avatars, group selector behavior, video duration labels and
   sidebar sections.

Do not globally bypass TLS. The existing trust hook accepts only the
recoverable missing-root result for the exact OpenVK API certificate, because
iOS 8 lacks the current Let's Encrypt root.

There is an unfinished account/instance-switching prototype near the top of
`Tweak.xm`. Its UI hooks intentionally use the nonexistent class names
`OVKDisabledLoginViewController` and `OVKDisabledSettingsViewController`, so it
is inactive. Routing remains fixed to `api.openvk.org`. Keep it disabled until
the account flow is redesigned and tested separately.

## Build

The Debian build host is reachable as `nyash@furserv` on port 2222. Theos is
installed at `~/theos` and the remote source directory is
`~/OpenVKiPadBridge`.

From the workspace root on Windows:

```powershell
scp -P 2222 OpenVKiPadBridge/Tweak.xm OpenVKiPadBridge/control OpenVKiPadBridge/Makefile nyash@furserv:~/OpenVKiPadBridge/
ssh nyash@furserv -p 2222 "cd ~/OpenVKiPadBridge && make clean package FINALPACKAGE=1 THEOS=~/theos"
scp -P 2222 nyash@furserv:~/OpenVKiPadBridge/packages/org.openvk.ipadbridge_VERSION_iphoneos-arm.deb OpenVKiPadBridge/packages/
```

Always increment `Version:` in `OpenVKiPadBridge/control`; otherwise `dpkg`
and package caches make it too easy to test an older binary by accident.

## Install on the iPad

The test iPad is reachable at `root@192.168.3.90`. Its old SSH server requires
the `ssh-rsa` compatibility options. Let SSH prompt for credentials; do not
commit them to this repository.

```powershell
scp -O -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa OpenVKiPadBridge/packages/org.openvk.ipadbridge_VERSION_iphoneos-arm.deb root@192.168.3.90:/tmp/
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.3.90 "dpkg -i /tmp/org.openvk.ipadbridge_VERSION_iphoneos-arm.deb && killall -9 VkHdAppstore 2>/dev/null || true"
```

The package is rootful and depends on Cydia Substrate. `OpenVKiPadBridge.plist`
limits injection to `com.vk.vkhd`.

## Native video playback

`OVKProxyVideoURL` deliberately returns the original OpenVK CDN URL unchanged.
The old `video_proxy/openvk_video_proxy.py` remains in the workspace only as
historical/diagnostic code and is not used by the tweak. Do not silently turn
it back on.

The 0:00 fallback reads the direct MP4 duration asynchronously with
`AVURLAsset` and caches it for the current process. OpenVK genuinely returns
`duration=0` for some older video rows, so response-field renaming alone cannot
fix them. Some old iOS builds may not decode every audio codec found in uploaded
MP4 files; that is a source-codec limitation, not a reason to add a hidden
network proxy.

## Diagnostics

The tweak writes sanitized request and exception information to:

```text
/tmp/OpenVKiPadBridge.log
```

Useful commands:

```powershell
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.3.90 "tail -200 /tmp/OpenVKiPadBridge.log"
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.3.90 "ls -lt /var/mobile/Library/Logs/CrashReporter | head"
```

When debugging an API mismatch, first capture the method and safe parameters,
then reproduce it directly against OpenVK. Prefer fixing the response shape in
the execute script or `OVKNormalizeJSON`; hook a view/controller only when the
client's own state machine is the problem.

## Regression checklist

After every package change, test at least:

1. Cold launch and login persistence.
2. Feed scrolling for several pages and opening a repost/profile/group.
3. User and group avatar taps.
4. News → Lists → My news and Global news.
5. A verified user and a verified group in both a wall and a profile header.
6. Groups → Management, and confirm Events is absent.
7. An old video formerly showing 0:00; wait briefly for async duration loading,
   then play, seek and confirm audio.
8. Friends, requests, comments, Feedback and photo albums.
9. Sidebar absence of Bookmarks/Favorites.

If a group wall suddenly crashes again, inspect the raw post for a newly added
modern attachment/model. Do not reintroduce `geo`: removing it globally is a
deliberate stability fix for this client.

## Source references

- OpenVK API/documentation checkout: `.cache_openvk` and the upstream
  `OpenVK/openvk` / `OpenVK/docs` repositories.
- Original app bundle and resources: `unpacked/Payload/VkHdAppstore.app`.
- Previous working packages: `OpenVKiPadBridge/packages/`.

Preserve unrelated working compatibility code when making focused changes;
this client is very sensitive to response shapes, and a seemingly harmless
modern field can crash a model initializer several screens later.
