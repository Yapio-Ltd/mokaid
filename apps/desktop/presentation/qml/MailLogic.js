.pragma library
function sender(message) { return message.from_name || message.from_email || "Unknown sender"; }
function initials(message) {
    const name=sender(message).replace(/@.*/,"").trim().split(/[\s._-]+/);
    return (name[0].slice(0,1)+(name.length>1 ? name[1].slice(0,1) : name[0].slice(1,2))).toUpperCase();
}
function date(value,detail) {
    const date=new Date(value); if(isNaN(date.getTime())) return "";
    const today=new Date();
    if(detail) return date.toLocaleString(Qt.locale(),"MMM d, HH:mm");
    return date.toDateString()===today.toDateString() ? date.toLocaleTimeString(Qt.locale(),"HH:mm") : date.toLocaleDateString(Qt.locale(),"MMM d");
}
function size(bytes) { return bytes>=1048576 ? (bytes/1048576).toFixed(1)+" MB" : bytes>=1024 ? Math.round(bytes/1024)+" KB" : bytes+" B"; }
function category(message) { const text=message.ai_category || ""; return text ? text.charAt(0).toUpperCase()+text.slice(1) : ""; }
function color(category) {
    switch((category || "").toLowerCase()) {
    case "finance": case "billing": return "#27cbb0";
    case "marketing": case "social": return "#83b7ff";
    case "notification": case "important": return "#bc91ff";
    default:return "#b9b3cc";
    }
}
