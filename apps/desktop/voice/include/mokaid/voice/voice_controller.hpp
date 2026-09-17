#pragma once
#include <QObject>
#include <mokaid/voice/audio_utils.hpp>
#include <QByteArray>
#include <QFutureWatcher>
#include <QProcess>
#include <QTimer>
#include <memory>
class QAudioSource;
class QAudioOutput;
class QMediaPlayer;
class QTextToSpeech;
class QTemporaryDir;
namespace mokaid::desktop {
class VoiceController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString transcript READ transcript NOTIFY changed)
    Q_PROPERTY(QString language READ language NOTIFY changed)
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(double progress READ progress NOTIFY changed)
    Q_PROPERTY(double level READ level NOTIFY changed)
    Q_PROPERTY(QString modelDescription READ modelDescription CONSTANT)
public:
    explicit VoiceController(QObject* parent = nullptr, QString runtimeDirectory = {});
    ~VoiceController() override;
    QString state() const { return state_; }
    QString error() const { return error_; }
    QString transcript() const { return transcript_; }
    QString language() const { return language_; }
    bool ready() const { return ready_; }
    double progress() const { return progress_; }
    double level() const { return level_; }
    QString modelDescription() const { return QStringLiteral("Whisper base · Kokoro 82M · audio local"); }
    Q_INVOKABLE void setup();
    Q_INVOKABLE void startListening();
    Q_INVOKABLE void stopListening();
    Q_INVOKABLE void speak(const QString& text, const QString& language = {});
    Q_INVOKABLE void cancel();
signals:
    void changed();
    void transcribed(const QString& text, const QString& language);
private:
    friend class VoiceControllerTestAccess;
    void beginCapture();
    void beginTranscription(const voice::AudioConversion& audio);
    void launch(const QString& executable, const QStringList& arguments);
    void processFinished(int exitCode, QProcess::ExitStatus status);
    void fail(const QString& message);
    void finish();
    QString path(const QString& relative) const;
    QString state_{QStringLiteral("unavailable")};
    QString error_, transcript_, language_, runtime_;
    bool ready_{false};
    bool cancelling_{false};
    bool permissionPending_{false};
    double progress_{0}, level_{0};
    quint64 generation_{0};
    QFutureWatcher<QString> verification_;
    QFutureWatcher<voice::AudioConversion> conversion_;
    quint64 conversionGeneration_{0};
    QProcess process_;
    QTimer limit_, watchdog_;
    QAudioSource* source_{};
    QAudioFormat format_;
    QByteArray pcm_;
    QAudioOutput* output_{};
    QMediaPlayer* player_{};
    QTextToSpeech* speech_{};
    std::unique_ptr<QTemporaryDir> temporary_;
};
}
