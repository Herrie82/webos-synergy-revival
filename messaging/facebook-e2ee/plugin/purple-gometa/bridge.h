#pragma once

#include <purple.h> // PurpleAccount
#include <time.h>   // time_t

// Message types crossing the Go -> purple boundary.
enum gometa_message_type {
    gometa_message_type_error,        // text = error message; fatal = connection-fatal
    gometa_message_type_connected,    // account reached CONNACK / send-ready
    gometa_message_type_disconnected, // account went offline
    gometa_message_type_text,         // incoming text message (who/text/timestamp)
};

// Flat struct used to hand data from Go goroutines to libpurple. libpurple is NOT
// thread-safe, so gometa_process_message() (implemented in the C glue) takes ownership
// of the malloc'd char* fields and marshals delivery onto the glib main thread.
typedef struct gometa_message {
    PurpleAccount *account; // account this message belongs to
    char *who;              // conversation / sender id (Facebook id as string)
    char *name;             // sender display name (optional)
    char *text;             // payload / error text
    char *id;               // message id (optional)
    time_t timestamp;       // seconds since epoch (0 = now)
    char msgtype;           // enum gometa_message_type
    char isGroup;           // 1 if a group/thread message
    char isOutgoing;        // 1 if an echo of our own outgoing message
    char fatal;             // for error type: 1 = should disconnect the account
} gometa_message_t;

// Go -> purple. C glue owns/free()s the char* fields and schedules onto the main thread.
extern void gometa_process_message(gometa_message_t msg);
