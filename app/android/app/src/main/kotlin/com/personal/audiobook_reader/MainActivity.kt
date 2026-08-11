package com.personal.audiobook_reader

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity, not FlutterActivity, so the UI and the
// background service share one FlutterEngine.
//
// The media session outlives this Activity: the service keeps running when the
// task is swiped away or the screen locks, and a lock-screen or headset command
// arriving then must reach the same isolate that holds the speech queue and the
// rendered-ahead files. AudioServiceActivity overrides provideFlutterEngine to
// hand back the plugin's cached engine; a plain FlutterActivity would spin up a
// second engine, whose handler is not the one the service is talking to, and the
// controls would appear to work while doing nothing.
//
// The manifest keeps pointing at .MainActivity rather than the plugin's
// AudioServiceActivity, so this stays the place any platform channel lands.
class MainActivity : AudioServiceActivity()
