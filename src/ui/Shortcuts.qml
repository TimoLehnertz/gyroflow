// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2022 Maik <myco at gmx>

import QtQuick

import Gyroflow
import "components/"

Item {
    property VideoArea videoArea;

    // Play/Pause
    Shortcut {
        sequences: ["Space", "F3"];
        onActivated: {
            if (videoArea.vid.playing) videoArea.vid.pause();
            else                       videoArea.vid.play();
        }
    }
    // Previous frame
    Shortcut {
        sequences: ["Left", "Page Up", ",", "F2"];
        onActivated:  videoArea.vid.seekToFrameDelta(-1);
    }
    // Previous trim range start / end
    Shortcut {
        sequences: ["Ctrl+Left", "Ctrl+Page Up", "Ctrl+,", "F5"];
        onActivated: videoArea.timeline.jumpToPrevTrimBoundary();
    }
    // Next frame
    Shortcut {
        sequences: ["Right", "Page Down", ".", "F4"];
        onActivated: videoArea.vid.seekToFrameDelta(1);
    }
    // Next trim range start / end
    Shortcut {
        sequences: ["Ctrl+Right", "Ctrl+Page Down", "Ctrl+.", "F6"];
        onActivated: videoArea.timeline.jumpToNextTrimBoundary();
    }
    // Go to trim start
    Shortcut {
        sequences: ["Home", "H"];
        onActivated: {
            let closestRange = videoArea.timeline.closestTrimRange(videoArea.timeline.position, true);
            if (closestRange == -1) closestRange = 0;
            videoArea.vid.currentFrame = videoArea.timeline.frameAtPosition(videoArea.timeline.getTrimRanges()[closestRange][0]) + 1;
        }
    }
    // Go to trim end
    Shortcut {
        sequences: ["End", ";"];
        onActivated: {
            let closestRange = videoArea.timeline.closestTrimRange(videoArea.timeline.position, false);
            if (closestRange == -1) closestRange = 0;
            videoArea.vid.currentFrame = videoArea.timeline.frameAtPosition(videoArea.timeline.getTrimRanges()[closestRange][1]) - 1;
        }
    }
    // Set trim start here
    Shortcut {
        sequences: ["i", "["];
        onActivated: {
            videoArea.timeline.setTrimStart(videoArea.timeline.closestTrimRange(videoArea.timeline.position, true), videoArea.timeline.position);
        }
    }
    // Set trim end here
    Shortcut {
        sequences: ["o", "]"];
        onActivated: {
            videoArea.timeline.setTrimEnd(videoArea.timeline.closestTrimRange(videoArea.timeline.position, false), videoArea.timeline.position);
        }
    }
    // Add new trim start here
    Shortcut {
        sequences: ["Ctrl+i", "Ctrl+["];
        onActivated: {
            videoArea.timeline.addTrimStart(videoArea.timeline.position);
        }
    }
    // Add new trim end here
    Shortcut {
        sequences: ["Ctrl+o", "Ctrl+]"];
        onActivated: {
            videoArea.timeline.addTrimEnd(videoArea.timeline.position);
        }
    }
    // Delete the active trim range, after a confirmation (the media list uses the key itself while it has the focus)
    Shortcut {
        sequences: ["Delete", "Backspace"];
        enabled: videoArea.timeline.trimRanges.length > 0 && videoArea.timeline.activeTrimRange >= 0 && !window.isDialogOpened
                 && !(window.mediaPanel && window.mediaPanel.listHasFocus);
        onActivated: {
            const index = videoArea.timeline.activeTrimRange;
            messageBox(Modal.Question, qsTr("Delete trim range %1?").arg(index + 1), [
                { text: qsTr("Delete"), accent: true, clicked: () => videoArea.timeline.removeTrimRange(index) },
                { text: qsTr("Cancel") },
            ]);
        }
    }
    // Clear trim range
    Shortcut {
        sequence: "c";
        onActivated: videoArea.timeline.resetTrim();
    }
    // Mute on/off
    Shortcut {
        sequence: "m";
        onActivated: videoArea.vid.muted = !videoArea.vid.muted;
    }
    // Stabilization on/off
    Shortcut {
        sequence: "s";
        onActivated: videoArea.stabEnabledBtn.checked = !videoArea.stabEnabledBtn.checked;
    }

    // Stabilization overview on/off
    Shortcut {
        sequence: "d";
        onActivated: videoArea.fovOverviewBtn.checked = !videoArea.fovOverviewBtn.checked;
    }

    // Stabilization overview split view
    Shortcut {
        sequence: "v";
        onActivated: videoArea.secondPreview.show = !videoArea.secondPreview.show;
    }

    // Hide chart axis X
    Shortcut {
        sequence: "x";
        onActivated: videoArea.timeline.toggleAxis(0, false);
    }
    // Hide chart axis Y
    Shortcut {
        sequence: "y";
        onActivated: videoArea.timeline.toggleAxis(1, false);
    }
    // Hide chart axis Z
    Shortcut {
        sequence: "z";
        onActivated: videoArea.timeline.toggleAxis(2, false);
    }
    // Hide chart axis W
    Shortcut {
        sequence: "w";
        onActivated: videoArea.timeline.toggleAxis(3, false);
    }

    // Show chart axis X
    Shortcut {
        sequence: "Shift+x";
        onActivated: videoArea.timeline.toggleAxis(0, true);
    }
    // Show chart axis Y
    Shortcut {
        sequence: "Shift+y";
        onActivated: videoArea.timeline.toggleAxis(1, true);
    }
    // Show chart axis Z
    Shortcut {
        sequence: "Shift+z";
        onActivated: videoArea.timeline.toggleAxis(2, true);
    }
    // Show chart axis W
    Shortcut {
        sequence: "Shift+w";
        onActivated: videoArea.timeline.toggleAxis(3, true);
    }

    // Chart display mode: Gyroscope
    Shortcut {
        sequence: "shift+g";
        onActivated: videoArea.timeline.setDisplayMode(0);
    }
    // Chart display mode: Accelerometer
    Shortcut {
        sequence: "shift+a";
        onActivated: videoArea.timeline.setDisplayMode(1);
    }
    // Chart display mode: Magnetometer
    Shortcut {
        sequence: "shift+m";
        onActivated: videoArea.timeline.setDisplayMode(2);
    }
    // Chart display mode: Quaternions
    Shortcut {
        sequence: "shift+q";
        onActivated: videoArea.timeline.setDisplayMode(3);
    }

    // One second forward / back
    Shortcut {
        sequence: "Shift+Right";
        onActivated: videoArea.vid.seekToFrameDelta(Math.max(1, Math.round(videoArea.vid.frameRate)));
    }
    Shortcut {
        sequence: "Shift+Left";
        onActivated: videoArea.vid.seekToFrameDelta(-Math.max(1, Math.round(videoArea.vid.frameRate)));
    }
    // Next keyframe
    Shortcut {
        sequences: ["Shift+Page Down"];
        onActivated: videoArea.timeline.jumpToNextKeyframe("");
    }
    // Previous keyframe
    Shortcut {
        sequences: ["Shift+Page Up"];
        onActivated: videoArea.timeline.jumpToPrevKeyframe("");
    }

    // Timeline: Auto sync here
    Shortcut {
        sequence: "a";
        onActivated: videoArea.timeline.addAutoSyncPoint(videoArea.timeline.position);
    }
    // Timeline: Add manual sync point here
    Shortcut {
        sequence: "p";
        onActivated: videoArea.timeline.addManualSyncPoint(videoArea.timeline.position);
    }

    // Close the render queue, or exit full screen mode
    Shortcut {
        sequence: "Esc";
        enabled: !(typeof window !== "undefined" && window.globalSettings && window.globalSettings.opened); // Esc closes the settings
        onActivated: {
            const queueModal = window.mediaPanel? window.mediaPanel.queueModal.item : null;
            if (queueModal && queueModal.shown) {
                queueModal.shown = false;
            } else if (window.videoDetails && window.videoDetails.shown) {
                window.videoDetails.shown = false;
            } else {
                videoArea.fullScreen = 0;
            }
        }
    }

    // Toggle full screen mode
    Shortcut {
        sequences: ["F11", "F"];
        onActivated: videoArea.fullScreen = (videoArea.fullScreen + 1) % 3;
    }

    // Add the active trim range to the render queue or remove it (the whole video without separate ranges)
    Shortcut {
        sequence: "q";
        onActivated: if (!videoArea.isCalibrator) window.renderBtn.toggleActiveRange();
    }
    // Add the whole video (all of its ranges) to the render queue, or remove it if all of it is queued. On macOS Ctrl is
    // Cmd for Qt, and Cmd+Q quits, so it's Control+Q there (Meta for Qt)
    Shortcut {
        sequence: Qt.platform.os == "osx"? "Meta+Q" : "Ctrl+Q";
        onActivated: if (!videoArea.isCalibrator) window.renderBtn.toggleClip();
    }

    // Stabilize this video now
    Shortcut {
        sequence: "Ctrl+W";
        onActivated: window.renderBtn.stabilizeNow();
    }

    // Save project file
    Shortcut {
        sequence: "Ctrl+s";
        onActivated: window.saveProject("");
    }

    // Toggle grid guide
    Shortcut {
        sequence: "G";
        onActivated: videoArea.gridGuide.shown = !videoArea.gridGuide.shown;
    }
    // Grid guide color white/black
    Shortcut {
        sequence: "Ctrl+G";
        onActivated: videoArea.gridGuide.isBlack = !videoArea.gridGuide.isBlack;
    }

    // J / K / L playback, as in DaVinci Resolve: J plays backward and L forward, pressed again they shuttle faster
    // (2x, 4x, 8x, 16x), K stops. Holding K with J or L plays slowly, and tapping J or L while K is held steps one frame.
    QtObject {
        id: transport;
        property bool jDown: false;
        property bool kDown: false;
        property bool lDown: false;
        // Signed speed of the shuttle, 0 when stopped
        property real rate: 0;
        // Playing slowly while K and J / L are held, it stops when one of them is released
        property bool slow: false;
        // The playback speed chosen in the video area, the shuttle speeds are multiples of it
        property real baseRate: 1;

        function setRate(r: real): void {
            const vid = videoArea.vid;
            if (transport.rate == 0) transport.baseRate = vid.playbackRate > 0? vid.playbackRate : 1;
            transport.rate = r;
            if (r > 0) {
                reverseTimer.stop();
                vid.playbackRate = r * transport.baseRate;
                vid.play();
            } else if (r < 0) {
                vid.pause();
                reverseTimer.begin(-r * transport.baseRate);
            } else {
                reverseTimer.stop();
                vid.pause();
                vid.playbackRate = transport.baseRate;
                transport.slow = false;
            }
        }
        function shuttle(dir: int): void {
            transport.slow = false;
            // Faster in the same direction, otherwise normal speed in this one
            if (Math.sign(transport.rate) == dir && Math.abs(transport.rate) >= 1) {
                transport.setRate(dir * Math.min(16, Math.abs(transport.rate) * 2));
            } else {
                transport.setRate(dir);
            }
        }
        function pressed(dir: int): void {
            if (!videoArea.vid.loaded) return;
            if (transport.kDown) {
                // One frame, and playing slowly if the key stays down
                transport.setRate(0);
                videoArea.vid.seekToFrameDelta(dir);
                slowTimer.dir = dir;
                slowTimer.restart();
            } else {
                transport.shuttle(dir);
            }
        }
        function released(): void {
            slowTimer.stop();
            if (transport.slow) transport.setRate(0);
        }
    }
    Timer {
        id: slowTimer;
        interval: 300;
        property int dir: 1;
        onTriggered: {
            if (transport.kDown && (dir > 0? transport.lDown : transport.jDown)) {
                transport.setRate(dir * 0.25);
                transport.slow = true;
            }
        }
    }
    // The player doesn't play backward, so it seeks back in steps, keeping the speed by the time that passed
    Timer {
        id: reverseTimer;
        interval: 40;
        repeat: true;
        property real speed: 1;
        property real lastTime: 0;
        property real frame: 0;
        function begin(speed: real): void {
            reverseTimer.speed = speed;
            reverseTimer.lastTime = Date.now();
            reverseTimer.frame = videoArea.vid.currentFrame;
            reverseTimer.restart();
        }
        onTriggered: {
            const vid = videoArea.vid;
            const now = Date.now();
            reverseTimer.frame -= (now - reverseTimer.lastTime) / 1000 * vid.frameRate * reverseTimer.speed;
            reverseTimer.lastTime = now;
            if (reverseTimer.frame <= 0) {
                vid.currentFrame = 0;
                transport.setRate(0);
                return;
            }
            const target = Math.round(reverseTimer.frame);
            if (target != vid.currentFrame) vid.currentFrame = target;
        }
    }
    Connections {
        target: videoArea.vid;
        // Played or paused another way (eg. Space or the play button) while going backward
        function onPlayingChanged(): void {
            if (videoArea.vid.playing && transport.rate < 0) {
                reverseTimer.stop();
                transport.rate = 0;
                transport.slow = false;
                videoArea.vid.playbackRate = transport.baseRate;
            } else if (!videoArea.vid.playing && transport.rate > 0) {
                transport.rate = 0;
                transport.slow = false;
                videoArea.vid.playbackRate = transport.baseRate;
            }
        }
    }
    Connections {
        target: ui_tools;
        function onTransport_key(key: int, pressed: bool): void {
            if (key == Qt.Key_K) {
                transport.kDown = pressed;
                if (pressed) transport.setRate(0);
                else transport.released();
            } else if (key == Qt.Key_J) {
                transport.jDown = pressed;
                if (pressed) transport.pressed(-1);
                else transport.released();
            } else if (key == Qt.Key_L) {
                transport.lDown = pressed;
                if (pressed) transport.pressed(1);
                else transport.released();
            }
        }
    }

    // Horizon lock roll adjustment shortcuts
    function hlRollAdjust(v: real): void {
        if (window.stab.horizonCb.checked) {
            window.stab.horizonRollSlider.field.value += v;
        }
    }
    Shortcut { sequence: "E";       onActivated: hlRollAdjust(0.5);  }
    Shortcut { sequence: "Ctrl+E";  onActivated: hlRollAdjust(0.1);  }
    Shortcut { sequence: "Alt+E";   onActivated: hlRollAdjust(1);    }
    Shortcut { sequence: "Shift+E"; onActivated: hlRollAdjust(5);    }
    Shortcut { sequence: "R";       onActivated: hlRollAdjust(-0.5); }
    Shortcut { sequence: "Ctrl+R";  onActivated: hlRollAdjust(-0.1); }
    Shortcut { sequence: "Alt+R";   onActivated: hlRollAdjust(-1);   }
    Shortcut { sequence: "Shift+R"; onActivated: hlRollAdjust(-5);   }

    // Save and open next queue item
    Shortcut {
        sequence: "Ctrl+Shift+D";
        onActivated: loadQueueItem(render_queue.get_next_item_id(render_queue.editing_job_id));
    }

    // Save and open prev queue item
    Shortcut {
        sequence: "Ctrl+Shift+A";
        onActivated: loadQueueItem(render_queue.get_prev_item_id(render_queue.editing_job_id));
    }

    function loadQueueItem(new_id: int): void {
        const current_id = render_queue.editing_job_id;
        if (current_id > 0) {
            // Save
            videoArea.vid.grabToImage(function(result) {
                render_queue.add(window.getAdditionalProjectDataJson(), controller.image_to_b64(result.image));
                if (new_id > 0) {
                    const data = render_queue.get_gyroflow_data(new_id);
                    videoArea.loadGyroflowData(JSON.parse(data), new_id);
                }
            });
        }
    }

    // Next file in folder
    Shortcut {
        sequence: "Ctrl+D";
        onActivated: {
            const url = filesystem.get_next_file_url(videoArea.loadedFileUrl, 1);
            if (url && url.toString()) videoArea.loadFile(url);
        }
    }

    // Previous file in folder. While the media list has the focus, Ctrl+A selects all of its items instead
    Shortcut {
        sequence: "Ctrl+A";
        enabled: !(window.mediaPanel && window.mediaPanel.listHasFocus);
        onActivated: {
            const url = filesystem.get_next_file_url(videoArea.loadedFileUrl, -1);
            if (url && url.toString()) videoArea.loadFile(url);
        }
    }
}
