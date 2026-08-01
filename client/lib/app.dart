/// Application root: composes the crypto engine, transport, local store and UI.
library;

import 'dart:async';

import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'crypto/attachment.dart';
import 'crypto/crypto_engine.dart';
import 'crypto/secure_key_storage.dart';
import 'data/local/dao/message_dao.dart';
import 'data/local/dao/session_dao.dart';
import 'data/local/database.dart';
import 'data/models/models.dart';
import 'data/remote/api_client.dart';
import 'data/remote/file_client.dart';
import 'data/remote/ws_client.dart';
import 'data/repositories/attachment_repository.dart';
import 'data/repositories/device_resolver.dart';
import 'data/repositories/message_repository.dart';
import 'features/auth/view/login_screen.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/chat/view/chat_screen.dart';
import 'features/chat_list/view/chat_list_screen.dart';
import 'features/settings/view/safety_number_screen.dart';
import 'features/settings/view/settings_screen.dart';
import 'ui/adaptive/adaptive_shell.dart';
import 'ui/theme/app_theme.dart';

/// Default server address. Overridable at build time:
/// `flutter run --dart-define=FROGSTER_SERVER=http://10.0.2.2:8080`
const String serverUrl = String.fromEnvironment(
  'FROGSTER_SERVER',
  defaultValue: 'http://127.0.0.1:8080',
);

/// Host and port of the attachment service. It is a separate gRPC server, so
/// it does not share the messaging server's address.
const String fileHost = String.fromEnvironment(
  'FROGSTER_FILE_HOST',
  defaultValue: '127.0.0.1',
);
const int filePort = int.fromEnvironment('FROGSTER_FILE_PORT', defaultValue: 8081);

class FrogsterApp extends StatelessWidget {
  const FrogsterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frogster',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Follows the system setting rather than forcing one appearance.
      themeMode: ThemeMode.system,
      home: const _AppRoot(),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  final _api = ApiClient(baseUrl: serverUrl);
  final _ws = WsClient(baseUrl: serverUrl);
  final _files = FileClient(host: fileHost, port: filePort);
  final _keys = SecureKeyStorage();

  AppDatabase? _database;
  MessageDao? _dao;
  FrogsterCryptoEngine? _crypto;
  DeviceResolver? _resolver;
  MessageRepository? _repository;
  AttachmentRepository? _attachments;

  Account? _account;
  List<Chat> _chats = const [];
  Chat? _selected;
  var _socketState = SocketState.disconnected;

  var _busy = false;
  String? _error;

  StreamSubscription<SocketState>? _socketSub;
  StreamSubscription<String>? _chatSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final database = await AppDatabase.open();
    setState(() {
      _database = database;
      _dao = MessageDao(database.db);
      _crypto = FrogsterCryptoEngine(
        keyStorage: _keys,
        sessionStore: SqfliteSessionStore(database.db),
      );
    });

