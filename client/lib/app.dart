/// Application root: composes the crypto engine, transport, local store and UI.
library;

import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'crypto/crypto_engine.dart';
import 'data/audio/voice_player.dart';
import 'data/audio/voice_recording.dart';
import 'crypto/secure_key_storage.dart';
import 'crypto/state_sealer.dart';
import 'data/local/account_store.dart';
import 'data/local/preferences.dart';
import 'data/local/dao/message_dao.dart';
import 'data/local/dao/session_dao.dart';
import 'data/local/database.dart';
import 'data/models/models.dart';
import 'data/notifications/notification_service.dart';
import 'data/remote/api_client.dart';
import 'data/remote/file_client.dart';
import 'data/remote/server_config.dart';
import 'data/remote/ws_client.dart';
import 'data/repositories/attachment_repository.dart';
import 'data/repositories/avatar_store.dart';
import 'data/repositories/device_resolver.dart';
import 'data/repositories/group_cipher.dart';
import 'data/repositories/key_maintenance.dart';
import 'data/repositories/message_repository.dart';
import 'data/repositories/presence_tracker.dart';
import 'features/auth/view/login_screen.dart';
import 'features/chat/attachments.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/chat/view/chat_screen.dart';
import 'features/chat_list/view/chat_list_screen.dart';
import 'features/group/view/group_info_screen.dart';
import 'features/new_chat/view/new_chat_screen.dart';
import 'features/search/view/search_screen.dart';
import 'features/settings/view/safety_number_screen.dart';
import 'features/settings/view/settings_screen.dart';
import 'l10n/app_localizations.dart';
import 'ui/adaptive/adaptive_shell.dart';
import 'ui/desktop/desktop_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/avatars.dart';
import 'ui/widgets/brand_mark.dart';

/// Server offered on the sign-in screen of a fresh install. Overridable at
/// build time: `flutter run --dart-define=FROGSTER_SERVER=chat.example.com`.
/// Users can always type another one.
const String defaultServer = String.fromEnvironment('FROGSTER_SERVER');

/// Certificate fingerprint of [defaultServer], for a server on a bare IP
/// with its own certificate authority: `frogster fingerprint` on the server
/// prints it. Built in, so testers never have to type it.
const String defaultFingerprint = String.fromEnvironment('FROGSTER_FINGERPRINT');

/// Shown under "About". Release builds pass the tag:
/// `--dart-define=FROGSTER_VERSION=v1.2.0`.
const String appVersion = String.fromEnvironment('FROGSTER_VERSION', defaultValue: '1.0.0');

class FrogsterApp extends StatefulWidget {
  const FrogsterApp({super.key});

  @override
  State<FrogsterApp> createState() => _FrogsterAppState();
}

class _FrogsterAppState extends State<FrogsterApp> {
  final _preferences = AppPreferences();

  /// Pictures and presence of the signed-in session, for every screen --
  /// those pushed on top of the root too, hence above the navigator.
  final _session = ValueNotifier<_SessionScope?>(null);

  @override
  void initState() {
    super.initState();
    _preferences.load();
  }

  @override
  void dispose() {
    _preferences.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _preferences,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _preferences.themeMode,
        locale: _preferences.locale,
        supportedLocales: supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        localeListResolutionCallback: (preferred, supported) =>
            resolveLocale(preferred, supported),
        // The system bars follow the app's theme, not the phone's: left to
        // themselves they keep white icons, invisible on the light theme.
        builder: (context, child) {
          final theme = Theme.of(context);
          final light = theme.brightness == Brightness.light;
          final icons = light ? Brightness.dark : Brightness.light;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: icons,
              statusBarBrightness: light ? Brightness.light : Brightness.dark,
              systemNavigationBarColor: theme.scaffoldBackgroundColor,
              systemNavigationBarIconBrightness: icons,
              systemNavigationBarDividerColor: Colors.transparent,
            ),
            child: ValueListenableBuilder<_SessionScope?>(
              valueListenable: _session,
              builder: (context, session, _) => AvatarScope(
                avatars: session?.avatars,
                presence: session?.presence,
                selfUserId: session?.selfUserId,
                child: child!,
              ),
            ),
          );
        },
        home: _AppRoot(preferences: _preferences, session: _session),
      ),
    );
  }
}

