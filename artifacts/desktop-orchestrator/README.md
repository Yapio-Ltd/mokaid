# Moked native interface evidence

All PNGs here are native Qt Quick renders from `orchestrator_qml_tests.cpp`.
Their workspace, agent names, messages and mission records are synthetic test
data, explicitly labeled in each capture; they are not live customer activity.

The matrix covers 1440×900 and 1000×680: collapsed companion, empty and populated
conversation, missions, dictation/transcription/speech, offline, sign-out, voice
setup, notification and hovered primary action. Current fixture tests have nine
passing QtTest entries and no QML engine warnings. A Qt font alias diagnostic
belongs to the synthetic workspace's Basic.Button.

Regenerate with `MOKAID_ORCHESTRATOR_CAPTURE_DIR` pointing at this directory when
running `mokaid_orchestrator_qml_tests`. These captures do not establish live
backend operation, physical microphone quality, or universal TTS coverage.
