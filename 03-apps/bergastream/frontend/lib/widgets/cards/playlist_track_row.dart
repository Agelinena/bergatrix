/// Responsive Spotify-style playlist track row.
///
/// Desktop (≥900 px): table layout — # | Cover+Title+Artist | Album |
///                    AddedBy | AddedAt | Duration | menu
/// Mobile  (<900 px): compact layout — Cover | Title/Artist (small) | menu
///
/// Why a dedicated widget instead of reusing TrackCard?  TrackCard is the
/// generic "track in a list" with a fixed mobile-style ListTile; playlists
/// need extra columns (album, added by, added when) and want the row's
/// width to align with a column header above the list.  Keeping two
/// widgets avoids ballooning TrackCard with optional layout modes.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../core/theme/app_theme.dart';
import '../../models/playlist.dart';
import '../../providers/downloaded_tracks_provider.dart';
import '../../providers/player_provider.dart';
import '../cards/track_card.dart' show TrackMenuSheet;

/// Width at which we flip from mobile rows to the desktop table.  Kept
/// slightly below the global kDesktopBreakpoint so a desktop user who
/// has the queue panel open still sees the table.
const double playlistTrackTableBreakpoint = 800;

class PlaylistTrackRow extends ConsumerWidget {
  final PlaylistTrack item;
  final int displayIndex;          // 1-based # column
  final bool isPlaying;            // currently playing this track?
  final VoidCallback onTap;
  final String? playlistId;
  final VoidCallback? onRemoved;

  const PlaylistTrackRow({
    super.key,
    required this.item,
    required this.displayIndex,
    required this.isPlaying,
    required this.onTap,
    this.playlistId,
    this.onRemoved,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (_, c) {
        final wide = c.maxWidth >= playlistTrackTableBreakpoint;
        return wide ? _buildDesktop(context, ref) : _buildMobile(context, ref);
      },
    );
  }

  // ── Mobile (compact ListTile) ──────────────────────────────────────────

