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
}
