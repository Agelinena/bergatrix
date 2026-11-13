import 'local_store.dart';
import 'memory_store.dart';

/// Web: só memória. A web funciona online; ao abrir, baixa tudo do servidor.
/// O que for feito sem conexão fica na fila enquanto a aba estiver aberta.
Future<LocalStore> openLocalStore(String userId) async =>
    MemoryLocalStore(userId: userId);

Future<void> deleteLocalStore(String userId) async {}
