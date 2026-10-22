import 'page_reload_stub.dart'
    if (dart.library.js_interop) 'page_reload_web.dart'
    as impl;

/// Recarrega a página (só na web; nos apps não faz nada).
void reloadPage() => impl.reloadPage();
