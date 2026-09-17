#pragma once
#include <QByteArray>
#include <QVariantMap>

namespace mokaid::desktop {
// One format decision shared by inline cards and the full deliverable viewer.
QVariantMap describeDeliverable(const QVariantMap& file);
QVariantMap normalizeDeliverable(QVariantMap file);
QByteArray readableDocument(const QVariantMap& format, const QByteArray& bytes);
QByteArray imageThumbnail(const QByteArray& bytes);
}
