#include <mokaid/features/feature_catalog.hpp>
#include <mokaid/features/detail_browser.hpp>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <algorithm>

namespace mokaid::desktop {
namespace {
QVariantMap field(const char* key, const char* label, const char* type = "text", bool required = false, const QStringList& options = {}) {
    QVariantList choices; for (const auto& option : options) choices.append(option);
    return {{"key",key},{"label",label},{"type",type},{"required",required},{"options",choices}};
}
FeatureAction action(const char* id, const char* title, const char* method, const char* path,
                     bool selected = false, bool destructive = false, QVariantList fields = {}, QVariantMap defaults = {}) {
    return {id,title,method,path,selected,destructive,std::move(fields),std::move(defaults)};
}
FeatureDescriptor page(const char* id, const char* title, const char* icon, const char* path,
                       const char* detail = "", QList<FeatureAction> actions = {},
                       const char* collection = "", bool admin = false, bool hidden = false, bool paginated = false) {
    return {id,title,admin ? "Administration" : "Workspace",icon,path,detail,collection,
        admin ? core::Scope::administration : core::Scope::workspace,std::move(actions),hidden,paginated};
}
QVariantList agentFields(bool creation) {
    QVariantList result{field("display_name","Name","text",true),field("role_title","Role"),
        field("department","Department"),field("instructions","Instructions","multiline"),
        field("autonomy_mode","Autonomy","enum",false,{"supervised","balanced","autonomous"}),
        field("model_quality","Model","enum",false,{"fast","smart"}),field("avatar_asset_id","Avatar asset ID")};
    if (creation) {
        result.append(field("kind","Kind","enum",true,{"ai","human_linked","hybrid"}));
        result.append(field("archetype_key","Agent specialization key","text",true));
        result.append(field("boost_key","Training boost key"));
        result.append(field("knowledge_brief","Initial knowledge","multiline"));
        result.append(field("linked_user_id","Linked user ID"));
        result.append(field("linked_member_id","Linked member ID"));
    } else {
        result.append(field("status","Status","enum",false,{"active","busy","idle","waiting","blocked","away","offline","archived","training"}));
        result.append(field("human_takeover_enabled","Allow human takeover","bool"));
    }
    return result;
}
QList<FeatureAction> agentActions() {
    return {action("create","Create agent","POST","/api/agents",false,false,agentFields(true),{{"kind","ai"}}),
        action("edit","Edit agent","PATCH","/api/agents/{id}",true,false,agentFields(false)),
        action("delete","Remove agent","DELETE","/api/agents/{id}",true,true),
        action("training","Training progress","GET","/api/agents/{id}/training",true),
        action("progression","Skills and progression","GET","/api/agents/{id}/progression",true),
        action("permissions","Permission rules","GET","/api/agents/{id}/permission-rules",true),
        action("schedules","Schedules","GET","/api/agents/{id}/schedules",true),
        action("upload","Add knowledge files","UPLOAD","/api/agents/{id}/files",true,false,{field("files","Files","files",true)}),
        action("transfer","Copy agent to another workspace (charges destination credits)","POST","/api/agents/{id}/transfer",true,true,
            {field("target_workspace_id","Destination workspace ID","text",true)}),
        action("assign-task","Assign a task","POST","/api/agents/{id}/assign-task",true,false,{field("task_id","Task ID","text",true)})};
}
QList<FeatureAction> adminUserActions() {
    return {
        action("edit","Edit user","PATCH","/api/admin/users/{id}",true,true,
            {field("full_name","Full name"),field("locale","Language","enum",false,{"en","fr","he"}),field("timezone","Timezone"),
             field("status","Status","enum",false,{"active","suspended","disabled"}),field("is_platform_admin","Platform administrator","bool"),field("operator_notes","Operator notes","multiline")}),
        action("ban","Suspend user","POST","/api/admin/users/{id}/ban",true,true,{field("reason","Reason","multiline",true),field("ban_expires_at","Ban expires at","datetime")}),
        action("unban","Restore user access","POST","/api/admin/users/{id}/unban",true,true),
        action("schedule-deletion","Schedule account deletion","POST","/api/admin/users/{id}/schedule-deletion",true,true,
            {field("reason","Reason","multiline",true),field("days","Grace period in days","int",true)}),
        action("cancel-deletion","Cancel scheduled deletion","POST","/api/admin/users/{id}/cancel-deletion",true,true),
        action("reset-password","Reset password","POST","/api/admin/users/{id}/reset-password",true,true,{field("password","New password (10+ characters)","password",true)}),
        action("summary","Activity and billing summary","GET","/api/admin/users/{id}/summary",true)};
}
QList<FeatureAction> adminWorkspaceActions() {
    return {action("edit","Edit workspace","PATCH","/api/admin/workspaces/{id}",true,true,
            {field("name","Name"),field("description","Description","multiline"),field("industry","Industry"),field("timezone","Timezone"),
             field("language","Language","enum",false,{"en","fr","he"}),field("default_landing_page","Default page"),
             field("usage_limits","Usage limits","json"),field("settings","Settings","json"),field("feature_toggles","Feature toggles","json")}),
        action("delete","Suspend workspace","DELETE","/api/admin/workspaces/{id}",true,true),
        action("restore","Restore workspace","POST","/api/admin/workspaces/{id}/restore",true,true)};
}
QString first(const QVariantMap& record, std::initializer_list<const char*> keys) {
    for (const auto* key : keys) { const auto value = record.value(key).toString(); if (!value.isEmpty()) return value; }
    return {};
}
}

const QList<FeatureDescriptor>& featureCatalog() {
    static const auto catalog = [] {
        const QVariantList taskFields{field("title","Title","text",true),field("description","Description","multiline"),
            field("priority","Priority","enum",false,{"low","medium","high","urgent"}),
            field("status","Status","enum",false,{"to_do","in_progress","in_review","waiting","blocked","completed","canceled","overdue"}),
            field("due_at","Due date","datetime"),field("assigned_agent_id","Assigned agent ID"),field("project_id","Project ID"),field("requires_approval","Requires approval","bool")};
        const QVariantList projectFields{field("name","Name","text",true),field("description","Description","multiline"),
            field("status","Status","enum",false,{"planning","active","in_review","on_hold","completed","archived"}),
            field("priority","Priority","enum",false,{"low","medium","high","urgent"}),field("due_at","Due date","datetime")};
        const QVariantList knowledgeFields{field("title","Title","text",true),field("type","Type","enum",true,{"document","link","note"}),
            field("body","Content","multiline"),field("source_url","Source URL"),field("status","Status","enum",false,{"draft","published","archived"}),
            field("visibility","Visibility","enum",false,{"workspace","restricted","private"}),field("category_id","Category ID"),field("project_id","Project ID"),field("agent_id","Agent ID")};
        const QVariantList planFields{field("key","Plan key","text",true),field("name","Name","text",true),
            field("price_cents_monthly","Monthly price (cents)","int",true),field("price_cents_yearly","Yearly price (cents)","int",true),
            field("limits","Limits","json"),field("features","Feature list","json")};
        QList<FeatureDescriptor> result{
            page("office","Office","office","/api/agents","/api/agents/{id}",agentActions()),
            page("agents","Agents","agents","/api/agents","/api/agents/{id}",agentActions()),
            page("agent-new","Create agent","add","/api/agents/catalog","",{agentActions().front()},"archetypes",false,true),
            page("agent-detail","Agent profile","agents","/api/agents","/api/agents/{id}",agentActions(),"",false,true),
            page("agent-training","Agent training","training","/api/agents","/api/agents/{id}/training",{},"",false,true),
            page("tasks","Tasks","tasks","/api/tasks","/api/tasks/{id}",{
                action("create","Create task","POST","/api/tasks",false,false,taskFields),
                action("edit","Edit task","PATCH","/api/tasks/{id}",true,false,taskFields),
                action("delete","Delete task","DELETE","/api/tasks/{id}",true,true),
                action("run","Run agent","POST","/api/tasks/{id}/execute-ai",true,true),
                action("stop","Stop agent","POST","/api/tasks/{id}/stop-ai",true,true),
                action("runs","Execution history","GET","/api/tasks/{id}/runs",true),
                action("comment","Add comment","POST","/api/tasks/{id}/comments",true,false,{field("body","Comment","multiline",true)}),
                action("approve","Review requested action","POST","/api/tasks/{id}/approve-action",true,true,
                    {field("approval_request_id","Approval request ID","text",true),field("decision","Decision","enum",true,{"approved","rejected"}),field("payload","Approved parameters","json")})}),
            page("projects","Projects","projects","/api/projects","/api/projects/{id}",{
                action("create","Create project","POST","/api/projects",false,false,projectFields),
                action("edit","Edit project","PATCH","/api/projects/{id}",true,false,projectFields),
                action("delete","Delete project","DELETE","/api/projects/{id}",true,true),
                action("tasks","Project tasks","GET","/api/tasks?project_id={id}",true),
                action("files","Project files","GET","/api/drive/{drive_folder_id}/children",true),
                action("assign-agent","Assign agent","POST","/api/projects/{id}/agents",true,false,{field("agent_id","Agent ID","text",true)})}),
            page("knowledge","Knowledge","knowledge","/api/knowledge","/api/knowledge/{id}",{
                action("create","Add knowledge","POST","/api/knowledge",false,false,knowledgeFields),
                action("edit","Edit knowledge","PATCH","/api/knowledge/{id}",true,false,knowledgeFields),
                action("delete","Delete knowledge","DELETE","/api/knowledge/{id}",true,true),
                action("upload","Upload documents","UPLOAD","/api/knowledge/upload",false,false,{field("files","Documents","files",true),field("agent_id","Agent ID"),field("project_id","Project ID")}),
                action("graph","Knowledge graph","GET","/api/knowledge-graph"),
                action("rebuild","Rebuild communities","POST","/api/knowledge-graph/rebuild",false,true),
                action("reindex","Reindex documents","POST","/api/knowledge-graph/reindex",false,true)}),
            page("drive","Files","drive","/api/drive","/api/drive/{id}",{
                action("create","New folder","POST","/api/drive",false,false,{field("name","Folder name","text",true),field("parent_id","Parent folder ID")},{{"kind","folder"}}),
                action("edit","Rename or move","PATCH","/api/drive/{id}",true,false,{field("name","Name"),field("parent_id","Parent folder ID")}),
                action("upload","Upload file","UPLOAD","/api/drive/upload",false,false,{field("files","File","files",true),field("parent_id","Parent folder ID")}),
                action("open","Open deliverable","DELIVERY","",true),
                action("children","Folder contents","GET","/api/drive/{id}/children",true),
                action("delete","Move to trash","DELETE","/api/drive/{id}",true,true),
                action("trash","View trash","GET","/api/drive-trash"),
                action("restore","Restore item","POST","/api/drive/{id}/restore",true)}),
            page("calendar","Calendar","calendar","/api/calendar/events","",{
                action("create","Create event","POST","/api/calendar/events",false,false,
                    {field("title","Title","text",true),field("start_at","Starts at","datetime",true),field("end_at","Ends at","datetime"),
                     field("description","Description","multiline"),field("kind","Kind","enum",false,{"event","meeting","deadline","milestone","personal"}),field("all_day","All day","bool"),field("project_id","Project ID")})}),
            page("mail","Mail","mail","/api/mail/messages","/api/mail/messages/{id}",{
                action("accounts","Connected accounts","GET","/api/mail/accounts"),
                action("rules","Mail rules","GET","/api/mail/rules"),
                action("create-rule","Create mail rule","POST","/api/mail/rules",false,false,{field("name","Name","text",true),field("prompt","Instruction","multiline",true),
                    field("action","Action","enum",false,{"notify","notify_email","label"}),field("mail_account_id","Mailbox account ID")}),
                action("sync","Synchronize mailbox","POST","/api/mail/accounts/{account_id}/sync",false,false,{field("account_id","Mailbox account ID","text",true)})}),
            page("analytics","Analytics","analytics","/api/analytics/overview","",{
                action("agents","Agent metrics","GET","/api/analytics/agents"),action("tasks","Task metrics","GET","/api/analytics/tasks")}),
            page("settings","Settings","settings","/api/workspaces/{workspace}","",{
                action("edit","Save workspace settings","PATCH","/api/workspaces/{workspace}",false,false,
                    {field("name","Workspace name","text",true),field("description","Description","multiline"),field("industry","Industry"),
                     field("timezone","Timezone"),field("language","Language","enum",false,{"en","fr","he"}),field("date_format","Date format"),field("time_format","Time format"),
                     field("default_landing_page","Default page"),field("settings","Advanced settings","json"),field("feature_toggles","Feature toggles","json")}),
                action("upload-logo","Upload logo","UPLOAD","/api/workspaces/{workspace}/logo",false,false,{field("files","Logo","files",true)})}),
            page("profile","Profile","profile","/api/me","",{
                action("edit","Update profile","PATCH","/api/me",false,false,{field("full_name","Full name","text",true),field("locale","Language","enum",false,{"en","fr","he"}),field("timezone","Timezone")}),
                action("password","Change password","POST","/api/me/password",false,false,{field("current_password","Current password","password",true),field("password","New password","password",true),field("password_confirmation","Confirm password","password",true)}),
                action("upload-avatar","Upload avatar","UPLOAD","/api/me/avatar",false,false,{field("files","Avatar","files",true)}),
                action("remove-avatar","Remove avatar","DELETE","/api/me/avatar",false,true)},"user"),
            page("members","Members","members","/api/members","",{
                action("invite","Invite member","POST","/api/members/invite",false,false,{field("email","Email","email",true),field("role_id","Role ID")}),
                action("edit","Edit member","PATCH","/api/members/{id}",true,false,{field("title","Job title"),field("role_id","Role ID"),field("team_id","Team ID"),field("status","Status","enum",false,{"active","invited","suspended","removed"})}),
                action("delete","Remove member","DELETE","/api/members/{id}",true,true),
                action("link-agent","Link human agent","POST","/api/members/{id}/link-agent",true,false,{field("agent_id","Agent ID","text",true)}),
                action("leaves","Leave requests","GET","/api/leave-requests")}),
            page("integrations","Integrations","integrations","/api/mcp","",{
                action("install","Install MCP server","POST","/api/mcp/{key}/install",true,false,
                    {field("credentials","Credentials","json"),field("server_url","Server URL"),field("connected_account","Connected account")}),
                action("uninstall","Uninstall MCP server","DELETE","/api/mcp/installations/{installation_id}",true,true),
                action("connections","Provider connections","GET","/api/integrations"),
                action("browser","Manage OAuth connections in browser","EXTERNAL","/integrations")},"servers"),
            page("billing","Billing","billing","/api/billing/overview","",{
                action("invoices","Invoices","GET","/api/billing/invoices"),action("plans","Available plans","GET","/api/billing/plans"),
                action("packs","Credit packs","GET","/api/billing/credit-packs"),
                action("checkout","Choose plan","POST","/api/billing/checkout",false,true,{field("plan_key","Plan key","text",true),field("billing_cycle","Billing cycle","enum",true,{"monthly","yearly"})}),
                action("credits","Buy credits","POST","/api/billing/credits/checkout",false,true,{field("pack_key","Credit pack key","text",true)}),
                action("portal","Open billing portal","POST","/api/billing/portal"),
                action("auto-recharge","Automatic recharge","POST","/api/billing/auto-recharge",false,true,{field("enabled","Enable automatic recharge","bool",true),field("pack_key","Credit pack key"),field("threshold","Credit threshold","int")})}),
            page("admin-overview","Platform overview","analytics","/api/admin/metrics","",{action("history","Historical metrics","GET","/api/admin/metrics/timeseries")},"",true),
            page("admin-users","Users","members","/api/admin/users","/api/admin/users/{id}",adminUserActions(),"",true,false,true),
            page("admin-user-detail","User details","profile","/api/admin/users","/api/admin/users/{id}/summary",adminUserActions(),"",true,true,true),
            page("admin-workspaces","Workspaces","office","/api/admin/workspaces","/api/admin/workspaces/{id}",adminWorkspaceActions(),"",true,false,true),
            page("admin-workspace-detail","Workspace details","office","/api/admin/workspaces","/api/admin/workspaces/{id}",adminWorkspaceActions(),"",true,true,true),
            page("admin-subscriptions","Subscriptions","billing","/api/admin/subscriptions","/api/admin/subscriptions/{id}",{
                action("edit","Update subscription","PATCH","/api/admin/subscriptions/{id}",true,true,
                    {field("plan_key","Plan key"),field("billing_cycle","Billing cycle","enum",false,{"monthly","yearly"}),field("status","Status","enum",false,{"active","past_due","canceled","canceled_at_period_end"}),field("credits_adjustment","Credit adjustment","int")})},"",true,false,true),
            page("admin-plans","Plans","billing","/api/admin/plans","",{
                action("create","Create plan","POST","/api/admin/plans",false,true,planFields),
                action("edit","Update plan","PATCH","/api/admin/plans/{id}",true,true,planFields)},"",true),
            page("admin-invoices","Invoices","billing","/api/admin/invoices","/api/admin/invoices/{id}",{
                action("mark-paid","Mark paid","POST","/api/admin/invoices/{id}/mark-paid",true,true),
                action("void","Void invoice","POST","/api/admin/invoices/{id}/void",true,true)},"",true,false,true),
            page("admin-credits","Credits","billing","/api/admin/credits/transactions","",{
                action("adjust","Adjust credits","POST","/api/admin/credits/adjust",false,true,
                    {field("workspace_id","Workspace ID","text",true),field("amount","Credit adjustment","int",true),field("reason","Reason","multiline",true)})},"",true,false,true),
            page("admin-costs","Costs","analytics","/api/admin/costs","",{
                action("summary","Cost summary","GET","/api/admin/costs/summary"),
                action("sync","Synchronize provider costs","POST","/api/admin/costs/sync",false,true,{field("days","Number of days (1–90)","int",true)})},"",true),
            page("admin-usage","AI usage","analytics","/api/admin/usage-events","",{},"",true,false,true),
            page("admin-members","Platform members","members","/api/admin/members","",{
                action("edit","Update membership","PATCH","/api/admin/members/{id}",true,true,{field("title","Title"),field("status","Status","enum",false,{"active","invited","suspended","removed"}),field("role_id","Role ID")})},"",true,false,true),
            page("admin-invites","Invitations","members","/api/admin/invites","",{action("delete","Cancel invitation","DELETE","/api/admin/invites/{id}",true,true)},"",true,false,true),
            page("admin-audit","Audit log","logs","/api/admin/audit-logs","",{},"",true,false,true),
            page("admin-logs","Logs","logs","/api/admin/logs","",{},"",true,false,true)
        };
        for (auto& descriptor : result) if (descriptor.id == "profile") descriptor.scope = core::Scope::identity;
        return result;
    }();
    return catalog;
}
const FeatureDescriptor* findFeature(const QString& id) {
    const auto& catalog = featureCatalog();
    const auto found = std::find_if(catalog.cbegin(), catalog.cend(), [&](const auto& feature) { return feature.id == id; });
    return found == catalog.cend() ? nullptr : &*found;
}
QString featureRecordId(const QVariantMap& record) {
    auto id = first(record,{"id","key","request_id"});
    if (!id.isEmpty()) return id;
    return QString::fromLatin1(QCryptographicHash::hash(QJsonDocument::fromVariant(record).toJson(QJsonDocument::Compact),QCryptographicHash::Sha256).toHex());
}
QString featureRecordTitle(const QVariantMap& record) {
    auto title = first(record,{"display_name","full_name","name","title","subject","number","server_name","provider","action","event_type","email","key","id"});
    return title.isEmpty() ? QStringLiteral("Record") : title;
}
QString featureRecordSubtitle(const QVariantMap& record) {
    auto subtitle = first(record,{"role_title","description","email","workspace_name","connected_account","start_at","occurred_at","inserted_at","category","body_text"});
    if (subtitle.isEmpty() && record.contains("value")) {
        const auto value = record.value("value");
        if (value.metaType().id() == QMetaType::QVariantMap || value.metaType().id() == QMetaType::QVariantList)
            subtitle = value.metaType().id()==QMetaType::QVariantMap?QString("%1 fields · open to inspect").arg(value.toMap().size()):QString("%1 items · open to inspect").arg(value.toList().size());
        else subtitle = value.toString();
    }
    return subtitle;
}
QVariantList extractFeatureRecords(const QJsonObject& response, const QString& collectionKey) {
    QJsonValue data = response.contains("data") ? response.value("data") : QJsonValue(response);
    if (!collectionKey.isEmpty()) {
        if (data.isObject() && data.toObject().contains(collectionKey)) data = data.toObject().value(collectionKey);
        else if (response.contains(collectionKey)) data = response.value(collectionKey);
    }
    if (data.isArray()) {
        QVariantList rows;
        for (const auto& value : data.toArray()) if (value.isObject()) rows.append(value.toObject().toVariantMap());
        if (collectionKey == "servers") {
            const auto installations = response.value("data").toObject().value("installations").toArray();
            for (auto& row : rows) {
                auto item = row.toMap();
                for (const auto& value : installations) {
                    const auto installation = value.toObject();
                    if (installation.value("server_id").toString() == item.value("id").toString()) {
                        item.insert("installation_id",installation.value("id").toString());
                        item.insert("status",installation.value("status").toString());
                        item.insert("connected_account",installation.value("connected_account").toString());
                    }
                }
                row = item;
            }
        }
        return rows;
    }
    if (!data.isObject() || data.toObject().isEmpty()) return {};
    const auto object = data.toObject();
    if (object.contains("id")) return {object.toVariantMap()};
    QVariantList rows;
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (isSensitiveDisplayField(it.key())) continue;
        auto label = it.key(); label.replace('_',' ');
        rows.append(QVariantMap{{"id",it.key()},{"title",label},{"value",it.value().toVariant()}});
    }
    return rows;
}
}
