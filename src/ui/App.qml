// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import QtQuick.Dialogs

import "."
import "components/"
// `Menu` is the namespace of the side panels here, the menu component is `Components.Menu`
import "components/" as Components
import "menu/" as Menu
import "Util.js" as Util;

Rectangle {
    id: window;
    visible: true
    color: styleBackground;
    anchors.fill: parent;

    property QtObject controller: main_controller;

    property bool isLandscape: width > height;
    property bool mediaPanelShown: +settings.value("mediaPanelShown", 1) > 0;
    onMediaPanelShownChanged: settings.setValue("mediaPanelShown", mediaPanelShown? 1 : 0);
    property real mediaPanelWidth: mediaPanel.visible? mediaPanel.width : 0;
    onIsLandscapeChanged: {
        if (isLandscape) {
            // Landscape layout
            rightPanel.x = Qt.binding(() => window.mediaPanelWidth + videoAreaCol.width);
            rightPanel.y = 0;
            videoAreaCol.x = Qt.binding(() => (videoArea.fullScreen? 0 : window.mediaPanelWidth));
            videoAreaCol.width = Qt.binding(() => mainLayout.width - (videoArea.fullScreen? 0 : window.mediaPanelWidth + rightPanel.width));
            videoAreaCol.height = Qt.binding(() => mainLayout.height);
            rightPanel.fixedWidth = 0;
        } else {
            // Portrait layout
            videoAreaCol.y = 0;
            videoAreaCol.x = 0;
            videoAreaCol.width = Qt.binding(() => window.width);
            videoAreaCol.height = Qt.binding(() => window.height * (videoArea.fullScreen? 1 : (window.isMobileLayout? (window.videoArea.vid.loaded && window.videoArea.vid.height > window.videoArea.vid.width? 0.6 : 0.4) : 0.5)));
            rightPanel.fixedWidth = Qt.binding(() => window.width);
            rightPanel.x = 0;
            rightPanel.y = Qt.binding(() => videoAreaCol.height);
        }
    }
    // property bool isMobileLayout: width < (1500 * dpiScale);
    property bool isMobileLayout: ((isMobile && screenSize < 7.0) || forceMobileLayout) && !forceDesktopLayout;
    onIsMobileLayoutChanged: {
        if (isMobileLayout) {
            vidInfo      .parent = inputsTab.inner;
            vidInfoHr    .parent = inputsTab.inner;
            lensProfile  .parent = inputsTab.inner;
            lensProfileHr.parent = inputsTab.inner;
            motionData   .parent = inputsTab.inner;

            sync    .parent = paramsTab.inner;
            syncHr  .parent = paramsTab.inner;
            stab    .parent = paramsTab.inner;
            stabHr  .parent = paramsTab.inner;
            advanced.parent = paramsTab.inner;
            advancedHr.parent = paramsTab.inner;
            nlePlugins.parent = paramsTab.inner;
            mobileSettingsBtn.parent = paramsTab.inner;

            outputPathLabel.parent = exportTab.inner;
            renderBtnRow   .parent = exportTab.inner;
            exportSettings .parent = exportTab.inner;
        } else {
            vidInfo      .parent = videoDetails.col;
            vidInfoHr    .parent = videoDetails.col;
            lensProfile  .parent = videoDetails.col;
            lensProfileHr.parent = videoDetails.col;
            motionData   .parent = videoDetails.col;

            sync          .parent = rightPanel.col;
            syncHr        .parent = rightPanel.col;
            stab          .parent = rightPanel.col;
            stabHr        .parent = rightPanel.col;
            exportSettings.parent = rightPanel.col;
            exportHr      .parent = rightPanel.col;
            advanced      .parent = rightPanel.col;
            advancedHr    .parent = rightPanel.col;
            nlePlugins    .parent = rightPanel.col;

            outputPathLabel.parent = exportbar;
            renderBtnRow   .parent = exportbar;
        }
    }
    property alias vidInfo: vidInfo.item;
    property alias videoArea: videoArea;
    property alias mediaPanel: mediaPanel;
    property alias videoDetails: videoDetails;
    property alias motionData: motionData.item;
    property alias lensProfile: lensProfile.item;
    property alias outputFile: outputFile;
    property alias sync: sync.item;
    property alias stab: stab.item;
    property alias exportSettings: exportSettings.item;
    property alias advanced: advanced.item;
    property alias globalSettings: globalSettings.item;
    property alias renderBtn: renderBtn;

    readonly property bool stabilizationEnabled: !exportSettings.item || exportSettings.item.stabilizationEnabled;

    readonly property bool wasModified: window.videoArea.vid.loaded;
    property bool isDialogOpened: false;

    FileDialog {
        id: fileDialog;
        property var extensions: [ "mp4", "mov", "mxf", "mkv", "webm", "insv", "ffconcat", "gyroflow", "png", "jpg", "exr", "dng", "braw", "r3d", "nev" ];

        title: qsTr("Choose a video file")
        nameFilters: Qt.platform.os == "android"? undefined : [qsTr("Video files") + " (*." + extensions.concat(extensions.map(x => x.toUpperCase())).join(" *.") + ")"];
        type: "video";
        fileMode: FileDialog.OpenFiles;
        onAccepted: videoArea.loadMultipleFiles(selectedFiles, false);
    }

    property string pendingLoadPreset: loadPresetOnStart;
    property url pendingOpenFileOrg: openFileOnStart;
    property url pendingOpenFile: pendingOpenFileOrg;
    onPendingOpenFileOrgChanged: { pendingOpenFile = pendingOpenFileOrg; onItemLoaded(); }
    Connections {
        target: filesystem;
        function onUrl_opened(url: url): void { pendingOpenFileOrg = ""; pendingOpenFileOrg = url; }
    }
    function onItemLoaded(): void {
        if (window.vidInfo && window.stab && window.exportSettings && window.sync && window.motionData && pendingOpenFile.toString()) {
            pendingFileLoadTimer.start();
        }
        tabs.updateHeights();
    }
    Timer {
        id: pendingFileLoadTimer;
        interval: 250;
        running: false;
        onTriggered: {
            if (pendingOpenFile.toString()) {
                videoArea.loadFile(pendingOpenFile);
                pendingOpenFile = "";
            }
        }
    }

    Item {
        id: mainLayout;
        width: parent.width;
        height: parent.height - y;

        MediaSidebar {
            id: mediaPanel;
            visible: window.mediaPanelShown && !videoArea.fullScreen && !isMobileLayout && window.isLandscape;
            maxWidth: parent.width - rightPanel.lastWidth - 50 * dpiScale;
            implicitWidth: settings.value("mediaPanelSize", defaultWidth);
            onWidthChanged: settings.setValue("mediaPanelSize", width);
        }

        Column {
            id: videoAreaCol;
            y: 0;
            x: videoArea.fullScreen? 0 : window.mediaPanelWidth;
            width: parent? parent.width - (videoArea.fullScreen? 0 : window.mediaPanelWidth + rightPanel.width) : 0;
            height: parent? parent.height : 0;
            VideoArea {
                id: videoArea;
                height: parent.height - (videoArea.fullScreen || isMobileLayout? 0 : exportbar.height);
                vidInfo: vidInfo.item;
            }

            // Bottom bar
            Rectangle {
                id: exportbar;
                width: parent.width;
                height: Math.max(60 * dpiScale, renderBtnRow.height + 16 * dpiScale);
                color: styleBackground2;
                visible: !isMobileLayout;

                Hr { width: parent.width; }

                // With trim ranges exported as separate videos, every range has its own output path,
                // the one of the active range (the one the playhead is in, or was in last) is shown
                readonly property int rangeCount: videoArea.timeline.trimRanges.length;
                readonly property bool separateRanges: !!exportSettings.item && exportSettings.item.exportTrimsSeparately.checked;
                // The media list is hidden with the button in its header, and shown again here
                LinkButton {
                    id: showMediaBtn;
                    visible: !window.mediaPanelShown && !videoArea.isCalibrator;
                    x: 6 * dpiScale;
                    anchors.verticalCenter: parent.verticalCenter;
                    width: visible? 30 * dpiScale : 0;
                    height: 30 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "chevron-right";
                    tooltip: qsTr("Show the media list");
                    onClicked: window.mediaPanelShown = true;
                }
                ComboBox {
                    id: rangesModeBox;
                    x: showMediaBtn.visible? showMediaBtn.x + showMediaBtn.width + 6 * dpiScale : 10 * dpiScale;
                    visible: exportbar.rangeCount > 1;
                    anchors.verticalCenter: parent.verticalCenter;
                    width: visible? 165 * dpiScale : 0;
                    height: 28 * dpiScale;
                    font.pixelSize: 12 * dpiScale;
                    // Ranges with their own settings can only be exported as separate videos, so it's one choice.
                    // The list explains them, the box shows a short name
                    model: [QT_TRANSLATE_NOOP("Popup", "One video per range"), QT_TRANSLATE_NOOP("Popup", "One video per range, separate settings"), QT_TRANSLATE_NOOP("Popup", "Join ranges into one video")];
                    displayText: [qsTr("Per range"), qsTr("Per range, own settings"), qsTr("Joined")][currentIndex] || "";
                    currentIndex: videoArea.separateRangeSettings? 1 : exportbar.separateRanges? 0 : 2;
                    onActivated: (index) => {
                        videoArea.setSeparateRangeSettings(index == 1);
                        exportSettings.item.exportTrimsSeparately.checked = index != 2;
                        currentIndex = Qt.binding(() => videoArea.separateRangeSettings? 1 : exportbar.separateRanges? 0 : 2);
                        // A queued video is rendered in the new mode: the whole video joined, or every range on its own
                        Qt.callLater(mediaPanel.saveCurrentSettings);
                    }
                    tooltip: qsTr("Export every trim range as its own video, with the same or with its own stabilization and export settings, or all of them joined into one video");
                }
                Label {
                    x: rangesModeBox.x + rangesModeBox.width + (rangesModeBox.visible? 10 : 0) * dpiScale;
                    id: outputPathLabel;
                    anchors.verticalCenter: (isMobileLayout? undefined : parent.verticalCenter);
                    anchors.verticalCenterOffset: -1 * dpiScale;
                    text: exportbar.separateRanges && exportbar.rangeCount > 1 && videoArea.timeline.activeTrimRange >= 0?
                          qsTr("Range %1:").arg(videoArea.timeline.activeTrimRange + 1) : qsTr("Output:");
                    position: isMobileLayout? Label.TopPosition : Label.LeftPosition;
                    // The path is shown elided, it doesn't need the whole bar
                    width: Math.min(380 * dpiScale, parent.width - (isMobileLayout? 0 : renderBtnRow.width + 10 * dpiScale) - x - 10 * dpiScale);
                    OutputPathField {
                        id: outputFile;
                        onFolderUrlChanged: {
                            if (exportSettings.item.preserveOutputPath.checked) {
                                const outputFolder = folderUrl.toString();
                                if (outputFolder) settings.setValue("preservedOutputPath", outputFolder);
                            }
                        }
                    }
                }

                Row {
                    id: renderBtnRow;
                    anchors.right: (isMobileLayout? undefined : parent.right);
                    anchors.rightMargin: 5 * dpiScale;
                    spacing: 5 * dpiScale;
                    anchors.verticalCenter: (isMobileLayout? undefined : parent.verticalCenter);
                    anchors.horizontalCenter: (isMobileLayout? parent.horizontalCenter : undefined);

                    // The queue and the direct export are separate, always visible buttons now, no dropdown.
                    // `renderBtn` is the shared logic of both, the buttons below only pick the action.
                    Item {
                        id: renderBtn;
                        width: 0; height: 0; visible: false;

                        // Whether the item loaded in the main view is in the render queue right now
                        // Any of its keys is queued (also while their jobs are added, see `mediaPanel.keyStates`)
                        readonly property bool isQueued: Object.keys(mediaPanel.keyStates).length > 0;
                        property bool allowFile: false;
                        property bool allowLens: false;
                        property bool allowSync: false;
                        // "queue" adds it to the render queue, "now" renders it right away, overruling the queue
                        property string pendingAction: "queue";
                        // Job started by "Stabilize now" and the queue state to restore when it's done.
                        // With trim ranges exported as separate videos, the jobs of the other ranges render after it
                        property int directJobId: 0;
                        property var directNextJobs: [];
                        // The trim range "Stabilize now" renders, -1 for all of them
                        property int directRange: -1;
                        property bool resumeQueueAfter: false;

                        readonly property bool canExport: window.videoArea.vid.loaded && outputFile.filename.length > 3
                                                       && exportSettings.item && exportSettings.item.canExport && !videoArea.videoLoader.active;

                        property bool addQueueDelayed: false;
                        Timer { id: delayAddQueue; interval: 2000; onTriggered: renderBtn.addQueueDelayed = false; }

                        function startAction(action: string): void {
                            // A path that's still being typed is the one to render to
                            outputFile.commit();
                            renderBtn.pendingAction = action;
                            renderBtn.allowFile = false;
                            renderBtn.allowLens = false;
                            renderBtn.allowSync = false;
                            window.videoArea.vid.pause();
                            renderBtn.render();
                        }
                        // Adding to or removing from the queue always goes through the media list
                        function toggleQueue(): void {
                            if (renderBtn.isQueued) {
                                mediaPanel.unqueueLoadedFile();
                            } else {
                                renderBtn.queueOnly(-1);
                            }
                        }
                        // The shortcuts, also written on the queue buttons
                        readonly property string rangeShortcut: "Q";
                        readonly property string clipShortcut: Qt.platform.os == "osx"? "⌃Q" : "Ctrl+Q";
                        readonly property bool allQueued: queuePerRange? queuedRangeCount >= exportbar.rangeCount : isQueued;
                        // Q: the active range, or the whole video without separate ranges
                        function toggleActiveRange(): void {
                            if (!canExport && !isQueued) return;
                            if (!queuePerRange) return renderBtn.toggleClip();
                            if (activeRangeQueued) mediaPanel.unqueueLoadedRange(activeRange);
                            else renderBtn.queueOnly(activeRange);
                        }
                        // Ctrl+Q: all of the video, the ranges that aren't queued yet, or out of the queue if all of it is
                        function toggleClip(): void {
                            if (renderBtn.allQueued) mediaPanel.unqueueLoadedFile();
                            else if (canExport) renderBtn.queueOnly(-1);
                        }
                        // The trim range "Queue" adds, -1 for all of them
                        property int queueRange: -1;
                        function queueOnly(range: int): void {
                            renderBtn.queueRange = range;
                            renderBtn.startAction("queue");
                        }
                        // With the trim ranges exported as separate videos, the queue button is about the active range
                        readonly property bool queuePerRange: canChooseRange && render_queue.editing_job_id <= 0;
                        readonly property int activeRange: videoArea.timeline.activeTrimRange;
                        // The queue state of the ranges, by the ids the timeline has for them (see `mediaPanel.keyStates`)
                        function rangeUid(i: int): string { const r = videoArea.timeline.trimRanges[i]; return r && r[2]? (r[2].uid || "") : ""; }
                        readonly property string activeRangeState: mediaPanel.keyStates[rangeUid(activeRange)] || "";
                        readonly property bool activeRangeQueued: activeRangeState.length > 0;
                        readonly property int queuedRangeCount: videoArea.timeline.trimRanges.filter((x, i) => !!mediaPanel.keyStates[rangeUid(i)]).length;
                        function stabilizeNow(): void { renderBtn.stabilizeRange(-1); }
                        function stabilizeRange(range: int): void {
                            renderBtn.directRange = range;
                            renderBtn.startAction("now");
                        }
                        // With several trim ranges exported as separate videos, "Stabilize now" asks if it's all of them or only the active one
                        readonly property bool canChooseRange: exportbar.separateRanges && exportbar.rangeCount > 1 && videoArea.timeline.activeTrimRange >= 0;
                        // The direct render is done, let the queue continue where it was paused
                        // Cancelled: the files of the other trim ranges aren't rendered either
                        function cancelDirectRender(): void {
                            for (const jobId of renderBtn.directNextJobs) render_queue.remove(jobId);
                            renderBtn.directNextJobs = [];
                            renderBtn.directRenderFinished();
                        }
                        // Hidden: it keeps rendering in the queue, and so do the files of the other trim ranges
                        function hideDirectRender(): void {
                            renderBtn.directNextJobs = [];
                            renderBtn.directRenderFinished();
                        }
                        function directRenderFinished(): void {
                            if (renderBtn.directNextJobs.length) {
                                const next = renderBtn.directNextJobs.shift();
                                renderBtn.directJobId = next;
                                render_queue.main_job_id = next;
                                render_queue.render_job(next);
                                return;
                            }
                            renderBtn.directJobId = 0;
                            if (renderBtn.resumeQueueAfter) {
                                renderBtn.resumeQueueAfter = false;
                                render_queue.start();
                            }
                        }
                        Connections {
                            target: render_queue;
                            function onRender_progress(job_id: real, progress: real, frame: int, total_frames: int, finished: bool, start_time: real, is_conversion: bool): void {
                                if (finished && renderBtn.directJobId > 0 && job_id == renderBtn.directJobId) renderBtn.directRenderFinished();
                            }
                        }

                        function render(): void {
                            const fname = vidInfo.item.filename.toLowerCase();
                            if (fname.endsWith('.braw') || ((fname.endsWith('.r3d') || fname.endsWith('.nev')) && !controller.find_redline()) || fname.endsWith('.dng')) {
                                messageBox(Modal.Info, qsTr("This format is not available for rendering.\nThe recommended workflow is to export project file and use one of [video editor plugins] (%1).").replace(/\[(.*?)\]/, '<a href="https://gyroflow.xyz/download#plugins"><font color="' + styleTextColor + '">$1</font></a>').arg("DaVinci Resolve, Adobe Premiere/Ae, Final Cut Pro"), [
                                    { text: qsTr("Ok"), accent: true }
                                ]);
                                return;
                            }
                            if (window.stabilizationEnabled && !controller.lens_loaded && !allowLens) {
                                messageBox(Modal.Warning, qsTr("Lens profile is not loaded, your result will be incorrect. Are you sure you want to render this file?"), [
                                    { text: qsTr("Yes"), clicked: () => { allowLens = true; renderBtn.render(); }},
                                    { text: qsTr("No"), accent: true },
                                ]);
                                return;
                            }
                            const usesQuats = ((motionData.item.hasQuaternions && motionData.item.integrationMethod === 0) || motionData.item.hasAccurateTimestamps) && motionData.item.filename == vidInfo.item.filename;
                            if (window.stabilizationEnabled && !usesQuats && controller.offsets_model.rowCount() == 0 && !allowSync) {
                                messageBox(Modal.Warning, qsTr("There are no sync points present, your result will be incorrect. Are you sure you want to render this file?"), [
                                    { text: qsTr("Yes"), clicked: () => { allowSync = true; renderBtn.render(); }},
                                    { text: qsTr("No"), accent: true },
                                ]);
                                return;
                            }
                            // With trim ranges exported as separate videos, the bottom bar shows only the file of the active range
                            const outputs = renderBtn.pendingAction == "now"? mediaPanel.loadedOutputs(renderBtn.directRange) : [];
                            const exists = filesystem.exists_in_folder(outputFile.folderUrl, outputFile.filename.replace("_%05d", "_00001"))
                                        || outputs.some(x => filesystem.exists_in_folder(x.output_folder, x.output_filename.replace("_%05d", "_00001")));
                            if ((exists || render_queue.file_exists_in_folder(outputFile.folderUrl, outputFile.filename)) && !allowFile) {
                                function overwrite() {
                                    allowFile = true;
                                    renderBtn.render();
                                }
                                function rename() {
                                    outputFile.setFilename(window.renameOutput(outputFile.filename, outputFile.folderUrl));
                                    renderBtn.render();
                                }

                                if (renderBtn.pendingAction == "queue" && render_queue.overwrite_mode === 1) {
                                    overwrite();
                                    showNotification(Modal.Info, qsTr("Added to queue") + ", " + qsTr("file %1 will be overwritten").arg(outputFile.filename))
                                } else if (renderBtn.pendingAction == "queue" && render_queue.overwrite_mode === 2) {
                                    rename();
                                    showNotification(Modal.Info, qsTr("Added to queue") + ", " + qsTr("file will be rendered to %1").arg(outputFile.filename))
                                } else {
                                    messageBox(Modal.Question, qsTr("Output file already exists, do you want to overwrite it?"), [
                                        { text: qsTr("Yes"), clicked: overwrite },
                                        { text: qsTr("Rename"), clicked: rename },
                                        { text: qsTr("No"), accent: true },
                                    ]);
                                }

                                return;
                            }

                            if (fname.endsWith('.r3d') && controller.find_redline()) {
                                messageBox(Modal.Info, "Gyroflow will use REDline to convert .R3D to ProRes before stabilizing in order to export from Gyroflow directly.\nIf you want to work on RAW data instead, export project file (Ctrl+S) and use one of [video editor plugins] (%1).".replace(/\[(.*?)\]/, '<a href="https://gyroflow.xyz/download#plugins"><font color="' + styleTextColor + '">$1</font></a>').arg("DaVinci Resolve, Final Cut Pro"), [
                                    { text: qsTr("Ok"), accent: true }
                                ], undefined, Text.StyledText, "r3d-conversion" );
                            }

                            const encoder = render_queue.get_default_encoder(window.exportSettings.outCodec, window.exportSettings.outGpu);
                            if ((encoder + "").endsWith("_amf") && window.exportSettings.outBitrate > 100) {
                                messageBox(Modal.Info, qsTr("Some AMD GPU encoders have a bug where it limits the bitrate to 20 Mbps, if the target bitrate is greater than 100 Mbps.\n\n" +
                                                            "Please check the file bitrate after rendering and if you're affected by this bug, you can either:\n" +
                                                            "- Set output bitrate to less than 100 Mbps\n" +
                                                            "- Use \"Custom encoder options\": `-rc cqp -qp_i 28 -qp_p 28`"), [
                                    { text: qsTr("Ok") },
                                ], undefined, Text.MarkdownText, "amd-bitrate-warning");
                            }

                            videoArea.vid.grabToImage(function(result) {
                                if (isSandboxed && (!outputFile.folderUrl.toString() || !filesystem.can_create_file(outputFile.folderUrl, outputFile.filename))) {
                                    let el = messageBox(Modal.Info, qsTr("Due to file access restrictions, you need to select the destination folder manually.\nClick Ok and select the destination folder."), [
                                        { text: qsTr("Ok"), clicked: () => {
                                            outputFile.selectFolder(outputFile.folderUrl, function(_) { renderBtn.render(); });
                                        }},
                                    ], undefined, Text.AutoText, "file-access-restriction");
                                    if (!el) { // Don't show again triggered
                                        outputFile.selectFolder(outputFile.folderUrl, function(_) { renderBtn.render(); });
                                    }
                                    return;
                                }
                                if (isMobile) {
                                    messageBox(Modal.Info, qsTr("Keep this app in the foreground and don't lock the screen.\nDue to limitations of the system video encoders, rendering in the background is not supported."), [
                                        { text: qsTr("Ok") },
                                    ], undefined, Text.AutoText, "keep-in-foreground");
                                }

                                if (renderBtn.pendingAction == "queue") {
                                    // The media list is the single source of truth for the queue, so instead of creating
                                    // a job here, queue the loaded item there. Saving an edited job still goes directly.
                                    if (render_queue.editing_job_id > 0 || mediaPanel.queueLoadedFile(renderBtn.queueRange) <= 0) {
                                        render_queue.add(window.getAdditionalProjectDataJson(), controller.image_to_b64(result.image));
                                    }
                                    renderBtn.addQueueDelayed = true;
                                    delayAddQueue.start();

                                    if (+settings.value("showQueueWhenAdding", "1"))
                                        window.mediaPanelShown = true;
                                } else {
                                    // Stabilize now: this one render overrules the queue, which is resumed afterwards
                                    if (render_queue.status == "active") {
                                        render_queue.pause();
                                        renderBtn.resumeQueueAfter = true;
                                    }
                                    const job_id = render_queue.add(window.getAdditionalProjectDataJson(), controller.image_to_b64(result.image));
                                    // One job per output file, they share the loaded video and render one after another
                                    const jobs = mediaPanel.splitDirectJob(job_id, renderBtn.directRange);
                                    renderBtn.directNextJobs = jobs.slice(1);
                                    renderBtn.directJobId = jobs[0];
                                    render_queue.main_job_id = jobs[0];
                                    render_queue.render_job(jobs[0]);
                                }
                            }, Qt.size(50 * dpiScale * videoArea.vid.parent.ratio, 50 * dpiScale));
                        }

                        // "preset" creates a settings preset, "apply" applies the selected settings to the whole queue
                        function openSettingsSelector(type: string): void {
                            const el = Qt.createComponent("SettingsSelector.qml").createObject(window, { type: type });
                            el.opened = true;
                            el.onApply.connect((obj) => {
                                const allData = JSON.parse(controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
                                let finalData = el.getFilteredObject(allData, obj);

                                if (finalData.hasOwnProperty("output")) {
                                    finalData.output.output_filename = ""; // Don't modify filenames, only target folder
                                }
                                if (obj.synchronization && obj.synchronization.do_autosync) {
                                    finalData.synchronization.do_autosync = true;
                                }
                                if (type == "preset") {
                                    if (obj.save_type == "file") {
                                        presetFileDialog.presetData = finalData;
                                        presetFileDialog.open2();
                                    } else if (obj.save_type == "default") {
                                        finalData.name = "Default preset";
                                        const saved_to = controller.export_preset("", finalData, obj.save_type, "");
                                        showNotification(Modal.Info, qsTr("Preset saved to %1").arg("<b>" + saved_to + "</b>"))
                                    } else {
                                        const dlg = messageBox(Modal.Info, qsTr("Enter the name for the preset: "), [
                                            { text: qsTr("Ok"), accent: true, clicked: function() {
                                                let name = dlg.mainColumn.children[1].text;
                                                if (!name) {
                                                    messageBox(Modal.Error, qsTr("Name cannot be empty."), [ { text: qsTr("Ok") } ]);
                                                    return false;
                                                }
                                                finalData.name = name;
                                                const saved_to = controller.export_preset("", finalData, obj.save_type, name);
                                                showNotification(Modal.Info, qsTr("Preset saved to %1").arg("<b>" + saved_to + "</b>"))
                                            } },
                                            { text: qsTr("Cancel") },
                                        ]);
                                        const tf = Qt.createComponent("components/TextField.qml").createObject(dlg.mainColumn, { });
                                        tf.anchors.horizontalCenter = dlg.mainColumn.horizontalCenter;
                                        tf.focus = true;
                                    }
                                } else { // Apply
                                    mediaPanel.applySettingsToQueue(finalData);
                                }
                            });
                        }
                    }

                    // The queue actions are always visible, not hidden behind a dropdown
                    Button {
                        id: queueToggleBtn;
                        // Queued: the video, or with the trim ranges exported as separate videos, all of them (or the active one
                        // when only some of them are)
                        readonly property bool queued: !renderBtn.queuePerRange? renderBtn.isQueued
                                                      : renderBtn.queuedRangeCount >= exportbar.rangeCount || (renderBtn.queuedRangeCount > 0 && renderBtn.activeRangeQueued);
                        accent: !queued;
                        accentColor: queued? styleQueuedColor : styleAccentColor;
                        height: 32 * dpiScale;
                        font.pixelSize: 12 * dpiScale;
                        icon.width: 12 * dpiScale;
                        icon.height: 12 * dpiScale;
                        iconName: renderBtn.addQueueDelayed? "confirmed" : queued? "minus" : "plus";
                        enabled: renderBtn.canExport && !renderBtn.addQueueDelayed;
                        text: renderBtn.addQueueDelayed? qsTr("Added")
                            : render_queue.editing_job_id > 0? qsTr("Save")
                            : qsTr("Queue") + "  (" + renderBtn.rangeShortcut + ")";
                        tooltip: render_queue.editing_job_id > 0? qsTr("Save the changes to the job in the render queue")
                               : renderBtn.queuePerRange? qsTr("Add trim ranges to the render queue or remove them")
                               : queued? qsTr("Remove from the render queue") : qsTr("Add to the render queue");
                        rightPadding: renderBtn.queuePerRange? 30 * dpiScale : leftPadding;
                        onClicked: {
                            if (renderBtn.queuePerRange) queueMenu.popup(queueToggleBtn, 0, -queueMenu.height);
                            else renderBtn.toggleQueue();
                        }
                        DropdownChevron { visible: renderBtn.queuePerRange; opened: queueMenu.visible; color: queueToggleBtn.textColor; }
                        Components.Menu {
                            id: queueMenu;
                            Action {
                                iconName: renderBtn.activeRangeQueued? "minus" : "plus";
                                text: (renderBtn.activeRangeQueued? qsTr("Remove range %1 from the queue").arg(renderBtn.activeRange + 1)
                                                                  : qsTr("Add range %1 to the queue").arg(renderBtn.activeRange + 1)) + "  (" + renderBtn.rangeShortcut + ")";
                                enabled: !renderBtn.activeRangeQueued || ["rendering", "processing"].indexOf(renderBtn.activeRangeState) < 0;
                                onTriggered: {
                                    if (renderBtn.activeRangeQueued) mediaPanel.unqueueLoadedRange(renderBtn.activeRange);
                                    else renderBtn.queueOnly(renderBtn.activeRange);
                                }
                            }
                            QQC.MenuSeparator { verticalPadding: 5 * dpiScale; }
                            Action {
                                iconName: "plus";
                                text: qsTr("Add all %1 ranges").arg(exportbar.rangeCount) + "  (" + renderBtn.clipShortcut + ")";
                                enabled: renderBtn.queuedRangeCount < exportbar.rangeCount;
                                onTriggered: renderBtn.queueOnly(-1);
                            }
                            Action {
                                iconName: "minus";
                                text: qsTr("Remove all ranges from the queue") + (renderBtn.allQueued? "  (" + renderBtn.clipShortcut + ")" : "");
                                enabled: renderBtn.isQueued;
                                onTriggered: mediaPanel.unqueueLoadedFile();
                            }
                        }
                    }
                    Button {
                        id: stabilizeNowBtn;
                        height: 32 * dpiScale;
                        font.pixelSize: 12 * dpiScale;
                        icon.width: 14 * dpiScale;
                        icon.height: 14 * dpiScale;
                        iconName: "video";
                        enabled: renderBtn.canExport;
                        tooltip: qsTr("Renders this video right away, before everything else in the render queue. The queue is resumed afterwards.");
                        text: qsTr("Stabilize now");
                        rightPadding: renderBtn.canChooseRange? 30 * dpiScale : leftPadding;
                        onClicked: {
                            if (renderBtn.canChooseRange) stabilizeNowMenu.popup(stabilizeNowBtn, 0, -stabilizeNowMenu.height);
                            else renderBtn.stabilizeNow();
                        }
                        DropdownChevron { visible: renderBtn.canChooseRange; opened: stabilizeNowMenu.visible; color: stabilizeNowBtn.textColor; }
                        Components.Menu {
                            id: stabilizeNowMenu;
                            Action { iconName: "video"; text: qsTr("All %1 ranges").arg(exportbar.rangeCount); onTriggered: renderBtn.stabilizeRange(-1); }
                            Action {
                                iconName: "video";
                                text: qsTr("Only the active range (%1)").arg(videoArea.timeline.activeTrimRange + 1);
                                onTriggered: renderBtn.stabilizeRange(videoArea.timeline.activeTrimRange);
                            }
                        }
                    }
                    // The actions that are used less often, so the bar stays compact
                    LinkButton {
                        id: moreBtn;
                        height: 32 * dpiScale;
                        leftPadding: 8 * dpiScale;
                        rightPadding: 8 * dpiScale;
                        icon.width: 18 * dpiScale;
                        icon.height: 18 * dpiScale;
                        iconName: "menu";
                        tooltip: qsTr("Project files");
                        onClicked: moreMenu.popup(moreBtn, 0, -moreMenu.height);
                        Components.Menu {
                            id: moreMenu;
                            Action { iconName: "save"; text: qsTr("Export project file"); onTriggered: window.saveProject("WithGyroData"); }
                            Action { iconName: "save"; text: qsTr("Save project file"); enabled: controller.project_file_url != ""; onTriggered: window.saveProject(""); }
                        }
                    }
                }
            }
        }

        SidePanel {
            id: rightPanel;
            visible: !videoArea.fullScreen;
            x: window.mediaPanelWidth + videoAreaCol.width;
            direction: SidePanel.HandleLeft;
            maxWidth: parent.width - window.mediaPanelWidth - 50 * dpiScale;
            implicitWidth: settings.value("rightPanelSize", defaultWidth);
            onWidthChanged: settings.setValue("rightPanelSize", width);
            col.visible: !isMobileLayout;

            Tabs {
                id: tabs;
                Component.onCompleted: { parent = rightPanel; currentIndex = 0; }
                visible: isMobileLayout;
                tabs: [QT_TRANSLATE_NOOP("Tabs", "Inputs"), QT_TRANSLATE_NOOP("Tabs", "Parameters"), QT_TRANSLATE_NOOP("Tabs", "Export")];
                tabsIcons: ["video", "settings", "save"];
                tabsIconsSize: [20, 24, 24];

                TabColumn { id: inputsTab; parentHeight: rightPanel.height; }
                TabColumn { id: paramsTab; parentHeight: rightPanel.height; }
                TabColumn { id: exportTab; parentHeight: rightPanel.height; inner.spacing: 10 * dpiScale; }
            }

            ItemLoader { id: sync; visible: status == Loader.Ready && window.stabilizationEnabled; sourceComponent: Component { Menu.Synchronization { } } }
            Hr { id: syncHr; visible: window.stabilizationEnabled; }
            ItemLoader { id: stab; visible: status == Loader.Ready && window.stabilizationEnabled; sourceComponent: Component { Menu.Stabilization { } } }
            Hr { id: stabHr; visible: window.stabilizationEnabled; }
            ItemLoader { id: advanced; sourceComponent: Component { Menu.Advanced { } } }
            // On the mobile layout it's the last one of the parameters tab, before the plugins
            Hr { id: advancedHr; visible: !isMobileLayout || nlePlugins.active }
            ItemLoader { id: exportSettings; sourceComponent: Component { Menu.Export { showBtn: !window.isMobileLayout; } } }
            Hr { id: exportHr; visible: !isMobileLayout && nlePlugins.active; }
            ItemLoader { id: nlePlugins; active: controller.is_nle_installed(); sourceComponent: Component { Menu.NlePlugins { } } }

            // Stays at the bottom of the panel while the settings above scroll: applying the settings shown to other
            // ranges, clips or the queue, and creating a preset from them
            Item {
                id: settingsFooter;
                Component.onCompleted: { parent = rightPanel; rightPanel.bottomPadding = Qt.binding(() => settingsFooter.visible? settingsFooter.height : 0); }
                visible: !isMobileLayout && !videoArea.isCalibrator;
                width: parent? parent.width : 0;
                height: 48 * dpiScale;
                y: parent? parent.height - height : 0;
                Hr { width: parent.width; anchors.top: parent.top; }
                Row {
                    id: settingsFooterRow;
                    anchors.verticalCenter: parent.verticalCenter;
                    anchors.horizontalCenter: parent.horizontalCenter;
                    spacing: 8 * dpiScale;
                    readonly property real buttonWidth: (settingsFooter.width - 3 * spacing) / 2;
                    Button {
                        id: applySettingsBtn;
                        width: settingsFooterRow.buttonWidth;
                        height: 30 * dpiScale;
                        font.pixelSize: 12 * dpiScale;
                        iconName: "gyroflow";
                        text: qsTr("Apply settings");
                        rightPadding: 28 * dpiScale;
                        tooltip: qsTr("Apply the settings shown to other ranges, clips or the render queue");
                        enabled: applyToQueue.enabled || applyToRanges.enabled || applyEverywhere.enabled;
                        onClicked: applySettingsMenu.popup(applySettingsBtn, 0, -applySettingsMenu.height);
                        DropdownChevron { opened: applySettingsMenu.visible; }
                        Components.Menu {
                            id: applySettingsMenu;
                            hideDisabled: true;
                            Action { id: applyToQueue; iconName: "queue"; text: qsTr("To the render queue…"); enabled: render_queue.queue.rowCount() > 0; onTriggered: renderBtn.openSettingsSelector("apply"); }
                            QQC.MenuSeparator {
                                verticalPadding: 5 * dpiScale;
                                visible: applyToQueue.enabled && (applyToRanges.enabled || applyEverywhere.enabled);
                                height: visible? implicitHeight : 0;
                            }
                            Action {
                                id: applyToRanges;
                                iconName: "gyroflow";
                                text: qsTr("To all ranges of this clip (stabilization)");
                                enabled: videoArea.separateRangeSettings;
                                onTriggered: {
                                    videoArea.applySettingsToAllRanges();
                                    mediaPanel.saveCurrentSettings();
                                    showNotification(Modal.Success, qsTr("Stabilization settings applied to all trim ranges of this video."));
                                }
                            }
                            Action {
                                id: applyEverywhere;
                                iconName: "gyroflow";
                                text: qsTr("Everywhere");
                                enabled: videoArea.vid.loaded;
                                onTriggered: mediaPanel.applyStabilizationToAll();
                            }
                        }
                    }
                    Button {
                        width: settingsFooterRow.buttonWidth;
                        height: 30 * dpiScale;
                        font.pixelSize: 12 * dpiScale;
                        iconName: "settings";
                        text: qsTr("Create preset");
                        tooltip: qsTr("Create a settings preset from the settings shown");
                        onClicked: renderBtn.openSettingsSelector("preset");
                    }
                }
            }
            LinkButton {
                id: mobileSettingsBtn;
                visible: isMobileLayout;
                text: qsTr("Settings");
                iconName: "settings";
                anchors.horizontalCenter: parent.horizontalCenter;
                onClicked: window.globalSettings.show();
            }
        }
    }

    // Files can be dropped anywhere in the window. The drop area is below the modals, so the ones that take their own
    // files (eg. the motion data of the video details) still get them
    DropArea {
        id: windowDrop;
        anchors.fill: parent;
        property var pendingUrls: [];
        onEntered: (drag) => {
            windowDrop.pendingUrls = Util.collectDropUrls(drag);
            drag.accepted = windowDrop.pendingUrls.length > 0;
        }
        onDropped: (drop) => {
            let urls = Util.collectDropUrls(drop);
            if (!urls.length) urls = windowDrop.pendingUrls;
            windowDrop.pendingUrls = [];
            window.handleDroppedUrls(urls);
        }
    }
    Rectangle {
        anchors.fill: parent;
        anchors.margins: 10 * dpiScale;
        z: 50;
        color: styleBackground;
        radius: 5 * dpiScale;
        opacity: windowDrop.containsDrag? 0.85 : 0.0;
        visible: opacity > 0;
        Ease on opacity { duration: 300; }
        BasicText {
            anchors.centerIn: parent;
            width: parent.width - 40 * dpiScale;
            horizontalAlignment: Text.AlignHCenter;
            wrapMode: Text.WordWrap;
            font.pixelSize: (window.isMobileLayout? 23 : 30) * dpiScale;
            text: qsTr("Drop files or folders here");
        }
        Loader {
            anchors.fill: parent;
            anchors.margins: 5 * dpiScale;
            asynchronous: true;
            sourceComponent: Component { DropTargetRect { } }
        }
    }

    Shortcuts {
        videoArea: videoArea;
    }

    // Video information, lens profile and motion data are opened from the video, in the media list
    VideoDetailsModal {
        id: videoDetails;
        anchors.fill: parent;
        z: 100;

        ItemLoader { id: vidInfo; sourceComponent: Component {
            Menu.VideoInformation {
                onSelectFileRequest: fileDialog.open2();
            }
        } }
        Hr { id: vidInfoHr; visible: window.stabilizationEnabled; }
        ItemLoader { id: lensProfile; visible: status == Loader.Ready && window.stabilizationEnabled; sourceComponent: Component {
            Menu.LensProfile { }
        } }
        Hr { id: lensProfileHr; visible: window.stabilizationEnabled; }
        ItemLoader { id: motionData; visible: status == Loader.Ready && window.stabilizationEnabled; sourceComponent: Component {
            Menu.MotionData { }
        } }
    }

    function handleDroppedUrls(urls) {
        mediaPanel.handleDroppedUrls(urls);
    }

    Loader {
        id: globalSettings;
        asynchronous: true;
        z: 150; // Above the modals covering the window, below the message boxes
        anchors.fill: parent;
        sourceComponent: Component { GlobalSettings { } }
    }

    function showNotification(type: int, text: string, textFormat: var, container: var): void {
        if (typeof textFormat === "undefined" || !textFormat) textFormat = text.includes("<b>")? Text.StyledText : Text.AutoText; // default
        const im = Qt.createComponent("components/InfoMessage.qml").createObject(container || window.videoArea.infoMessages, {
            text: text,
            type: type - 1,
            opacity: 0
        });
        im.t.textFormat = textFormat;
        im.opacity = 1;
        Qt.createQmlObject("import QtQuick; Timer { interval: 5000; running: true; }", im, "t1").onTriggered.connect(() => {
            im.opacity = 0;
            im.height = -5 * dpiScale;
            im.destroy(700);
        });
    }

    // Notification container of the window that owns `parentItem`, falling back to the main window
    function notificationContainer(parentItem: var): var {
        const win = parentItem && parentItem.Window? parentItem.Window.window : null;
        if (win && win.videoArea && win.videoArea.infoMessages) return win.videoArea.infoMessages;
        return window.videoArea.infoMessages;
    }

    function messageBox(type: int, text: string, buttons: list<var>, parent: QtObject, textFormat: var, identifier: var): Modal {
        if (typeof textFormat === "undefined" || !textFormat) textFormat = text.includes("<b>")? Text.StyledText : Text.AutoText; // default
        if (typeof identifier === "undefined") identifier = "";

        let el = null;

        if (identifier && +settings.value("dontShowAgain-" + identifier, 0)) {
            const clickedButton = +settings.value("dontShowAgain-" + identifier, 0) - 1;
            if (identifier == "open-rdc-folder") {
                Qt.callLater(function() {
                    buttons[0].clicked();
                });
            }
            if (buttons.length == 1) {
                showNotification(type, text, textFormat, notificationContainer(parent));
                return null;
            } else {
                console.log("previously clicked", clickedButton);
                if (buttons.length == 1 || clickedButton != buttons.length - 1 || identifier == "delete-after-join") { // Don't auto-click the last button (it's always Cancel/Close)
                    Qt.callLater(function() {
                        if (el)
                            el.clicked(clickedButton, true);
                    });
                }
            }
        }
        if (type == Modal.Error)   play_sound("error");
        if (type == Modal.Success) play_sound("success");

        el = Qt.createComponent("components/Modal.qml").createObject(parent || window, { textFormat: textFormat, iconType: type, modalIdentifier: identifier || "" });
        // Above the modals that cover the whole window (render queue, video details, marker import), they can ask questions too
        if (!parent) el.z = 200;
        el.text = text;
        el.onClicked.connect((index, dontShowAgain) => {
            if (identifier && dontShowAgain) {
                settings.setValue("dontShowAgain-" + identifier, index + 1);
            }

            let returnVal = undefined;
            if (buttons[index].clicked)
                returnVal = buttons[index].clicked();
            if (returnVal !== false) {
                el.close();
                window.isDialogOpened = false;
            }
        });
        let buttonTexts = [];
        for (const i in buttons) {
            buttonTexts.push(buttons[i].text);
            if (buttons[i].accent) {
                el.accentButton = i;
            }
        }
        el.buttons = buttonTexts;

        el.opened = true;
        window.isDialogOpened = true;
        return el;
    }
    function play_sound(type: string): void {
        if (settings.value("playSounds", "true") == "true")
            controller.play_sound(type);
    }

    Connections {
        target: controller;
        function onError(text: string, arg: string, callback: string): void {
            text = getReadableError(qsTr(text).arg(arg));
            if (text)
                messageBox(Modal.Error, text, [ { text: qsTr("Ok"), clicked: window[callback] } ]);
        }
        function onMessage(text: string, arg: string, callback: string, id: string): void {
            messageBox(Modal.Info, qsTr(text).arg(arg), [ { text: qsTr("Ok"), clicked: window[callback] } ], null, undefined, id);
        }
        function onRequest_recompute(): void {
            Qt.callLater(controller.recompute_threaded);
        }
        function openUpdatePage(): void {
            if (Qt.platform.os == "android") {
                Qt.openUrlExternally("https://play.google.com/store/apps/details?id=xyz.gyroflow");
            } else if (Qt.platform.os == "ios") {
                Qt.openUrlExternally("https://apps.apple.com/us/app/gyroflow/id6447994244");
            } else if (Qt.platform.os == "osx" && isStorePackage) {
                Qt.openUrlExternally("https://apps.apple.com/us/app/gyroflow/id6447994244");
            } else if (Qt.platform.os == "windows" && isStorePackage) {
                // https://apps.microsoft.com/store/detail/gyroflow/9NZG7T0JCG9H
                Qt.openUrlExternally("ms-windows-store://pdp/?ProductId=9NZG7T0JCG9H");
            } else {
                Qt.openUrlExternally("https://github.com/gyroflow/gyroflow/releases");
            }
        }
        function onUpdates_available(version: string, changelog: string): void {
            const heading = "<p align=\"center\">" + qsTr("There's a newer version available: %1.").arg("<b>" + version + "</b>") + "</p>\n\n";
            const el = messageBox(Modal.Info, heading + changelog, [ { text: qsTr("Download"),accent: true, clicked: () => openUpdatePage() },{ text: qsTr("Close") }], undefined, Text.MarkdownText);
            el.t.horizontalAlignment = Text.AlignLeft;
        }
        function onRequest_location(url: string, type: string): void {
            gfFileDialog.projectType = type;
            gfFileDialog.currentFolder = filesystem.get_folder(url);
            gfFileDialog.open();
        }
    }
    FileDialog {
        id: profileFileDialog;
        fileMode: FileDialog.SaveFile;
        title: qsTr("Select file destination");
        nameFilters: ["*.json"];
        type: "output-profile";
        property var cb: null;
        onAccepted: { const f = cb; cb = null; if (f) f(selectedFile); }
        onRejected: cb = null;
    }
    FileDialog {
        id: gfFileDialog;
        fileMode: FileDialog.SaveFile;
        title: qsTr("Select file destination");
        nameFilters: ["*.gyroflow"];
        type: "output-project";
        property string projectType: "Simple";
        onAccepted: saveProjectToUrl(selectedFile, projectType);
    }
    FileDialog {
        id: presetFileDialog;
        fileMode: FileDialog.SaveFile;
        title: qsTr("Select file destination");
        nameFilters: ["*.gyroflow"];
        type: "output-preset";
        property var presetData: ({});
        onAccepted: {
            presetData.name = filesystem.get_filename(selectedFile).replace(".gyroflow", "");
            const saved_to = controller.export_preset(selectedFile, presetData, "file", "");
            showNotification(Modal.Info, qsTr("Preset saved to %1").arg("<b>" + saved_to + "</b>"))
        }
    }

    Component.onCompleted: {
        controller.check_updates();

        QT_TRANSLATE_NOOP("App", "An error occurred: %1");
        QT_TRANSLATE_NOOP("App", "Gyroflow file exported to %1.");
        QT_TRANSLATE_NOOP("App", "--REPLACE_WITH_NATIVE_NAME_OF_YOUR_LANGUAGE_IN_YOUR_LANGUAGE--", "Translate this to the native name of your language");
        QT_TRANSLATE_NOOP("App", "Gyroflow will shut down the computer in 60 seconds because all tasks have been completed.");
        QT_TRANSLATE_NOOP("App", "Gyroflow will reboot the computer in 60 seconds because all tasks have been completed.");

        Qt.callLater(filesystem.restore_allowed_folders);
    }

    function getReadableError(text: string): string {
        if (text.includes("ffmpeg")) {
            if (text.includes("Encoder not found") && text.includes("libx26") && controller.check_external_sdk("ffmpeg_gpl")) {
                if (videoArea.externalSdkModal === null) {
                    const licenseUrl = "https://code.videolan.org/videolan/x264/-/raw/master/COPYING";
                    // const licenseUrl = "https://bitbucket.org/multicoreware/x265_git/raw/master/COPYING";
                    const dlg = messageBox(Modal.Info, qsTr("This encoder requires an external library licensed as GPL.\nDo you agree with the [GPL license] and want to download the additional codec?").replace(/\[(.*?)\]/, '<a href="' + licenseUrl + '"><font color="' + styleTextColor + '">$1</font></a>'), [
                        { text: qsTr("Yes, I agree"), accent: true, clicked: function() {
                            dlg.btnsRow.children[0].enabled = false;
                            controller.install_external_sdk("ffmpeg_gpl");
                            return false;
                        } },
                        { text: qsTr("Cancel"), clicked: function() {
                            videoArea.externalSdkModal = null;
                        } },
                    ]);
                    videoArea.externalSdkModal = dlg;
                    dlg.addLoader();
                }
                return "";
            }

            if (text.includes("Permission denied")) return qsTr("Permission denied. Unable to create or write file.\nChange the output path or run the program as administrator.\nMake sure you have write permissions to the target directory and make sure target file is not used by any other application.");
            if (text.includes("required nvenc API version")) return qsTr("NVIDIA GPU driver is too old, GPU encoding will not work for this format.\nUpdate your NVIDIA drivers to the newest version: %1.\nIf the issue is still present after driver update, your GPU probably doesn't support GPU encoding with this format. Disable GPU encoding in this case.").arg("<a href=\"https://www.nvidia.com/download/index.aspx\">https://www.nvidia.com/download/index.aspx</a>");

            text = text.replace(/ @ [A-F0-9]{6,}\]/g, "]"); // Remove ffmpeg function addresses

            // Remove duplicate lines
            text = [...new Set(text.split(/\r\n|\n\r|\n|\r/g))].join("\n");
        }
        if (text.startsWith("convert_format:")) {
            const format = text.split(":")[1].split(";")[0];
            return qsTr("GPU accelerated encoder doesn't support this pixel format (%1).\nDo you want to convert to a different supported pixel format or keep the original one and render on the CPU?").arg("<b>" + format + "</b>");
        }
        if (text.startsWith("file_exists:")) {
            return qsTr("Output file already exists, do you want to overwrite it?");
        }
        if (text.startsWith("uses_cpu")) {
            return qsTr("GPU encoder failed to initialize and rendering is done on the CPU, which is much slower.\nIf you have a modern device, latest GPU drivers and you think this shouldn't happen, report this on GitHub including gyroflow.log file.");
        }
        if (text.includes("hevc") && text.includes("-12912")) {
            return qsTr("Your GPU doesn't support H.265/HEVC encoding, try to use H.264/AVC or disable GPU encoding in Export settings.");
        }
        if (text.includes("failed to decode picture") && text.includes("-12909")) {
            return qsTr("GPU decoder failed to decode this file. Disable GPU decoding in \"Settings\" and try again.") + "\n\n" + text;
        }
        if (text.includes("codec not currently supported in container")) {
            return qsTr("Make sure your output extension supports the selected codec. \".mov\" should work in most cases.") + "\n\n" + text;
        }
        if (text.includes("[aac]") && text.includes("Invalid data found when processing input")) {
            return qsTr("Audio encoder couldn't process the input data. Try unchecking \"Export audio\" in Export settings.") + "\n\n" + text;
        }

        return text.trim();
    }

    function renameOutput(filename: string, folderUrl: url): string {
        let newName = filename;
        for (let i = 1; i < 1000; ++i) {
            newName = filename.replace(/(_\d+)?((?:_%05d)?\.[a-z0-9]+)$/i, "_" + i + "$2");

            if (!filesystem.exists_in_folder(folderUrl, newName.replace("_%05d", "_00001")) && !render_queue.file_exists_in_folder(folderUrl, newName))
                break;
        }

        return newName;
    }

    function reportProgress(progress: real, type: string): void {
        if (videoArea.videoLoader.active) {
            if (type === "loader") ui_tools.set_progress(progress);
            return;
        }
        ui_tools.set_progress(progress);
    }

    function getAdditionalProjectData(): var {
        return {
            "output": exportSettings.item.getExportOptions(),
            "synchronization": sync.item.getSettings(),
            // Output path of each trim range (and its stabilization settings if they are separate), in the order of `trim_ranges_ms`
            "trim_range_info": (videoArea.storeDisplayedRangeSettings(), videoArea.timeline.getTrimRangeInfo()),
            "trim_range_config": videoArea.separateRangeSettings? "separate" : "shared",

            "muted": window.videoArea.vid.muted,
            "playback_speed": window.videoArea.vid.playbackRate
        };
    }
    function getAdditionalProjectDataJson(): string { return JSON.stringify(getAdditionalProjectData()); }

    function saveProjectToUrl(url: url, type: string): void {
        videoArea.videoLoader.show(qsTr("Saving..."), false);
        controller.export_gyroflow_file(url, type, window.getAdditionalProjectData());
    }
    function saveProject(type: string): void {
        if (!type) type = "WithGyroData";

        if (controller.project_file_url) // Always overwrite
            return saveProjectToUrl(controller.project_file_url, type);

        const folder = filesystem.get_folder(controller.input_file_url);
        const filename = filesystem.filename_with_extension(filesystem.get_filename(controller.input_file_url), "gyroflow");

        if (!filesystem.exists_in_folder(folder, filename)) {
            getSaveFileUrl(folder, filename, function(url) { saveProjectToUrl(url, type); }, type);
        } else {
            messageBox(Modal.Question, qsTr("`.gyroflow` file already exists, what do you want to do?"), [
                { text: qsTr("Overwrite"), "accent": true, clicked: function() {
                    getSaveFileUrl(folder, filename, function(url) { saveProjectToUrl(url, type); }, type);
                } },
                { text: qsTr("Rename"), clicked: () => {
                    let newGfFilename = filename;
                    let i = 1;
                    while (filesystem.exists_in_folder(folder, newGfFilename)) {
                        newGfFilename = filename.replace(/(_\d+)?\.([a-z0-9]+)$/i, "_" + i++ + ".$2");
                        if (i > 1000) break;
                    }

                    const suffix = globalSettings.item.defaultSuffix.text;
                    const newFilename = outputFile.filename.replace(new RegExp(suffix + "(_\\d+)?\\.([a-z0-9]+)$", "i"), suffix + "_" + (i - 1) + ".$2");
                    if (!filesystem.exists_in_folder(folder, newFilename)) {
                        outputFile.setFilename(newFilename);
                    }
                    getSaveFileUrl(folder, newGfFilename, function(url) { saveProjectToUrl(url, type); }, type);
                } },
                { text: qsTr("Choose a different location"), clicked: () => {
                    gfFileDialog.projectType = type;
                    gfFileDialog.currentFolder = folder;
                    gfFileDialog.open();
                } },
                { text: qsTr("Cancel") }
            ], undefined, Text.MarkdownText);
        }
    }
    function getSaveFileUrl(folder: url, filename: string, cb, type: string, parentItem: var): void {
        const parentItm = parentItem || window;
        if (isSandboxed) {
            const opf = Qt.createComponent("components/OutputPathField.qml").createObject(parentItm, { visible: false });
            opf.folderSelectionCanceled.connect(function() { opf.destroy(); });
            opf.selectFolder(folder, function(folder_url) {
                cb(filesystem.get_file_url(folder_url, filename, true));
                opf.destroy();
            });
            return;
        }
        if (filesystem.can_create_file(folder, filename)) {
            cb(filesystem.get_file_url(folder, filename, true));
        } else {
            const dialog = type == "Lens profile"? profileFileDialog : gfFileDialog;
            if (type == "Lens profile") { profileFileDialog.cb = cb; }
            else                        { gfFileDialog.projectType = type; }
            // Present the dialog on top of the window that asked for it, not always the main one
            dialog.parentWindow = (parentItm.Window && parentItm.Window.window) || window.Window.window;
            dialog.currentFolder = folder;
            dialog.selectedFile = filesystem.get_file_url(folder, filename, true);
            dialog.open();
        }
    }

    /*Row {
        id: fps;
        property int frameCounter: 0;
        property int fps: 0;
        Image {
            id: spinnerImage;
            width: 2; height: 2;
            source: "qrc:/resources/logo_black.svg";
            NumberAnimation on rotation { from: 0; to: 360; duration: 800; loops: Animation.Infinite }
            onRotationChanged: fps.frameCounter++;
        }
        Text { color: "red"; font.pixelSize: 18; text: fps.fps + " fps"; }
        Timer {
            interval: 2000;
            repeat: true;
            running: true;
            onTriggered: {
                fps.fps = fps.frameCounter / 2;
                fps.frameCounter = 0;
            }
        }
    }*/
}
