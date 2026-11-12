// C interface of the Nimbus engine. See src/ffi.rs.

#ifndef NIMBUS_CORE_H
#define NIMBUS_CORE_H

#include <stdbool.h>

// Receives one event as JSON text. The text is only valid during the call.
// Can be called from any thread.
typedef void (*nimbus_callback)(void *context, const char *json);

// Sets the device to connect to and the identity to report to Apple:
// {"local_device": {"address": "10.7.0.1", "pairing_file": "/path"}, "client_info": "...", "user_agent": "..."}
bool nimbus_configure(const char *json);

// Runs a command and returns once it's finished: {"command": "apps", "args": ["UDID"], "request": {...}}.
// Returns whether it succeeded. One command runs at a time; a second call waits for the first.
bool nimbus_run(const char *json, nimbus_callback callback, void *context);

// Answers the prompt the running command is waiting on.
void nimbus_reply(const char *json);

// Stops the running command.
void nimbus_cancel(void);

#endif
