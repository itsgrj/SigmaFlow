// SigmaFlow's bridge to MediaRemote, the private framework behind the Now Playing widget
// and the keyboard's play/pause key.
//
// Since macOS 15.4, MediaRemote answers "nothing playing" to any process without Apple's
// private entitlement: MRMediaRemoteGetNowPlayingApplicationIsPlaying reports false while a
// video is audibly playing, and commands sent from the app go nowhere. Apple's own platform
// binaries pass that check, and /usr/bin/perl is one that will load an arbitrary dylib — its
// DynaLoader exists to load CPAN extensions, so it carries no library validation. This dylib
// is that "extension": its constructor runs the moment perl dlopen()s it, performs the one
// command named by SIGMAFLOW_MEDIA_COMMAND, prints one word on stdout, and exits the perl
// process. Core/MediaPauser.swift is the caller.
//
// Nothing here links MediaRemote at build time. Every symbol is looked up at runtime, so a
// renamed symbol degrades to "error", never to a crash.
//
//   SIGMAFLOW_MEDIA_COMMAND   stdout                exit
//   status                    playing | paused      0
//   pause                     paused  | idle        0    paused = we paused it; idle = nothing was playing
//   play                      playing               0
//   (any failure)             error <reason>        1-3

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*IsPlayingFn)(dispatch_queue_t queue, void (^completion)(bool playing));
typedef bool (*SendCommandFn)(int command, const void *options);

enum { kMRPlay = 0, kMRPause = 1 };

static void fail(const char *reason, int code) {
    printf("error %s\n", reason);
    fflush(stdout);
    exit(code);
}

/// A command is asynchronous XPC: exiting straight after the send drops the message on the
/// floor (verified — the first cut of this file "succeeded" and paused nothing). A short wait
/// and then a round trip to mediaremoted guarantee delivery before the process exits.
static void flush(IsPlayingFn query) {
    usleep(100 * 1000);
    __block bool ignored = false;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    query(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(bool value) {
        ignored = value;
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    (void)ignored;
}

/// One round trip to mediaremoted.
static bool isPlaying(IsPlayingFn query) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block bool playing = false;
    query(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(bool value) {
        playing = value;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        fail("timeout", 2);
    }
    return playing;
}

__attribute__((constructor))
static void sigmaflow_media_host_main(void) {
    const char *command = getenv("SIGMAFLOW_MEDIA_COMMAND");
    if (command == NULL) command = "status";

    void *mediaRemote = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (mediaRemote == NULL) fail("no-framework", 3);
    IsPlayingFn query =
        (IsPlayingFn)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    SendCommandFn send = (SendCommandFn)dlsym(mediaRemote, "MRMediaRemoteSendCommand");
    if (query == NULL || send == NULL) fail("no-symbol", 3);

    if (strcmp(command, "status") == 0) {
        printf(isPlaying(query) ? "playing\n" : "paused\n");
    } else if (strcmp(command, "pause") == 0) {
        // Look before pausing: a pause sent into a quiet room is harmless, but the caller
        // resumes only what it stopped, and this is where it learns whether it stopped anything.
        if (!isPlaying(query)) {
            printf("idle\n");
        } else {
            if (!send(kMRPause, NULL)) fail("rejected", 1);
            flush(query);
            printf("paused\n");
        }
    } else if (strcmp(command, "play") == 0) {
        if (!send(kMRPlay, NULL)) fail("rejected", 1);
        flush(query);
        printf("playing\n");
    } else {
        fail("unknown-command", 1);
    }
    fflush(stdout);
    exit(0);
}
