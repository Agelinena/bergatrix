import 'package:flutter/widgets.dart';

/// Clique com o botão direito (computador e web) abre o mesmo menu do ⋮.
/// Sem [onMenu], só devolve o [child].
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.onMenu,
    required this.child,
  });

  final VoidCallback? onMenu;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final menu = onMenu;
    if (menu == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTap: menu,
      child: child,
    );
  }
}
