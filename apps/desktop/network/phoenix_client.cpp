#include <mokaid/network/phoenix_client.hpp>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QUrlQuery>
#include <algorithm>
namespace mokaid::desktop {
PhoenixClient::PhoenixClient(QObject* parent) : QObject(parent) {
    socket_.setMaxAllowedIncomingFrameSize(2 * 1024 * 1024);
    socket_.setMaxAllowedIncomingMessageSize(2 * 1024 * 1024);
    heartbeat_.setInterval(25000);
    reconnect_.setSingleShot(true);
    joinTimeout_.setSingleShot(true);
    connect(&joinTimeout_, &QTimer::timeout, this, [this] { socket_.abort(); });
    connect(&reconnect_, &QTimer::timeout, this, &PhoenixClient::open);
    connect(&heartbeat_, &QTimer::timeout, this, [this] {
        if (!pendingHeartbeat_.isEmpty()) { socket_.abort(); return; }
        pendingHeartbeat_ = send("phoenix", "heartbeat", {});
    });
    connect(&socket_, &QWebSocket::connected, this, [this] {
        joins_.clear(); joined_.clear(); pendingHeartbeat_.clear();
        for (const auto& topic : topics_) {
            const auto ref = QString::number(++ref_);
            joins_.insert(topic, ref);
            const auto frame = QJsonArray{ref, ref, topic, "phx_join", QJsonObject{}};
            socket_.sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact)));
        }
        heartbeat_.start(); joinTimeout_.start(10000);
    });
    connect(&socket_, &QWebSocket::disconnected, this, [this] {
        heartbeat_.stop(); joinTimeout_.stop(); pendingHeartbeat_.clear(); joins_.clear(); joined_.clear(); emit connectionChanged(false);
        if (running_) reconnect_.start(std::min(30000, 500 * (1 << std::min(attempts_++, 6))) + QRandomGenerator::global()->bounded(250));
    });
    connect(&socket_, &QWebSocket::textMessageReceived, this, &PhoenixClient::receive);
    connect(&socket_, &QWebSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        if (running_ && !reconnect_.isActive() && socket_.state() == QAbstractSocket::UnconnectedState)
            reconnect_.start(std::min(30000, 500 * (1 << std::min(attempts_++, 6))));
    });
}
void PhoenixClient::start(const QUrl& origin, const QByteArray& token, const QString& workspace, const QString& user) {
    stop();
    if (token.isEmpty() || user.isEmpty()) return;
    url_ = origin; url_.setScheme(origin.scheme() == "https" ? "wss" : "ws");
    url_.setPath("/socket/websocket"); url_.setQuery("vsn=2.0.0");
    token_ = token; topics_ = {"notifications:" + user};
    if (!workspace.isEmpty()) topics_.append("workspace:" + workspace);
    running_ = true; open();
}
void PhoenixClient::open() {
    if (!running_) return;
    QNetworkRequest request(url_);
    request.setRawHeader("X-Mokaid-Authorization", "Bearer " + token_);
    socket_.open(request);
}
void PhoenixClient::stop() {
    running_ = false; reconnect_.stop(); heartbeat_.stop(); joinTimeout_.stop(); joined_.clear();
    socket_.abort(); token_.fill('\0'); token_.clear(); joins_.clear(); pendingHeartbeat_.clear();
}
QString PhoenixClient::send(const QString& topic, const QString& event, const QJsonObject& payload, const QString& join) {
    const auto ref = QString::number(++ref_);
    QJsonArray frame{join.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(join), ref, topic, event, payload};
    socket_.sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact)));
    return ref;
}
void PhoenixClient::receive(const QString& message) {
    const auto a = QJsonDocument::fromJson(message.toUtf8()).array();
    if (a.size() != 5 || !a[2].isString() || !a[3].isString() || !a[4].isObject()) return;
    const auto topic = a[2].toString(), event = a[3].toString(), ref = a[1].toString();
    const auto payload = a[4].toObject();
    if (event == "phx_reply") {
        if (topic == "phoenix" && !pendingHeartbeat_.isEmpty() && ref == pendingHeartbeat_) {
            if (payload.value("status") == "ok") pendingHeartbeat_.clear();
            else socket_.abort();
        }
        if (joins_.contains(topic) && joins_.value(topic) == ref && a[0].toString() == ref) {
            if (payload.value("status") == "ok") {
                joined_.insert(topic);
                if (joined_.size() == topics_.size()) {
                    joinTimeout_.stop(); attempts_ = 0; emit connectionChanged(true); emit rejoined();
                }
            }
            else { stop(); emit authenticationExpired(); }
        }
        return;
    }
    if (event == "disconnect" && topic == "phoenix") { stop(); emit authenticationExpired(); return; }
    if (!topics_.contains(topic)) return;
    const auto incomingJoin = a[0].toString();
    if (!incomingJoin.isEmpty() && incomingJoin != joins_.value(topic)) return;
    if (event == "phx_error" || event == "phx_close") { socket_.abort(); return; }
    if (!joined_.contains(topic)) return;
    emit eventReceived(topic, event, payload);
}
}
