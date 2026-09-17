.pragma library

// Presentation only. Counts are derived from loaded records, never invented totals.
var pages = {
    "agent-new": { subtitle: "Choose an expertise for your next teammate.", primary: "create", action: "Create agent", icon: "agents", empty: "No specializations available", hint: "Refresh to retrieve your workspace agent catalog.", view: "grid" },
    tasks: { subtitle: "Bring the next piece of work into focus.", primary: "create", action: "New task", icon: "tasks", empty: "Your next task starts here", hint: "Create a task, set a priority, and give your team a clear next step.", view: "board" },
    projects: { subtitle: "A clear view of what your team is building.", primary: "create", action: "New project", icon: "projects", empty: "Make room for your next project", hint: "Organize a goal, its tasks, and the people bringing it to life.", view: "grid" },
    drive: { subtitle: "Everything your workspace creates, together.", primary: "upload", action: "Upload file", icon: "folder", empty: "A place for your team's work", hint: "Upload a file or create a folder to keep your work organized.", view: "grid" },
    calendar: { subtitle: "Make time for the work that matters.", primary: "create", action: "New event", icon: "calendar", empty: "Your schedule is clear", hint: "Add a meeting, milestone, or deadline to your calendar.", view: "calendar" },
    mail: { subtitle: "Your connected mail, ready for a closer look.", primary: "sync", action: "Sync mailbox", icon: "mail", empty: "Your inbox is quiet", hint: "Review your connected accounts or synchronize a mailbox to bring messages here.", view: "list" },
    analytics: { subtitle: "Understand how work moves through your workspace.", primary: "tasks", action: "Task report", icon: "analytics", view: "summary" },
    settings: { subtitle: "Make this workspace feel like yours.", primary: "edit", action: "Edit workspace", icon: "settings", view: "summary" },
    profile: { subtitle: "Your identity and preferences across the workspace.", primary: "edit", action: "Edit profile", icon: "profile", view: "summary" },
    members: { subtitle: "The people behind your workspace.", primary: "invite", action: "Invite member", icon: "members", empty: "Build your team", hint: "Invite a colleague to collaborate in this workspace.", view: "list" },
    integrations: { subtitle: "Connect the tools your team depends on.", primary: "browser", action: "Manage connections", icon: "integrations", empty: "No integrations available", hint: "Refresh the catalog or manage your provider connections.", view: "grid" },
    billing: { subtitle: "Your plan, available credits, and billing history.", primary: "portal", action: "Billing portal", icon: "billing", view: "summary" },
    "admin-overview": { subtitle: "Platform health and activity at a glance.", primary: "history", action: "Historical metrics", icon: "analytics", view: "summary" },
    "admin-users": { subtitle: "Manage account access and user activity.", icon: "members", empty: "No users match this view", hint: "Try another search or refresh the user directory.", view: "list" },
    "admin-user-detail": { subtitle: "Review account access, activity, and billing.", icon: "profile", view: "list" },
    "admin-workspaces": { subtitle: "Manage the workspaces across your platform.", icon: "office", empty: "No workspaces match this view", hint: "Try another search or refresh the workspace directory.", view: "grid" },
    "admin-workspace-detail": { subtitle: "Workspace configuration and access.", icon: "office", view: "list" },
    "admin-subscriptions": { subtitle: "Review plans, renewals, and subscription status.", icon: "billing", empty: "No subscriptions match this view", hint: "Subscription records will appear when available.", view: "list" },
    "admin-plans": { subtitle: "Shape the plans available on your platform.", primary: "create", action: "New plan", icon: "billing", empty: "No plans yet", hint: "Create a plan to define pricing and included features.", view: "grid" },
    "admin-invoices": { subtitle: "Track payments and review invoices.", icon: "billing", empty: "No invoices match this view", hint: "Invoices will appear here when they are issued.", view: "list" },
    "admin-credits": { subtitle: "Review credit movements across workspaces.", primary: "adjust", action: "Adjust credits", icon: "billing", empty: "No credit transactions", hint: "Credit purchases, grants, and usage appear in this ledger.", view: "list" },
    "admin-costs": { subtitle: "Review provider spend and reconcile costs.", primary: "summary", action: "Cost summary", icon: "analytics", view: "summary" },
    "admin-usage": { subtitle: "A detailed record of AI usage across the platform.", icon: "analytics", empty: "No usage events match this view", hint: "Usage appears as the platform processes work.", view: "list" },
    "admin-members": { subtitle: "Review membership and access across workspaces.", icon: "members", empty: "No members match this view", hint: "Try another search to find a platform membership.", view: "list" },
    "admin-invites": { subtitle: "Keep track of pending invitations.", icon: "members", empty: "No invitations match this view", hint: "Workspace invitations will appear here.", view: "list" },
    "admin-audit": { subtitle: "Trace important changes across your platform.", icon: "shield", empty: "No audit events match this view", hint: "Recorded administrative actions will appear here.", view: "list" },
    "admin-logs": { subtitle: "Investigate platform events and diagnostics.", icon: "pulse", empty: "No logs match this view", hint: "Try another search or refresh for recent events.", view: "list" }
};
function meta(page) { return pages[page] || { subtitle: "Manage your workspace.", icon: "office", empty: "Nothing here yet", hint: "Refresh this view to retrieve the latest data.", view: "list" }; }
function alpha(color,opacity) { return Qt.rgba(color.r,color.g,color.b,opacity); }
function text(value) { return value === undefined || value === null ? "" : typeof value === "object" ? "" : String(value); }
function first(record, keys, fallback) {
    for (var i = 0; i < keys.length; i++) { var value = text(record[keys[i]]); if (value.length) return value; }
    return fallback || "";
}
function id(r) { return first(r, ["_rowId", "id", "key", "request_id"]); }
function title(r, page) {
    if (page === "mail") return first(r, ["subject"], "No subject");
    if (page === "admin-credits") return first(r, ["description", "workspace_name", "kind"], "Credit transaction");
    if (page === "admin-logs") return first(r, ["message", "event_type", "action", "title"], "Platform event");
    return first(r, ["display_name", "full_name", "name", "title", "subject", "number", "server_name", "provider", "action", "event_type", "email", "key"], "Untitled record");
}
function human(value) { var s = text(value).replace(/_/g, " ").replace(/-/g, " "); return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""; }
function status(r, page) {
    if (page === "mail") return human(r.ai_category || r.folder || "");
    if (page === "integrations") return human(r.status || (r.installation_id ? "connected" : "available"));
    return human(r.status || r.kind || r.level || "");
}
function tone(value) {
    var s = text(value).toLowerCase().replace(/_/g," ");
    if (["completed","active","paid","connected","success","approved"].indexOf(s)>=0) return "success";
    if (["blocked","overdue","urgent","error","suspended","failed","disabled","disconnected"].indexOf(s)>=0) return "danger";
    if (["waiting","in review","pending","invited","high","past due","warning"].indexOf(s)>=0) return "warning";
    return "primary";
}
function date(value, withTime) {
    if (!value) return "";
    var d = new Date(value); if (isNaN(d.getTime())) return "";
    return Qt.formatDateTime(d, withTime ? "MMM d, yyyy · hh:mm" : "MMM d, yyyy");
}
function shortDate(value) { if (!value) return ""; var d = new Date(value); return isNaN(d.getTime()) ? "" : Qt.formatDateTime(d, "MMM d"); }
function bytes(value) { if (value === undefined || value === null) return ""; var n=Number(value); return n >= 1048576 ? (n/1048576).toFixed(1)+" MB" : n >= 1024 ? (n/1024).toFixed(1)+" KB" : n+" B"; }
function money(value, currency) { return value === undefined || value === null ? "" : (Number(value) / 100).toFixed(2) + " " + (currency || "USD"); }
function subtitle(r, page) {
    if (page === "tasks") return [r.project_name, r.assigned_agent_name || "Unassigned"].filter(Boolean).join(" · ");
    if (page === "projects") return first(r, ["description", "owner_name"], "No description yet");
    if (page === "drive") return [r.kind === "folder" ? "Folder" : first(r, ["extension", "mime_type"], "File"), bytes(r.size_bytes)].filter(Boolean).join(" · ");
    if (page === "mail") return first(r, ["from_name", "from_email"], "Unknown sender");
    if (page.indexOf("member") >= 0) return [r.role_name, r.team_name, r.email].filter(Boolean).join(" · ");
    if (page === "integrations") return first(r, ["connected_account", "description", "category"], "Select to connect this tool");
    if (page.indexOf("invoice") >= 0) return [r.workspace_name, money(r.amount_cents, r.currency), date(r.issued_at)].filter(Boolean).join(" · ");
    if (page === "admin-credits") return [r.workspace_name, human(r.kind), date(r.inserted_at)].filter(Boolean).join(" · ");
    if (page === "admin-audit" || page === "admin-logs" || page === "admin-usage") return [r.actor_name || r.user_email || r.workspace_name, date(r.occurred_at || r.inserted_at, true)].filter(Boolean).join(" · ");
    return first(r, ["description", "email", "workspace_name", "connected_account", "role_title", "industry", "billing_cycle", "value"], date(r.inserted_at));
}
function progress(r) { return typeof r.progress_percent === "number" && isFinite(r.progress_percent) ? Math.max(0, Math.min(100,r.progress_percent)) : null; }
function initials(r, page) { var words = title(r, page).trim().split(/\s+/); return words.slice(0,2).map(function(w) { return w.slice(0,1).toUpperCase(); }).join(""); }
function boardGroup(r) {
    var state=text(r.status).toLowerCase().replace(/[ -]/g,"_");
    if (["completed","canceled","cancelled"].indexOf(state)>=0) return "done";
    if (["in_review","waiting","blocked","overdue","failed"].indexOf(state)>=0) return "review";
    if (state === "in_progress") return "doing";
    return "todo";
}
function boardRows(rows, group) { return rows.filter(function(r) { return boardGroup(r) === group; }); }
function subtaskDone(r) { return r.done===true || r.completed===true || r.status==="completed"; }
function taskSubtasks(r) {
    var subtasks=Array.isArray(r.subtasks)?r.subtasks:[];
    if(subtasks.length) return {total:subtasks.length,completed:subtasks.filter(subtaskDone).length};
    var total=typeof r.subtask_count==="number" ? Math.max(0,r.subtask_count) : 0;
    var completed=typeof r.subtask_done_count==="number" ? Math.max(0,Math.min(total,r.subtask_done_count)) : 0;
    return {total:total,completed:completed};
}
function taskRunState(r) {
    if(r.pending_approval || (r.latest_run || {}).status==="waiting_for_approval") return "approval";
    var state=(r.latest_run || {}).status;
    if(state==="queued" || state==="running") return "running";
    if(state==="failed" && r.status!=="completed") return "failed";
    return "";
}
function taskHint(r) {
    var run=taskRunState(r);
    if(run==="approval") return "Your agent is waiting for a decision. Review the requested action to continue.";
    if(run==="running") return "Your agent is working. Open execution history to follow its activity.";
    if(run==="failed") return "The last run could not finish. Review its history before trying again.";
    if(r.status==="completed") return "This task is complete. Its deliverables and conversation stay available here.";
    if(r.status==="canceled") return "This task was canceled. Its history stays available here.";
    if(!r.assigned_agent_id && !r.assigned_agent_name) return "Assign a teammate in Edit task to start moving this work forward.";
    if(r.status==="in_review") return "Review the work and update the task when it is ready.";
    if(r.status==="blocked") return "Resolve the blocker, then update the task or restart your agent.";
    return "Keep the brief clear, follow your agent's activity, and review the result here.";
}
function stats(page, rows) {
    var count = function(predicate) { return rows.filter(predicate).length; };
    if (page === "tasks") return [{label:"Loaded tasks", value:rows.length}, {label:"In progress", value:count(function(r){return r.status==="in_progress";})}, {label:"Needs attention", value:count(function(r){return ["blocked","overdue","in_review","waiting"].indexOf(r.status)>=0;})}, {label:"Completed", value:count(function(r){return r.status==="completed";})}];
    if (page === "projects") return [{label:"Loaded projects",value:rows.length}, {label:"Active",value:count(function(r){return r.status==="active";})}, {label:"In review",value:count(function(r){return r.status==="in_review";})}, {label:"Completed",value:count(function(r){return r.status==="completed";})}];
    if (page === "drive") return [{label:"Items in this view",value:rows.length}, {label:"Folders",value:count(function(r){return r.kind==="folder";})}, {label:"Files",value:count(function(r){return r.kind!=="folder";})}];
    if (page === "members") return [{label:"Loaded members",value:rows.length}, {label:"Active",value:count(function(r){return r.status==="active";})}, {label:"Invited",value:count(function(r){return r.status==="invited";})}];
    return [];
}
function field(label,value) { return {label:label,value:text(value)}; }
function details(page,r) {
    var result=[];
    function add(label,value) { var v=text(value); if (v.length) result.push(field(label,v)); }
    add("Status",status(r,page));
    if (r.value !== undefined && typeof r.value !== "object") add("Value",r.value);
    if (page === "mail") { add("From",[r.from_name,r.from_email].filter(Boolean).join(" · ")); add("To",(r.to_emails || []).join(", ")); add("Received",date(r.received_at,true)); add("Folder",r.folder); }
    else {
        add("Priority",human(r.priority)); add("Project",r.project_name); add("Assigned to",r.assigned_agent_name); add("Owner",r.owner_name);
        add("Due",date(r.due_at,true)); add("Starts",date(r.start_at,true)); add("Ends",date(r.end_at,true));
        add("Email",r.email); add("Role",r.role_name || r.role_title); add("Team",r.team_name); add("Workspace",r.workspace_name);
        add("Connected account",r.connected_account); add("Provider",r.provider); add("Size",bytes(r.size_bytes)); add("File type",r.mime_type);
        if(r.task_count!==undefined) add("Tasks",(r.completed_task_count || 0)+" of "+r.task_count+" completed");
        if(r.members && r.members.length) add("Members",r.members.map(function(m){return m.full_name || m.role;}).filter(Boolean).join(", "));
        if(r.agent_ids) add("Assigned agents",r.agent_ids.length);
        add("Amount",money(r.amount_cents,r.currency)); add("Monthly price",money(r.price_cents_monthly,r.currency)); add("Yearly price",money(r.price_cents_yearly,r.currency));
        add("Credit change",r.amount); add("Balance after",r.balance_after); add("Billing cycle",human(r.billing_cycle));
        add("Joined",date(r.joined_at)); add("Last active",date(r.last_active_at,true)); add("Updated",date(r.updated_at,true)); add("Created",date(r.inserted_at,true));
    }
    return result;
}
function body(page,r) { return page === "mail" ? first(r,["body_text","snippet"],"Message content has not been provided.") : first(r,["description","body","reason","operator_notes","message"]); }
function reportAction(page,id) {
    var reports={tasks:["runs"],projects:["tasks","files"],mail:["accounts","rules"],analytics:["agents","tasks"],members:["leaves"],integrations:["connections"],billing:["invoices","plans","packs"],"admin-overview":["history"],"admin-users":["summary"],"admin-user-detail":["summary"],"admin-costs":["summary"]};
    return (reports[page] || []).indexOf(id)>=0;
}
function summaryGroups(page,data) {
    var d=data || {}, groups=[];
    function group(title,entries) { groups.push({title:title,rows:entries.map(function(e){return field(e[0], e[1]===undefined || e[1]===null || e[1]==="" ? "Not set" : e[1]);})}); }
    if(page==="settings") {
        group("Workspace",[["Name",d.name],["Description",d.description],["Industry",d.industry]]);
        group("Language & time",[["Language",d.language],["Timezone",d.timezone],["Date format",d.date_format],["Time format",d.time_format]]);
        group("Experience",[["Default page",human(d.default_landing_page)]]);
    } else if(page==="profile") {
        d=d.user || d;
        group("Personal details",[["Full name",d.full_name],["Email",d.email]]);
        group("Preferences",[["Language",d.locale],["Timezone",d.timezone]]);
        group("Security",[["Multi-factor authentication",d.mfa_enabled===undefined?"Not available":d.mfa_enabled?"Enabled":"Not enabled"]]);
    } else if(page==="billing") {
        var sub=d.subscription || {}, plan=sub.plan || d.plan || {}, credits=d.credits || {};
        group("Current plan",[["Plan",plan.name || sub.plan_name || sub.plan_key],["Status",human(sub.status)],["Billing cycle",human(sub.billing_cycle)],["Period ends",date(sub.current_period_end)]]);
        group("Credits",[["Available",credits.unlimited?"Unlimited":credits.spendable],["Included remaining",credits.included_remaining],["Purchased balance",credits.balance],["Automatic recharge",credits.auto_recharge_enabled===undefined?"Not available":credits.auto_recharge_enabled?"Enabled":"Disabled"]]);
        if((d.credit_transactions || []).length) group("Recent credit activity", d.credit_transactions.slice(0,8).map(function(r){ return [first(r,["description"],human(r.kind))+" · "+shortDate(r.inserted_at), (Number(r.amount)>0?"+":"")+r.amount+" credits"]; }));
    } else if(page==="admin-costs") {
        var providers=d.totals_cents || {};
        group("Reported provider costs",Object.keys(providers).map(function(k){return [human(k),money(providers[k])];}));
        if((d.snapshots || []).length) group("Recent cost reports",d.snapshots.slice(0,20).map(function(r){return [human(r.provider)+" · "+date(r.period_start),money(r.amount_cents,r.currency)];}));
        if((d.reconciliation || []).length) group("Reconciliation differences",d.reconciliation.slice(0,20).map(function(r){return [human(r.provider)+" · "+date(r.day),money(r.delta_cents)];}));
    }
    return groups;
}
function metricEntries(page,data) {
    var d=page==="analytics"?(data.overview || {}):data, result=[];
    var labels={total_tasks:"Total tasks",completed_tasks:"Completed",completion_rate:"Completion rate",in_progress:"In progress",overdue:"Overdue",active_agents:"Active agents",avg_task_hours:"Average task time",users_total:"Total users",users_active:"Active users",users_banned:"Suspended users",workspaces_total:"Workspaces",mrr_cents:"Monthly recurring revenue",arr_cents:"Annual recurring revenue",arpu_cents:"Revenue per subscriber",subscriptions_active:"Active subscriptions",subscriptions_past_due:"Past-due subscriptions",invoices_pending:"Pending invoices",new_users_30d:"New users · 30 days",credits_spend_30d:"Credits spent · 30 days",credits_balance_total:"Total credit balance",internal_ai_cost_mtd_cents:"AI cost · this month",provider_cost_mtd_cents:"Provider cost · this month",openai_cost_mtd_cents:"OpenAI · this month",anthropic_cost_mtd_cents:"Anthropic · this month",aws_cost_mtd_cents:"AWS · this month",gross_margin_cents:"Gross margin",deletions_pending:"Pending deletions",total_cents:"Total reported cost",days:"Days in reporting window"};
    var keys=page==="analytics"?["total_tasks","completed_tasks","completion_rate","in_progress","overdue","active_agents","avg_task_hours"]:page==="admin-costs"?["total_cents","days"]:Object.keys(d);
    keys.forEach(function(k) { if(typeof d[k]==="number") result.push({label:labels[k] || human(k),value:k.indexOf("cents")>=0?money(d[k]):d[k]+(k==="completion_rate"?"%":k==="avg_task_hours"?" h":"")}); });
    return result;
}
