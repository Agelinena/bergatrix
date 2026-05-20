import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/error_messages.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/auth_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/offline_service.dart';
import '../../widgets/cards/track_card.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String id;
  const PlaylistScreen({super.key, required this.id});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  Playlist? _playlist;
  bool _loading = true;
  bool _deleting = false;
  String? _error;
  Map<String, dynamic>? _dlStatus;
  Timer? _dlTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getPlaylist(widget.id);
      final playlist = Playlist.fromJson(data);
      setState(() { _playlist = playlist; _loading = false; });
      _startDownloadPolling();
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _fetchDownloadStatus() async {
    if (!mounted || _playlist == null) return;
    try {
      final status = await ref.read(apiClientProvider).getPlaylistDownloadStatus(widget.id);
      if (!mounted) return;
      setState(() => _dlStatus = status);
      final percent = (status['percent'] as num?)?.toInt() ?? 100;
      if (percent >= 100) {
        _dlTimer?.cancel();
        _dlTimer = null;
      }
    } catch (_) {}
  }

  void _startDownloadPolling() {
    _fetchDownloadStatus();
    _dlTimer?.cancel();
    _dlTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchDownloadStatus());
  }

  @override
  void dispose() {
    _dlTimer?.cancel();
    super.dispose();
  }

  void _playAll() {
    if (_playlist == null) return;
    final tracks = _playlist!.tracks.map((pt) => pt.track).toList();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
    }
  }

  void _shuffle() {
    if (_playlist == null) return;
    final tracks = [..._playlist!.tracks.map((pt) => pt.track)]..shuffle();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
      ref.read(playerProvider.notifier).toggleShuffle();
    }
  }

  void _showEditDialog() {
    if (_playlist == null) return;
    showDialog(
      context: context,
      builder: (_) => _EditPlaylistDialog(
        playlistId: widget.id,
        playlist: _playlist!,
        onSaved: (name, description, coverUrl, isPublic) async {
          await ref.read(libraryProvider.notifier).updatePlaylist(
            widget.id,
            name: name,
            description: description,
            coverUrl: coverUrl,
            isPublic: isPublic,
          );
          await _load();
        },
      ),
    );
  }

  Future<void> _share() async {
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.sharePlaylist(widget.id);
      final url = data['share_url'] as String? ?? '';
      if (mounted && url.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copiado!'), duration: Duration(seconds: 2)),
        );
      }
    } catch (_) {}
  }

  Future<void> _downloadOffline() async {
    final pl = _playlist;
    if (pl == null || pl.tracks.isEmpty) return;
    final tracks = pl.tracks.map((pt) => pt.track).toList();
    final client = ref.read(apiClientProvider);

    // Mostra um dialog de progresso enquanto baixa.
    final progressNotifier = ValueNotifier<({int done, int total, Track? current})>(
      (done: 0, total: tracks.length, current: null),
    );
    var cancelled = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Baixando para uso offline'),
        content: ValueListenableBuilder(
          valueListenable: progressNotifier,
          builder: (_, value, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: value.total > 0 ? value.done / value.total : null,
                color: AppColors.primary,
              ),
              const SizedBox(height: 12),
              Text('${value.done} / ${value.total} faixas'),
              if (value.current != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${value.current!.title} — ${value.current!.artist}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );

    try {
      final result = await OfflineService.downloadPlaylist(
        tracks,
        client,
        onProgress: (done, total, current) {
          if (cancelled) return;
          progressNotifier.value = (done: done, total: total, current: current);
        },
      );
      if (!mounted) return;
      // Fecha o dialog de progresso (se ainda aberto).
      if (Navigator.canPop(context)) Navigator.pop(context);
      final msg = result.allSucceeded
          ? 'Baixadas ${result.succeeded} faixas (${result.skipped} já tinham)'
          : 'Baixadas ${result.succeeded}, falharam ${result.failed} de ${result.total}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      if (Navigator.canPop(context)) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao baixar: $e'), duration: const Duration(seconds: 4)),
      );
    } finally {
      progressNotifier.dispose();
    }
  }

  Future<void> _delete() async {
    if (_deleting) return;

    final client = ref.read(apiClientProvider);
    final library = ref.read(libraryProvider.notifier);
    final playlistId = widget.id;

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Deletar playlist?'),
        content: Text('Tem certeza que quer deletar "${_playlist?.name}"? Isso não pode ser desfeito.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Deletar'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (mounted) setState(() => _deleting = true);
    final messenger = mounted ? ScaffoldMessenger.of(context) : null;

    try {
      await client.deletePlaylist(playlistId);
      library.load();
      if (mounted) context.go('/library');
    } catch (e) {
      if (mounted) setState(() => _deleting = false);
      messenger?.showSnackBar(SnackBar(
        content: Text(_extractError(e)),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  String _extractError(Object e) => friendlyError(e, fallback: 'Algo deu errado. Tente novamente.');

  void _showCollaboratorsDialog() {
    if (_playlist == null) return;
    showDialog(
      context: context,
      builder: (_) => _CollaboratorsDialog(
        playlistId: widget.id,
        collaborators: _playlist!.collaborators,
        onChanged: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));
    if (_playlist == null) return Scaffold(
      body: Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Playlist não encontrada', style: TextStyle(color: AppColors.textSecondary)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12), textAlign: TextAlign.center),
            ),
          ],
          const SizedBox(height: 16),
          TextButton(onPressed: _load, child: const Text('Tentar novamente')),
        ],
      )),
    );

    final pl = _playlist!;
    final tracks = pl.tracks.map((pt) => pt.track).toList();
    final totalDuration = tracks.fold(0, (sum, t) => sum + (t.durationMs ?? 0));
    final totalMin = totalDuration ~/ 60000;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            actions: [
              if (_deleting)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
                )
              else
              Builder(builder: (context) {
                final currentUserId = ref.read(authProvider).valueOrNull?.id;
                final isOwner = currentUserId != null && pl.ownerId == currentUserId;
                return PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'edit') _showEditDialog();
                    if (v == 'collaborators') _showCollaboratorsDialog();
                    if (v == 'share') _share();
                    if (v == 'delete') _delete();
                    if (v == 'download_offline') _downloadOffline();
                  },
                  itemBuilder: (_) => [
                    if (isOwner) ...[
                      const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Editar'))),
                      const PopupMenuItem(value: 'collaborators', child: ListTile(leading: Icon(Icons.group_add_outlined), title: Text('Colaboradores'))),
                      const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Compartilhar'))),
                      const PopupMenuItem(value: 'download_offline', child: ListTile(leading: Icon(Icons.download_for_offline_outlined), title: Text('Baixar offline'))),
                      const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Deletar', style: TextStyle(color: Colors.red)))),
                    ] else ...[
                      const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Compartilhar'))),
                      const PopupMenuItem(value: 'download_offline', child: ListTile(leading: Icon(Icons.download_for_offline_outlined), title: Text('Baixar offline'))),
                    ],
                  ],
                );
              }),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  pl.coverUrl != null
                      ? CachedNetworkImage(imageUrl: pl.coverUrl!, fit: BoxFit.cover)
                      : Container(color: AppColors.surfaceVariant, child: const Icon(Icons.queue_music, size: 80)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppColors.background],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16, left: 16, right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pl.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        if (pl.description != null && pl.description!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(pl.description!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text('${tracks.length} músicas · $totalMin min', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            if (pl.isPublic) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.public, size: 14, color: AppColors.textSecondary),
                              const SizedBox(width: 2),
                              const Text('Pública', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _shuffle,
                    icon: const Icon(Icons.shuffle, size: 18),
                    label: const Text('Aleatório'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _playAll,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Tocar tudo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.textSecondary),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_dlStatus != null)
            SliverToBoxAdapter(
              child: _DownloadStatusBanner(status: _dlStatus!),
            ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(
                track: tracks[i],
                queue: tracks,
                playlistId: widget.id,
                onRemoved: _load,
              ),
              childCount: tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}

// ── Editar playlist ────────────────────────────────────────────────────────

class _EditPlaylistDialog extends ConsumerStatefulWidget {
  final String playlistId;
  final Playlist playlist;
  final Future<void> Function(String? name, String? description, String? coverUrl, bool? isPublic) onSaved;

  const _EditPlaylistDialog({required this.playlistId, required this.playlist, required this.onSaved});

  @override
  ConsumerState<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends ConsumerState<_EditPlaylistDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _coverCtrl;
  late bool _isPublic;
  bool _saving = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.playlist.name);
    _descCtrl = TextEditingController(text: widget.playlist.description ?? '');
    _coverCtrl = TextEditingController(text: widget.playlist.coverUrl ?? '');
    _isPublic = widget.playlist.isPublic;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _coverCtrl.dispose();
    super.dispose();
  }

  // ── Seleção e crop de imagem ─────────────────────────────────────────────

  Future<void> _pickAndCrop() async {
    try {
      // file_picker works on web, Android, Linux, Windows, macOS
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;

      final bytes = result.files.first.bytes;
      if (bytes == null || !mounted) return;

      // Abre o modal de crop — retorna PNG cropado ou null se cancelado
      final cropped = await showDialog<Uint8List>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ImageCropperDialog(imageBytes: bytes),
      );
      if (cropped == null || !mounted) return;

      // Faz upload dos bytes cropados
      setState(() => _uploading = true);
      await _uploadBytes(cropped, 'image/png');
    } catch (e) {
      debugPrint('[EditPlaylist] pickAndCrop error: $e');
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadBytes(Uint8List bytes, String mimeType) async {
    try {
      final client = ref.read(apiClientProvider);
      final url = await client.uploadPlaylistCover(widget.playlistId, bytes, mimeType);
      if (url != null && mounted) {
        setState(() {
          _coverCtrl.text = url;
          _uploading = false;
        });
      } else {
        if (mounted) setState(() => _uploading = false);
      }
    } catch (e) {
      debugPrint('[EditPlaylist] upload error: $e');
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _uploading;

    return AlertDialog(
      backgroundColor: AppColors.surfaceVariant,
      title: const Text('Editar playlist'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nome'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: 'Descrição'),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              // ── Capa ──────────────────────────────────────────────────────
              const Text('Capa', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Preview
                  _CoverPreview(url: _coverCtrl.text, uploading: _uploading),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // URL
                        TextField(
                          controller: _coverCtrl,
                          decoration: const InputDecoration(
                            labelText: 'URL da imagem',
                            hintText: 'https://...',
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}), // atualiza preview
                        ),
                        const SizedBox(height: 8),
                        // Upload button
                        OutlinedButton.icon(
                          onPressed: busy ? null : _pickAndCrop,
                          icon: _uploading
                              ? const SizedBox(width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.upload_file, size: 18),
                          label: Text(_uploading ? 'Enviando...' : 'Enviar imagem'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'JPEG, PNG ou WebP · máx. 5 MB · saída 500×500 px',
                          style: TextStyle(fontSize: 10, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Playlist pública', style: TextStyle(fontSize: 14)),
                value: _isPublic,
                onChanged: busy ? null : (v) => setState(() => _isPublic = v),
                activeColor: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => _saving = true);
                  await widget.onSaved(
                    _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : null,
                    _descCtrl.text.trim(),
                    _coverCtrl.text.trim().isNotEmpty ? _coverCtrl.text.trim() : null,
                    _isPublic,
                  );
                  if (mounted) Navigator.pop(context);
                },
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Salvar'),
        ),
      ],
    );
  }
}

// Preview da capa (pequeno quadrado ao lado do campo URL)
class _CoverPreview extends StatelessWidget {
  final String url;
  final bool uploading;
  const _CoverPreview({required this.url, required this.uploading});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 72,
        height: 72,
        child: uploading
            ? Container(
                color: AppColors.background,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
              )
            : url.isNotEmpty
                ? Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder(),
                  )
                : _placeholder(),
      ),
    );
  }

  Widget _placeholder() => Container(
        color: AppColors.background,
        child: const Icon(Icons.image_outlined, size: 32, color: AppColors.textSecondary),
      );
}

