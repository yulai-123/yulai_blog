# Deployment Notes

The blog is a static Hexo site. Production should serve the generated `public/`
directory with Nginx instead of running `hexo server`.

## Build

```bash
npm ci
npm run build
```

The generated site is written to `public/`.

## Recommended VPS Layout

```text
/srv/yulai_blog/repo     # git checkout
/srv/yulai_blog/public   # optional release/symlink target
```

Deployment can either build directly in `/srv/yulai_blog/repo` and point Nginx
at `repo/public`, or copy `public/` into a release directory and switch a
symlink.

## Cloudflare

- Keep `yulai.org` proxied through Cloudflare.
- Use Cloudflare SSL/TLS mode `Full (strict)`.
- Prefer a Cloudflare Origin Certificate on the VPS, or fix certbot renewal
  before enabling Nginx.
- Restrict origin HTTP/HTTPS traffic to Cloudflare IP ranges with UFW and/or
  the existing Nginx `cloudflare-only.conf` snippet.
