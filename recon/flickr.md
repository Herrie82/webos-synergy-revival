# Flickr — recon

**Verdict: VIABLE (photos).** The REST API and real photo-library browsing are still open in 2026
— the standout PHOTO.UPLOAD gap after the storage providers. Built as a PHOTO.UPLOAD-only
connector (`flickr/`). Untested pending a Flickr API key + secret.

## The catch: OAuth 1.0a (not OAuth2)
Flickr never moved to OAuth2 — it's **3-legged OAuth 1.0a with HMAC-SHA1 request signing**. That's
the one real divergence from the rest of the repo's PKCE/OAuth2 stack. It works here because:

- **Signing happens in node**, not over TLS. `crypto.createHmac('sha1', key)` runs fine on the
  device's OpenSSL-0.9.8k runtime (HMAC-SHA1 is an old algorithm). Only the finished, signed HTTPS
  request is handed to the bundled modern curl for transport.
- `oauth1.js` implements RFC-3986 percent-encoding, the `METHOD&enc(url)&enc(sorted params)`
  signature base string, and the `consumer_secret&token_secret` HMAC key. **The signer was
  verified against the canonical OAuth Core 1.0a Appendix A.5 test vector — exact signature match**
  (`tR3+Ty81lMeYAr/Fid0kMTYa/WM=`).

## Auth flow (3 legs)
1. `GET https://www.flickr.com/services/oauth/request_token` (signed) → `oauth_token` + secret
2. User authorizes at `https://www.flickr.com/services/oauth/authorize?oauth_token=…&perms=read`
   (in Atlas); redirect returns `oauth_verifier` (captured instead of `?code=`)
3. `GET https://www.flickr.com/services/oauth/access_token` (signed) → long-lived `oauth_token` +
   `oauth_token_secret` (both stored)

**Needs the consumer secret** — it's literally half the HMAC key, so unlike Dropbox this can't be a
secretless public client.

## REST (read/browse + download)
`https://api.flickr.com/services/rest/?method=…&api_key=…&format=json&nojsoncallback=1` + signed params:
| Op | Method |
|---|---|
| albums | `flickr.photosets.getList` → sets[]; plus a synthetic "All Photos" album via `flickr.people.getPhotos?user_id=me` |
| photos | `flickr.photosets.getPhotos?photoset_id=&extras=url_o,url_b,url_c,…` |
| download URL | prefer `url_o` (original) else `url_b`, else build `https://live.staticflickr.com/{server}/{id}_{secret}_b.jpg` (ordinary https, no auth header) |

Upload is out of scope — this pulls a user's Flickr photos into the stock Photos app as albums.

## Notes for activation
- Register an app at `flickr.com/services/apps` → API key + secret into
  `flickr/service/com.palm.service.flickr/config.js`.
- Configure the app's callback to allow the auth app's localhost callback (Atlas intercepts it); if
  Flickr rejects a localhost callback for the app type, fall back to the `oob` verifier flow (small
  auth-app change).
- Unlike the single-album storage providers, Flickr exercises the **multi-album** path of the
  Photos-aggregator contract.