// ── Crop modal ─────────────────────────────────────────────────────────────

/// Modal de corte de imagem.
/// – Exibe a imagem no tamanho real (ou reduzido para caber na tela).
/// – Usuário faz pan/zoom para posicionar a área desejada.
/// – Ao confirmar, captura a área visível do frame 420×420 e a escala
///   para 500×500 pixels via RepaintBoundary.toImage().
class _ImageCropperDialog extends StatefulWidget {
  final Uint8List imageBytes;
  const _ImageCropperDialog({required this.imageBytes});

  @override
  State<_ImageCropperDialog> createState() => _ImageCropperDialogState();
}

class _ImageCropperDialogState extends State<_ImageCropperDialog> {
  static const _frameSize = 420.0;
  static const _outputPx = 500.0;

  final _cropKey = GlobalKey();
  final _transformCtrl = TransformationController();

  double? _natW;
  double? _natH;
  double _minScale = 1.0;
  bool _ready = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _loadImageDimensions();
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  // Decodifica as dimensões reais da imagem e calcula a transformação inicial
  // que centraliza a imagem e a escala para cobrir o frame (cover fit).
  Future<void> _loadImageDimensions() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final natW = image.width.toDouble();
      final natH = image.height.toDouble();
      image.dispose();

      // Escala mínima = "cover": a menor escala que ainda cobre o frame
      final s = math.max(_frameSize / natW, _frameSize / natH);