/// What [AvatarScope] hands down for one signed-in session.
class _SessionScope {
  const _SessionScope({required this.avatars, required this.presence, required this.selfUserId});

  final AvatarStore avatars;
  final PresenceTracker presence;
  final String selfUserId;
}

class _AppRoot extends StatefulWidget {
  const _AppRoot({required this.preferences, required this.session});

  final AppPreferences preferences;
  final ValueNotifier<_SessionScope?> session;

  @override
  State<_AppRoot> createState() => _AppRootState();
}

/// Network clients bound to one server. Rebuilt when the user signs in to a
/// different server, because the address and the trusted certificate are
/// fixed for a client's lifetime.
class _Connection {
  _Connection(this.server)
      : api = ApiClient(server: server),
        files = FileClient(server: server) {
    ws = WsClient(server: server, accessToken: api.validAccessToken);
    files.accessToken = api.validAccessToken;
  }

  final ServerConfig server;
  final ApiClient api;
  final FileClient files;
  late final WsClient ws;

  Future<void> dispose() async {
    await ws.dispose();
    await files.shutdown();
    api.close();
  }
}

class _AppRootState extends State<_AppRoot> with WidgetsBindingObserver {
  final _notifications = NotificationService();
  StreamSubscription<Message>? _arrivalSub;
  StreamSubscription<String>? _tapSub;
  var _lifecycle = AppLifecycleState.resumed;

  /// The chat whose notification was last cleared, so a rebuild does not
  /// clear it over and over.
  String? _clearedFor;

  final _keys = SecureKeyStorage();
  final _accounts = AccountStore();

  _Connection? _connection;

  AppDatabase? _database;
  MessageDao? _dao;
  StateSealer? _sealer;
  FrogsterCryptoEngine? _crypto;
  DeviceResolver? _resolver;
  MessageRepository? _repository;
  AttachmentRepository? _attachments;
  AvatarStore? _avatars;

  /// One voice message at a time, across every chat.
  final _voicePlayer = VoicePlayer();
  PresenceTracker? _presence;
  KeyMaintenance? _keyMaintenance;

  Account? _account;
  List<Chat> _chats = const [];

  /// The same list for screens pushed on top, such as the archive, which
  /// must follow changes without being rebuilt from here.
  final _chatList = ValueNotifier<List<Chat>>(const []);
  Chat? _selected;
  var _socketState = SocketState.disconnected;

  var _starting = true;
  var _busy = false;
  var _askFingerprint = false;
  String _lastServer = defaultServer;
  String? _error;

  StreamSubscription<SocketState>? _socketSub;
  StreamSubscription<String>? _chatSub;
  StreamSubscription<void>? _expirySub;

