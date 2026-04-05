# Music & Audiobook Setup

Three separate services all pointing to `/mnt/tank/shared/jellyfin/media` on TrueNAS.

## Starting Services

```bash
cd foundry/navidrome && docker-compose up -d
cd foundry/audiobookshelf && docker-compose up -d
cd foundry/jellyfin && docker-compose up -d
```

## Access

| Service | URL | Port |
|---------|-----|------|
| Jellyfin (Video) | http://192.168.69.2:8096 | 8096 |
| Navidrome (Music) | http://192.168.69.2:4533 | 4533 |
| Audiobookshelf (Audiobooks) | http://192.168.69.2:13378 | 13378 |

## Initial Setup

### Navidrome
1. Open http://192.168.69.2:4533
2. Create admin user (first user is admin)
3. Music folder: `/music` (auto-scanned)
4. Download mobile app: Symfonium (Android) or Subsonic (iOS)

### Audiobookshelf
1. Open http://192.168.69.2:13378
2. Create root account
3. Audiobooks location: `/audiobooks` (set in admin panel)
4. Download app: Official Audiobookshelf app (iOS/Android)

## Mobile Apps with Offline Support

**Navidrome:**
- Symfonium (Android) - best offline support, auto-sync playlists
- Subsonic (iOS/Android)

**Audiobookshelf:**
- Official app (iOS/Android) - download chapters for offline, progress syncs automatically

## Library Structure

Organize in `/mnt/tank/shared/jellyfin/media` like:

```
media/
├── Movies/
├── TV/
├── Music/          (Navidrome reads this)
│   ├── Artist/
│   │   └── Album/
│   │       ├── song.mp3
│   │       └── ...
├── Audiobooks/     (Audiobookshelf reads this)
│   ├── Title/
│   │   ├── chapter1.m4b
│   │   └── chapter2.m4b
└── ...
```

Both services scan media on startup and periodically. If you add files, refresh in the web UI.
