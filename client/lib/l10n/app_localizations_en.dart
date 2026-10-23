// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Frogster';

  @override
  String get loginTagline => 'Private messenger with secret chats';

  @override
  String get serverLabel => 'Server';

  @override
  String get serverHint => 'chat.example.com or 203.0.113.5';

  @override
  String get serverRequired => 'Enter the server address';

  @override
  String get fingerprintLabel => 'Certificate fingerprint';

  @override
  String get fingerprintHelper =>
      'Printed by the installer, or run \"frogster fingerprint\" on the server';

  @override
  String get fingerprintTooShort => 'Enter all 8 groups';

  @override
  String get haveFingerprint => 'I have a certificate fingerprint';

  @override
  String get usernameLabel => 'Username';

  @override
  String get passwordLabel => 'Password';

  @override
  String get usernameTooShort => 'At least 3 characters';

  @override
  String get usernameInvalid => 'Latin letters, digits and underscore only';

  @override
  String get passwordTooShort => 'At least 10 characters';

  @override
  String get signIn => 'Sign in';

  @override
  String get createAccount => 'Create account';

  @override
  String get haveAccount => 'I already have an account';

  @override
  String get newAccount => 'Create a new account';

  @override
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get errorTooManyAttempts =>
      'Too many attempts. Try again in a few minutes.';

  @override
  String get errorUnreachable => 'Could not reach the server';

  @override
  String get errorTimeout => 'The server did not answer in time';

  @override
  String get errorBadAddress => 'This does not look like a server address';

  @override
  String get errorIncompleteLink => 'This connection link is incomplete';

  @override
  String get errorUntrustedCertificate =>
      'The server uses its own certificate. Enter the fingerprint shown by the installer (or \"frogster fingerprint\" on the server).';

  @override
  String get errorFingerprintMismatch =>
      'The certificate fingerprint does not match. Check it with \"frogster fingerprint\" on the server. If it is right, someone may be intercepting the connection.';

  @override
  String get errorNoCa =>
      'This server does not publish its own certificate. If it has a domain name, connect without a fingerprint.';

  @override
  String get errorFingerprintChars =>
      'The fingerprint may only contain 0–9 and A–F';

  @override
  String errorServerStatus(int code) {
    return 'The server answered with an error ($code)';
  }

  @override
  String errorSignIn(String error) {
    return 'Sign-in failed: $error';
  }

  @override
  String get sessionEnded => 'Your session has ended. Sign in again.';

  @override
  String get connectionSecure => 'online';

  @override
  String get connectionConnecting => 'connecting…';

  @override
  String get connectionOffline => 'offline';

  @override
  String get emptyChatsTitle => 'No chats yet';

  @override
  String get emptyChatsBody => 'Start a conversation with the + button';

  @override
  String get navChats => 'Chats';

  @override
  String get navNewChat => 'New chat';

  @override
  String get navSettings => 'Settings';

  @override
  String get selectConversation => 'Pick a conversation';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get today => 'Today';

  @override
  String get newChatTitle => 'New chat';

  @override
  String get newChatUsername => 'Their username';

  @override
  String get cancel => 'Cancel';

  @override
  String get start => 'Start';

  @override
  String get back => 'Back';

  @override
  String get safetyNumberTooltip => 'Safety number';

  @override
  String get messagePlaceholder => 'Message';

  @override
  String get verifyToSend => 'Verify the contact to send';

  @override
  String get attach => 'Attach a photo';

  @override
  String get send => 'Send';

  @override
  String get removeAttachment => 'Remove';

  @override
  String get noMessages => 'No messages yet — say hi';

  @override
  String get couldNotLoad => 'Could not load messages';

  @override
  String couldNotReadFile(String error) {
    return 'Could not read the file: $error';
  }

  @override
  String get identityChangedBlocking =>
      'This contact\'s safety number has changed. They may have reinstalled the app — or someone may be intercepting your messages. Verify before sending.';

  @override
  String get identityChangedInfo =>
      'This contact\'s safety number has changed, usually because they switched to a new device. Your messages are still encrypted. Verify the number if you want to be certain.';

  @override
  String get iVerifiedIt => 'I verified it';

  @override
  String get gotIt => 'Got it';

  @override
  String get statusSending => 'Sending';

  @override
  String get statusSent => 'Sent';

  @override
  String get statusDelivered => 'Delivered';

  @override
  String get statusRead => 'Read';

  @override
  String get statusFailed => 'Not sent';

  @override
  String get attachmentPhoto => 'Photo';

  @override
  String get attachmentVideo => 'Video';

  @override
  String get attachmentAudio => 'Audio';

  @override
  String get attachmentPdf => 'PDF document';

  @override
  String get attachmentFile => 'File';

  @override
  String attachmentTapToOpen(String size) {
    return 'Tap to open · $size';
  }

  @override
  String get attachmentDownloadFailed => 'Download failed';

  @override
  String get attachmentCannotDisplay => 'Could not display';

  @override
  String get filesTooLarge => 'Files must be under 100 MB';

  @override
  String savedTo(String path) {
    return 'Saved to $path';
  }

  @override
  String couldNotOpenFile(String error) {
    return 'Could not open the file: $error';
  }

  @override
  String couldNotComputeSafety(String error) {
    return 'Could not compute the safety number: $error';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String signedInAs(String server) {
    return 'Signed in on $server';
  }

  @override
  String get appearance => 'Appearance';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get security => 'Security';

  @override
  String get changePassword => 'Change password';

  @override
  String get changePasswordHint => 'Signs out every other device';

  @override
  String get activeSessions => 'Active sessions';

  @override
  String get noOtherSessions => 'No other sessions';

  @override
  String get signOut => 'Sign out';

  @override
  String get signOutHint => 'Keeps your keys so you can sign back in';

  @override
  String get signOutDeviceTitle => 'Sign out this device?';

  @override
  String signOutDeviceBody(String device) {
    return '\"$device\" will be signed out immediately and retired: your contacts stop encrypting new messages to it. Use this for a phone you no longer have.';
  }

  @override
  String get signOutTitle => 'Sign out?';

  @override
  String get signOutBody =>
      'Your messages and encryption keys stay on this device, so you can sign back in and carry on where you left off.\n\nErasing everything also removes this device\'s identity. Your contacts will see it as a new device, and existing conversations cannot be continued.';

  @override
  String get eraseEverything => 'Erase everything';

  @override
  String get unknownDevice => 'Unknown device';

  @override
  String get thisDevice => 'This device';

  @override
  String lastUsed(String date) {
    return 'Last used $date';
  }

  @override
  String get safetyNumberTitle => 'Safety number';

  @override
  String verifyWith(String name) {
    return 'Verify with $name';
  }

  @override
  String get safetyExplain =>
      'Compare these numbers in person or over a call you trust. If they match, nobody in between can read your conversation.';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Safety number copied';

  @override
  String get markVerified => 'Mark as verified';

  @override
  String get safetyChangeNote =>
      'If this number changes later, your contact may have reinstalled the app — or someone may be intercepting the conversation. Frogster will tell you when it happens.';

  @override
  String get chatEncrypted => 'End-to-end encrypted';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get connectionOfflineHint =>
      'Messages will be sent when the connection is back';

  @override
  String get filterAll => 'All';

  @override
  String get filterDirect => 'Direct';

  @override
  String get filterGroups => 'Groups';

  @override
  String get filterEmpty => 'Nothing here yet';

  @override
  String get filterSecret => 'Secret';

  @override
  String get modeCloud => 'Regular';

  @override
  String get modeSecret => 'Secret';

  @override
  String get modeCloudExplain =>
      'Stored on the server in encrypted form and synced to all your devices.';

  @override
  String get modeSecretExplain =>
      'End-to-end encrypted: only the participants’ devices can read it. History stays on the devices it was written on.';

  @override
  String get secretChatSubtitle => 'secret chat';

  @override
  String secretGroupSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return 'secret group · $_temp0';
  }

  @override
  String membersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get newChatSearchHint => 'Username';

  @override
  String get searchTooShort => 'Type at least two letters of a username';

  @override
  String get searchNobody => 'Nobody by that name';

  @override
  String searchFailed(String error) {
    return 'Search failed: $error';
  }

  @override
  String get newGroup => 'New group';

  @override
  String get newGroupTitle => 'New group';

  @override
  String get groupNameLabel => 'Group name';

  @override
  String get groupMembersLabel => 'Members';

  @override
  String get groupAddPeople => 'Find people to add';

  @override
  String get groupNeedsMembers => 'Add at least one member';

  @override
  String get groupNeedsName => 'Give the group a name';

  @override
  String get create => 'Create';

  @override
  String get groupInfo => 'Group info';

  @override
  String get addMembers => 'Add members';

  @override
  String get add => 'Add';

  @override
  String get removeFromGroup => 'Remove from group';

  @override
  String get leaveGroup => 'Leave group';

  @override
  String get leaveGroupTitle => 'Leave the group?';

  @override
  String get leaveGroupBody =>
      'You will stop receiving its messages. To come back, an admin has to add you again.';

  @override
  String get leave => 'Leave';

  @override
  String get rename => 'Rename';

  @override
  String get save => 'Save';

  @override
  String get roleAdmin => 'admin';

  @override
  String youSuffix(String name) {
    return '$name (you)';
  }

  @override
  String get actionCopy => 'Copy';

  @override
  String get actionEdit => 'Edit';

  @override
  String get actionDelete => 'Delete for everyone';

  @override
  String get actionRetry => 'Send again';

  @override
  String get textCopied => 'Copied';

  @override
  String get editingMessage => 'Editing';

  @override
  String get editedMark => 'edited';

  @override
  String get deleteMessageTitle => 'Delete for everyone?';

  @override
  String get deleteMessageBody =>
      'The message disappears from this chat on every device.';

  @override
  String get delete => 'Delete';

  @override
  String get previewPhoto => 'Photo';

  @override
  String get previewFile => 'File';

  @override
  String get failedTapToRetry => 'Not sent — tap to try again';

  @override
  String actionFailed(String error) {
    return 'Could not do that: $error';
  }

  @override
  String get secretGroupNameNote =>
      'The name is sent end to end: the server never sees it.';

  @override
  String get actionReply => 'Reply';

  @override
  String get actionForward => 'Forward';

  @override
  String get forwardTo => 'Forward to';

  @override
  String forwardedFrom(String name) {
    return 'Forwarded from $name';
  }

  @override
  String forwardedDone(String chat) {
    return 'Forwarded to $chat';
  }

  @override
  String replyingTo(String name) {
    return 'Reply to $name';
  }

  @override
  String get replyUnknown => 'Message';

  @override
  String get you => 'You';

  @override
  String get typing => 'typing…';

  @override
  String typingNamed(String name) {
    return '$name is typing…';
  }

  @override
  String get typingSeveral => 'several people are typing…';

  @override
  String get draftPrefix => 'Draft:';

  @override
  String get unreadDivider => 'Unread messages';

  @override
  String get chatPin => 'Pin';

  @override
  String get chatUnpin => 'Unpin';

  @override
  String get chatMute => 'Mute';

  @override
  String get chatUnmute => 'Unmute';

  @override
  String get chatArchive => 'Archive';

  @override
  String get chatUnarchive => 'Unarchive';

  @override
  String get archiveTitle => 'Archive';

  @override
  String get deleteChat => 'Delete chat';

  @override
  String get deleteChatTitle => 'Delete this chat?';

  @override
  String get deleteChatBody =>
      'Its history is removed from all your devices. The other side keeps theirs.';

  @override
  String get deleteSecretChatBody =>
      'Its history is removed from this device. The other side keeps theirs.';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get displayNameLabel => 'Name';

  @override
  String get displayNameHint => 'How contacts see you';

  @override
  String get bioLabel => 'About';

  @override
  String get profileSaved => 'Profile saved';

  @override
  String get currentPassword => 'Current password';

  @override
  String get newPassword => 'New password';

  @override
  String get repeatPassword => 'Repeat the new password';

  @override
  String get passwordsDiffer => 'The passwords do not match';

  @override
  String get passwordWrong => 'The current password is wrong';

  @override
  String get passwordChanged =>
      'Password changed. Your other devices were signed out.';

  @override
  String get deleteAccount => 'Delete account';

  @override
  String get deleteAccountHint => 'For good: devices, keys and name';

  @override
  String get deleteAccountTitle => 'Delete your account?';

  @override
  String get deleteAccountBody =>
      'All your devices are signed out and their keys erased, you leave every group, and your username becomes free. Messages you sent stay with the people who received them. This cannot be undone.';

  @override
  String get deleteAccountConfirm => 'Delete for good';

  @override
  String get about => 'About';

  @override
  String appVersion(String version) {
    return 'Version $version';
  }

  @override
  String get licenses => 'Open-source licenses';

  @override
  String get deletedAccount => 'Deleted account';

  @override
  String get search => 'Search';

  @override
  String get searchHint => 'Chats and messages';

  @override
  String get searchMessages => 'Messages';

  @override
  String get searchNothing => 'Nothing found';

  @override
  String get notifications => 'Notifications';

  @override
  String get notificationsShow => 'Show notifications';

  @override
  String get notificationsPreview => 'Show message text';

  @override
  String get notificationsPreviewHint =>
      'Off: only \"New message\", without a name or words';

  @override
  String get notifyNewMessage => 'New message';

  @override
  String get notifyVoice => 'Voice message';

  @override
  String get trayOpen => 'Open Frogster';

  @override
  String get trayQuit => 'Quit';

  @override
  String get previewVoice => 'Voice message';

  @override
  String get saveFile => 'Save';

  @override
  String get attachGallery => 'Photo or video';

  @override
  String get attachCamera => 'Camera';

  @override
  String get attachFile => 'File';

  @override
  String get attachFileHint => 'Any file, sent as it is';

  @override
  String fileTooLargeNamed(String name) {
    return '$name is over 100 MB';
  }

  @override
  String get fileSaved => 'Saved';

  @override
  String get fileOpenedAsSave =>
      'Programs are saved, not opened: open it yourself if you trust the sender';

  @override
  String get presenceOnline => 'online';

  @override
  String presenceLastSeen(String when) {
    return 'last seen $when';
  }

  @override
  String get presenceRecently => 'last seen recently';

  @override
  String get presenceWeek => 'last seen within a week';

  @override
  String get presenceMonth => 'last seen within a month';

  @override
  String get presenceLongAgo => 'last seen a long time ago';

  @override
  String lastSeenToday(String time) {
    return 'at $time';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'yesterday at $time';
  }

  @override
  String lastSeenDate(String date, String time) {
    return '$date at $time';
  }

  @override
  String get hideHistoryTitle => 'Hide history from new members';

  @override
  String get hideHistoryHint =>
      'People added from now on see only what is said after they join';

  @override
  String get avatarChoose => 'Choose a photo';

  @override
  String get avatarRemove => 'Remove photo';

  @override
  String get avatarFailed => 'Could not use this picture';

  @override
  String get privacy => 'Privacy';

  @override
  String get lastSeenVisible => 'Show when I was online';

  @override
  String get lastSeenVisibleHint =>
      'Off: others see \"recently\", and you see the same of them';

  @override
  String get searchOnServer => 'Older messages from the server';

  @override
  String get actionSelect => 'Select';

  @override
  String selectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '$count selected',
    );
    return '$_temp0';
  }

  @override
  String deleteMessagesTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count messages?',
      one: 'Delete the message?',
    );
    return '$_temp0';
  }

  @override
  String get voicePlay => 'Play';

  @override
  String get voicePause => 'Pause';

  @override
  String get voiceRecord => 'Voice message: tap, or hold and let go to send';

  @override
  String get voiceDiscard => 'Discard';

  @override
  String get voiceSlideToCancel => '‹ slide to cancel';

  @override
  String get micPermission =>
      'Frogster may not use the microphone. Allow it in the system settings.';

  @override
  String get micFailed => 'The microphone did not start';

  @override
  String get sound => 'Sound';

  @override
  String get microphone => 'Microphone';

  @override
  String get microphoneDefault => 'System default';

  @override
  String get noiseSuppression => 'Noise suppression';

  @override
  String get noiseSuppressionHint =>
      'Removes fans, traffic and keyboards from your voice';

  @override
  String get autoGain => 'Level my voice';

  @override
  String get autoGainHint => 'Brings quiet speech up to a comfortable level';

  @override
  String get micTest => 'Test the microphone';

  @override
  String get micTestHint =>
      'Records three seconds and plays them back as others will hear you';

  @override
  String get micTestRecording => 'Speak now…';

  @override
  String get micTestPlaying => 'Playing back…';

  @override
  String get previewVoiceShort => 'Voice message';

  @override
  String get speaker => 'Speaker';

  @override
  String get speakerDefault => 'System default';

  @override
  String get voiceChannels => 'Voice channels';

  @override
  String voiceChannelsActive(int count) {
    return 'Voice channels · $count talking';
  }

  @override
  String get voiceJoin => 'Join';

  @override
  String get voiceYouAreHere => 'You are here';

  @override
  String get voiceLeave => 'Leave the channel';

  @override
  String get voiceMute => 'Turn the microphone off';

  @override
  String get voiceUnmute => 'Turn the microphone on';

  @override
  String get voiceDeafen => 'Turn the sound off';

  @override
  String get voiceUndeafen => 'Turn the sound on';

  @override
  String get voiceConnecting => 'Connecting…';

  @override
  String get voiceConnected => 'Connected';

  @override
  String get voiceRelayed => 'Connected through the server\'s HTTPS port';

  @override
  String voicePing(int ms) {
    return '$ms ms';
  }

  @override
  String get voiceFull => 'The channel is full';

  @override
  String get voiceGone => 'This channel no longer exists';

  @override
  String get voiceJoinFailed => 'Could not join the channel';

  @override
  String get voiceNewChannel => 'New voice channel';

  @override
  String get voiceRenameChannel => 'Rename';

  @override
  String get voiceDeleteChannel => 'Delete';

  @override
  String get voiceManageChannel => 'Channel options';

  @override
  String get voiceChannelNameHint => 'For example, General';

  @override
  String voiceInChat(int count) {
    return '$count in voice';
  }

  @override
  String get errorLogCopy => 'Copy the error log';

  @override
  String get errorLogHint =>
      'What went wrong in the app, without your messages: to send to the developer';

  @override
  String get errorLogCopied => 'Copied';

  @override
  String get errorLogEmpty => 'No errors recorded';
}
