#include "call.h"
#include "client-utils.h"
#include "receiving.h"
#include "config.h"
#include "buildopt.h"
#include "format.h"
#include "purple-info.h"
#include "td-client.h"
#include "call-luna.h"

static td::td_api::object_ptr<td::td_api::callProtocol> getCallProtocol()
{
    auto protocol = td::td_api::make_object<td::td_api::callProtocol>();
    protocol->udp_p2p_       = true;
    protocol->udp_reflector_ = true;
    protocol->min_layer_     = 65;
    protocol->max_layer_     = 92;
    return protocol;
}

bool initiateCall(int64_t userId, TdAccountData &account, TdTransceiver &transceiver)
{
    // userId is tdlib's int53 (createCall.user_id_): Telegram user ids exceed INT32_MAX (e.g. Alan =
    // 8823012961), so this MUST be 64-bit - an int32_t param truncated large ids to a garbage user and
    // the call silently never started (no state pushed -> Phone app stuck on the video tab).
#ifndef NoVoip
    if (!account.hasActiveCall()) {
        td::td_api::object_ptr<td::td_api::createCall> callRequest = td::td_api::make_object<td::td_api::createCall>();
        callRequest->user_id_  = userId;
        callRequest->protocol_ = getCallProtocol();
        transceiver.sendQuery(std::move(callRequest), nullptr);
        return true;   // call request sent; report success so the dial isn't logged as FAILED TO DIAL
    } else
        // TRANSLATOR: Dialog title of an error message.
        purple_notify_warning(account.purpleAccount, _("Voice call"),
                              // TRANSLATOR: Dialog content of an error message.
                              _("Cannot start new call, already in another call"), NULL);
#endif

    return false;
}

static void discardCall(int32_t callId, TdTransceiver &transceiver)
{
    td::td_api::object_ptr<td::td_api::discardCall> discardReq = td::td_api::make_object<td::td_api::discardCall>();
    discardReq->call_id_ = callId;
    discardReq->is_disconnected_ = true;
    discardReq->duration_ = 0;
    discardReq->connection_id_ = 0;
    transceiver.sendQuery(std::move(discardReq), nullptr);
}

struct CallRequestData {
    int            callId;
    TdTransceiver *transceiver;
    TdAccountData *account;
};

static void acceptCallCb(CallRequestData *data, int action)
{
    std::unique_ptr<CallRequestData> request(data);

    td::td_api::object_ptr<td::td_api::acceptCall> acceptReq = td::td_api::make_object<td::td_api::acceptCall>();
    acceptReq->call_id_ = request->callId;
    acceptReq->protocol_ = getCallProtocol();
    request->transceiver->sendQuery(std::move(acceptReq), nullptr);
}

static void discardCallCb(CallRequestData *data, int action)
{
    std::unique_ptr<CallRequestData> request(data);
    discardCall(request->callId, *request->transceiver);
    request->account->removeActiveCall();
}

static std::string getPurpleUserName(UserId userId, TdAccountData &account)
{
    const td::td_api::user *user = account.getUser(userId);
    if (user) {
        const td::td_api::chat *privateChat = account.getPrivateChatByUserId(userId);
        if (privateChat && isChatInContactList(*privateChat, user))
            return getPurpleBuddyName(*user);
        else
            return account.getDisplayName(*user);
    } else
        return std::string();
}

