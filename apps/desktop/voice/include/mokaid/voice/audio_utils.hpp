#pragma once
#include <QAudioFormat>
#include <QByteArray>
#include <QString>
#include <QJsonObject>
namespace mokaid::desktop::voice {
struct AudioConversion { QByteArray wav; double rms{}; double seconds{}; QString error; };
AudioConversion whisperWav(const QByteArray& pcm, const QAudioFormat& format);
struct Transcript { QString text; QString language; QString error; };
Transcript parseTranscript(const QByteArray& json);
struct KokoroVoice { int speaker; QString language; };
KokoroVoice kokoroVoice(const QString& language);
QString validateRuntime(const QString& directory);
}