      // Offset para centralizar a imagem escalada dentro do frame
      final tx = (_frameSize - s * natW) / 2;
      final ty = (_frameSize - s * natH) / 2;

      // Matrix4: translate(tx, ty) * scale(s)
      // Resultado: ponto (0,0) da imagem → viewport (tx, ty)
      //            ponto (natW, natH)     → viewport (tx+s*natW, ty+s*natH)
      final matrix = Matrix4.identity();
      matrix.translate(tx, ty);
      matrix.scale(s, s, 1.0);

      if (mounted) {
        setState(() {
          _natW = natW;
          _natH = natH;
          _minScale = s;
          _ready = true;
        });
        _transformCtrl.value = matrix;
      }
    } catch (e) {
      debugPrint('[Cropper] loadImageDimensions error: $e');
    }
  }

  // Captura o RepaintBoundary (420×420 exibidos) e escala para 500×500 px.
  Future<void> _confirm() async {
    if (_confirming || !_ready) return;
    setState(() => _confirming = true);
    try {
      final boundary = _cropKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: _outputPx / _frameSize);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (!mounted) return;
      Navigator.of(context).pop(byteData!.buffer.asUint8List());
    } catch (e) {
      debugPrint('[Cropper] confirm error: $e');
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF141420),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Título ─────────────────────────────────────────────────
              const Text(
                'Ajustar capa',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Arraste para reposicionar  ·  Scroll ou pinch para zoom',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 20),

              // ── Frame de crop ──────────────────────────────────────────
              Center(
                child: SizedBox(
                  width: _frameSize,
                  height: _frameSize,
                  child: _ready
                      ? Stack(
                          children: [
                            // Conteúdo capturável
                            RepaintBoundary(
                              key: _cropKey,
                              child: SizedBox(
                                width: _frameSize,
                                height: _frameSize,
                                child: ClipRect(
                                  child: ColoredBox(
                                    color: Colors.black,
                                    child: InteractiveViewer(
                                      transformationController: _transformCtrl,
                                      constrained: false,
                                      minScale: _minScale,
                                      maxScale: _minScale * 6,
                                      // Sem boundaryMargin: EdgeInsets.zero impede que a
                                      // imagem saia dos limites do frame (boundary = child rect).
                                      boundaryMargin: EdgeInsets.zero,
                                      child: Image.memory(
                                        widget.imageBytes,
                                        width: _natW,
                                        height: _natH,
                                        fit: BoxFit.fill,
                                        gaplessPlayback: true,
                                        filterQuality: FilterQuality.high,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Grid / overlay de guia (não capturado)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(painter: _CropGridPainter()),
                              ),
                            ),
                          ],
                        )
                      : Container(
                          color: Colors.black,
                          child: const Center(
                            child: CircularProgressIndicator(color: AppColors.primary),
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Rodapé ─────────────────────────────────────────────────
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    'Saída: ${_outputPx.toInt()}×${_outputPx.toInt()} px · PNG',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _confirming ? null : () => Navigator.of(context).pop(null),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: (!_ready || _confirming) ? null : _confirm,
                    icon: _confirming
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.crop, size: 16),
                    label: const Text('Confirmar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadStatusBanner extends StatelessWidget {
  final Map<String, dynamic> status;
  const _DownloadStatusBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final total = (status['total'] as num?)?.toInt() ?? 0;
    final downloaded = (status['downloaded'] as num?)?.toInt() ?? 0;
    final downloading = (status['downloading'] as num?)?.toInt() ?? 0;
    final queued = (status['queued'] as num?)?.toInt() ?? 0;

    if (total == 0 || downloaded >= total) return const SizedBox.shrink();

    final progress = downloaded / total;
    final active = downloading + queued;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.download_rounded, size: 15, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  'Download: $downloaded / $total músicas',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                if (active > 0)
                  Text(
                    '$active em andamento',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: AppColors.background,
                color: AppColors.primary,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pinta a grade de referência (regra dos terços + borda + alças de canto)
/// por cima do InteractiveViewer. Usa IgnorePointer para não bloquear o toque.
class _CropGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Borda branca
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Alças de canto em L
    const handleLen = 22.0;
    final hp = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Superior-esquerdo
    canvas.drawLine(Offset.zero, const Offset(handleLen, 0), hp);
    canvas.drawLine(Offset.zero, const Offset(0, handleLen), hp);
    // Superior-direito
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - handleLen, 0), hp);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, handleLen), hp);
    // Inferior-esquerdo
    canvas.drawLine(Offset(0, size.height), Offset(handleLen, size.height), hp);
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - handleLen), hp);
    // Inferior-direito
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width - handleLen, size.height), hp);
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width, size.height - handleLen), hp);

    // Regra dos terços
    final gp = Paint()
      ..color = Colors.white.withOpacity(0.28)
      ..strokeWidth = 0.8;
    final w3 = size.width / 3;
    final h3 = size.height / 3;
    canvas.drawLine(Offset(w3, 0), Offset(w3, size.height), gp);
    canvas.drawLine(Offset(w3 * 2, 0), Offset(w3 * 2, size.height), gp);
    canvas.drawLine(Offset(0, h3), Offset(size.width, h3), gp);
    canvas.drawLine(Offset(0, h3 * 2), Offset(size.width, h3 * 2), gp);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Colaboradores ─────────────────────────────────────────────────────────────

