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

// Moves the device to a place and keeps it there, apart from nimbus_run's commands. Returns
// once the device is there. On failure, *error (when error isn't NULL) gets a message to free
// with nimbus_free_string.
bool nimbus_teleport(const char *udid, double latitude, double longitude, char **error);

// Puts the device back on its real location.
void nimbus_teleport_stop(void);

// Whether the device is held at a place. Turns false when the connection is lost, which also
// puts the device back on its real location.
bool nimbus_teleport_active(void);

// Frees a string the engine handed out.
void nimbus_free_string(char *text);

#endif
