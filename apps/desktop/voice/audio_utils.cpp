#include <mokaid/voice/audio_utils.hpp>
#include <QCryptographicHash>
#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QtEndian>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>
namespace mokaid::desktop::voice {
AudioConversion whisperWav(const QByteArray& pcm, const QAudioFormat& format) {
    AudioConversion result;
    if (!format.isValid() || format.sampleRate() < 8000 || format.channelCount() > 8 || format.bytesPerSample() <= 0) {
        result.error = QStringLiteral("Format audio non pris en charge."); return result;
    }
    const auto frameSize = format.bytesPerFrame();
    const auto frames = pcm.size() / frameSize;
    result.seconds = double(frames) / format.sampleRate();
    if (result.seconds < 0.35 || result.seconds > 91) {
        result.error = QStringLiteral("Parlez entre une demi-seconde et 90 secondes."); return result;
    }
    std::vector<float> mono(static_cast<size_t>(frames));
    double energy = 0;
    for (qsizetype frame = 0; frame < frames; ++frame) {
        float value = 0;
        for (int channel = 0; channel < format.channelCount(); ++channel) {
            const char* data = pcm.constData() + frame * frameSize + channel * format.bytesPerSample();
            switch (format.sampleFormat()) {
                case QAudioFormat::UInt8: value += (static_cast<unsigned char>(*data) - 128) / 128.f; break;
                case QAudioFormat::Int16: { qint16 x; std::memcpy(&x, data, sizeof x); value += x / 32768.f; break; }
                case QAudioFormat::Int32: { qint32 x; std::memcpy(&x, data, sizeof x); value += float(x / 2147483648.0); break; }
                case QAudioFormat::Float: { float x; std::memcpy(&x, data, sizeof x); value += std::isfinite(x) ? x : 0.f; break; }
                default: result.error = QStringLiteral("Format audio inconnu."); return result;
            }
        }
        value = std::clamp(value / format.channelCount(), -1.f, 1.f);
        mono[static_cast<size_t>(frame)] = value; energy += value * value;
    }
    result.rms = std::sqrt(energy / frames);
    const auto outputFrames = static_cast<quint32>(frames * 16000 / format.sampleRate());
    QDataStream stream(&result.wav, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4); stream << quint32(36 + outputFrames * 2);
    stream.writeRawData("WAVEfmt ", 8); stream << quint32(16) << quint16(1) << quint16(1) << quint32(16000) << quint32(32000) << quint16(2) << quint16(16);
    stream.writeRawData("data", 4); stream << quint32(outputFrames * 2);
    // Average each input interval before downsampling; avoids simply dropping
    // high-rate samples and preserves speech energy on 44.1/48 kHz microphones.
    for (quint32 sample = 0; sample < outputFrames; ++sample) {
        const double begin = double(sample) * format.sampleRate() / 16000;
        const double end = double(sample + 1) * format.sampleRate() / 16000;
        double value = 0;
        for (auto index = static_cast<qsizetype>(begin); index < std::ceil(end) && index < frames; ++index) {
            const double weight = std::max(0.0, std::min(end, double(index + 1)) - std::max(begin, double(index)));
            value += mono[static_cast<size_t>(index)] * weight;
        }
        stream << static_cast<qint16>(std::clamp(value / (end - begin), -1.0, 1.0) * 32767);
    }
    return result;
}
Transcript parseTranscript(const QByteArray& json) {
    Transcript output;
    QJsonParseError error;
    const auto doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) { output.error = QStringLiteral("La transcription locale est invalide."); return output; }
    const auto root = doc.object();
    output.language = root.value(QStringLiteral("result")).toObject().value(QStringLiteral("language")).toString();
    if (!QRegularExpression(QStringLiteral("^[a-z]{2,3}$")).match(output.language).hasMatch() || !root.value(QStringLiteral("transcription")).isArray()) {
        output.error = QStringLiteral("La langue de transcription est introuvable."); return output;
    }
    for (const auto segment : root.value(QStringLiteral("transcription")).toArray()) output.text += segment.toObject().value(QStringLiteral("text")).toString();
    output.text = output.text.trimmed();
    if (output.text.size() > 24000) output.error = QStringLiteral("La transcription dépasse la taille autorisée.");
    if (output.text.isEmpty()) output.error = QStringLiteral("Je n’ai pas entendu de parole. Réessayez près du microphone.");
    return output;
}
KokoroVoice kokoroVoice(const QString& language) {
    const auto code = language.toLower().replace('_', '-').section('-', 0, 0);
    if (code == QStringLiteral("en")) return {3, QStringLiteral("en-us")};
    if (code == QStringLiteral("fr")) return {30, QStringLiteral("fr")};
    if (code == QStringLiteral("es")) return {28, QStringLiteral("es")};
    if (code == QStringLiteral("it")) return {35, QStringLiteral("it")};
    if (code == QStringLiteral("pt")) return {42, QStringLiteral("pt-br")};
    if (code == QStringLiteral("hi")) return {31, QStringLiteral("hi")};
    if (code == QStringLiteral("zh")) return {45, QStringLiteral("cmn")};
    return {-1, {}};
}
QString validateRuntime(const QString& directory) {
    QFile manifest(QDir(directory).filePath(QStringLiteral("manifest.json")));
    if (!manifest.open(QIODevice::ReadOnly) || manifest.size() > 2 * 1024 * 1024) return QStringLiteral("Le module vocal local n’est pas installé dans cette version de Moked.");
    const auto root = QJsonDocument::fromJson(manifest.readAll()).object();
    const auto entries = root.value(QStringLiteral("files")).toObject();
    if (root.value(QStringLiteral("schema")).toInt() != 1 || entries.isEmpty()) return QStringLiteral("Le manifeste vocal est invalide.");
    if (!entries.contains(QStringLiteral("models/ggml-base-q5_1.bin")) || !entries.contains(QStringLiteral("models/kokoro/model.int8.onnx"))) return QStringLiteral("Les modèles vocaux sont incomplets.");
    // Qt canonical paths use '/' on every platform, including Windows. Keep
    // the boundary in that same representation so valid files remain inside it.
    const QString base = QFileInfo(directory).canonicalFilePath() + QLatin1Char('/');
    for (auto it = entries.begin(); it != entries.end(); ++it) {
        const auto filename = QDir(directory).filePath(it.key());
        const auto canonical = QFileInfo(filename).canonicalFilePath();
        if (!canonical.startsWith(base) || it.value().toString().size() != 64) return QStringLiteral("Le manifeste vocal contient un chemin invalide.");
        QFile file(filename);
        if (!file.open(QIODevice::ReadOnly)) return QStringLiteral("Un fichier vocal est manquant. Réinstallez Moked.");
        QCryptographicHash hash(QCryptographicHash::Sha256);
        if (!hash.addData(&file) || hash.result().toHex() != it.value().toString().toLatin1()) return QStringLiteral("Un modèle vocal est endommagé. Réinstallez Moked.");
    }
#ifdef Q_OS_WIN
    const QString suffix = QStringLiteral(".exe");
#else
    const QString suffix;
#endif
    for (const auto& relative : {QStringLiteral("bin/whisper-cli") + suffix, QStringLiteral("sherpa/bin/sherpa-onnx-offline-tts") + suffix}) {
        if (!QFileInfo(QDir(directory).filePath(relative)).isExecutable()) return QStringLiteral("Un moteur vocal est absent du package.");
    }
    return {};
}
}
