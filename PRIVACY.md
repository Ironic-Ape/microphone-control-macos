# Privacy

Microphone Control requires microphone permission because macOS sends supported headphone mute gestures to an application that owns an active input session.

The app:

- discards every microphone audio buffer immediately;
- does not record or save audio;
- does not analyze speech or sound;
- does not connect to a network;
- does not include analytics, advertising, crash reporting, or tracking;
- stores no microphone content or user identity.

The app creates one process-lock file in the current user's cache directory. The empty file contains no user data and only prevents duplicate app processes.

macOS shows a microphone privacy indicator while the input session is active. Automatic startup is controlled by macOS Login Items and can be disabled from the app's menu.
