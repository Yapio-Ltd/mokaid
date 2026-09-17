#pragma once
#include <mokaid/application/session_controller.hpp>
#include <mokaid/features/feature_catalog.hpp>
#include <mokaid/features/record_list_model.hpp>
#include <mokaid/features/detail_browser.hpp>
#include <mokaid/features/drive_download.hpp>
#include <mokaid/storage/cache_store.hpp>
#include <QHash>
#include <QTimer>

namespace mokaid::desktop {
class FeatureController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pages READ pages NOTIFY changed)
    Q_PROPERTY(QString currentPage READ currentPage NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)
    Q_PROPERTY(QAbstractListModel* records READ records CONSTANT)
    Q_PROPERTY(QVariantList visibleRecords READ visibleRecords NOTIFY changed)
    Q_PROPERTY(QVariantList allRecords READ allRecords NOTIFY changed)
    Q_PROPERTY(QVariantMap overview READ overview NOTIFY changed)
    Q_PROPERTY(QVariantMap selectedRecord READ selectedRecord NOTIFY changed)
    Q_PROPERTY(bool showingRecordDetails READ showingRecordDetails NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(bool offline READ offline NOTIFY changed)
    Q_PROPERTY(QVariantList fields READ fields NOTIFY changed)
    Q_PROPERTY(QVariantList actions READ actions NOTIFY changed)
    Q_PROPERTY(QVariantMap details READ details NOTIFY changed)
    Q_PROPERTY(QObject* detailView READ detailView CONSTANT)
    Q_PROPERTY(QString selectedId READ selectedId NOTIFY changed)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY changed)
    Q_PROPERTY(QVariantList driveBreadcrumbs READ driveBreadcrumbs NOTIFY changed)
    Q_PROPERTY(QString driveFolderId READ driveFolderId NOTIFY changed)
    Q_PROPERTY(bool driveTrash READ driveTrash NOTIFY changed)
    Q_PROPERTY(bool driveCanGoBack READ driveCanGoBack NOTIFY changed)
    Q_PROPERTY(bool driveCanDownload READ driveCanDownload NOTIFY changed)
    Q_PROPERTY(QObject* driveDownload READ driveDownload CONSTANT)
public:
    FeatureController(ApiClient& api, SessionController& session, CacheStore& cache, QObject* parent = nullptr);
    QVariantList pages() const;
    QString currentPage() const { return currentPage_; }
    QString title() const;
    QAbstractListModel* records() { return &records_; }
    QVariantList visibleRecords() const;
    QVariantList allRecords() const;
    QVariantMap overview() const;
    QVariantMap selectedRecord() const;
    bool showingRecordDetails() const { return detailHeading_ == "Record details"; }
    bool busy() const { return busy_; }
    QString error() const { return error_; }
    bool offline() const { return offline_; }
    QVariantList fields() const;
    QVariantList actions() const;
    QVariantMap details() const { return details_; }
    QObject* detailView() { return &detailView_; }
    QString selectedId() const { return selectedId_; }
    bool hasMore() const { return nextPage_ > 0; }
    QVariantList driveBreadcrumbs() const { return driveBreadcrumbs_; }
    QString driveFolderId() const { return driveBreadcrumbs_.last().toMap().value("id").toString(); }
    bool driveTrash() const { return driveTrash_; }
    bool driveCanGoBack() const { return driveTrash_ || driveBreadcrumbs_.size() > 1; }
    bool driveCanDownload() const;
    QObject* driveDownload() { return &driveDownload_; }
    Q_INVOKABLE void openDriveFolder(const QString& id);
    Q_INVOKABLE void navigateDriveBreadcrumb(int index);
    Q_INVOKABLE void driveBack();
    Q_INVOKABLE void setDriveTrash(bool trash);
    Q_INVOKABLE void requestDriveDownload();
    Q_INVOKABLE void navigate(const QString& page);
    Q_INVOKABLE void openRecord(const QString& page, const QString& id);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void select(const QString& id);
    Q_INVOKABLE void submit(const QString& action, const QVariantMap& values);
    Q_INVOKABLE void search(const QString& query);
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void showOverview();
    Q_INVOKABLE void showRecordDetails();
    Q_INVOKABLE void loadMore();
    Q_INVOKABLE QVariantList fieldsForAction(const QString& action) const;
    Q_INVOKABLE QString actionContext(const QString& action) const;
signals:
    void changed();
    void openDelivery(QVariantMap delivery);
    void requestExternal(QUrl url);
    void actionSucceeded(QString context);
private:
    void sessionChanged();
    void clear();
    void load(int page, bool append);
    void acceptList(const QJsonObject& response, bool append);
    void readCached(const QString& path, quint64 epoch, quint64 generation, bool append);
    QString resolvePath(QString path, const QString& id, const QVariantMap& values = {}) const;
    QString cacheKey(const QString& path) const;
    void fail(QString message);
    bool permitted(const FeatureDescriptor& feature, bool mutation) const;
    const FeatureAction* findAction(const QString& id) const;
    bool driveActionAllowed(const QString& action, const QString& id) const;
    QString driveListPath() const;
    void changeDriveLocation(QVariantList breadcrumbs, bool trash);
    void invalidateDriveCache(const QString& id, const QString& oldParent, const QString& newParent);
    ApiClient& api_;
    SessionController& session_;
    CacheStore& cache_;
    RecordListModel records_;
    DetailBrowser detailView_;
    DriveDownload driveDownload_;
    QTimer searchTimer_;
    QString currentPage_{"office"}, selectedId_, error_, search_, contextTag_;
    QString pendingSelection_, detailHeading_, detailCollection_;
    // Secondary reports may replace displayed details, but never edit defaults.
    QVariantMap details_, editDetails_, overview_;
    QVariantList driveBreadcrumbs_{{QVariantMap{{"id",QString{}},{"name","Drive"}}}};
    bool driveTrash_{};
    QHash<QByteArray, QString> retryKeys_;
    quint64 epoch_{}, detailEpoch_{}, sessionGeneration_{}, viewGeneration_{};
    int nextPage_{};
    bool busy_{}, offline_{}, loadingMore_{};
};
}