  ApiClient get _api => _connection!.api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_notifications.initialize());
    _tapSub = _notifications.taps.listen(_openFromNotification);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final database = await AppDatabase.open();
    _database = database;
    _dao = MessageDao(database.db);
    // Ratchet and sender-key state is sealed under a key that never leaves
    // the keychain, so the database file alone gives nothing away.
    final sealer = StateSealer(await _keys.localStateKey());
    _sealer = sealer;
    _crypto = FrogsterCryptoEngine(
      keyStorage: _keys,
      sessionStore: SqfliteSessionStore(database.db, sealer: sealer),
    );

    final lastServer = await _accounts.loadServer();
    if (lastServer != null) _lastServer = lastServer.displayAddress;

    // A stored session opens the app straight away, even offline: the
    // messages are local, and the socket connects whenever the network does.
    final session = await _accounts.loadSession();
    if (session != null) {
      try {
        _connect(session.server);
        _api.refreshToken = session.refreshToken;
        await _startSession(session.account);
      } catch (e) {
        // ignore: avoid_print
        print('[frogster] could not resume the stored session: $e');
        await _accounts.clearSession();
        await _disconnect();
      }
    }

    if (mounted) setState(() => _starting = false);
  }

  /// Builds the network clients for [server], replacing any previous ones.
  void _connect(ServerConfig server) {
    final connection = _Connection(server);
    connection.api.onRefreshTokenRotated = _accounts.saveRefreshToken;
    _connection = connection;

    _socketSub?.cancel();
    _socketSub = connection.ws.connectionState.listen(
      (state) => setState(() => _socketState = state),
    );
    // The server revoked this session: signed out on another device, or the
    // password changed. Only a new sign-in helps.
    _expirySub?.cancel();
    _expirySub = connection.api.sessionExpired.listen((_) {
      if (!mounted) return;
      _signOut(reason: AppLocalizations.of(context).sessionEnded);
    });
  }

  Future<void> _disconnect() async {
    await _socketSub?.cancel();
    await _expirySub?.cancel();
    _socketSub = null;
    _expirySub = null;
    await _connection?.dispose();
    _connection = null;
  }

  /// The fingerprint built into the app, when the address is the built-in
  /// server's. Another server never gets it: it would not match anyway.
  static String? _builtInFingerprintFor(Uri baseUri) {
    if (defaultServer.isEmpty || defaultFingerprint.isEmpty) return null;
    try {
      if (parseServerAddress(defaultServer).baseUri != baseUri) return null;
      return normalizeFingerprint(defaultFingerprint);
    } on ServerConfigException {
      return null;
    }
  }

  /// Resolves what the user typed into a server configuration, pinning the
  /// server's own certificate authority when it has one.
  Future<ServerConfig> _resolveServer(LoginRequest request) async {
    final address = parseServerAddress(request.server);
    final fingerprint = request.fingerprint.isNotEmpty
        ? normalizeFingerprint(request.fingerprint)
        : address.fingerprint ?? _builtInFingerprintFor(address.baseUri);

    // A server whose CA was pinned before keeps it, so the fingerprint is
    // asked for once, not on every sign-in.
    final saved = await _accounts.loadServer();
    ServerConfig config;
    if (fingerprint != null) {
      config = await pinServerCa(address.baseUri, fingerprint);
    } else if (saved != null &&
        saved.baseUri == address.baseUri &&
        saved.hasPinnedCa) {
      config = saved;
    } else {
      config = ServerConfig(baseUri: address.baseUri);
    }

    await probeServer(config);
    return config;
  }

  Future<void> _authenticate(LoginRequest request) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final server = await _resolveServer(request);
      final crypto = _crypto!;

      if (_connection?.server.baseUri != server.baseUri ||
          _connection?.server.caCertificatePem != server.caCertificatePem) {
        await _disconnect();
        _connect(server);
      }

      // Generates the identity on first launch and returns only public
      // material; private keys stay in the platform keychain.
      final bundle = await crypto.initializeIdentity();

      // Signing in from an install that already registered must resume that
      // device, not create another one: the keys in the keychain carry the
      // same registration id, and re-registering them collides with
      // UNIQUE(user_id, registration_id) -- which locks the user out of their
      // own account with an error about keys.
      final knownDeviceId = await _keys.loadDeviceId();

      final tokens = request.register
          ? await _api.register(
              username: request.username,
              password: request.password,
              deviceName: _deviceName(),
              keys: bundle,
            )
          : await _api.login(
              username: request.username,
              password: request.password,
              deviceName: _deviceName(),
              // A fresh install has no device id and must register one; a
              // returning install resumes the device it already owns.
              keys: knownDeviceId == null ? bundle : null,
              deviceId: knownDeviceId,
            );

      await _keys.saveDeviceId(tokens.deviceId);

      final account = Account(
        userId: tokens.userId,
        username: request.username,
        deviceId: tokens.deviceId,
      );
      await _accounts.saveSession(
        server: server,
        account: account,
        refreshToken: tokens.refreshToken,
      );

      await _startSession(account);
      setState(() {
        _busy = false;
        _askFingerprint = false;
        _lastServer = server.displayAddress;
      });
    } on ServerConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _askFingerprint = e.error == ServerError.untrustedCertificate;
        _error = _describeServerError(AppLocalizations.of(context), e);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Server messages are English; the common ones are known well
        // enough to say in the user's language.
        _error = e.isRateLimited
            ? AppLocalizations.of(context).errorTooManyAttempts
            : e.message;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppLocalizations.of(context).errorUnreachable;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppLocalizations.of(context).errorSignIn('$e');
      });
    }
  }

  static String _describeServerError(
    AppLocalizations l10n,
    ServerConfigException e,
  ) =>
      switch (e.error) {
        ServerError.noAddress => l10n.serverRequired,
        ServerError.badAddress => l10n.errorBadAddress,
        ServerError.incompleteLink => l10n.errorIncompleteLink,
        ServerError.fingerprintChars => l10n.errorFingerprintChars,
        ServerError.fingerprintTooShort => l10n.fingerprintTooShort,
        ServerError.noCertificate ||
        ServerError.oversizedCertificate ||
        ServerError.noCa =>
          l10n.errorNoCa,
        ServerError.fingerprintMismatch => l10n.errorFingerprintMismatch,
        ServerError.untrustedCertificate => l10n.errorUntrustedCertificate,
        ServerError.unreachable => l10n.errorUnreachable,
        ServerError.timeout => l10n.errorTimeout,
        ServerError.serverStatus => l10n.errorServerStatus(e.status ?? 0),
      };

  /// Wires up messaging for a signed-in account and opens the socket.
  Future<void> _startSession(Account account) async {
    final crypto = _crypto!;
    final connection = _connection!;

    final resolver = DeviceResolver(
      api: connection.api,
      crypto: crypto,
      selfDeviceId: account.deviceId,
      selfUsername: account.username,
    );

    final db = _database!.db;
    final repository = MessageRepository(
      crypto: crypto,
      ws: connection.ws,
      dao: _dao!,
      outbox: OutboxDao(db),
      groups: GroupCipher(
        dao: SenderKeyDao(db, sealer: _sealer),
        selfDeviceId: account.deviceId,
      ),
      resolver: resolver,
      api: connection.api,
      account: account,
    );

    await _chatSub?.cancel();
    _chatSub = repository.chatUpdates.listen((_) => _refreshChats());
    await _arrivalSub?.cancel();
    _arrivalSub = repository.arrivals.listen(_onArrival);

    final maintenance = KeyMaintenance(
      crypto: crypto,
      preKeyCount: connection.api.preKeyCount,
      uploadPreKeys: connection.api.uploadPreKeys,
      uploadSignedPreKey: connection.api.rotateSignedPreKey,
    );

    unawaited(connection.ws.connect());
    maintenance.start();

    final chats = await _dao!.chats();
    final blobCache = await AppDatabase.attachmentCacheDirectory();
    final avatarCache = Directory('${(await AppDatabase.dataDirectory()).path}/avatars');
    final api = connection.api;
    final avatars = AvatarStore(
      fetch: (owner, id) => owner == AvatarOwner.user ? api.userAvatar(id) : api.chatAvatar(id),
      cacheDir: avatarCache,
    );
    await _presence?.dispose();
    final presence = PresenceTracker(
      ws: connection.ws,
      api: api,
      contacts: () async => [
        for (final chat in await _dao!.chats())
          for (final m in chat.members)
            if (m.userId != account.userId) m.userId,
      ],
    );
    presence.setActive(_lifecycle == AppLifecycleState.resumed);
    if (!mounted) return;
    _avatars = avatars;
    _presence = presence;
    widget.session.value = _SessionScope(avatars: avatars, presence: presence, selfUserId: account.userId);
    setState(() {
      _account = account;
      _resolver = resolver;
      _repository = repository;
      _attachments = AttachmentRepository(connection.files, cacheDir: blobCache);
      _keyMaintenance = maintenance;
      _chats = chats;
    });
    _chatList.value = chats;
  }

  Future<void> _refreshChats() async {
    final chats = await _dao!.chats();
    if (!mounted) return;
    _chatList.value = chats;
    setState(() {
      _chats = chats;
      // The open chat follows its row: renamed, or gone after leaving.
      final selected = _selected;
      if (selected != null) {
        _selected = chats.where((c) => c.id == selected.id).firstOrNull;
      }
    });
  }

  /// Signs out, optionally destroying this device's identity.
  ///
  /// [forget] erases the identity keys as well. That is the right thing when
  /// handing the machine on, but it also makes the device unrecognisable: every
  /// contact has pinned the old identity key, so after signing back in the
  /// device is a stranger to them and no existing conversation can continue.
  /// The ordinary case keeps the identity and only drops the session, so
  /// signing back in resumes exactly where it left off.
  Future<void> _signOut({bool forget = false, String? reason}) async {
    if (_account == null && _connection == null) return;

    _keyMaintenance?.stop();
    // Order matters: stop the socket first. Wiping while frames are still
    // arriving would produce a burst of decrypt failures.
    await _connection?.ws.close();
    try {
      // Best effort: the session ends locally either way.
      await _connection?.api.logout();
    } catch (_) {}
    await _accounts.clearSession();
    if (forget) {
      await _keys.wipeAll();
      await _database?.wipe();
      // Unreadable without the keys just erased, but no reason to keep it.
      await _attachments?.clear();
      await _avatars?.clear();
    }
    widget.session.value = null;
    await _presence?.dispose();
    _presence = null;
    _avatars = null;
    await _repository?.dispose();
    await _chatSub?.cancel();
    _chatSub = null;
    await _disconnect();

    if (!mounted) return;
    setState(() {
      _account = null;
      _resolver = null;
      _repository = null;
      _attachments = null;
      _keyMaintenance = null;
      _chats = const [];
      _selected = null;
      _error = reason;
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error is ApiException ? error.message : '$error';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).actionFailed(message))),
    );
  }

  /// Finds someone and opens a chat with them, or starts a group.
  Future<void> _startChat() async {
    final navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => NewChatScreen(
        search: _api.searchUsers,
        onStart: (user, mode) async {
          try {
            final remote = await _api.createChat(
              type: 'direct',
              mode: mode,
              peer: user.username,
            );
            final chat = await _repository!.adoptChat(remote);
            navigator.pop();
            if (mounted) setState(() => _selected = chat);
          } catch (e) {
            _showError(e);
          }
        },
        onNewGroup: () => navigator.push(MaterialPageRoute<void>(
          builder: (_) => NewGroupScreen(
            search: _api.searchUsers,
            onCreate: (title, members, mode, hideHistory) async {
              final remote = await _api.createChat(
                type: 'group',
                mode: mode,
                members: [for (final m in members) m.username],
                title: title,
                hideHistory: hideHistory,
              );
              var chat = await _repository!.adoptChat(remote);
              if (chat.isSecret) {
                // The name goes to the members end to end, together with
                // our sender key; the server never had it.
                await _repository!.renameSecretGroup(chat.id, title);
                chat = await _repository!.chat(chat.id) ?? chat;
              }
              navigator
                ..pop()
                ..pop();
              if (mounted) setState(() => _selected = chat);
            },
          ),
        )),
      ),
    ));
  }

  /// Carries out what a chat row's menu asked for.
  Future<void> _onChatAction(Chat chat, ChatAction action) async {
    final repository = _repository;
    if (repository == null) return;
    final l10n = AppLocalizations.of(context);
    try {
      switch (action) {
        case ChatAction.togglePin:
          await repository.setPinned(chat.id, !chat.pinned);
        case ChatAction.toggleMute:
          await repository.setMuted(chat.id, !chat.muted);
        case ChatAction.toggleArchive:
          await repository.setArchived(chat.id, !chat.archived);
        case ChatAction.delete:
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(chat.isGroup ? l10n.leaveGroupTitle : l10n.deleteChatTitle),
              content: Text(chat.isGroup
                  ? l10n.leaveGroupBody
                  : chat.isCloud
                      ? l10n.deleteChatBody
                      : l10n.deleteSecretChatBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(chat.isGroup ? l10n.leave : l10n.delete),
                ),
              ],
            ),
          );
          if (!(confirmed ?? false)) return;
          if (chat.isGroup) {
            await _api.leaveChat(chat.id);
            await repository.forgetChat(chat.id);
          } else {
            await repository.deleteDirectChat(chat.id);
          }
          if (mounted && _selected?.id == chat.id) setState(() => _selected = null);
      }
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openArchive() async {
    final navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => ValueListenableBuilder<List<Chat>>(
        valueListenable: _chatList,
        builder: (context, chats, _) => ChatListScreen(
          archive: true,
          chats: chats,
          connection: _socketState,
          onOpenChat: (chat) {
            navigator.pop();
            setState(() => _selected = chat);
          },
          onChatAction: _onChatAction,
        ),
      ),
    ));
  }

  Future<void> _openSearch() async {
    final navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => SearchScreen(
        chats: _chats,
        searchMessages: (query) => _dao!.search(query),
        searchServer: _repository?.searchServer,
        onOpenChat: (chat) {
          navigator.pop();
          setState(() => _selected = chat);
        },
      ),
    ));
  }

  /// Asks which chat a message should be forwarded to.
  Future<Chat?> _pickForwardTarget() {
    final l10n = AppLocalizations.of(context);
    final targets = _chats.where((c) => !c.hidden).toList();
    return showDialog<Chat>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.forwardTo),
        children: [
          SizedBox(
            width: 360,
            height: 420,
            child: ListView(
              children: [
                for (final chat in targets)
                  ListTile(
                    leading: Icon(
                      chat.isGroup ? Icons.groups_rounded : Icons.person_rounded,
                      color: chat.isSecret ? Theme.of(dialogContext).colorScheme.tertiary : null,
                    ),
                    title: Text(chat.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: chat.isSecret ? const Icon(Icons.lock_rounded, size: 16) : null,
                    onTap: () => Navigator.of(dialogContext).pop(chat),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openGroupInfo(Chat chat) async {
    final account = _account;
    final repository = _repository;
    if (account == null || repository == null) return;
    final navigator = Navigator.of(context);

    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => GroupInfoScreen(
        chat: chat,
        selfUserId: account.userId,
        onRename: (title) async {
          if (chat.isCloud) {
            return repository.adoptChat(await _api.renameChat(chat.id, title));
          }
          await repository.renameSecretGroup(chat.id, title);
          return repository.chat(chat.id);
        },
        onAddMembers: () async {
          final current = await repository.chat(chat.id) ?? chat;
          final picked = await navigator.push<List<UserProfile>>(MaterialPageRoute(
            builder: (_) => UserPickerScreen(
              search: _api.searchUsers,
              excludeIds: {for (final m in current.members) m.userId},
            ),
          ));
          if (picked == null || picked.isEmpty) return null;
          final updated = await repository.adoptChat(
            await _api.addMembers(chat.id, [for (final u in picked) u.username]),
          );
          // Newcomers to a secret group learn its name from the members,
          // never from the server.
          final title = updated.title;
          if (updated.isSecret && title != null) {
            await repository.renameSecretGroup(updated.id, title);
          }
          return repository.chat(chat.id);
        },
        onRemove: (member) async =>
            repository.adoptChat(await _api.removeMember(chat.id, member.userId)),
        onChangeAvatar: chat.isSecret
            ? null
            : () async {
                final picture = await _pickAvatar();
                if (picture == null) return null;
                final version = await _api.setChatAvatar(chat.id, picture);
                await _avatars?.put(AvatarOwner.chat, chat.id, version, picture);
                return repository.adoptChat(await _api.getChat(chat.id));
              },
        onRemoveAvatar: chat.isSecret
            ? null
            : () async {
                await _api.clearChatAvatar(chat.id);
                return repository.adoptChat(await _api.getChat(chat.id));
              },
        onSetHideHistory: chat.isSecret
            ? null
            : (hide) async => repository.adoptChat(await _api.setHideHistory(chat.id, hide)),
        onLeave: () async {
          try {
            await _api.leaveChat(chat.id);
            await repository.forgetChat(chat.id);
            navigator.pop();
          } catch (e) {
            _showError(e);
          }
        },
      ),
    ));
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
          server: _connection?.server.displayAddress ?? _lastServer,
          preferences: widget.preferences,
          sessions: sessions,
          onRevokeSession: (session) => _api.revokeSession(session.id),
          onSignOut: ({required bool forget}) {
            Navigator.of(context).pop();
            _signOut(forget: forget);
          },
          appVersion: appVersion,
          voicePlayer: _voicePlayer,
          loadProfile: _api.me,
          onSaveProfile: (name, bio) => _api.updateMe(displayName: name, bio: bio),
          onChangeAvatar: () async {
            final picture = await _pickAvatar();
            if (picture == null) return null;
            final version = await _api.setMyAvatar(picture);
            await _avatars?.put(AvatarOwner.user, account.userId, version, picture);
            return _api.me();
          },
          onRemoveAvatar: () async {
            await _api.clearMyAvatar();
            return _api.me();
          },
          onSetLastSeenVisible: (visible) async {
            final me = await _api.updateMe(lastSeenVisible: visible);
            // What we see of others changes too.
            unawaited(_presence?.refresh());
            return me;
          },
          onChangePassword: (current, next) =>
              _api.changePassword(currentPassword: current, newPassword: next),
          onDeleteAccount: (password) async {
            await _api.deleteAccount(password);
            if (!mounted) return;
            Navigator.of(context).pop();
            // Nothing of the account is left to come back to: the keys and
            // the local history go too.
            await _signOut(forget: true);
          },
        ),
      ),
    );
  }

  /// Lets the user pick a photo and makes an avatar of it: the centre
  /// square, small. Null when they changed their mind.
  Future<Uint8List?> _pickAvatar() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final picked = await const AttachmentPicker().pick(AttachSource.gallery);
    final photo = picked.where((p) => p.isImage).firstOrNull;
    if (photo == null) return null;
    try {
      return await prepareAvatar(photo.bytes);
    } on FormatException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.avatarFailed)));
      return null;
    }
  }

  /// Opens a received file in the program the system has for it.
  Future<void> _openAttachment(AttachmentPayload attachment, Uint8List bytes) =>
      _handOver(attachment, bytes, open: true);

  /// Asks where to keep a received file and writes it there.
  Future<void> _saveAttachment(AttachmentPayload attachment, Uint8List bytes) =>
      _handOver(attachment, bytes, open: false);

  Future<void> _handOver(
    AttachmentPayload attachment,
    Uint8List bytes, {
    required bool open,
  }) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = attachment.fileName ?? l10n.attachmentFile;
    const saver = AttachmentSaver();
    try {
      final outcome = open
          ? await saver.open(name, bytes, attachment.mimeType)
          : await saver.save(name, bytes, attachment.mimeType);
      if (outcome == SaveOutcome.saved) {
        final program = open && AttachmentSaver.isExecutable(AttachmentSaver.safeFileName(name));
        messenger.showSnackBar(SnackBar(
          content: Text(program ? l10n.fileOpenedAsSave : l10n.fileSaved),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.couldNotOpenFile('$e'))));
    }
  }
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
    _keyMaintenance?.stop();
    _chatSub?.cancel();
    _arrivalSub?.cancel();
    _tapSub?.cancel();
    _notifications.dispose();
    _voicePlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _chatList.dispose();
    _repository?.dispose();
    _disconnect();
    _database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_starting) {
      return const Scaffold(body: Center(child: BrandMark(size: 48)));
    }

    if (_account == null) {
      return LoginScreen(
        onSubmit: _authenticate,
        busy: _busy,
        initialServer: _lastServer,
        askFingerprint: _askFingerprint,
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
        onChatAction: _onChatAction,
        onOpenArchive: _openArchive,
        onSearch: _openSearch,
      ),
      detail: _selected == null ? null : _buildChat(_selected!),
    );
  }

  /// Builds the conversation view with its own bloc.
  ///
  /// Keyed by chat id so switching conversations creates a fresh bloc rather
  /// than reusing one still holding the previous chat's messages.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // In the background we still get messages, but are not "online".
    _presence?.setActive(state == AppLifecycleState.resumed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tray menu speaks the interface language, and follows it.
    final l10n = AppLocalizations.of(context);
    unawaited(DesktopShell.instance.attach(openLabel: l10n.trayOpen, quitLabel: l10n.trayQuit));
  }

  /// A message from someone else arrived: tell the user unless they are
  /// already looking at it.
  Future<void> _onArrival(Message message) async {
    final chat = await _dao?.chatById(message.chatId);
    final inFront = _lifecycle == AppLifecycleState.resumed &&
        await DesktopShell.instance.isInFront();
    final prefs = widget.preferences;
    if (!shouldNotify(
      message: message,
      chat: chat,
      enabled: prefs.notifications,
      appInFront: inFront,
      openChatId: _selected?.id,
    )) {
      return;
    }
    if (!mounted || chat == null) return;
    final l10n = AppLocalizations.of(context);
    final content = notificationContent(
      message: message,
      chat: chat,
      showPreview: prefs.notificationPreview,
      texts: NotificationTexts(
        newMessage: l10n.notifyNewMessage,
        photo: l10n.previewPhoto,
        file: l10n.previewFile,
        voice: l10n.notifyVoice,
        appName: l10n.appTitle,
      ),
    );
    _clearedFor = null;
    await _notifications.show(chatId: chat.id, title: content.title, body: content.body);
  }

  /// The user tapped a notification: show that chat.
  Future<void> _openFromNotification(String chatId) async {
    await DesktopShell.instance.bringToFront();
    final chat = _chats.where((c) => c.id == chatId).firstOrNull ??
        await _dao?.chatById(chatId);
    if (chat != null && mounted) setState(() => _selected = chat);
  }

  Widget _buildChat(Chat chat) {
    if (_clearedFor != chat.id) {
      _clearedFor = chat.id;
      unawaited(_notifications.clear(chat.id));
    }
    return BlocProvider<ChatBloc>(
      key: ValueKey(chat.id),
      create: (_) => ChatBloc(
        repository: _repository!,
        crypto: _crypto!,
        resolver: _resolver!,
        attachments: _attachments,
      )..add(ChatOpened(chat)),
      child: ChatScreen(
        selfUserId: _account?.userId,
        onBack: () => setState(() => _selected = null),
        onShowSafetyNumber: () => _showSafetyNumber(chat),
        onOpenInfo: () => _openGroupInfo(chat),
        onPickForwardTarget: _pickForwardTarget,
        onPickAttachment: const AttachmentPicker().pick,
        onDownloadAttachment: (attachment, onProgress) => _attachments!.download(
          attachment,
          onProgress: (p) => onProgress(p.fraction),
        ),
        cachedAttachment: (attachment) => _attachments?.cached(attachment.blobId),
        onOpenAttachment: _openAttachment,
        onSaveAttachment: _saveAttachment,
        voicePlayer: _voicePlayer,
        startRecording: () => VoiceRecording.start(widget.preferences),
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
        SnackBar(
          content: Text(AppLocalizations.of(context).couldNotComputeSafety('$e')),
        ),
      );
    }
  }
}