  Widget _buildMobile(BuildContext context, WidgetRef ref) {
    final track = item.track;
    final downloaded = ref.watch(downloadedTracksProvider).contains(track.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _Cover(url: track.coverUrl, isPlaying: isPlaying),
      title: Text(
        track.title,
        style: TextStyle(
          color: isPlaying ? AppColors.primary : AppColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        // Spotify shows "Artist • Album" when there's enough room; we do
        // the same and let ellipsis cut the album when not.
        track.album != null && track.album!.isNotEmpty
            ? '${track.artist} • ${track.album}'
            : track.artist,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DownloadIndicator(downloaded: downloaded),
          const SizedBox(width: 4),
          Text(track.durationFormatted,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          IconButton(
            icon: const Icon(Icons.more_vert, size: 20, color: AppColors.textSecondary),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  // ── Desktop (table row) ────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext context, WidgetRef ref) {
    final track = item.track;
    final added = item.addedAt;
    final downloaded = ref.watch(downloadedTracksProvider).contains(track.id);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              // # column
              SizedBox(
                width: 40,
                child: isPlaying
                    ? const Icon(Icons.volume_up, color: AppColors.primary, size: 16)
                    : Text(
                        '$displayIndex',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
              ),
              // Cover + Title + Artist
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    _Cover(url: track.coverUrl, isPlaying: isPlaying),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            style: TextStyle(
                              color: isPlaying ? AppColors.primary : AppColors.textPrimary,
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          _ArtistLink(
                            artist: track.artist,
                            artistId: track.artistId,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Album
              Expanded(
                flex: 3,
                child: _AlbumLink(
                  album: track.album,
                  albumId: track.albumId,
                ),
              ),
              // Added by
              Expanded(
                flex: 2,
                child: Text(
                  item.addedByUsername ?? '—',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
              // Added at
              Expanded(
                flex: 2,
                child: Text(
                  added != null ? timeago.format(added, locale: 'pt_BR') : '—',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
              // Download indicator
              SizedBox(
                width: 30,
                child: _DownloadIndicator(downloaded: downloaded),
              ),
              // Duration
              SizedBox(
                width: 60,
                child: Text(
                  track.durationFormatted,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
              // Menu
              SizedBox(
                width: 40,
                child: IconButton(
                  icon: const Icon(Icons.more_vert, size: 18, color: AppColors.textSecondary),
                  onPressed: () => _showMenu(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceVariant,
      builder: (_) => TrackMenuSheet(
        track: item.track,
        playlistId: playlistId,
        onRemoved: onRemoved,
      ),
    );
  }
}

/// Album cell with the album name. Tappable when albumId is non-null.
class _AlbumLink extends StatelessWidget {
  final String? album;
  final String? albumId;
  const _AlbumLink({this.album, this.albumId});

  @override
  Widget build(BuildContext context) {
    final text = album ?? '—';
    final style = const TextStyle(color: AppColors.textSecondary, fontSize: 13);
    if (albumId == null || album == null || album!.isEmpty) {
      return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return InkWell(
      onTap: () => context.push('/album/$albumId'),
      child: Text(
        text,
        style: style.copyWith(decoration: TextDecoration.none),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Artist name; click → artist page.  Uses an InkWell instead of a
/// GestureDetector so it picks up the hover/cursor change on desktop.
class _ArtistLink extends StatelessWidget {
  final String artist;
  final String? artistId;
  const _ArtistLink({required this.artist, this.artistId});

  @override
  Widget build(BuildContext context) {
    final style = const TextStyle(color: AppColors.textSecondary, fontSize: 12);
    if (artistId == null) {
      return Text(artist, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push('/artist/$artistId'),
        child: Text(artist, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// Square cover thumbnail.  When the track is currently playing, overlays a
/// translucent black panel with the primary-colour equalizer icon.
class _Cover extends StatelessWidget {
  final String? url;
  final bool isPlaying;
  const _Cover({this.url, this.isPlaying = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        children: [
          CachedNetworkImage(
            imageUrl: url ?? '',
            width: 44, height: 44, fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(
              width: 44, height: 44, color: AppColors.surfaceVariant,
              child: const Icon(Icons.music_note, size: 18),
            ),
          ),
          if (isPlaying)
            Container(
              width: 44, height: 44,
              color: Colors.black45,
              child: const Icon(Icons.equalizer, color: AppColors.primary, size: 20),
            ),
        ],
      ),
    );
  }
}

/// Header strip with column titles, rendered above the list on desktop.
/// Hidden on mobile (returns SizedBox.shrink).
class PlaylistTrackHeader extends StatelessWidget {
  const PlaylistTrackHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        if (c.maxWidth < playlistTrackTableBreakpoint) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: const [
              SizedBox(width: 40, child: Text('#', textAlign: TextAlign.center, style: _headerStyle)),
              Expanded(flex: 4, child: Padding(
                padding: EdgeInsets.only(left: 56),
                child: Text('Título', style: _headerStyle),
              )),
              Expanded(flex: 3, child: Text('Álbum', style: _headerStyle)),
              Expanded(flex: 2, child: Text('Adicionada por', style: _headerStyle)),
              Expanded(flex: 2, child: Text('Adicionada em', style: _headerStyle)),
              SizedBox(width: 30, child: Icon(Icons.download_done, size: 14, color: AppColors.textSecondary)),
              SizedBox(width: 60, child: Icon(Icons.access_time, size: 14, color: AppColors.textSecondary)),
              SizedBox(width: 40),
            ],
          ),
        );
      },
    );
  }
}

const _headerStyle = TextStyle(
  color: AppColors.textSecondary,
  fontSize: 12,
  letterSpacing: 0.4,
);

/// Small icon showing whether this track is on the device (green ✓)
/// or only streamable (greyed cloud-off).  Reads the downloaded-tracks
/// provider so it updates in real time as a batch download progresses.
class _DownloadIndicator extends StatelessWidget {
  final bool downloaded;
  const _DownloadIndicator({required this.downloaded});

  @override
  Widget build(BuildContext context) {
    if (downloaded) {
      return const Tooltip(
        message: 'Baixada offline',
        child: Icon(Icons.download_done, size: 14, color: AppColors.primary),
      );
    }
    return const Tooltip(
      message: 'Disponível apenas online',
      child: Icon(
        Icons.cloud_outlined,
        size: 14,
        color: AppColors.textSecondary,
      ),
    );
  }
}
