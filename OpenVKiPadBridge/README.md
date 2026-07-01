# OpenVK Bridge for VK iPad

A small rootful Theos tweak for the legacy VK iPad app (`com.vk.vkhd`). It
redirects only the client's VK API and OAuth traffic:

- `api.vk.com` -> `api.openvk.org`
- `oauth.vk.com` -> `api.openvk.org`
- `api.openvk.org/token/` -> `api.openvk.org/token`
- plain HTTP API requests are upgraded to HTTPS before CFNetwork sends them

Normal profile and content links on `vk.com` are intentionally unchanged.
Replacement is also applied inside the OAuth query string, so the old
`redirect_uri=https://oauth.vk.com/blank.html` becomes an OpenVK URL.

iOS 8 predates the Let's Encrypt root currently used by `api.openvk.org`.
The tweak therefore accepts the recoverable missing-root trust result only
when the presented leaf certificate's subject is exactly `api.openvk.org`.
It does not disable certificate validation for other hosts.

## Build

```sh
export THEOS=~/theos
make clean package FINALPACKAGE=1
```

The resulting rootful package is written to `packages/`. Install it on a
jailbroken iOS 8 device with Cydia Substrate, then restart the VK app.

For the full architecture, deployment workflow, diagnostics and regression
checklist, see [`../PROJECT_HANDOFF.md`](../PROJECT_HANDOFF.md).
