# Privacy Policy

**Project:** webOS Synergy Revival — cloud storage connectors
**Repository:** https://github.com/Herrie82/webos-synergy-revival
**Last updated:** 22 July 2026

This Privacy Policy describes how the webOS Synergy Revival connector software (the
"Software") handles information. The Software is a free, open-source, non-commercial
community project that lets you connect your own third-party cloud storage account
(such as Koofr) to your legacy webOS device (e.g. an HP TouchPad) for browsing,
uploading, downloading and syncing your own files and photos.

## Summary

- We (the project maintainers) **do not collect, receive, store, sell, or share any of
  your personal data.**
- The project **operates no servers and no backend.** There is nothing for us to collect
  data with.
- The Software runs **entirely on your device.** Your data flows **directly** between your
  device and your chosen cloud provider's own servers.
- There is **no analytics, tracking, advertising, or telemetry** of any kind.

## What information the Software handles (on your device only)

To provide its features, the Software processes the following **locally on your device**:

- **Your cloud account credentials.** When you sign in, an authorization token (for OAuth
  providers) or an application password (for providers that use one) is obtained from your
  chosen provider and stored in your device's local account database so the Software can
  access your storage on your behalf. These credentials are **never transmitted to the
  project maintainers or to any third party** other than the cloud provider that issued them.
- **The files and photos you choose to access.** When you browse, open, upload, download or
  sync a file or photo, its contents pass between your device and your cloud provider. This
  data is **not** routed through, copied to, or retained by the project maintainers.

## Where your data goes

All network communication is made **directly from your device to your chosen cloud
provider's official API** over an encrypted (HTTPS) connection — for example,
`https://app.koofr.net` for Koofr. The project maintainers have no involvement in, and no
access to, this traffic.

Your use of the cloud provider is also governed by **that provider's own privacy policy and
terms** (for example, Koofr's), which you should review separately.

## Storage and retention

Credentials and any cached data are stored only in your device's local storage. **Removing
the account from your device deletes the stored credentials.** You can also revoke the
Software's access at any time from your cloud provider's account/security settings (for
example, Koofr → Preferences → Connected apps / App passwords).

## Third parties

The Software does not integrate any third-party analytics, advertising, or data-sharing
services. The only third party involved is the **cloud storage provider you choose to
connect**, and only to the extent needed to provide the features you use.

## Children

The Software is general-purpose software and is not directed at children under 13, and we do
not knowingly collect any information from anyone (we collect no information at all).

## Changes to this policy

This policy may be updated from time to time. Changes will be published at this document's
URL in the project repository, with the "Last updated" date revised accordingly.

## Contact

Questions about this policy or the Software can be raised via the project's issue tracker:
https://github.com/Herrie82/webos-synergy-revival/issues
