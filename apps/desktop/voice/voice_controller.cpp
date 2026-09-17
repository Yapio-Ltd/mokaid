#include <mokaid/voice/voice_controller.hpp>
#include <mokaid/voice/audio_utils.hpp>
#include <QAudioDevice>
#include <QAudioOutput>
#include <QAudioSource>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QPermissions>
#include <QTemporaryDir>
#include <QTextToSpeech>
#include <QtConcurrent/QtConcurrentRun>
#include <algorithm>
#include <cmath>
namespace mokaid::desktop {
namespace {
QString runtimePath() {
#ifdef Q_OS_MACOS
    const auto bundled = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("../Resources/voice"));
#else
    const auto bundled = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("voice"));
#endif
    if (QFileInfo::exists(QDir(bundled).filePath(QStringLiteral("manifest.json")))) return QDir::cleanPath(bundled);
    return QStringLiteral(MOKAID_VOICE_DEV_RUNTIME);
}
QString executableSuffix() {
#ifdef Q_OS_WIN
    return QStringLiteral(".exe");
#else
    return {};
#endif
}
}
VoiceController::VoiceController(QObject* parent, QString runtimeDirectory) : QObject(parent),
    language_(QLocale::system().name().section('_', 0, 0)), runtime_(runtimeDirectory.isEmpty() ? runtimePath() : std::move(runtimeDirectory)) {
    output_ = new QAudioOutput(this);
    player_ = new QMediaPlayer(this);
    player_->setAudioOutput(output_);
    limit_.setSingleShot(true); limit_.setInterval(90000);
    watchdog_.setSingleShot(true); watchdog_.setInterval(120000);
    connect(&limit_, &QTimer::timeout, this, &VoiceController::stopListening);
    connect(&watchdog_, &QTimer::timeout, this, [this] { fail(QStringLiteral("Le moteur vocal a dépassé le délai. Réessayez avec une phrase plus courte.")); });
    connect(&process_, &QProcess::finished, this, &VoiceController::processFinished);
    connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (!cancelling_) fail(QStringLiteral("Le moteur vocal local n’a pas pu démarrer."));
    });
    // CLI output can contain private transcript text. Never log or retain it.
    connect(&process_, &QProcess::readyReadStandardOutput, this, [this] { process_.readAllStandardOutput(); });
    connect(&process_, &QProcess::readyReadStandardError, this, [this] { process_.readAllStandardError(); });
    connect(player_, &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        if (!cancelling_ && state_ == QStringLiteral("speaking") && status == QMediaPlayer::EndOfMedia) finish();
    });
    connect(player_, &QMediaPlayer::errorOccurred, this, [this](QMediaPlayer::Error, const QString&) {
        if (!cancelling_) fail(QStringLiteral("La sortie audio est indisponible. La réponse reste visible dans la conversation."));
    });
    connect(&verification_, &QFutureWatcher<QString>::finished, this, [this] {
        error_ = verification_.result(); ready_ = error_.isEmpty();
        progress_ = ready_ ? 1 : 0;
        // Setup verifies only public shipped assets: cancelling private audio
        // must not discard its result or leave dictation permanently disabled.
        if (state_ == QStringLiteral("preparing") || state_ == QStringLiteral("unavailable") || state_ == QStringLiteral("error"))
            state_ = ready_ ? QStringLiteral("ready") : QStringLiteral("error");
        emit changed();
    });
    connect(&conversion_, &QFutureWatcher<voice::AudioConversion>::finished, this, [this] {
        auto future = conversion_.future();
        if (future.resultCount() == 0) return;
        auto result = future.takeResult();
        if (generation_ == conversionGeneration_ && state_ == QStringLiteral("transcribing")) beginTranscription(result);
        result.wav.fill(0);
    });
    QTimer::singleShot(0, this, &VoiceController::setup);
}
VoiceController::~VoiceController() { cancel(); verification_.waitForFinished(); conversion_.waitForFinished(); }
QString VoiceController::path(const QString& relative) const { return QDir(runtime_).filePath(relative); }
void VoiceController::setup() {
    if (verification_.isRunning() || ready_) return;
    cancel(); state_ = QStringLiteral("preparing"); error_.clear(); progress_ = 0; emit changed();
    // Model verification is local and runs outside the UI thread. It never opens
    // the microphone or fetches executable code during application use.
    verification_.setFuture(QtConcurrent::run([directory = runtime_] { return voice::validateRuntime(directory); }));
}
void VoiceController::startListening() {
    if (!ready_) { if (!verification_.isRunning()) setup(); return; }
    if (permissionPending_ || conversion_.isRunning()) return;
    cancel(); error_.clear(); transcript_.clear();
    const QMicrophonePermission permission;
    const auto status = qApp->checkPermission(permission);
    if (status == Qt::PermissionStatus::Denied) {
        fail(QStringLiteral("Autorisez le microphone pour Moked dans les réglages de confidentialité du système.")); return;
    }
    if (status == Qt::PermissionStatus::Undetermined) {
        permissionPending_ = true;
        const auto generation = generation_;
        qApp->requestPermission(permission, this, [this, generation](const QPermission& result) {
            permissionPending_ = false;
            if (generation != generation_) return;
            if (result.status() == Qt::PermissionStatus::Granted) beginCapture();
            else fail(QStringLiteral("L’accès au microphone est nécessaire pour dicter un message."));
        });
        return;
    }
    beginCapture();
}
void VoiceController::beginCapture() {
    const auto device = QMediaDevices::defaultAudioInput();
    if (device.isNull()) { fail(QStringLiteral("Aucun microphone n’est disponible.")); return; }
    format_.setSampleRate(16000); format_.setChannelCount(1); format_.setSampleFormat(QAudioFormat::Int16);
    if (!device.isFormatSupported(format_)) format_ = device.preferredFormat();
    if (!format_.isValid() || format_.sampleRate() > 96000 || format_.channelCount() > 2) {
        fail(QStringLiteral("Le format de ce microphone n’est pas pris en charge.")); return;
    }
    source_ = new QAudioSource(device, format_, this);
    source_->setBufferSize(format_.bytesForDuration(100000));
    pcm_.clear(); state_ = QStringLiteral("listening"); level_ = 0; emit changed();
    connect(source_, &QAudioSource::stateChanged, this, [this](QAudio::State) {
        if (source_ && state_ == QStringLiteral("listening") && source_->error() != QAudio::NoError)
            fail(QStringLiteral("Le microphone a été déconnecté ou n’est plus disponible."));
    });
    auto* input = source_->start();
    if (!input) { fail(QStringLiteral("Impossible d’ouvrir le microphone.")); return; }
    connect(input, &QIODevice::readyRead, this, [this, input] {
        if (state_ != QStringLiteral("listening")) return;
        const auto data = input->readAll();
        const auto maximum = std::min<qsizetype>(32 * 1024 * 1024, format_.bytesForDuration(90000000));
        pcm_.append(data.left(std::max<qsizetype>(0, maximum - pcm_.size())));
        // Meter a sparse selection of samples, without storing any second copy.
        float maximumLevel = 0;
        for (qsizetype i = 0; i + format_.bytesPerSample() <= data.size(); i += format_.bytesPerSample() * 16)
            maximumLevel = std::max(maximumLevel, std::abs(format_.normalizedSampleValue(data.constData() + i)));
        level_ = std::min(1.0, double(maximumLevel) * 3); emit changed();
        if (pcm_.size() >= maximum) stopListening();
    });
    limit_.start();
}
void VoiceController::stopListening() {
    if (state_ != QStringLiteral("listening")) return;
    limit_.stop(); state_ = QStringLiteral("transcribing"); level_ = 0; emit changed();
    if (source_) { source_->stop(); source_->deleteLater(); source_ = nullptr; }
    conversionGeneration_ = generation_;
    conversion_.setFuture(QtConcurrent::run([pcm = std::move(pcm_), format = format_]() mutable {
        const auto result = voice::whisperWav(pcm, format);
        pcm.fill(0);
        return result;
    }));
}
void VoiceController::beginTranscription(const voice::AudioConversion& converted) {
    if (!converted.error.isEmpty()) { fail(converted.error); return; }
    if (converted.rms < 0.002) { fail(QStringLiteral("Le microphone est silencieux. Rapprochez-vous et réessayez.")); return; }
    temporary_ = std::make_unique<QTemporaryDir>(QDir::tempPath() + QStringLiteral("/moked-voice-XXXXXX"));
    if (!temporary_->isValid()) { fail(QStringLiteral("Impossible de préparer la transcription locale.")); return; }
    QFile audio(temporary_->filePath(QStringLiteral("input.wav")));
    if (!audio.open(QIODevice::WriteOnly) || audio.write(converted.wav) != converted.wav.size()) { audio.close(); fail(QStringLiteral("Impossible de préparer la transcription locale.")); return; }
    audio.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner); audio.close();
    const auto output = temporary_->filePath(QStringLiteral("transcript"));
    launch(QStringLiteral("bin/whisper-cli") + executableSuffix(), {
        QStringLiteral("-m"), path(QStringLiteral("models/ggml-base-q5_1.bin")),
        QStringLiteral("-f"), audio.fileName(), QStringLiteral("-l"), QStringLiteral("auto"),
        QStringLiteral("-t"), QStringLiteral("4"), QStringLiteral("-oj"), QStringLiteral("-of"), output,
        QStringLiteral("-np"), QStringLiteral("-nt")});
}
void VoiceController::speak(const QString& text, const QString& language) {
    const auto spoken = text.trimmed();
    if (spoken.isEmpty()) return;
    if (spoken.size() > 6000) { fail(QStringLiteral("Cette réponse est trop longue pour être lue en une fois.")); return; }
    cancel(); error_.clear();
    if (!language.isEmpty()) language_ = language.toLower().replace('_', '-').section('-', 0, 0);
    const auto voice = voice::kokoroVoice(language_);
    if (ready_ && voice.speaker >= 0) {
        temporary_ = std::make_unique<QTemporaryDir>(QDir::tempPath() + QStringLiteral("/moked-voice-XXXXXX"));
        if (!temporary_->isValid()) { fail(QStringLiteral("Impossible de préparer la voix locale.")); return; }
        state_ = QStringLiteral("synthesizing"); emit changed();
        const auto models = QStringLiteral("models/kokoro/");
        QStringList arguments{
            QStringLiteral("--kokoro-model=") + path(models + QStringLiteral("model.int8.onnx")),
            QStringLiteral("--kokoro-voices=") + path(models + QStringLiteral("voices.bin")),
            QStringLiteral("--kokoro-tokens=") + path(models + QStringLiteral("tokens.txt")),
            QStringLiteral("--kokoro-data-dir=") + path(models + QStringLiteral("espeak-ng-data")),
            QStringLiteral("--kokoro-lang=") + voice.language,
            QStringLiteral("--num-threads=2"), QStringLiteral("--debug=0"), QStringLiteral("--sid=") + QString::number(voice.speaker),
            QStringLiteral("--output-filename=") + temporary_->filePath(QStringLiteral("speech.wav"))};
        if (language_ == QStringLiteral("zh")) arguments.append(QStringLiteral("--kokoro-lexicon=") + path(models + QStringLiteral("lexicon-us-en.txt")) + ',' + path(models + QStringLiteral("lexicon-zh.txt")));
        // A leading space makes even text beginning with '--' a positional
        // argument. QProcess never invokes a shell or expands message content.
        arguments.append(QStringLiteral(" ") + spoken);
        launch(QStringLiteral("sherpa/bin/sherpa-onnx-offline-tts") + executableSuffix(), arguments);
        return;
    }
    if (!speech_) {
        speech_ = new QTextToSpeech(this);
        connect(speech_, &QTextToSpeech::stateChanged, this, [this](QTextToSpeech::State status) {
            if (cancelling_ || state_ != QStringLiteral("speaking")) return;
            if (status == QTextToSpeech::Ready) finish();
            else if (status == QTextToSpeech::Error) fail(QStringLiteral("La voix système est indisponible pour cette langue."));
        });
    }
    const auto locales = speech_->availableLocales();
    const auto selected = std::find_if(locales.begin(), locales.end(), [this](const QLocale& locale) { return locale.name().section('_', 0, 0) == language_; });
    if (selected == locales.end()) { fail(QStringLiteral("Aucune voix locale n’est installée pour cette langue. La réponse est disponible à l’écrit.")); return; }
    speech_->setLocale(*selected);
    state_ = QStringLiteral("speaking"); emit changed(); speech_->say(spoken);
}
void VoiceController::launch(const QString& executable, const QStringList& arguments) {
    process_.setWorkingDirectory(runtime_);
    process_.setProgram(path(executable)); process_.setArguments(arguments);
    process_.start(); watchdog_.start();
}
void VoiceController::processFinished(int exitCode, QProcess::ExitStatus status) {
    watchdog_.stop();
    process_.setArguments({});
    if (cancelling_) return;
    if (exitCode != 0 || status != QProcess::NormalExit) { fail(QStringLiteral("Le traitement vocal local a échoué. Réessayez avec une phrase plus courte.")); return; }
    if (!temporary_) return;
    if (state_ == QStringLiteral("transcribing")) {
        QFile result(temporary_->filePath(QStringLiteral("transcript.json")));
        if (!result.open(QIODevice::ReadOnly) || result.size() > 1024 * 1024) { result.close(); fail(QStringLiteral("Le moteur local n’a pas produit de transcription.")); return; }
        const auto transcript = voice::parseTranscript(result.readAll()); result.close();
        if (!transcript.error.isEmpty()) { fail(transcript.error); return; }
        transcript_ = transcript.text; language_ = transcript.language;
        finish(); emit transcribed(transcript_, language_);
    } else if (state_ == QStringLiteral("synthesizing")) {
        const auto file = temporary_->filePath(QStringLiteral("speech.wav"));
        if (QFileInfo(file).size() <= 44 || QFileInfo(file).size() > 64 * 1024 * 1024) { fail(QStringLiteral("Le moteur local n’a pas produit de voix.")); return; }
        player_->setSource(QUrl::fromLocalFile(file)); state_ = QStringLiteral("speaking"); emit changed(); player_->play();
    }
}
void VoiceController::finish() {
    cancelling_ = true;
    player_->stop(); player_->setSource({}); temporary_.reset();
    cancelling_ = false;
    state_ = ready_ ? QStringLiteral("ready") : QStringLiteral("unavailable"); level_ = 0; emit changed();
}
void VoiceController::fail(const QString& message) {
    cancel(); error_ = message; state_ = QStringLiteral("error"); emit changed();
}
void VoiceController::cancel() {
    ++generation_; cancelling_ = true; limit_.stop(); watchdog_.stop();
    if (source_) { source_->stop(); source_->deleteLater(); source_ = nullptr; }
    if (process_.state() != QProcess::NotRunning) { process_.kill(); process_.waitForFinished(1500); }
    process_.setArguments({});
    if (speech_) speech_->stop();
    player_->stop(); player_->setSource({});
    pcm_.fill(0); pcm_.clear(); temporary_.reset();
    cancelling_ = false; level_ = 0;
    transcript_.clear();
    state_ = ready_ ? QStringLiteral("ready") : QStringLiteral("unavailable"); emit changed();
}
}