static bool activateCall(const td::td_api::call &call, const std::string &buddyName,
                         TdAccountData &account, TdTransceiver &transceiver)
{
#ifndef NoVoip
    if (call.state_->get_id() != td::td_api::callStateReady::ID)
        return false;
    const td::td_api::callStateReady &state = static_cast<const td::td_api::callStateReady &>(*call.state_);

    if (state.protocol_->max_layer_ < 74) {
        // libtgvoip crashes with openssl assertion failure if it goes into if(!useMTProto2) branch
        // of VoIPController::ProcessIncomingPacket
        // Unlikely error message not worth translating
        if (!buddyName.empty())
            showMessageTextIm(account, buddyName.c_str(), NULL,
                              "Discarding call due to low protocol layer",
                              time(NULL), PURPLE_MESSAGE_SYSTEM);

        return false;
    }

    tgvoip::VoIPController *voip = account.getCallData();
    if (!voip)
        return false;

    static tgvoip::VoIPController::Config config;
    // DIAG: disable the software AEC/NS/AGC while bringing up capture. On a loudspeaker call libtgvoip's
    // echo canceller/noise suppressor can over-cancel the mic to silence (the peer hears nothing) - rule
    // it out first; re-enable once two-way audio is confirmed.
    config.enableAEC = false;
    config.enableNS  = false;
    config.enableAGC = false;
    // DIAG: libtgvoip writes NOTHING to the system log, so an unestablished media path (peer stuck on
    // "Connecting") is invisible. Point it at a file to see the reflector connection + audio init.
    config.logFilePath       = "/media/internal/tgvoip.log";
    config.statsDumpFilePath = "/media/internal/tgvoip-stats.log";
    voip->SetConfig(config);

    std::vector<tgvoip::Endpoint> endpoints;
    for (const auto &pServer: state.servers_)
        if (pServer && pServer->type_ && (pServer->type_->get_id() == td::td_api::callServerTypeTelegramReflector::ID)) {
            const td::td_api::callServerTypeTelegramReflector &reflectorInfo =
                static_cast<const td::td_api::callServerTypeTelegramReflector &>(*pServer->type_);
            std::vector<unsigned char> tag(16);
            memmove(tag.data(), reflectorInfo.peer_tag_.c_str(), std::min(reflectorInfo.peer_tag_.length(), tag.size()));
            endpoints.push_back(tgvoip::Endpoint(pServer->id_, pServer->port_,
                                                tgvoip::IPv4Address(pServer->ip_address_),
                                                tgvoip::IPv6Address(pServer->ipv6_address_),
                                                tgvoip::Endpoint::UDP_RELAY,
                                                tag.data()));
        }
    voip->SetRemoteEndpoints(endpoints, state.allow_p2p_ && state.protocol_->udp_p2p_,
                             state.protocol_->max_layer_);

    std::vector<char> key(state.encryption_key_.length()+1);
    memmove(key.data(), state.encryption_key_.c_str(), key.size());
    voip->SetEncryptionKey(key.data(), call.is_outgoing_);
    tgcLog("activateCall: endpoints=%zu p2p=%d max_layer=%d key_len=%zu outgoing=%d",
           endpoints.size(), (int)(state.allow_p2p_ && state.protocol_->udp_p2p_),
           (int)state.protocol_->max_layer_, state.encryption_key_.length(), (int)call.is_outgoing_);
    voip->Start();
    voip->Connect();
    callLunaSetCallAudio(true);   // enable audiod phone scenario -> voip/voipsource carry real audio

    if (!buddyName.empty()) {
        // For an outgoing call, "type /hangup to terminate" has already been shown when the call
        // was initiated
        // TRANSLATOR: In-chat status message
        const char *message = call.is_outgoing_ ? _("Call active") :
                                                  // TRANSLATOR: In-chat status message. Please keep '/hangup' verbatim!
                                                  _("Call active, type /hangup to terminate");
        showMessageTextIm(account, buddyName.c_str(), NULL, message,
                          time(NULL), PURPLE_MESSAGE_SYSTEM);
    }

#endif
    return true;
}

static void deactivateCall(TdAccountData &account)
{
#ifndef NoVoip
    callLunaSetCallAudio(false);   // clear audiod phone scenario on hangup
    tgvoip::VoIPController *voip = account.getCallData();
    if (voip)
        voip->Stop();
#endif
}

