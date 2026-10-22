import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Frogster'**
  String get appTitle;

  /// No description provided for @loginTagline.
  ///
  /// In en, this message translates to:
  /// **'Private messenger with secret chats'**
  String get loginTagline;

  /// No description provided for @serverLabel.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get serverLabel;

  /// No description provided for @serverHint.
  ///
  /// In en, this message translates to:
  /// **'chat.example.com or 203.0.113.5'**
  String get serverHint;

  /// No description provided for @serverRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address'**
  String get serverRequired;

  /// No description provided for @fingerprintLabel.
  ///
  /// In en, this message translates to:
  /// **'Certificate fingerprint'**
  String get fingerprintLabel;

  /// No description provided for @fingerprintHelper.
  ///
  /// In en, this message translates to:
  /// **'Printed by the installer, or run \"frogster fingerprint\" on the server'**
  String get fingerprintHelper;

  /// No description provided for @fingerprintTooShort.
  ///
  /// In en, this message translates to:
  /// **'Enter all 8 groups'**
  String get fingerprintTooShort;

  /// No description provided for @haveFingerprint.
  ///
  /// In en, this message translates to:
  /// **'I have a certificate fingerprint'**
  String get haveFingerprint;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get usernameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @usernameTooShort.
  ///
  /// In en, this message translates to:
  /// **'At least 3 characters'**
  String get usernameTooShort;

  /// No description provided for @usernameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Latin letters, digits and underscore only'**
  String get usernameInvalid;

  /// No description provided for @passwordTooShort.
  ///
  /// In en, this message translates to:
  /// **'At least 10 characters'**
  String get passwordTooShort;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get createAccount;

  /// No description provided for @haveAccount.
  ///
  /// In en, this message translates to:
  /// **'I already have an account'**
  String get haveAccount;

  /// No description provided for @newAccount.
  ///
  /// In en, this message translates to:
  /// **'Create a new account'**
  String get newAccount;

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @errorTooManyAttempts.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Try again in a few minutes.'**
  String get errorTooManyAttempts;

  /// No description provided for @errorUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server'**
  String get errorUnreachable;

  /// No description provided for @errorTimeout.
  ///
  /// In en, this message translates to:
  /// **'The server did not answer in time'**
  String get errorTimeout;

  /// No description provided for @errorBadAddress.
  ///
  /// In en, this message translates to:
  /// **'This does not look like a server address'**
  String get errorBadAddress;

  /// No description provided for @errorIncompleteLink.
  ///
  /// In en, this message translates to:
  /// **'This connection link is incomplete'**
  String get errorIncompleteLink;

  /// No description provided for @errorUntrustedCertificate.
  ///
  /// In en, this message translates to:
  /// **'The server uses its own certificate. Enter the fingerprint shown by the installer (or \"frogster fingerprint\" on the server).'**
  String get errorUntrustedCertificate;

  /// No description provided for @errorFingerprintMismatch.
  ///
  /// In en, this message translates to:
  /// **'The certificate fingerprint does not match. Check it with \"frogster fingerprint\" on the server. If it is right, someone may be intercepting the connection.'**
  String get errorFingerprintMismatch;

  /// No description provided for @errorNoCa.
  ///
  /// In en, this message translates to:
  /// **'This server does not publish its own certificate. If it has a domain name, connect without a fingerprint.'**
  String get errorNoCa;

  /// No description provided for @errorFingerprintChars.
  ///
  /// In en, this message translates to:
  /// **'The fingerprint may only contain 0–9 and A–F'**
  String get errorFingerprintChars;

  /// No description provided for @errorServerStatus.
  ///
  /// In en, this message translates to:
  /// **'The server answered with an error ({code})'**
  String errorServerStatus(int code);

  /// No description provided for @errorSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed: {error}'**
  String errorSignIn(String error);

  /// No description provided for @sessionEnded.
  ///
  /// In en, this message translates to:
  /// **'Your session has ended. Sign in again.'**
  String get sessionEnded;

  /// No description provided for @connectionSecure.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get connectionSecure;

  /// No description provided for @connectionConnecting.
  ///
  /// In en, this message translates to:
  /// **'connecting…'**
  String get connectionConnecting;

  /// No description provided for @connectionOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get connectionOffline;

  /// No description provided for @emptyChatsTitle.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get emptyChatsTitle;

  /// No description provided for @emptyChatsBody.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation with the + button'**
  String get emptyChatsBody;

  /// No description provided for @navChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navNewChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get navNewChat;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @selectConversation.
  ///
  /// In en, this message translates to:
  /// **'Pick a conversation'**
  String get selectConversation;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @newChatTitle.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get newChatTitle;

  /// No description provided for @newChatUsername.
  ///
  /// In en, this message translates to:
  /// **'Their username'**
  String get newChatUsername;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @start.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get start;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @safetyNumberTooltip.
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get safetyNumberTooltip;

  /// No description provided for @messagePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messagePlaceholder;

  /// No description provided for @verifyToSend.
  ///
  /// In en, this message translates to:
  /// **'Verify the contact to send'**
  String get verifyToSend;

  /// No description provided for @attach.
  ///
  /// In en, this message translates to:
  /// **'Attach a photo'**
  String get attach;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @removeAttachment.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeAttachment;

  /// No description provided for @noMessages.
  ///
  /// In en, this message translates to:
  /// **'No messages yet — say hi'**
  String get noMessages;

  /// No description provided for @couldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load messages'**
  String get couldNotLoad;

  /// No description provided for @couldNotReadFile.
  ///
  /// In en, this message translates to:
  /// **'Could not read the file: {error}'**
  String couldNotReadFile(String error);

  /// No description provided for @identityChangedBlocking.
  ///
  /// In en, this message translates to:
  /// **'This contact\'s safety number has changed. They may have reinstalled the app — or someone may be intercepting your messages. Verify before sending.'**
  String get identityChangedBlocking;

  /// No description provided for @identityChangedInfo.
  ///
  /// In en, this message translates to:
  /// **'This contact\'s safety number has changed, usually because they switched to a new device. Your messages are still encrypted. Verify the number if you want to be certain.'**
  String get identityChangedInfo;

  /// No description provided for @iVerifiedIt.
  ///
  /// In en, this message translates to:
  /// **'I verified it'**
  String get iVerifiedIt;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @statusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get statusSending;

  /// No description provided for @statusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get statusSent;

  /// No description provided for @statusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get statusDelivered;

  /// No description provided for @statusRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get statusRead;

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Not sent'**
  String get statusFailed;

  /// No description provided for @attachmentPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get attachmentPhoto;

  /// No description provided for @attachmentVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get attachmentVideo;

  /// No description provided for @attachmentAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get attachmentAudio;

  /// No description provided for @attachmentPdf.
  ///
  /// In en, this message translates to:
  /// **'PDF document'**
  String get attachmentPdf;

  /// No description provided for @attachmentFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get attachmentFile;

  /// No description provided for @attachmentTapToOpen.
  ///
  /// In en, this message translates to:
  /// **'Tap to open · {size}'**
  String attachmentTapToOpen(String size);

  /// No description provided for @attachmentDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get attachmentDownloadFailed;

  /// No description provided for @attachmentCannotDisplay.
  ///
  /// In en, this message translates to:
  /// **'Could not display'**
  String get attachmentCannotDisplay;

  /// No description provided for @filesTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Files must be under 100 MB'**
  String get filesTooLarge;

  /// No description provided for @savedTo.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String savedTo(String path);

  /// No description provided for @couldNotOpenFile.
  ///
  /// In en, this message translates to:
  /// **'Could not open the file: {error}'**
  String couldNotOpenFile(String error);

  /// No description provided for @couldNotComputeSafety.
  ///
  /// In en, this message translates to:
  /// **'Could not compute the safety number: {error}'**
  String couldNotComputeSafety(String error);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in on {server}'**
  String signedInAs(String server);

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @security.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get security;

  /// No description provided for @changePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get changePassword;

  /// No description provided for @changePasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Signs out every other device'**
  String get changePasswordHint;

  /// No description provided for @activeSessions.
  ///
  /// In en, this message translates to:
  /// **'Active sessions'**
  String get activeSessions;

  /// No description provided for @noOtherSessions.
  ///
  /// In en, this message translates to:
  /// **'No other sessions'**
  String get noOtherSessions;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @signOutHint.
  ///
  /// In en, this message translates to:
  /// **'Keeps your keys so you can sign back in'**
  String get signOutHint;

  /// No description provided for @signOutDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out this device?'**
  String get signOutDeviceTitle;

  /// No description provided for @signOutDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'\"{device}\" will be signed out immediately and retired: your contacts stop encrypting new messages to it. Use this for a phone you no longer have.'**
  String signOutDeviceBody(String device);

  /// No description provided for @signOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get signOutTitle;

  /// No description provided for @signOutBody.
  ///
  /// In en, this message translates to:
  /// **'Your messages and encryption keys stay on this device, so you can sign back in and carry on where you left off.\n\nErasing everything also removes this device\'s identity. Your contacts will see it as a new device, and existing conversations cannot be continued.'**
  String get signOutBody;

  /// No description provided for @eraseEverything.
  ///
  /// In en, this message translates to:
  /// **'Erase everything'**
  String get eraseEverything;

  /// No description provided for @unknownDevice.
  ///
  /// In en, this message translates to:
  /// **'Unknown device'**
  String get unknownDevice;

  /// No description provided for @thisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// No description provided for @lastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used {date}'**
  String lastUsed(String date);

  /// No description provided for @safetyNumberTitle.
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get safetyNumberTitle;

  /// No description provided for @verifyWith.
  ///
  /// In en, this message translates to:
  /// **'Verify with {name}'**
  String verifyWith(String name);

  /// No description provided for @safetyExplain.
  ///
  /// In en, this message translates to:
  /// **'Compare these numbers in person or over a call you trust. If they match, nobody in between can read your conversation.'**
  String get safetyExplain;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Safety number copied'**
  String get copied;

  /// No description provided for @markVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified'**
  String get markVerified;

  /// No description provided for @safetyChangeNote.
  ///
  /// In en, this message translates to:
  /// **'If this number changes later, your contact may have reinstalled the app — or someone may be intercepting the conversation. Frogster will tell you when it happens.'**
  String get safetyChangeNote;

  /// No description provided for @chatEncrypted.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted'**
  String get chatEncrypted;

  /// No description provided for @chatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @connectionOfflineHint.
  ///
  /// In en, this message translates to:
  /// **'Messages will be sent when the connection is back'**
  String get connectionOfflineHint;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @filterDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get filterDirect;

  /// No description provided for @filterGroups.
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get filterGroups;

  /// No description provided for @filterEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get filterEmpty;

  /// No description provided for @filterSecret.
  ///
  /// In en, this message translates to:
  /// **'Secret'**
  String get filterSecret;

  /// No description provided for @modeCloud.
  ///
  /// In en, this message translates to:
  /// **'Regular'**
  String get modeCloud;

  /// No description provided for @modeSecret.
  ///
  /// In en, this message translates to:
  /// **'Secret'**
  String get modeSecret;

  /// No description provided for @modeCloudExplain.
  ///
  /// In en, this message translates to:
  /// **'Stored on the server in encrypted form and synced to all your devices.'**
  String get modeCloudExplain;

  /// No description provided for @modeSecretExplain.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted: only the participants’ devices can read it. History stays on the devices it was written on.'**
  String get modeSecretExplain;

  /// No description provided for @secretChatSubtitle.
  ///
  /// In en, this message translates to:
  /// **'secret chat'**
  String get secretChatSubtitle;

  /// No description provided for @secretGroupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'secret group · {count, plural, =1{1 member} other{{count} members}}'**
  String secretGroupSubtitle(int count);

  /// No description provided for @membersCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String membersCount(int count);

  /// No description provided for @newChatSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get newChatSearchHint;

  /// No description provided for @searchTooShort.
  ///
  /// In en, this message translates to:
  /// **'Type at least two letters of a username'**
  String get searchTooShort;

  /// No description provided for @searchNobody.
  ///
  /// In en, this message translates to:
  /// **'Nobody by that name'**
  String get searchNobody;

  /// No description provided for @searchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed: {error}'**
  String searchFailed(String error);

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @newGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroupTitle;

  /// No description provided for @groupNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameLabel;

  /// No description provided for @groupMembersLabel.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupMembersLabel;

  /// No description provided for @groupAddPeople.
  ///
  /// In en, this message translates to:
  /// **'Find people to add'**
  String get groupAddPeople;

  /// No description provided for @groupNeedsMembers.
  ///
  /// In en, this message translates to:
  /// **'Add at least one member'**
  String get groupNeedsMembers;

  /// No description provided for @groupNeedsName.
  ///
  /// In en, this message translates to:
  /// **'Give the group a name'**
  String get groupNeedsName;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @groupInfo.
  ///
  /// In en, this message translates to:
  /// **'Group info'**
  String get groupInfo;

  /// No description provided for @addMembers.
  ///
  /// In en, this message translates to:
  /// **'Add members'**
  String get addMembers;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @removeFromGroup.
  ///
  /// In en, this message translates to:
  /// **'Remove from group'**
  String get removeFromGroup;

  /// No description provided for @leaveGroup.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get leaveGroup;

  /// No description provided for @leaveGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave the group?'**
  String get leaveGroupTitle;

  /// No description provided for @leaveGroupBody.
  ///
  /// In en, this message translates to:
  /// **'You will stop receiving its messages. To come back, an admin has to add you again.'**
  String get leaveGroupBody;

  /// No description provided for @leave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @roleAdmin.
  ///
  /// In en, this message translates to:
  /// **'admin'**
  String get roleAdmin;

  /// No description provided for @youSuffix.
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String youSuffix(String name);

  /// No description provided for @actionCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get actionCopy;

  /// No description provided for @actionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get actionEdit;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get actionDelete;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get actionRetry;

  /// No description provided for @textCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get textCopied;

  /// No description provided for @editingMessage.
  ///
  /// In en, this message translates to:
  /// **'Editing'**
  String get editingMessage;

  /// No description provided for @editedMark.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get editedMark;

  /// No description provided for @deleteMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone?'**
  String get deleteMessageTitle;

  /// No description provided for @deleteMessageBody.
  ///
  /// In en, this message translates to:
  /// **'The message disappears from this chat on every device.'**
  String get deleteMessageBody;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @previewPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get previewPhoto;

  /// No description provided for @previewFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get previewFile;

  /// No description provided for @failedTapToRetry.
  ///
  /// In en, this message translates to:
  /// **'Not sent — tap to try again'**
  String get failedTapToRetry;

  /// No description provided for @actionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not do that: {error}'**
  String actionFailed(String error);

  /// No description provided for @secretGroupNameNote.
  ///
  /// In en, this message translates to:
  /// **'The name is sent end to end: the server never sees it.'**
  String get secretGroupNameNote;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
