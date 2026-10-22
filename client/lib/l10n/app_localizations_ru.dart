// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Frogster';

  @override
  String get loginTagline => 'Приватный мессенджер с секретными чатами';

  @override
  String get serverLabel => 'Сервер';

  @override
  String get serverHint => 'chat.example.com или 203.0.113.5';

  @override
  String get serverRequired => 'Введите адрес сервера';

  @override
  String get fingerprintLabel => 'Отпечаток сертификата';

  @override
  String get fingerprintHelper =>
      'Его печатает установщик, или выполните «frogster fingerprint» на сервере';

  @override
  String get fingerprintTooShort => 'Введите все 8 групп';

  @override
  String get haveFingerprint => 'У меня есть отпечаток сертификата';

  @override
  String get usernameLabel => 'Имя пользователя';

  @override
  String get passwordLabel => 'Пароль';

  @override
  String get usernameTooShort => 'Минимум 3 символа';

  @override
  String get usernameInvalid => 'Только латиница, цифры и _';

  @override
  String get passwordTooShort => 'Минимум 10 символов';

  @override
  String get signIn => 'Войти';

  @override
  String get createAccount => 'Создать аккаунт';

  @override
  String get haveAccount => 'У меня уже есть аккаунт';

  @override
  String get newAccount => 'Создать новый аккаунт';

  @override
  String get showPassword => 'Показать пароль';

  @override
  String get hidePassword => 'Скрыть пароль';

  @override
  String get errorTooManyAttempts =>
      'Слишком много попыток. Попробуйте через несколько минут.';

  @override
  String get errorUnreachable => 'Не удалось связаться с сервером';

  @override
  String get errorTimeout => 'Сервер не ответил вовремя';

  @override
  String get errorBadAddress => 'Это не похоже на адрес сервера';

  @override
  String get errorIncompleteLink => 'Ссылка для подключения неполная';

  @override
  String get errorUntrustedCertificate =>
      'Сервер использует собственный сертификат. Введите отпечаток из вывода установщика (или «frogster fingerprint» на сервере).';

  @override
  String get errorFingerprintMismatch =>
      'Отпечаток сертификата не совпадает. Сверьте его с «frogster fingerprint» на сервере. Если он верный — возможно, соединение кто-то перехватывает.';

  @override
  String get errorNoCa =>
      'Этот сервер не публикует собственный сертификат. Если у него есть домен — подключайтесь без отпечатка.';

  @override
  String get errorFingerprintChars => 'В отпечатке допустимы только 0–9 и A–F';

  @override
  String errorServerStatus(int code) {
    return 'Сервер ответил ошибкой ($code)';
  }

  @override
  String errorSignIn(String error) {
    return 'Не удалось войти: $error';
  }

  @override
  String get sessionEnded => 'Сессия завершена. Войдите снова.';

  @override
  String get connectionSecure => 'в сети';

  @override
  String get connectionConnecting => 'подключение…';

  @override
  String get connectionOffline => 'нет сети';

  @override
  String get emptyChatsTitle => 'Пока нет чатов';

  @override
  String get emptyChatsBody => 'Начните разговор кнопкой +';

  @override
  String get navChats => 'Чаты';

  @override
  String get navNewChat => 'Новый чат';

  @override
  String get navSettings => 'Настройки';

  @override
  String get selectConversation => 'Выберите разговор';

  @override
  String get yesterday => 'Вчера';

  @override
  String get today => 'Сегодня';

  @override
  String get newChatTitle => 'Новый чат';

  @override
  String get newChatUsername => 'Имя собеседника';

  @override
  String get cancel => 'Отмена';

  @override
  String get start => 'Начать';

  @override
  String get back => 'Назад';

  @override
  String get safetyNumberTooltip => 'Код безопасности';

  @override
  String get messagePlaceholder => 'Сообщение';

  @override
  String get verifyToSend => 'Сверьте контакт, чтобы писать';

  @override
  String get attach => 'Прикрепить фото';

  @override
  String get send => 'Отправить';

  @override
  String get removeAttachment => 'Убрать';

  @override
  String get noMessages => 'Сообщений пока нет — поздоровайтесь';

  @override
  String get couldNotLoad => 'Не удалось загрузить сообщения';

  @override
  String couldNotReadFile(String error) {
    return 'Не удалось прочитать файл: $error';
  }

  @override
  String get identityChangedBlocking =>
      'Код безопасности собеседника изменился. Возможно, он переустановил приложение — или кто-то перехватывает переписку. Сверьте код перед отправкой.';

  @override
  String get identityChangedInfo =>
      'Код безопасности собеседника изменился — обычно это значит, что он сменил устройство. Сообщения по-прежнему зашифрованы. Сверьте код, если хотите быть уверены.';

  @override
  String get iVerifiedIt => 'Я сверил';

  @override
  String get gotIt => 'Понятно';

  @override
  String get statusSending => 'Отправляется';

  @override
  String get statusSent => 'Отправлено';

  @override
  String get statusDelivered => 'Доставлено';

  @override
  String get statusRead => 'Прочитано';

  @override
  String get statusFailed => 'Не отправлено';

  @override
  String get attachmentPhoto => 'Фото';

  @override
  String get attachmentVideo => 'Видео';

  @override
  String get attachmentAudio => 'Аудио';

  @override
  String get attachmentPdf => 'PDF-документ';

  @override
  String get attachmentFile => 'Файл';

  @override
  String attachmentTapToOpen(String size) {
    return 'Нажмите, чтобы открыть · $size';
  }

  @override
  String get attachmentDownloadFailed => 'Не удалось скачать';

  @override
  String get attachmentCannotDisplay => 'Не удалось показать';

  @override
  String get filesTooLarge => 'Файл должен быть меньше 100 МБ';

  @override
  String savedTo(String path) {
    return 'Сохранено: $path';
  }

  @override
  String couldNotOpenFile(String error) {
    return 'Не удалось открыть файл: $error';
  }

  @override
  String couldNotComputeSafety(String error) {
    return 'Не удалось вычислить код безопасности: $error';
  }

  @override
  String get settingsTitle => 'Настройки';

  @override
  String signedInAs(String server) {
    return 'Вход выполнен на $server';
  }

  @override
  String get appearance => 'Оформление';

  @override
  String get themeSystem => 'Как в системе';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get language => 'Язык';

  @override
  String get languageSystem => 'Как в системе';

  @override
  String get security => 'Безопасность';

  @override
  String get changePassword => 'Сменить пароль';

  @override
  String get changePasswordHint =>
      'Все остальные устройства выйдут из аккаунта';

  @override
  String get activeSessions => 'Активные сеансы';

  @override
  String get noOtherSessions => 'Других сеансов нет';

  @override
  String get signOut => 'Выйти';

  @override
  String get signOutHint => 'Ключи останутся, можно будет войти снова';

  @override
  String get signOutDeviceTitle => 'Выйти на этом устройстве?';

  @override
  String signOutDeviceBody(String device) {
    return '«$device» сразу выйдет из аккаунта и будет отключено: собеседники перестанут шифровать для него новые сообщения. Подходит для потерянного телефона.';
  }

  @override
  String get signOutTitle => 'Выйти?';

  @override
  String get signOutBody =>
      'Сообщения и ключи шифрования останутся на этом устройстве — можно войти снова и продолжить с того же места.\n\n«Стереть всё» удалит и личность устройства. Собеседники увидят его как новое, и продолжить прежние секретные переписки не получится.';

  @override
  String get eraseEverything => 'Стереть всё';

  @override
  String get unknownDevice => 'Неизвестное устройство';

  @override
  String get thisDevice => 'Это устройство';

  @override
  String lastUsed(String date) {
    return 'Был активен $date';
  }

  @override
  String get safetyNumberTitle => 'Код безопасности';

  @override
  String verifyWith(String name) {
    return 'Сверка с $name';
  }

  @override
  String get safetyExplain =>
      'Сравните эти цифры при встрече или по звонку, которому доверяете. Если совпадают — никто посередине не может читать вашу переписку.';

  @override
  String get copy => 'Копировать';

  @override
  String get copied => 'Код скопирован';

  @override
  String get markVerified => 'Отметить как сверенный';

  @override
  String get safetyChangeNote =>
      'Если код потом изменится, собеседник мог переустановить приложение — или кто-то перехватывает переписку. Frogster сообщит, когда это случится.';

  @override
  String get chatEncrypted => 'Сквозное шифрование';

  @override
  String get chatsTitle => 'Чаты';

  @override
  String get connectionOfflineHint =>
      'Сообщения отправятся, когда связь восстановится';

  @override
  String get filterAll => 'Все';

  @override
  String get filterDirect => 'Личные';

  @override
  String get filterGroups => 'Группы';

  @override
  String get filterEmpty => 'Здесь пока пусто';

  @override
  String get filterSecret => 'Секретные';

  @override
  String get modeCloud => 'Обычный';

  @override
  String get modeSecret => 'Секретный';

  @override
  String get modeCloudExplain =>
      'Хранится на сервере в зашифрованном виде и доступен на всех ваших устройствах.';

  @override
  String get modeSecretExplain =>
      'Сквозное шифрование: прочитать могут только устройства участников. История остаётся там, где была написана.';

  @override
  String get secretChatSubtitle => 'секретный чат';

  @override
  String secretGroupSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count участника',
      many: '$count участников',
      few: '$count участника',
      one: '$count участник',
    );
    return 'секретная группа · $_temp0';
  }

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count участника',
      many: '$count участников',
      few: '$count участника',
      one: '$count участник',
    );
    return '$_temp0';
  }

  @override
  String get newChatSearchHint => 'Имя пользователя';

  @override
  String get searchTooShort => 'Введите хотя бы две буквы имени';

  @override
  String get searchNobody => 'Никого с таким именем';

  @override
  String searchFailed(String error) {
    return 'Поиск не удался: $error';
  }

  @override
  String get newGroup => 'Новая группа';

  @override
  String get newGroupTitle => 'Новая группа';

  @override
  String get groupNameLabel => 'Название группы';

  @override
  String get groupMembersLabel => 'Участники';

  @override
  String get groupAddPeople => 'Найдите, кого добавить';

  @override
  String get groupNeedsMembers => 'Добавьте хотя бы одного участника';

  @override
  String get groupNeedsName => 'Дайте группе название';

  @override
  String get create => 'Создать';

  @override
  String get groupInfo => 'О группе';

  @override
  String get addMembers => 'Добавить участников';

  @override
  String get add => 'Добавить';

  @override
  String get removeFromGroup => 'Удалить из группы';

  @override
  String get leaveGroup => 'Покинуть группу';

  @override
  String get leaveGroupTitle => 'Покинуть группу?';

  @override
  String get leaveGroupBody =>
      'Новые сообщения перестанут приходить. Вернуться можно, только если вас снова добавит админ.';

  @override
  String get leave => 'Покинуть';

  @override
  String get rename => 'Переименовать';

  @override
  String get save => 'Сохранить';

  @override
  String get roleAdmin => 'админ';

  @override
  String youSuffix(String name) {
    return '$name (вы)';
  }

  @override
  String get actionCopy => 'Копировать';

  @override
  String get actionEdit => 'Изменить';

  @override
  String get actionDelete => 'Удалить у всех';

  @override
  String get actionRetry => 'Отправить снова';

  @override
  String get textCopied => 'Скопировано';

  @override
  String get editingMessage => 'Редактирование';

  @override
  String get editedMark => 'изм.';

  @override
  String get deleteMessageTitle => 'Удалить у всех?';

  @override
  String get deleteMessageBody =>
      'Сообщение исчезнет из этого чата на всех устройствах.';

  @override
  String get delete => 'Удалить';

  @override
  String get previewPhoto => 'Фото';

  @override
  String get previewFile => 'Файл';

  @override
  String get failedTapToRetry => 'Не отправлено — нажмите, чтобы повторить';

  @override
  String actionFailed(String error) {
    return 'Не получилось: $error';
  }

  @override
  String get secretGroupNameNote =>
      'Название передаётся со сквозным шифрованием — сервер его не видит.';

  @override
  String get actionReply => 'Ответить';

  @override
  String get actionForward => 'Переслать';

  @override
  String get forwardTo => 'Переслать в';

  @override
  String forwardedFrom(String name) {
    return 'Переслано от $name';
  }

  @override
  String forwardedDone(String chat) {
    return 'Переслано в «$chat»';
  }

  @override
  String replyingTo(String name) {
    return 'Ответ $name';
  }

  @override
  String get replyUnknown => 'Сообщение';

  @override
  String get you => 'Вы';

  @override
  String get typing => 'печатает…';

  @override
  String typingNamed(String name) {
    return '$name печатает…';
  }

  @override
  String get typingSeveral => 'несколько человек печатают…';

  @override
  String get draftPrefix => 'Черновик:';

  @override
  String get unreadDivider => 'Непрочитанные сообщения';

  @override
  String get chatPin => 'Закрепить';

  @override
  String get chatUnpin => 'Открепить';

  @override
  String get chatMute => 'Без звука';

  @override
  String get chatUnmute => 'Включить звук';

  @override
  String get chatArchive => 'В архив';

  @override
  String get chatUnarchive => 'Из архива';

  @override
  String get archiveTitle => 'Архив';

  @override
  String get deleteChat => 'Удалить чат';

  @override
  String get deleteChatTitle => 'Удалить чат?';

  @override
  String get deleteChatBody =>
      'История удалится со всех ваших устройств. У собеседника она останется.';

  @override
  String get deleteSecretChatBody =>
      'История удалится с этого устройства. У собеседника она останется.';

  @override
  String get editProfile => 'Изменить профиль';

  @override
  String get displayNameLabel => 'Имя';

  @override
  String get displayNameHint => 'Как вас видят собеседники';

  @override
  String get bioLabel => 'О себе';

  @override
  String get profileSaved => 'Профиль сохранён';

  @override
  String get currentPassword => 'Текущий пароль';

  @override
  String get newPassword => 'Новый пароль';

  @override
  String get repeatPassword => 'Повторите новый пароль';

  @override
  String get passwordsDiffer => 'Пароли не совпадают';

  @override
  String get passwordWrong => 'Текущий пароль неверный';

  @override
  String get passwordChanged =>
      'Пароль изменён. Остальные устройства вышли из аккаунта.';

  @override
  String get deleteAccount => 'Удалить аккаунт';

  @override
  String get deleteAccountHint => 'Навсегда: устройства, ключи и имя';

  @override
  String get deleteAccountTitle => 'Удалить аккаунт?';

  @override
  String get deleteAccountBody =>
      'Все ваши устройства выйдут из аккаунта, их ключи сотрутся, вы покинете все группы, а имя пользователя освободится. Отправленные сообщения останутся у тех, кто их получил. Отменить это нельзя.';

  @override
  String get deleteAccountConfirm => 'Удалить навсегда';

  @override
  String get about => 'О приложении';

  @override
  String appVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get licenses => 'Лицензии открытого ПО';

  @override
  String get deletedAccount => 'Удалённый аккаунт';

  @override
  String get search => 'Поиск';

  @override
  String get searchHint => 'Чаты и сообщения';

  @override
  String get searchMessages => 'Сообщения';

  @override
  String get searchNothing => 'Ничего не нашлось';

  @override
  String get notifications => 'Уведомления';

  @override
  String get notificationsShow => 'Показывать уведомления';

  @override
  String get notificationsPreview => 'Показывать текст сообщения';

  @override
  String get notificationsPreviewHint =>
      'Если выключить — только «Новое сообщение», без имени и текста';

  @override
  String get notifyNewMessage => 'Новое сообщение';

  @override
  String get notifyVoice => 'Голосовое сообщение';

  @override
  String get trayOpen => 'Открыть Frogster';

  @override
  String get trayQuit => 'Выйти';
}