static void notifyCallError(const td::td_api::callStateError &error, const std::string &buddyName,
                            TdAccountData &account)
{
    std::string message;
    if (error.error_)
        message = formatMessage(errorCodeMessage(), {std::to_string(error.error_->code_),
                                error.error_->message_});
    else
        // Unlikely message not worth translating
        message = "unknown error";
    // TRANSLATOR: In-chat error message, argument is text
    message = formatMessage(_("Call failed: {}"), message);
    if (!buddyName.empty())
        showMessageTextIm(account, buddyName.c_str(), NULL, message.c_str(),
                          time(NULL), PURPLE_MESSAGE_SYSTEM);
}

void updateCall(const td::td_api::call &call, TdAccountData &account, TdTransceiver &transceiver)
{
    std::string buddyName = getPurpleUserName(getUserId(call), account);

#ifndef NoVoip
    // webOS (Path C): the call UI + audio is the stock Phone app via com.palm.telegram.call (see
    // call-luna.cpp), NOT PurpleMedia - so do not gate on the frontend's media caps; always accept
    // and drive the call over LS2. (libtgvoip does the media directly.)
    if (false) {
#else
    if (true) {
#endif
        purple_debug_misc(config::pluginId, "Ignoring incoming call: no audio capability\n");
        if (call.state_ && (call.state_->get_id() == td::td_api::callStatePending::ID)) {
            if (!buddyName.empty())
                showMessageTextIm(account, buddyName.c_str(), NULL,
                                  // TRANSLATOR: In-chat error message
                                  _("Received incoming call, but calls are not supported"),
                                  time(NULL), PURPLE_MESSAGE_SYSTEM);

            discardCall(call.id_, transceiver);
        }
        return;
    }

    if (!call.state_) return; // just in case

    if (!call.is_outgoing_ && (call.state_->get_id() == td::td_api::callStatePending::ID)) {
        if (!account.hasActiveCall()) {
            account.setActiveCall(call.id_);
            // webOS: ring the stock Phone app instead of a pidgin accept/reject dialog. The user
            // answers via com.palm.telegram.call/answer -> callBridgeAnswer -> acceptCurrentCall.
            callLunaPushState("incoming", buddyName.c_str(),
                              account.getDisplayName(getUserId(call)).c_str(), false, NULL);
        } else if (call.id_ != account.getActiveCallId()) {
            if (!buddyName.empty())
                showMessageTextIm(account, buddyName.c_str(), NULL,
                                // TRANSLATOR: In-chat error message
                                _("Received incoming call while already in another call"),
                                time(NULL), PURPLE_MESSAGE_SYSTEM);

            discardCall(call.id_, transceiver);
        }
    } else if (call.is_outgoing_ && (call.state_->get_id() == td::td_api::callStatePending::ID)) {
        if (!account.hasActiveCall()) {
            account.setActiveCall(call.id_);
            // The stock Phone app's CallSynergizer keys the "dialing/ringback" UI off the line
            // state string STATES.DIALING == "dialing" (not "outgoing"); send that so the call
            // card shows "Connecting..." while the outgoing call is pending, same as WhatsApp.
            callLunaPushState("dialing", buddyName.c_str(),
                              account.getDisplayName(getUserId(call)).c_str(), true, NULL);
        } else if (call.id_ != account.getActiveCallId()) {
            // This would happen if there was no active call when sending createCall, but there is one
            // a millisecond later when asynchronous response is received. Possible if two calls are
            // started at the same time, or one is started an another received at the same time.
            discardCall(call.id_, transceiver);
        }
    } else if (call.state_->get_id() == td::td_api::callStateReady::ID) {
        if (! activateCall(call, buddyName, account, transceiver)) {
            discardCall(call.id_, transceiver);
            account.removeActiveCall();
        } else {
            callLunaPushState("active", buddyName.c_str(),
                              account.getDisplayName(getUserId(call)).c_str(), call.is_outgoing_, NULL);
        }
    }
    else if ( ((call.state_->get_id() == td::td_api::callStateHangingUp::ID) ||
               (call.state_->get_id() == td::td_api::callStateDiscarded::ID) ||
               (call.state_->get_id() == td::td_api::callStateError::ID)) &&
              account.hasActiveCall() && account.getActiveCallId() == call.id_)
    {
        const char *cause = "normal";
        if (call.state_->get_id() == td::td_api::callStateDiscarded::ID) {
            const td::td_api::callStateDiscarded &d = static_cast<const td::td_api::callStateDiscarded &>(*call.state_);
            if (d.reason_) {
                if (d.reason_->get_id() == td::td_api::callDiscardReasonDeclined::ID) cause = "rejected";
                else if (d.reason_->get_id() == td::td_api::callDiscardReasonMissed::ID) cause = "missed";
            }
        } else if (call.state_->get_id() == td::td_api::callStateError::ID) {
            cause = "error";
        }
        callLunaPushState("disconnected", buddyName.c_str(),
                          account.getDisplayName(getUserId(call)).c_str(), call.is_outgoing_, cause);
        if (call.state_->get_id() == td::td_api::callStateError::ID) {
            const td::td_api::callStateError &error = static_cast<const td::td_api::callStateError &>(*call.state_);
            notifyCallError(error, buddyName, account);
        }
        deactivateCall(account);
        account.removeActiveCall();
    }
}

void discardCurrentCall(TdAccountData &account, TdTransceiver &transceiver)
{
    if (account.hasActiveCall())
        discardCall(account.getActiveCallId(), transceiver);
}

void acceptCurrentCall(TdAccountData &account, TdTransceiver &transceiver)
{
    if (!account.hasActiveCall()) return;
    td::td_api::object_ptr<td::td_api::acceptCall> acceptReq = td::td_api::make_object<td::td_api::acceptCall>();
    acceptReq->call_id_ = account.getActiveCallId();
    acceptReq->protocol_ = getCallProtocol();
    transceiver.sendQuery(std::move(acceptReq), nullptr);
}

// ---- LS2 <-> TDLib bridge: called by call-luna.cpp for the com.palm.telegram.call service ----
bool callBridgeDial(PurpleAccount *account, const char *who)
{
    PurpleTdClient *client = getTdClient(account);
    return (client && who) ? client->startVoiceCall(who) : false;
}

void callBridgeAnswer(PurpleAccount *account)
{
    PurpleTdClient *client = getTdClient(account);
    if (client) client->acceptCurrentCall();
}

void callBridgeHangup(PurpleAccount *account)
{
    PurpleTdClient *client = getTdClient(account);
    if (client) client->hangupVoiceCall();
}

void showCallMessage(const td::td_api::chat &chat, const TgMessageInfo &message,
                     const td::td_api::messageCall &callEnded, TdAccountData &account)
{
    std::string notification;
    if (callEnded.discard_reason_)
        switch (callEnded.discard_reason_->get_id()) {
            case td::td_api::callDiscardReasonMissed::ID:
                // TRANSLATOR: In-line reason for an ended call; appears after a colon (':')
                notification = _("call missed");
                break;
            case td::td_api::callDiscardReasonDeclined::ID:
                // TRANSLATOR: In-line reason for an ended call; appears after a colon (':')
                notification = _("declined by peer");
                break;
            case td::td_api::callDiscardReasonDisconnected::ID:
                // TRANSLATOR: In-line reason for an ended call; appears after a colon (':')
                notification = _("users disconnected");
                break;
            case td::td_api::callDiscardReasonHungUp::ID:
                // TRANSLATOR: In-line reason for an ended call; appears after a colon (':')
                notification = _("hung up");
                break;
        }
    if (notification.empty()) {
        // TRANSLATOR: In-line reason for an ended call; appears after a colon (':')
        notification = _("reason unknown");
    }

    // TRANSLATOR: In-chat message, arguments will be a duration and a few words (like "hung up")
    notification = formatMessage(_("Call ended ({0}): {1}"), {formatDuration(callEnded.duration_), notification});
    showMessageText(account, chat, message, NULL, notification.c_str());
}