class _CollaboratorsDialog extends ConsumerStatefulWidget {
  final String playlistId;
  final List<PlaylistCollaborator> collaborators;
  final VoidCallback onChanged;

  const _CollaboratorsDialog({
    required this.playlistId,
    required this.collaborators,
    required this.onChanged,
  });

  @override
  ConsumerState<_CollaboratorsDialog> createState() => _CollaboratorsDialogState();
}

class _CollaboratorsDialogState extends ConsumerState<_CollaboratorsDialog> {
  late List<PlaylistCollaborator> _collabs;
  final _addCtrl = TextEditingController();
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _collabs = List.from(widget.collaborators);
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final identifier = _addCtrl.text.trim();
    if (identifier.isEmpty) return;
    setState(() => _adding = true);
    try {
      await ref.read(apiClientProvider).addCollaborator(widget.playlistId, identifier);
      _addCtrl.clear();
      // Reload collaborators from the API
      final data = await ref.read(apiClientProvider).getCollaborators(widget.playlistId);
      setState(() {
        _collabs = data
            .map((c) => PlaylistCollaborator.fromJson(c as Map<String, dynamic>))
            .toList();
      });
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(PlaylistCollaborator collab) async {
    try {
      await ref.read(apiClientProvider).removeCollaborator(widget.playlistId, collab.userId);
      setState(() => _collabs.removeWhere((c) => c.userId == collab.userId));
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.group_outlined, color: AppColors.primary),
                  const SizedBox(width: 12),
                  const Text('Colaboradores',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Add collaborator input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Usuário ou e-mail',
                        prefixIcon: Icon(Icons.person_add_outlined, size: 20),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _adding ? null : _add,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    child: _adding
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Adicionar'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Colaboradores podem adicionar e remover músicas desta playlist.',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),

            // Collaborator list
            Expanded(
              child: _collabs.isEmpty
                  ? const Center(
                      child: Text(
                        'Nenhum colaborador ainda.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _collabs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                      itemBuilder: (_, i) {
                        final c = _collabs[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.surfaceVariant,
                            child: Text(
                              c.username.isNotEmpty ? c.username[0].toUpperCase() : '?',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          title: Text(c.username,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(c.email,
                              style: const TextStyle(
                                  color: AppColors.textSecondary, fontSize: 12)),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                            tooltip: 'Remover colaborador',
                            onPressed: () => _remove(c),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
