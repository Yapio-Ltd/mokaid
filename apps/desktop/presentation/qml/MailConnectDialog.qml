pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

MokaidDialog {
    id: root
    required property var controller
    property bool closingAfterCancel: false
    property string mode: "choose"
    property string existingId: ""
    property bool advanced: false
    property bool knownProvider: false
    property string detectedDomain: ""
    readonly property bool working: controller.submitting || controller.oauthPending
    readonly property var presets: [
        {name:"Detect from email address", host:"", smtp:"", smtpPort:465},
        {name:"iCloud", host:"imap.mail.me.com", smtp:"smtp.mail.me.com", smtpPort:587},
        {name:"Yahoo", host:"imap.mail.yahoo.com", smtp:"smtp.mail.yahoo.com", smtpPort:465},
        {name:"Gmail with app password", host:"imap.gmail.com", smtp:"smtp.gmail.com", smtpPort:465},
        {name:"Other provider / custom server", host:"", smtp:"", smtpPort:587}
    ]
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(620, parent ? parent.width - 32 : 620)
    height: Math.min(implicitHeight, parent ? parent.height - 32 : implicitHeight)
    modal: true; focus: true
    closePolicy: working ? Popup.NoAutoClose : Popup.CloseOnEscape
    title: existingId.length ? "Reconnect mailbox" : "Connect a mailbox"
    function clearDraft() {
        closingAfterCancel=false; mode="choose"; existingId=""; email.text=""; password.text=""; username.text="";
        provider.currentIndex=0; advanced=false; knownProvider=false; detectedDomain="";
        imapHost.text=""; imapPort.text="993"; imapSecurity.currentIndex=0;
        smtpHost.text=""; smtpPort.text="587"; smtpSecurity.currentIndex=1; outgoing.checked=true; differentSmtp.checked=false; smtpUsername.text=""; smtpPassword.text="";
    }
    function start(account) {
        clearDraft(); controller.clearError();
        if(account && account.id) {
            existingId=account.id; mode="imap"; email.text=account.email_address || "";
            const settings=account.settings || {};
            username.text=settings.username || ""; imapHost.text=settings.imap_host || "";
            imapPort.text=String(settings.imap_port || 993);
            imapSecurity.currentIndex=settings.imap_security==="starttls" || settings.imap_ssl===false ? 1 : 0;
            smtpHost.text=settings.smtp_host || ""; smtpPort.text=String(settings.smtp_port || 587);
            smtpSecurity.currentIndex=settings.smtp_security==="tls" || settings.smtp_ssl===true ? 0 : 1;
            smtpUsername.text=settings.smtp_username || ""; differentSmtp.checked=!!settings.smtp_username && settings.smtp_username!==settings.username;
            outgoing.checked=!!settings.smtp_host; provider.currentIndex=4; advanced=true;
        }
        open();
    }
    function applyPreset(index) {
        const value=presets[index]; knownProvider=index>0 && index<4;
        imapHost.text=value.host; imapPort.text="993"; imapSecurity.currentIndex=0;
        smtpHost.text=value.smtp; smtpPort.text=String(value.smtpPort); smtpSecurity.currentIndex=value.smtpPort===465 ? 0 : 1;
        advanced=!knownProvider; outgoing.checked=true;
    }
    function detect() {
        if(provider.currentIndex!==0) return;
        const domain=email.text.trim().toLowerCase().split("@")[1] || "";
        if(domain===detectedDomain) return;
        detectedDomain=domain;
        if(["icloud.com","me.com","mac.com"].indexOf(domain)>=0) applyPreset(1);
        else if(domain==="yahoo.com" || domain.indexOf("yahoo.")===0 || ["ymail.com","rocketmail.com"].indexOf(domain)>=0) applyPreset(2);
        else if(domain==="gmail.com" || domain==="googlemail.com") applyPreset(3);
        else applyPreset(4);
    }
    function submit() {
        detect();
        controller.connectImap({email_address:email.text, password:password.text, username:username.text,
            imap_host:imapHost.text, imap_port:imapPort.text, imap_security:imapSecurity.currentIndex===0 ? "tls" : "starttls",
            smtp_enabled:outgoing.checked, smtp_host:outgoing.checked ? smtpHost.text : "", smtp_port:smtpPort.text,
            smtp_security:smtpSecurity.currentIndex===0 ? "tls" : "starttls", different_smtp_login:differentSmtp.checked,
            smtp_username:smtpUsername.text, smtp_password:smtpPassword.text}, existingId);
    }
    onClosed: {password.text=""; smtpPassword.text="";}
    Connections {
        target: root.controller
        function onConnected() { password.text=""; smtpPassword.text=""; root.close(); }
        function onChanged() { if(root.closingAfterCancel && !root.controller.oauthPending && !root.controller.submitting) {root.closingAfterCancel=false; root.close();} }
        function onContextReset() { root.clearDraft(); root.close(); }
    }
    contentItem: ScrollView {
        clip: true
        implicitHeight: content.implicitHeight
        contentWidth: availableWidth
        ColumnLayout {
            id: content
            width: parent.width; spacing: 14
            MokaidLabel {
                Layout.fillWidth: true
                text: root.mode==="choose" ? "Bring your inboxes together in Mokaid. Add as many accounts as you need." : "Use the password your provider allows for mail apps. Your connection is checked before the mailbox is saved."
                color: Theme.secondary; wrapMode: Text.Wrap
            }
            ColumnLayout {
                visible: root.mode==="choose" && !root.controller.oauthPending
                Layout.fillWidth: true; spacing: 10
                MokaidButton {
                    objectName: "connectGmailButton"; Layout.fillWidth: true
                    text: "Continue with Google"; highlighted: true; enabled: root.controller.online && !root.working
                    onClicked: root.controller.connectGoogle()
                }
                MokaidLabel { Layout.fillWidth: true; text: "Gmail or Google Workspace. Sign in securely in your browser."; font.pixelSize: 12; color: Theme.secondary; wrapMode: Text.Wrap }
                MokaidButton {
                    objectName: "connectImapButton"; Layout.fillWidth: true
                    text: "Other email · IMAP / SMTP"; enabled: root.controller.online && !root.working
                    onClicked: { root.mode="imap"; email.forceActiveFocus(); }
                }
                MokaidLabel { Layout.fillWidth: true; text: "iCloud, Yahoo and other providers, with server settings filled in when recognized."; font.pixelSize: 12; color: Theme.secondary; wrapMode: Text.Wrap }
            }
            ColumnLayout {
                visible: root.controller.oauthPending; Layout.fillWidth: true; spacing: 12
                BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: root.controller.oauthPending; Layout.preferredWidth: 36; Layout.preferredHeight: 36 }
                MokaidLabel { Layout.fillWidth: true; text: "Finish connecting in your browser"; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
                MokaidLabel { Layout.fillWidth: true; text: "Choose a Google account and allow mail access. Your inbox will connect here automatically."; wrapMode: Text.Wrap; color: Theme.secondary; horizontalAlignment: Text.AlignHCenter }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    MokaidButton { text:"Reopen browser"; enabled:!root.controller.submitting; onClicked: root.controller.reopenBrowser() }
                    MokaidButton { text:"Check connection"; quiet:true; enabled:!root.controller.submitting; onClicked: root.controller.checkOAuth() }
                }
                GoogleSignInHelp { Layout.fillWidth:true }
            }
            ColumnLayout {
                visible: root.mode==="imap" && !root.controller.oauthPending
                enabled: !root.controller.submitting
                Layout.fillWidth: true; spacing: 8
                MokaidLabel { text:"Email address" }
                MokaidTextField { id:email; objectName:"mailEmail"; Layout.fillWidth:true; placeholderText:"you@example.com"; readOnly:root.existingId.length>0; inputMethodHints:Qt.ImhEmailCharactersOnly; onEditingFinished:root.detect(); Accessible.name:"Email address" }
                MokaidLabel { text:"Email provider" }
                MokaidComboBox { id:provider; objectName:"mailProvider"; Layout.fillWidth:true; model:root.presets.map(function(p){return p.name;}); onActivated:function(index){root.applyPreset(index); if(index===0) {root.detectedDomain=""; root.detect();}}; Accessible.name:"Email provider" }
                MokaidLabel { text:"App password or mailbox password" }
                MokaidTextField { id:password; objectName:"mailPassword"; Layout.fillWidth:true; echoMode:TextInput.Password; placeholderText:"Enter your app password"; inputMethodHints:Qt.ImhSensitiveData | Qt.ImhNoPredictiveText; Accessible.name:"App password or mailbox password"; onAccepted:root.submit() }
                MokaidLabel {
                    Layout.fillWidth:true; font.pixelSize:12; color:Theme.secondary; wrapMode:Text.Wrap
                    text:imapHost.text==="imap.mail.me.com" ? "Create an app-specific password in your Apple Account. If your address is an alias, use your main iCloud address as the username below."
                        : imapHost.text==="imap.mail.yahoo.com" ? "Generate an app password in Yahoo Account Security and paste it here."
                        : imapHost.text==="imap.gmail.com" ? "Google sign-in is recommended. An app password requires 2-Step Verification and may be disabled by your administrator."
                        : "For accounts with two-factor authentication, your usual password may not work. Generate an app password in your provider’s security settings."
                }
                MokaidButton { visible:imapHost.text==="imap.gmail.com" && !root.existingId.length; text:"Use Google sign-in instead"; quiet:true; onClicked:{root.mode="choose"; password.text=""; root.controller.connectGoogle();} }
                RowLayout {
                    visible:root.knownProvider; Layout.fillWidth:true; spacing:8
                    MokaidButton { text:"Provider setup help"; quiet:true; onClicked:root.controller.openProviderHelp(imapHost.text) }
                    MokaidButton {
                        objectName:"mailAdvancedButton"; text:root.advanced ? "Hide server settings" : "Server settings and username"; quiet:true
                        onClicked:root.advanced=!root.advanced
                    }
                    Item {Layout.fillWidth:true}
                }
                ColumnLayout {
                    visible:root.advanced || !root.knownProvider; Layout.fillWidth:true; spacing:8
                    MokaidLabel { text:"Username (optional)" }
                    MokaidTextField { id:username; objectName:"mailUsername"; Layout.fillWidth:true; placeholderText:"Uses your email address by default"; Accessible.name:"Mailbox username" }
                    MokaidLabel { text:"Incoming mail · IMAP"; font.weight:Font.DemiBold; Layout.topMargin:4 }
                    MokaidTextField { id:imapHost; objectName:"mailImapHost"; Layout.fillWidth:true; placeholderText:"imap.example.com"; Accessible.name:"IMAP server" }
                    RowLayout {
                        Layout.fillWidth:true
                        MokaidTextField { id:imapPort; objectName:"mailImapPort"; Layout.preferredWidth:100; text:"993"; inputMethodHints:Qt.ImhDigitsOnly; validator:IntValidator{bottom:1; top:65535} Accessible.name:"IMAP port" }
                        MokaidComboBox { id:imapSecurity; Layout.fillWidth:true; model:["SSL / TLS","STARTTLS"]; Accessible.name:"IMAP security"; onActivated:imapPort.text=currentIndex===0 ? "993" : "143" }
                    }
                    CheckBox { id:outgoing; objectName:"mailSmtpEnabled"; text:"Connect outgoing mail (SMTP)"; checked:true; palette.windowText:Theme.text; Accessible.name:text }
                    ColumnLayout {
                        visible:outgoing.checked; Layout.fillWidth:true; spacing:8
                        MokaidTextField { id:smtpHost; objectName:"mailSmtpHost"; Layout.fillWidth:true; placeholderText:"smtp.example.com"; Accessible.name:"SMTP server" }
                        RowLayout {
                            Layout.fillWidth:true
                            MokaidTextField { id:smtpPort; objectName:"mailSmtpPort"; Layout.preferredWidth:100; text:"587"; inputMethodHints:Qt.ImhDigitsOnly; validator:IntValidator{bottom:1; top:65535} Accessible.name:"SMTP port" }
                            MokaidComboBox { id:smtpSecurity; Layout.fillWidth:true; model:["SSL / TLS","STARTTLS"]; currentIndex:1; Accessible.name:"SMTP security"; onActivated:smtpPort.text=currentIndex===0 ? "465" : "587" }
                        }
                        CheckBox { id:differentSmtp; text:"Use a different SMTP sign-in"; palette.windowText:Theme.text; Accessible.name:text }
                        MokaidTextField { id:smtpUsername; objectName:"mailSmtpUsername"; visible:differentSmtp.checked; Layout.fillWidth:true; placeholderText:"SMTP username"; Accessible.name:"SMTP username" }
                        MokaidTextField { id:smtpPassword; objectName:"mailSmtpPassword"; visible:differentSmtp.checked; Layout.fillWidth:true; placeholderText:"SMTP password"; echoMode:TextInput.Password; inputMethodHints:Qt.ImhSensitiveData | Qt.ImhNoPredictiveText; Accessible.name:"SMTP password" }
                        MokaidLabel { visible:!differentSmtp.checked; Layout.fillWidth:true; text:"Uses the same username and password as incoming mail."; font.pixelSize:12; color:Theme.secondary; wrapMode:Text.Wrap }
                    }
                }
            }
            MokaidLabel { visible:root.controller.error.length>0; Layout.fillWidth:true; text:root.controller.error; color:Theme.warning; wrapMode:Text.Wrap; Accessible.role:Accessible.AlertMessage }
            MokaidLabel { visible:root.controller.submitting; Layout.fillWidth:true; text:root.mode==="imap" ? "Checking your mailbox and server settings…" : "Opening secure Google sign-in…"; color:Theme.secondary; wrapMode:Text.Wrap }
            MokaidLabel { visible:!root.controller.online; Layout.fillWidth:true; text:"Reconnect to the internet to add a mailbox."; color:Theme.warning; wrapMode:Text.Wrap }
        }
    }
    footer: RowLayout {
        spacing:10
        MokaidButton {
            Layout.leftMargin:24; Layout.topMargin:12; Layout.bottomMargin:24
            text:root.controller.oauthPending ? "Cancel sign-in" : "Cancel"; enabled:!root.controller.submitting
            onClicked:{if(root.controller.oauthPending) {root.closingAfterCancel=true; root.controller.cancelOAuth();} else root.close();}
        }
        Item {Layout.fillWidth:true}
        MokaidButton { visible:root.mode==="imap" && !root.existingId.length; text:"Back"; quiet:true; enabled:!root.working; onClicked:{root.mode="choose"; password.text=""; root.controller.clearError();} }
        MokaidButton {
            objectName:"mailSubmitButton"; Layout.rightMargin:24; Layout.topMargin:12; Layout.bottomMargin:24
            visible:root.mode==="imap" && !root.controller.oauthPending; text:root.controller.submitting ? "Checking…" : root.existingId.length ? "Reconnect mailbox" : "Connect mailbox"
            highlighted:true; enabled:root.controller.online && !root.working; onClicked:root.submit()
        }
    }
}