    _socketSub = _ws.connectionState.listen(
      (state) => setState(() => _socketState = state),
    );
  }

  Future<void> _authenticate(
    String username,
    String password,
    bool register,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final crypto = _crypto!;
      // Generates the identity on first launch and returns only public
      // material; private keys stay in the platform keychain.
      final bundle = await crypto.initializeIdentity();

      // Signing in from an install that already registered must resume that
      // device, not create another one: the keys in the keychain carry the
      // same registration id, and re-registering them collides with
      // UNIQUE(user_id, registration_id) -- which locks the user out of their
      // own account with an error about keys.
      final knownDeviceId = await _keys.loadDeviceId();

      final tokens = register
          ? await _api.register(
              username: username,
              password: password,
              deviceName: _deviceName(),
              keys: bundle,
            )
          : await _api.login(
              username: username,
              password: password,
              deviceName: _deviceName(),
              // A fresh install has no device id and must register one; a
              // returning install resumes the device it already owns.
              keys: knownDeviceId == null ? bundle : null,
              deviceId: knownDeviceId,
            );

      await _keys.saveDeviceId(tokens.deviceId);

      final account = Account(
        userId: tokens.userId,
        username: username,
        deviceId: tokens.deviceId,
      );

      final resolver = DeviceResolver(
        api: _api,
        crypto: crypto,
        selfDeviceId: account.deviceId,
        selfUsername: username,
      );

      final repository = MessageRepository(
        crypto: crypto,
        ws: _ws,
        dao: _dao!,
        resolver: resolver,
        account: account,
      );

      _chatSub = repository.chatUpdates.listen((_) => _refreshChats());

      // The gRPC service authenticates with the same bearer token.
      _files.accessToken = tokens.accessToken;

      await _ws.connect(tokens.accessToken);
      final chats = await _dao!.chats();

      setState(() {
        _account = account;
        _resolver = resolver;
        _repository = repository;
        _attachments = AttachmentRepository(_files);
        _chats = chats;
        _busy = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.isRateLimited
            ? 'Too many attempts. Try again in a few minutes.'
            : e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not reach the server at $serverUrl';
      });
    }
  }

  Future<void> _refreshChats() async {
    final chats = await _dao!.chats();
    if (mounted) setState(() => _chats = chats);
  }

  /// Signs out, optionally destroying this device's identity.
  ///
  /// [forget] erases the identity keys as well. That is the right thing when
  /// handing the machine on, but it also makes the device unrecognisable: every
  /// contact has pinned the old identity key, so after signing back in the
  /// device is a stranger to them and no existing conversation can continue.
  /// The ordinary case keeps the identity and only drops the session, so
  /// signing back in resumes exactly where it left off.
  Future<void> _signOut({bool forget = false}) async {
    // Order matters: stop the socket first. Wiping while frames are still
    // arriving would produce a burst of decrypt failures.
    await _ws.close();
    if (forget) {
      await _keys.wipeAll();
      await _database?.wipe();
    }
    await _repository?.dispose();

    _files.accessToken = null;

    setState(() {
      _account = null;
      _resolver = null;
      _repository = null;
      _attachments = null;
      _chats = const [];
      _selected = null;
    });
  }

  Future<void> _startChat() async {
    final username = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _NewChatDialog(),
    );
    if (username == null || username.isEmpty) return;

    try {
      final chat = await _api.createDirectChat(username);
      await _dao!.upsertChat(chat);
      await _refreshChats();
      if (mounted) setState(() => _selected = chat);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _openSettings() async {
    final account = _account;
    if (account == null) return;

    List<DeviceSession> sessions;
    try {
      sessions = await _api.sessions();
    } catch (_) {
      sessions = const [];
    }
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          account: account,
          sessions: sessions,
          onRevokeSession: (session) => _api.revokeSession(session.id),
          onSignOut: ({required bool forget}) {
            Navigator.of(context).pop();
            _signOut(forget: forget);
          },
        ),
      ),
    );
  }

  /// Opens the platform picker.
  ///
  /// Images only, for now. `file_picker` would cover arbitrary files, but
  /// version 11 has not migrated to Flutter's built-in Kotlin and fails to
  /// compile on Android under Flutter 3.44; the fix exists only in a 12.0.0
  /// beta. `image_picker` is maintained by the Flutter team and builds
  /// cleanly. The picker is injected into ChatScreen, so swapping it later
  /// touches this method alone.
  Future<PickedAttachment?> _pickFile() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();

    if (bytes.length > maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Files must be under 100 MB')),
        );
      }
      return null;
    }

    return PickedAttachment(
      bytes: bytes,
      mimeType: picked.mimeType ?? _mimeTypeFor(_extensionOf(picked.name)),
      fileName: picked.name,
    );
  }

  /// The extension of a file name, without the dot.
  static String? _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? null : name.substring(dot + 1);
  }

  /// Writes decrypted bytes to a temporary file so the platform can open them.
  ///
  /// The plaintext only touches disk here, in the app's own cache, and only
  /// because opening a file requires a path. It is deleted with the cache.
  Future<void> _openAttachment(
    AttachmentPayload attachment,
    Uint8List bytes,
  ) async {
    try {
      // Directory.systemTemp rather than path_provider: that package pulls in
      // path_provider_foundation, whose objective_c dependency fails the
      // Windows release build. dart:io covers this need on every platform.
      final dir = await Directory.systemTemp.createTemp('frogster');
      final name = attachment.fileName ?? 'attachment';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the file: $e')),
        );
      }
    }
  }

  /// Maps an extension to a MIME type.
  ///
  /// The real type stays inside the encrypted payload; the upload always
  /// declares a generic hint, so this never reaches the server.
  static String _mimeTypeFor(String? extension) => switch (extension?.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'pdf' => 'application/pdf',
        'mp4' => 'video/mp4',
        'mp3' => 'audio/mpeg',
        'txt' => 'text/plain',
        _ => 'application/octet-stream',
      };

  String _deviceName() {
    // Enough to tell devices apart on the sessions screen without shipping a
    // detailed fingerprint of the user's hardware to the server.
    return switch (Theme.of(context).platform) {
      TargetPlatform.android => 'Android device',
      TargetPlatform.iOS => 'iPhone',
      TargetPlatform.windows => 'Windows PC',
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.linux => 'Linux PC',
      _ => 'Frogster client',
    };
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _chatSub?.cancel();
    _repository?.dispose();
    _ws.dispose();
    _files.shutdown();
    _api.close();
    _database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_database == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_account == null) {
      return LoginScreen(
        onSubmit: _authenticate,
        busy: _busy,
        error: _error,
      );
    }

    return AdaptiveShell(
      hasSelection: _selected != null,
      onClearSelection: () => setState(() => _selected = null),
      list: ChatListScreen(
        chats: _chats,
        connection: _socketState,
        selectedChatId: _selected?.id,
        onOpenChat: (chat) => setState(() => _selected = chat),
        onNewChat: _startChat,
        onOpenSettings: _openSettings,
      ),
      detail: _selected == null ? null : _buildChat(_selected!),
    );
  }

  /// Builds the conversation view with its own bloc.
  ///
  /// Keyed by chat id so switching conversations creates a fresh bloc rather
  /// than reusing one still holding the previous chat's messages.
  Widget _buildChat(Chat chat) {
    return BlocProvider<ChatBloc>(
      key: ValueKey(chat.id),
      create: (_) => ChatBloc(
        repository: _repository!,
        crypto: _crypto!,
        resolver: _resolver!,
        attachments: _attachments,
      )..add(ChatOpened(chat.id, chat.peerUsername ?? chat.displayName)),
      child: ChatScreen(
        title: chat.displayName,
        onBack: () => setState(() => _selected = null),
        onShowSafetyNumber: () => _showSafetyNumber(chat),
        onPickAttachment: _pickFile,
        onDownloadAttachment: (attachment) =>
            _attachments!.download(attachment),
        onOpenAttachment: _openAttachment,
      ),
    );
  }

  /// Opens the safety-number screen for the peer's first device.
  Future<void> _showSafetyNumber(Chat chat) async {
    final account = _account;
    final username = chat.peerUsername;
    if (account == null || username == null) return;

    try {
      final devices = await _resolver!.devicesFor(username);
      if (devices.isEmpty) return;

      final digits = await _crypto!.safetyNumberFor(
        devices.first.address,
        account.userId,
      );
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SafetyNumberScreen(
            peerName: chat.displayName,
            digits: digits,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not compute safety number: $e')),
      );
    }
  }
}

class _NewChatDialog extends StatefulWidget {
  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New conversation'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Username'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Start'),
        ),
      ],
    );
  }
}
