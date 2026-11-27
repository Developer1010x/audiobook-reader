import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'playback_remote.dart';

/// Publishes the reader on D-Bus as an MPRIS player, so the keyboard's media
/// keys, headset buttons and the desktop's sound menu control read-aloud.
///
/// Linux only: GNOME, KDE and most other desktops route media keys to MPRIS.
/// Everything is forwarded to [PlaybackRemote]; nothing here knows about a
/// screen.
class MprisServer {
  MprisServer._();

  /// Bus name suffix. [MediaPlayerService] filters it out so the app never
  /// lists, or pauses, itself as "other" music.
  static const busSuffix = 'audier';

  static DBusClient? _client;

  /// Register on the session bus. Quiet on failure: no session bus (a bare
  /// window manager, a container) only costs the media keys.
  static Future<void> start() async {
    if (!Platform.isLinux || _client != null) return;
    final client = DBusClient.session();
    try {
      // A second running copy gets its own name rather than failing.
      final name = 'org.mpris.MediaPlayer2.$busSuffix';
      final reply = await client.requestName(name,
          flags: {DBusRequestNameFlag.doNotQueue});
      if (reply != DBusRequestNameReply.primaryOwner) {
        await client.requestName('$name.instance$pid',
            flags: {DBusRequestNameFlag.doNotQueue});
      }
      final object = MprisObject(PlaybackRemote.instance);
      await client.registerObject(object);
      PlaybackRemote.instance.addListener(object.onRemoteChanged);
      _client = client;
    } catch (e) {
      debugPrint('MPRIS unavailable: $e');
      await client.close();
    }
  }
}

/// The `/org/mpris/MediaPlayer2` object: the root and Player interfaces.
@visibleForTesting
class MprisObject extends DBusObject {
  MprisObject(this.remote) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final PlaybackRemote remote;

  static const _root = 'org.mpris.MediaPlayer2';
  static const _player = 'org.mpris.MediaPlayer2.Player';

  bool? _lastPlaying;
  String? _lastTitle;

  Map<String, DBusValue> get _rootProperties => {
        'CanQuit': const DBusBoolean(false),
        'CanRaise': const DBusBoolean(false),
        'HasTrackList': const DBusBoolean(false),
        'Identity': const DBusString('Audier'),
        'DesktopEntry': const DBusString('audier'),
        'SupportedUriSchemes': DBusArray.string(const []),
        'SupportedMimeTypes': DBusArray.string(const []),
      };

  Map<String, DBusValue> get playerProperties {
    final has = remote.hasTarget;
    return {
      'PlaybackStatus':
          DBusString(remote.isPlaying ? 'Playing' : has ? 'Paused' : 'Stopped'),
      'Metadata': DBusDict.stringVariant({
        'mpris:trackid':
            DBusObjectPath('/org/mpris/MediaPlayer2/Track/${has ? 1 : 0}'),
        if (remote.title != null) 'xesam:title': DBusString(remote.title!),
      }),
      'Rate': const DBusDouble(1),
      'MinimumRate': const DBusDouble(1),
      'MaximumRate': const DBusDouble(1),
      'Volume': const DBusDouble(1),
      'Position': const DBusInt64(0),
      'CanGoNext': DBusBoolean(has),
      'CanGoPrevious': DBusBoolean(has),
      'CanPlay': DBusBoolean(has),
      'CanPause': DBusBoolean(has),
      'CanSeek': const DBusBoolean(false),
      'CanControl': const DBusBoolean(true),
    };
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == _root) {
      // Raise and Quit are advertised as unsupported, so both are no-ops.
      if (methodCall.name == 'Raise' || methodCall.name == 'Quit') {
        return DBusMethodSuccessResponse();
      }
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (methodCall.interface != _player) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'PlayPause':
        await remote.togglePlay();
      case 'Play':
        if (!remote.isPlaying) await remote.togglePlay();
      case 'Pause':
      case 'Stop':
        if (remote.isPlaying) await remote.stop();
      case 'Next':
        await remote.skip(1);
      case 'Previous':
        await remote.skip(-1);
      case 'Seek':
      case 'SetPosition':
      case 'OpenUri':
        break; // CanSeek is false; nothing to open
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final props = interface == _root
        ? _rootProperties
        : interface == _player
            ? playerProperties
            : null;
    final value = props?[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> setProperty(
          String interface, String name, DBusValue value) async =>
      DBusMethodErrorResponse.propertyReadOnly();

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == _root) return DBusGetAllPropertiesResponse(_rootProperties);
    if (interface == _player) {
      return DBusGetAllPropertiesResponse(playerProperties);
    }
    return DBusGetAllPropertiesResponse({});
  }

  /// Tell the desktop when the state it shows changes; ticks within one
  /// state are not worth a signal.
  void onRemoteChanged() {
    if (client == null) return;
    if (_lastPlaying == remote.isPlaying && _lastTitle == remote.title) return;
    _lastPlaying = remote.isPlaying;
    _lastTitle = remote.title;
    final props = playerProperties;
    unawaited(emitPropertiesChanged(_player, changedProperties: {
      for (final key in ['PlaybackStatus', 'Metadata', 'CanPlay', 'CanPause',
          'CanGoNext', 'CanGoPrevious'])
        key: props[key]!,
    }));
  }
}
