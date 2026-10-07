import 'package:flutter/widgets.dart';

/// Medidas e formas da Seção 5.3.
abstract final class BergaSizes {
  /// Padding das telas (o inferior deixa espaço para mini player e navegação).
  static const screenPadding = EdgeInsets.fromLTRB(16, 18, 16, 170);

  static const h1Bottom = 14.0;
  static const h2Top = 20.0;
  static const h2Bottom = 10.0;

  static const coverRadius = 8.0;
  static const playerCoverRadius = 18.0;
  static const playlistCoverMaxHeight = 200.0;

  static const cardRadius = 14.0;
  static const cardPadding = 14.0;
  static const cardMarginTop = 10.0;

  static const fieldRadius = 12.0;
  static const fieldPadding = EdgeInsets.symmetric(
    vertical: 12,
    horizontal: 14,
  );

  static const chipPadding = EdgeInsets.symmetric(vertical: 7, horizontal: 14);
  static const chipGap = 8.0;

  static const buttonPadding = EdgeInsets.symmetric(
    vertical: 11,
    horizontal: 18,
  );

  static const playButton = 38.0;
  static const playButtonLarge = 60.0;

  static const trackCover = 46.0;
  static const trackGap = 12.0;
  static const trackPaddingVertical = 7.0;

  static const shelfItem = 96.0;
  static const shelfGap = 12.0;
  static const shelfCaptionTop = 6.0;

  static const statGap = 10.0;

  static const sheetRadius = 22.0;
  static const sheetPadding = EdgeInsets.fromLTRB(18, 16, 18, 26);
  static const sheetItemPaddingVertical = 13.0;

  static const progressHeight = 3.0;
  static const progressHeightLarge = 5.0;

  static const toastTop = 14.0;
  static const toastPadding = EdgeInsets.symmetric(vertical: 9, horizontal: 16);
  static const toastDuration = Duration(milliseconds: 1500);
  static const toastFade = Duration(milliseconds: 200);

  /// Largura máxima da coluna do app em telas largas (web/desktop).
  static const maxContentWidth = 430.0;
}
