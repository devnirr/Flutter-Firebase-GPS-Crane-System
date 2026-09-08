#!/usr/bin/env node
/**
 * Applies the native configuration Maps and background location require.
 *
 * Kept as a script rather than hand-edited files because `flutter create`
 * regenerates these on a fresh checkout, and because the client and driver
 * apps need *different* location permissions: the customer app only ever
 * locates you while you are looking at it, while the chofer app must keep
 * reporting with the screen off or it silently vanishes from dispatch.
 *
 * The Maps key is injected as a Gradle manifest placeholder and an Info.plist
 * build setting, so no key is ever committed. Every edit is guarded, so this
 * is safe to re-run.
 *
 *     node scripts/configure_platforms.mjs
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const APPS = [
  { dir: 'apps/client_app', background: false },
  { dir: 'apps/driver_app', background: true },
];

function patch(file, edit) {
  if (!existsSync(file)) {
    console.warn(`  ! missing ${file}`);
    return;
  }
  const before = readFileSync(file, 'utf8');
  const after = edit(before);
  if (after === before) return;
  writeFileSync(file, after);
  console.log(`  patched ${file}`);
}

/**
 * Inserts entries before the plist's closing tags.
 *
 * Flutter's generated plist carries CRLF on a Windows checkout, so this
 * matches either ending and keeps whichever the file already uses.
 */
function appendToPlist(plist, entries) {
  return plist.replace(
    /<\/dict>(\r?\n)<\/plist>/,
    (_, nl) => `${entries.join(nl)}${nl}</dict>${nl}</plist>`,
  );
}

for (const app of APPS) {
  console.log(app.dir);

  // ---- AndroidManifest: permissions and the Maps key ----------------------
  patch(`${app.dir}/android/app/src/main/AndroidManifest.xml`, (xml) => {
    if (xml.includes('ACCESS_FINE_LOCATION')) return xml;

    const permissions = [
      '    <uses-permission android:name="android.permission.INTERNET"/>',
      '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>',
      '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>',
      '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>',
      ...(app.background
        ? [
            '',
            '    <!-- The chofer app keeps reporting position with the screen off.',
            '         Without a foreground service Android stops delivering updates',
            '         within minutes, which means disappearing from dispatch',
            '         mid-shift. -->',
            '    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>',
            '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>',
            '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>',
            '    <uses-permission android:name="android.permission.WAKE_LOCK"/>',
            '    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>',
          ]
        : []),
    ].join('\n');

    const mapsMeta = [
      '        <meta-data',
      '            android:name="com.google.android.geo.API_KEY"',
      '            android:value="${MAPS_API_KEY}"/>',
    ].join('\n');

    return xml
      .replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
        `<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n${permissions}\n`,
      )
      .replace(/(<application[^>]*>)/, `$1\n${mapsMeta}`);
  });

  // ---- Gradle: fill the manifest placeholder from the environment ---------
  patch(`${app.dir}/android/app/build.gradle.kts`, (gradle) => {
    if (gradle.includes('MAPS_API_KEY')) return gradle;
    return gradle.replace(
      /(defaultConfig \{)/,
      `$1
        // Supplied by the build environment, never committed. An empty value
        // is fine: the app falls back to the drawn map.
        manifestPlaceholders["MAPS_API_KEY"] =
            System.getenv("MAPS_API_KEY") ?: ""
`,
    );
  });

  // ---- Info.plist: location usage strings --------------------------------
  patch(`${app.dir}/ios/Runner/Info.plist`, (plist) => {
    if (plist.includes('NSLocationWhenInUseUsageDescription')) return plist;

    const whenInUse = app.background
      ? 'Usamos tu ubicación para enviarte los servicios más cercanos y para que el cliente vea tu grúa en camino.'
      : 'Usamos tu ubicación para saber dónde enviarte la grúa.';

    return appendToPlist(plist, [
      '\t<key>NSLocationWhenInUseUsageDescription</key>',
      `\t<string>${whenInUse}</string>`,
      ...(app.background
        ? [
            '\t<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>',
            '\t<string>Necesitamos tu ubicación siempre para asignarte servicios y mostrar tu grúa al cliente, incluso con la app en segundo plano.</string>',
            '\t<key>UIBackgroundModes</key>',
            '\t<array>',
            '\t\t<string>location</string>',
            '\t\t<string>remote-notification</string>',
            '\t</array>',
          ]
        : []),
    ]);
  });

  // ---- Info.plist: the Maps key, from an xcconfig build setting ----------
  patch(`${app.dir}/ios/Runner/Info.plist`, (plist) => {
    if (plist.includes('MapsApiKey')) return plist;
    return appendToPlist(plist, [
      '\t<key>MapsApiKey</key>',
      '\t<string>$(MAPS_API_KEY)</string>',
    ]);
  });

  // ---- AppDelegate: hand the key to the Maps SDK -------------------------
  patch(`${app.dir}/ios/Runner/AppDelegate.swift`, (swift) => {
    if (swift.includes('GMSServices')) return swift;
    return swift
      .replace('import Flutter', 'import Flutter\nimport GoogleMaps')
      .replace(
        /(\) -> Bool \{)/,
        `$1
    // Read from the Info.plist build setting so no key is committed. Empty is
    // fine: the app falls back to the drawn map.
    if let key = Bundle.main.object(forInfoDictionaryKey: "MapsApiKey") as? String,
       !key.isEmpty {
      GMSServices.provideAPIKey(key)
    }
`,
      );
  });
}

console.log('\nSet MAPS_API_KEY in the build environment to enable real maps:');
console.log('  Android:  MAPS_API_KEY=... flutter build apk');
console.log('  iOS:      add MAPS_API_KEY to the Xcode build settings / xcconfig');
console.log('  Dart:     --dart-define=GOOGLE_MAPS_API_KEY=...');
