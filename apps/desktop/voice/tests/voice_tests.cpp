#include <mokaid/voice/audio_utils.hpp>
#include <mokaid/voice/voice_controller.hpp>
#include <QCryptographicHash>
#include <QDataStream>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QJsonDocument>
#include <QSignalSpy>
#include <QPromise>
#include <QTemporaryDir>
#include <QtTest>
#include <cmath>
using namespace mokaid::desktop;
namespace mokaid::desktop {
class VoiceControllerTestAccess {
public:
    static void controlledSetup(VoiceController& controller, const QFuture<QString>& future) {
        controller.state_ = QStringLiteral("preparing");
        controller.verification_.setFuture(future);
    }
    static void convertSilentCapture(VoiceController& controller) {
        controller.state_ = QStringLiteral("listening");
        controller.format_.setSampleRate(16000);
        controller.format_.setChannelCount(1);
        controller.format_.setSampleFormat(QAudioFormat::Int16);
        controller.pcm_ = QByteArray(32000, 0);
        controller.stopListening();
    }
};
}

class VoiceTests final : public QObject {
    Q_OBJECT
private slots:
    void convertsStereo48kToMono16k() {
        QAudioFormat format; format.setSampleRate(48000); format.setChannelCount(2); format.setSampleFormat(QAudioFormat::Int16);
        QByteArray samples; QDataStream data(&samples, QIODevice::WriteOnly); data.setByteOrder(QDataStream::LittleEndian);
        for (int i = 0; i < 48000; ++i) { const auto value = qint16(std::sin(i * 2 * 3.14159265 * 440 / 48000) * 12000); data << value << value; }
        const auto converted = voice::whisperWav(samples, format);
        QVERIFY2(converted.error.isEmpty(), qPrintable(converted.error));
        QCOMPARE(converted.wav.size(), 32044); QCOMPARE(converted.wav.first(4), QByteArray("RIFF"));
        QCOMPARE(converted.wav.mid(8, 4), QByteArray("WAVE"));
        QVERIFY(converted.rms > 0.25 && converted.rms < 0.27); QCOMPARE(converted.seconds, 1.0);
    }
    void rejectsShortAndInvalidAudio() {
        QAudioFormat format; QVERIFY(!voice::whisperWav({}, format).error.isEmpty());
        format.setSampleRate(16000); format.setChannelCount(1); format.setSampleFormat(QAudioFormat::Int16);
        QVERIFY(!voice::whisperWav(QByteArray(100, 0), format).error.isEmpty());
        const auto silent = voice::whisperWav(QByteArray(32000, 0), format);
        QVERIFY(silent.error.isEmpty()); QCOMPARE(silent.rms, 0.0);
    }
    void preservesDetectedLanguageAndUnicode() {
        const auto parsed = voice::parseTranscript(R"({"result":{"language":"fr"},"transcription":[{"text":" Bonjour"},{"text":" à l’équipe."}]})");
        QVERIFY(parsed.error.isEmpty()); QCOMPARE(parsed.language, QStringLiteral("fr")); QCOMPARE(parsed.text, QStringLiteral("Bonjour à l’équipe."));
        const auto hebrew = voice::parseTranscript(QStringLiteral("{\"result\":{\"language\":\"he\"},\"transcription\":[{\"text\":\"שלום\"}]}").toUtf8());
        QCOMPARE(hebrew.text, QStringLiteral("שלום"));
    }
    void rejectsInvalidAndEmptyTranscripts() {
        QVERIFY(!voice::parseTranscript("bad").error.isEmpty());
        QVERIFY(!voice::parseTranscript(R"({"result":{"language":"auto"},"transcription":[]})").error.isEmpty());
        QVERIFY(!voice::parseTranscript(R"({"result":{"language":"../../fr"},"transcription":[{"text":"x"}]})").error.isEmpty());
    }
    void picksLanguageSpecificVoices() {
        QCOMPARE(voice::kokoroVoice(QStringLiteral("fr-FR")).speaker, 30);
        QCOMPARE(voice::kokoroVoice(QStringLiteral("fr-FR")).language, QStringLiteral("fr"));
        QCOMPARE(voice::kokoroVoice(QStringLiteral("en_US")).speaker, 3);
        QCOMPARE(voice::kokoroVoice(QStringLiteral("he")).speaker, -1);
    }
    void acceptsVerifiedRuntimeUsingNativePathSeparators() {
        QTemporaryDir dir; QVERIFY(dir.isValid());
#ifdef Q_OS_WIN
        const QString suffix = QStringLiteral(".exe");
#else
        const QString suffix;
#endif
        const QStringList files = {
            QStringLiteral("models/ggml-base-q5_1.bin"),
            QStringLiteral("models/kokoro/model.int8.onnx"),
            QStringLiteral("bin/whisper-cli") + suffix,
            QStringLiteral("sherpa/bin/sherpa-onnx-offline-tts") + suffix,
        };
        QJsonObject entries;
        for (const auto& name : files) {
            const auto path = dir.filePath(name);
            QVERIFY(QDir().mkpath(QFileInfo(path).path()));
            QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly));
            QCOMPARE(file.write("verified-runtime-fixture"), qint64(24));
            file.close();
            QVERIFY(file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
            entries.insert(name, QString::fromLatin1(QCryptographicHash::hash("verified-runtime-fixture", QCryptographicHash::Sha256).toHex()));
        }
        QFile manifest(dir.filePath(QStringLiteral("manifest.json")));
        QVERIFY(manifest.open(QIODevice::WriteOnly));
        manifest.write(QJsonDocument(QJsonObject{{"schema", 1}, {"files", entries}}).toJson());
        manifest.close();
        const auto error = voice::validateRuntime(QDir::toNativeSeparators(dir.path()));
        QVERIFY2(error.isEmpty(), qPrintable(error));
    }
    void rejectsMissingTamperedAndEscapingModels() {
        QTemporaryDir dir; QVERIFY(dir.isValid());
        QVERIFY(!voice::validateRuntime(dir.path()).isEmpty());
        QDir(dir.path()).mkpath(QStringLiteral("models/kokoro"));
        QJsonObject entries;
        for (const auto& name : {QStringLiteral("models/ggml-base-q5_1.bin"), QStringLiteral("models/kokoro/model.int8.onnx")}) {
            QFile model(dir.filePath(name)); QVERIFY(model.open(QIODevice::WriteOnly)); model.write("test-model"); model.close();
            entries.insert(name, QString::fromLatin1(QCryptographicHash::hash("test-model", QCryptographicHash::Sha256).toHex()));
        }
        auto writeManifest = [&] { QFile file(dir.filePath(QStringLiteral("manifest.json"))); QVERIFY(file.open(QIODevice::WriteOnly)); file.write(QJsonDocument(QJsonObject{{"schema", 1}, {"files", entries}}).toJson()); };
        writeManifest();
        QVERIFY(voice::validateRuntime(dir.path()).contains(QStringLiteral("moteur")));
        // An existing sibling sharing the runtime's name must still be outside
        // the canonical directory boundary, even when its checksum is valid.
        QTemporaryDir sibling(dir.path() + QStringLiteral("-sibling-XXXXXX"));
        QVERIFY(sibling.isValid());
        QFile escaped(sibling.filePath(QStringLiteral("model.bin")));
        QVERIFY(escaped.open(QIODevice::WriteOnly)); escaped.write("test-model"); escaped.close();
        const auto escapePath = QStringLiteral("../") + QFileInfo(sibling.path()).fileName() + QStringLiteral("/model.bin");
        entries.insert(escapePath, QString::fromLatin1(QCryptographicHash::hash("test-model", QCryptographicHash::Sha256).toHex()));
        writeManifest();
        QVERIFY(voice::validateRuntime(dir.path()).contains(QStringLiteral("chemin")));
        entries.remove(escapePath); writeManifest();
        QFile broken(dir.filePath(QStringLiteral("models/ggml-base-q5_1.bin"))); QVERIFY(broken.open(QIODevice::WriteOnly)); broken.write("changed"); broken.close();
        QVERIFY(voice::validateRuntime(dir.path()).contains(QStringLiteral("endommagé")));
        entries.insert(QStringLiteral("../escape"), QString(64, '0')); writeManifest();
        QVERIFY(voice::validateRuntime(dir.path()).contains(QStringLiteral("chemin")));
    }
    void cancelledSetupStillCompletes() {
        QTemporaryDir directory;
        VoiceController voice(nullptr, directory.path());
        QTRY_COMPARE(voice.state(), QStringLiteral("error"));
        QPromise<QString> verification;
        verification.start();
        VoiceControllerTestAccess::controlledSetup(voice, verification.future());
        QCOMPARE(voice.state(), QStringLiteral("preparing"));
        voice.cancel();
        verification.addResult(QString());
        verification.finish();
        QTRY_VERIFY(voice.ready());
        QCOMPARE(voice.state(), QStringLiteral("ready"));
    }
    void conversionResultIsConsumedOnlyOnce() {
        QTemporaryDir directory;
        VoiceController voice(nullptr, directory.path());
        QTRY_COMPARE(voice.state(), QStringLiteral("error"));
        VoiceControllerTestAccess::convertSilentCapture(voice);
        QTRY_COMPARE(voice.state(), QStringLiteral("error"));
        QVERIFY(voice.error().contains(QStringLiteral("silencieux")));
        // An empty replacement future used to emit another finished signal and
        // dereference a nonexistent result on the next event-loop turn.
        QTest::qWait(30);
        QVERIFY(voice.error().contains(QStringLiteral("silencieux")));
        VoiceControllerTestAccess::convertSilentCapture(voice);
        QTRY_COMPARE(voice.state(), QStringLiteral("error"));
        QVERIFY(voice.error().contains(QStringLiteral("silencieux")));
    }
    void failedSetupIsVisibleWithoutOpeningMicrophone() {
        QTemporaryDir directory;
        VoiceController voice(nullptr, directory.path());
        QSignalSpy changes(&voice, &VoiceController::changed);
        QTRY_COMPARE(voice.state(), QStringLiteral("error"));
        QVERIFY(!voice.ready()); QVERIFY(!voice.error().isEmpty()); QVERIFY(!changes.isEmpty());
        voice.cancel(); QCOMPARE(voice.state(), QStringLiteral("unavailable"));
        QCOMPARE(voice.level(), 0.0); QVERIFY(voice.transcript().isEmpty());
    }
};
QTEST_GUILESS_MAIN(VoiceTests)
#include "voice_tests.moc"
