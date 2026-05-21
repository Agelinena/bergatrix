package xyz.bergaestudio.bergastream

import com.ryanheise.audioservice.AudioServiceActivity

/// Must extend AudioServiceActivity (not the default FlutterActivity)
/// so the just_audio_background plugin can attach its FlutterEngine
/// to the foreground media service.  Symptom of using FlutterActivity:
///   PlatformException(The Activity class declared in your
///   AndroidManifest.xml is wrong or has not provided the correct
///   FlutterEngine ...)
///   thrown from JustAudioBackground.init at app startup.
class MainActivity : AudioServiceActivity()
