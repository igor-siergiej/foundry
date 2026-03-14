# Jellyfin Companion Apps

Jellyfin handles video streaming to other devices via:
- **Web player** (built-in)
- **Mobile apps** (iOS/Android - official Jellyfin app)
- **Desktop clients** (Jellyfin Media Player, web UI)

For music, audiobooks, and offline sync, add these:

## Music Streaming: Navidrome

**Why:** Dedicated music server, lightweight, supports streaming to other devices. Can serve audiobooks too.

**Features:**
- Stream music from web/mobile
- Subsonic-compatible API (works with mobile apps like Symfonium, Subsonic, etc.)
- Offline sync support (via compatible mobile apps)
- Playlist management
- User management

```yaml
navidrome:
  image: deluan/navidrome:latest
  container_name: navidrome
  restart: unless-stopped
  environment:
    ND_LOGFORMAT: json
    ND_LOGFRAME: "false"
  volumes:
    - navidrome-config:/data
    - jellyfin-media:/music:ro
  ports:
    - "4533:4533"
  networks:
    - jellyfin
```

## Audiobooks: Audiobookshelf

**Why:** Purpose-built for audiobooks. Has mobile apps with offline download + sync support.

**Features:**
- Dedicated audiobook player
- Mobile app (iOS/Android) with offline download
- Progress sync across devices
- User management
- Can also serve podcasts

```yaml
audiobookshelf:
  image: advplyr/audiobookshelf:latest
  container_name: audiobookshelf
  restart: unless-stopped
  environment:
    AUDIOBOOKSHELF_UID: 1000
    AUDIOBOOKSHELF_GID: 1000
  volumes:
    - audiobookshelf-config:/config
    - jellyfin-media:/audiobooks:ro
  ports:
    - "13378:80"
  networks:
    - jellyfin
```

## Offline Sync: Syncthing

**Why:** Sync music library to mobile devices automatically for offline access.

```yaml
syncthing:
  image: syncthing/syncthing:latest
  container_name: syncthing
  restart: unless-stopped
  volumes:
    - syncthing-config:/var/syncthing
    - jellyfin-media:/synced-media:ro
  ports:
    - "8384:8384"  # Web UI
    - "22000:22000/tcp"
    - "22000:22000/udp"
  networks:
    - jellyfin
```

## Recommended Setup

- **Jellyfin** → Video streaming (via web + mobile apps)
- **Navidrome** → Music streaming from other devices (with offline sync via compatible apps)
- **Audiobookshelf** → Audiobooks with mobile offline support + progress sync
- **Optional: Syncthing** → If you want automatic library sync to mobile devices

All can point to `jellyfin-media` volume. Mount as read-only to prevent accidental deletions.

## Mobile Apps with Offline Support

**Navidrome (Music):**
- Symfonium (Android) - best offline support
- Subsonic (iOS/Android)
- Ultrasonic (Android)

**Audiobookshelf:**
- Official Audiobookshelf app (iOS/Android) - native offline + sync

**Jellyfin (Video):**
- Official Jellyfin app - can download episodes for offline (limited)

**Syncthing:**
- Official app - automatic folder sync
