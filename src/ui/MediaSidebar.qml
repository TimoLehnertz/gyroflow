// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

import QtQml
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Controls.impl as QQCI
import QtQuick.Dialogs as QQD

import "components/"
import "Util.js" as Util;

ResizablePanel {
    id: root;
    direction: ResizablePanel.HandleRight;
    defaultWidth: 330 * dpiScale;
    minWidth: 220 * dpiScale;
    height: parent? parent.height - y : 0;
    color: styleBackground2;

    property int currentItemId: media_library.current_item;
    property int selectedCount: 0;
    property bool isStabilizing: false;
    // Jobs queued from here, the user already decided to (re-)stabilize these items, so their output is always overwritten
    property var ownJobs: ({ });

    Connections {
        target: media_library;
        function onItems_changed(): void {
            root.selectedCount = media_library.selected_count();
            root.updateOutputField();
        }
        function onCurrent_item_changed(): void { root.updateOutputField(); }
    }

    // -----------------------------------------------------------------------------------------
    // --------------------------------------- Actions -----------------------------------------
    // -----------------------------------------------------------------------------------------

    function saveCurrentSettings(): void {
        const id = media_library.current_item;
        if (id > 0 && window.videoArea.vid.loaded && !window.videoArea.videoLoader.active) {
            media_library.save_settings(id, controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
        }
    }

    function loadItem(itemId: int): void {
        if (itemId <= 0 || itemId == media_library.current_item) return;
        root.saveCurrentSettings();
        root.updatingOutput = true;
        media_library.set_current_item(itemId);

        const data = media_library.get_project_data(itemId);
        if (data) {
            window.videoArea.loadGyroflowData(JSON.parse(data), 0);
        } else {
            window.videoArea.loadFile(media_library.get_item_url(itemId), true);
        }
        root.updateOutputFile();
    }

    // Keeps the output path in the bottom bar in sync with the item loaded in the main view
    property bool updatingOutput: false;
    function updateOutputFile(): void {
        const id = media_library.current_item;
        if (id <= 0 || !window.outputFile) { root.updatingOutput = false; return; }
        root.updatingOutput = true;
        window.outputFile.setFolder(media_library.get_output_folder(id));
        window.outputFile.setFilename(media_library.get_output_filename(id));
        root.updatingOutput = false;
    }
    // The output path can also be changed in the bottom bar, store it in the library then
    function pushOutputToItem(): void {
        const id = media_library.current_item;
        if (root.updatingOutput || id <= 0) return;
        if (!media_library.is_item_url(id, window.videoArea.loadedFileUrl.toString())) return;
        media_library.set_output_url(id, window.outputFile.folderUrl.toString(), window.outputFile.filename);
    }
    Connections {
        target: window.outputFile;
        function onFilenameChanged():  void { root.pushOutputToItem(); }
        function onFolderUrlChanged(): void { root.pushOutputToItem(); }
    }
    function updateOutputField(): void {
        const id = media_library.current_item;
        outputPathField.preventChange = true;
        outputPathField.text = id > 0? media_library.get_output_path(id) : "";
        outputPathField.preventChange = false;
    }

    function applyStabilizationToAll(): void {
        root.saveCurrentSettings();
        if (!window.videoArea.vid.loaded) {
            messageBox(Modal.Error, qsTr("Load a video first to apply its settings to the other videos."), [ { text: qsTr("Ok") } ]);
            return;
        }
        const allData = JSON.parse(controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
        const count = media_library.apply_stabilization_to_all(JSON.stringify({ stabilization: allData.stabilization }), 0);
        showNotification(Modal.Success, qsTr("Stabilization settings applied to %1 items.").arg("<b>" + count + "</b>"));
    }

    function stabilizeSelected(): void {
        root.saveCurrentSettings();
        const ids = media_library.get_render_items(true);
        if (!ids.length) {
            messageBox(Modal.Info, qsTr("Select the videos you want to stabilize."), [ { text: qsTr("Ok") } ]);
            return;
        }
        const additional = window.getAdditionalProjectData();
        for (const id of ids) {
            const status = media_library.get_item_job_status(id);
            if (status == "queued" || status == "rendering") continue; // Already in the queue
            if (status) root.cancelItem(id); // Stabilize it again
            let ad = JSON.parse(JSON.stringify(additional));
            ad.output = ad.output || ({ });
            // Every video is rendered in its own resolution
            delete ad.output.output_width;
            delete ad.output.output_height;
            ad.output.output_folder   = media_library.get_output_folder(id);
            ad.output.output_filename = media_library.get_output_filename(id);
            ad.output.metadata = Object.assign({ }, ad.output.metadata || { }, { stabilization_hash: media_library.settings_hash(id) });

            const jobId = render_queue.add_file(media_library.get_item_url(id), "", JSON.stringify(ad));
            media_library.set_item_job(id, jobId);
            root.ownJobs[jobId] = true;
        }
        // The queue is started when the files are loaded and the settings are applied, in onProcessing_done
        root.isStabilizing = true;
    }

    // A new section starts with the trim range of the main view if this video is loaded there, otherwise with the whole video
    function addSection(videoId: int, fromItemId: int): void {
        root.saveCurrentSettings();
        const isLoaded = media_library.current_item == fromItemId && window.videoArea.vid.loaded;
        const ranges = isLoaded? window.videoArea.timeline.getTrimRanges() : [[0.0, 1.0]];
        const newId = media_library.add_section(videoId, ranges[0][0], ranges[0][1]);
        if (newId > 0) root.loadItem(newId);
    }

    function removeItem(itemId: int): void {
        const jobs = media_library.remove_item(itemId);
        for (const jobId of jobs) render_queue.remove(jobId);
    }
    function cancelItem(itemId: int): void {
        const jobId = media_library.get_item_job(itemId);
        if (jobId > 0) {
            render_queue.remove(jobId);
            media_library.set_item_job(itemId, 0);
        }
    }
    function resetItem(itemId: int): void {
        const jobId = media_library.get_item_job(itemId);
        if (jobId > 0) {
            render_queue.reset_job(jobId);
            media_library.set_item_job(itemId, jobId);
        }
    }

    // -----------------------------------------------------------------------------------------
    // ------------------------------------- Render queue --------------------------------------
    // -----------------------------------------------------------------------------------------

    // This sidebar is the only queue UI, so every job of the render queue is represented by an item here,
    // no matter if it was queued from here, from the export panel or restored from the previous session.
    Instantiator {
        model: render_queue.queue;
        delegate: QtObject {
            property string errorString: error_string;
            onErrorStringChanged: root.updateJobState(job_id, errorString);
            // The job is not fully set up yet when the row is added, so register it in the next event loop iteration
            Component.onCompleted: root.scheduleJobRegistration(job_id, input_file, output_folder, output_filename);
            Component.onDestruction: root.unregisterJob(job_id);
        }
    }
    property var jobsToRegister: [];
    function scheduleJobRegistration(jobId: int, inputFile: string, outputFolder: string, outputFilename: string): void {
        root.jobsToRegister.push([jobId, inputFile, outputFolder, outputFilename]);
        registerTimer.start();
    }
    Timer {
        id: registerTimer;
        interval: 1;
        onTriggered: {
            const jobs = root.jobsToRegister;
            root.jobsToRegister = [];
            for (const job of jobs) root.registerJob(job[0], job[1], job[2], job[3]);
        }
    }
    function registerJob(jobId: int, inputFile: string, outputFolder: string, outputFilename: string): void {
        if (jobId <= 0 || media_library.is_library_job(jobId)) return;
        let itemId = media_library.is_item_url(media_library.current_item, inputFile)? media_library.current_item : media_library.find_by_url(inputFile);
        if (itemId <= 0) {
            media_library.add_files([inputFile]);
            itemId = media_library.find_by_url(inputFile);
        }
        if (itemId <= 0) return;
        // The job was configured elsewhere, take its settings and output path as the ones of the item
        const data = render_queue.get_gyroflow_data(jobId);
        if (data && data.includes("\"stabilization\"")) media_library.save_settings(itemId, data);
        media_library.set_output_url(itemId, outputFolder, outputFilename);
        media_library.set_item_job(itemId, jobId);
    }
    function renameJobOutput(itemId: int, jobId: int, filename: string, folder: string, start: bool): void {
        const newName = window.renameOutput(filename, folder);
        render_queue.set_job_output_filename(jobId, newName, start);
        if (itemId > 0) media_library.set_output_url(itemId, folder, newName);
    }
    function unregisterJob(jobId: int): void {
        delete root.ownJobs[jobId];
        const itemId = media_library.get_item_for_job(jobId);
        if (itemId > 0) media_library.set_item_job(itemId, 0);
    }
    // The error string of a queue item can be an error, a question (convert_format, file_exists) or just an informational note
    function updateJobState(jobId: int, errorString: string): void {
        if (jobId == render_queue.main_job_id && errorString == "uses_cpu") {
            window.videoArea.videoLoader.infoMessage.type = InfoMessage.Warning;
            window.videoArea.videoLoader.infoMessage.text = window.getReadableError(errorString);
            window.videoArea.videoLoader.infoMessage.show = true;
        }
        media_library.set_job_error_string(jobId, errorString);
    }

    Connections {
        target: render_queue;
        function onProcessing_done(job_id: real, by_preset: bool): void {
            if (by_preset || !media_library.is_library_job(job_id)) return;
            // The video is loaded in the queue now, apply the settings of this item on top of it
            const data = media_library.get_settings_for_job(job_id);
            if (data) {
                render_queue.apply_to_all(data, window.getAdditionalProjectDataJson(), job_id);
            }
            if (root.isStabilizing) render_queue.start();
        }
        function onProcessing_progress(job_id: real, progress: real): void {
            media_library.set_job_processing(job_id, progress);
        }
        function onRender_progress(job_id: real, progress: real, frame: int, total_frames: int, finished: bool, start_time: real, is_conversion: bool): void {
            if (media_library.is_library_job(job_id)) {
                media_library.update_job_progress(job_id, progress, finished && total_frames > 0);
            }
        }
        function onError(job_id: real, text: string, arg: string, callback: string): void {
            if (!media_library.is_library_job(job_id)) return;
            if (text.startsWith("file_exists:")) {
                // The item was explicitly selected for stabilization, so overwrite the existing file.
                // The queue is started in onProcessing_done, after the settings of the item are applied.
                // Other jobs ask in the message area of the item, according to the default overwrite action.
                if (root.ownJobs[job_id]) render_queue.reset_job(job_id);
                return;
            }
            media_library.set_job_error(job_id, window.getReadableError(qsTr(text).arg(arg)) || text);
        }
        function onQueue_finished(): void {
            if (root.isStabilizing && media_library.active_job_count() == 0) {
                root.isStabilizing = false;
                media_library.refresh_outputs();
            }
        }
        function onQueue_changed():  void { render_queue.save_render_queue(); }
        function onStatus_changed(): void { render_queue.save_render_queue(); }
        function onRequest_close(): void {
            main_window.closeConfirmed = true;
            Qt.callLater(Qt.quit);
        }
    }

    // Unfinished jobs of the previous session are added back to the queue and show up in the list above
    Timer {
        interval: 100;
        running: window.exportSettings != null && window.sync != null;
        onTriggered: {
            Qt.callLater(() => {
                if (render_queue.restore_render_queue(window.getAdditionalProjectDataJson())) {
                    messageBox(Modal.Info, qsTr("You have unfinished tasks in the render queue."), [
                        { text: qsTr("Show the media list"), accent: true, clicked: function() { window.mediaPanelShown = true; } },
                        { text: qsTr("Ok") }
                    ]);
                }
            });
        }
    }

    // The main view can also be loaded from outside of the sidebar, in that case follow the loaded file
    Connections {
        target: window.videoArea;
        function onLoadedFileUrlChanged(): void {
            const url = window.videoArea.loadedFileUrl.toString();
            if (!media_library.is_item_url(media_library.current_item, url)) {
                root.saveCurrentSettings();
                media_library.set_current_item(media_library.find_by_url(url));
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // ---------------------------------------- Header -----------------------------------------
    // -----------------------------------------------------------------------------------------

    Column {
        id: header;
        width: parent.width - 10 * dpiScale;
        x: 5 * dpiScale;
        y: 5 * dpiScale;
        spacing: 5 * dpiScale;

        Item {
            width: parent.width;
            height: 34 * dpiScale;
            BasicText {
                text: qsTr("Media");
                font.pixelSize: 15 * dpiScale;
                font.bold: true;
                leftPadding: 5 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
            }
            Row {
                anchors.right: parent.right;
                anchors.verticalCenter: parent.verticalCenter;
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "folder";
                    tooltip: qsTr("Add input folder");
                    onClicked: folderDialog.open();
                }
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "plus";
                    tooltip: qsTr("Add video files");
                    onClicked: filesDialog.open2();
                }
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "bin";
                    textColor: "#f67575";
                    tooltip: qsTr("Remove all");
                    onClicked: {
                        messageBox(Modal.Question, qsTr("Are you sure you want to remove all videos from the list?"), [
                            { text: qsTr("Yes"), accent: true, clicked: () => {
                                const ids = media_library.get_render_items(false);
                                for (const id of ids) root.cancelItem(id);
                                media_library.clear();
                            } },
                            { text: qsTr("No") }
                        ]);
                    }
                }
            }
        }

        TextField {
            id: searchField;
            width: parent.width;
            height: 30 * dpiScale;
            placeholderText: qsTr("Search");
            rightPadding: 30 * dpiScale;
            onTextChanged: media_library.search_text = text;
            QQCI.IconImage {
                name: "search";
                source: "qrc:/resources/icons/svg/search.svg";
                color: styleTextColor;
                anchors.right: parent.right;
                anchors.rightMargin: 5 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
                height: Math.round(parent.height * 0.7);
                width: height;
                layer.enabled: true;
                layer.textureSize: Qt.size(height*2, height*2);
                layer.smooth: true;
            }
        }

        Item {
            width: parent.width;
            height: sortBox.height;
            BasicText {
                text: qsTr("Sort by:");
                leftPadding: 5 * dpiScale;
                font.pixelSize: 12 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
            }
            ComboBox {
                id: sortBox;
                anchors.right: parent.right;
                width: Math.min(160 * dpiScale, parent.width * 0.6);
                height: 28 * dpiScale;
                font.pixelSize: 12 * dpiScale;
                model: [QT_TRANSLATE_NOOP("Popup", "Date taken"), QT_TRANSLATE_NOOP("Popup", "File name")];
                currentIndex: +settings.value("mediaSortByName", 0);
                onCurrentIndexChanged: {
                    media_library.sort_by_name = currentIndex == 1;
                    settings.setValue("mediaSortByName", currentIndex);
                }
            }
        }
        Hr { width: parent.width; }
    }

    // -----------------------------------------------------------------------------------------
    // ----------------------------------------- Tree ------------------------------------------
    // -----------------------------------------------------------------------------------------

    ListView {
        id: lv;
        x: 5 * dpiScale;
        width: parent.width - 12 * dpiScale;
        anchors.top: header.bottom;
        anchors.topMargin: 5 * dpiScale;
        anchors.bottom: footer.top;
        anchors.bottomMargin: 5 * dpiScale;
        clip: true;
        spacing: 2 * dpiScale;
        model: media_library.items;
        QQC.ScrollIndicator.vertical: QQC.ScrollIndicator { }

        BasicText {
            anchors.centerIn: parent;
            width: parent.width - 20 * dpiScale;
            visible: lv.count == 0;
            horizontalAlignment: Text.AlignHCenter;
            wrapMode: Text.WordWrap;
            font.pixelSize: 13 * dpiScale;
            opacity: 0.7;
            text: media_library.search_text? qsTr("No files match the search.") : qsTr("Drop video files or folders here, or use the buttons above.");
        }

        delegate: Rectangle {
            id: dlg;
            width: lv.width;
            height: itemCol.height + 10 * dpiScale;
            radius: 5 * dpiScale;
            property bool isFolder:  kind == "folder";
            property bool isSection: kind == "section";
            property bool isRendering:  job_status == "rendering";
            property bool isProcessing: job_status == "processing";
            property bool isQueued:     job_status == "queued";
            property bool isJobError:   job_status == "error";
            property bool isQuestion:   job_status == "question";
            property bool isJobDone:    job_status == "done";
            property bool isBusy: dlg.isRendering || dlg.isProcessing;

            color: isJobError? "#30ed7676"
                 : isQuestion? "#30" + styleAccentColor.toString().substring(1)
                 : stabilized_state == 1? "#3070e574"
                 : stabilized_state == 2? "#30f6a00b"
                 : selected? "#20ffffff" : "transparent";
            border.width: is_current? 1 * dpiScale : 0;
            border.color: styleAccentColor;

            MouseArea {
                anchors.fill: parent;
                acceptedButtons: Qt.LeftButton;
                cursorShape: dlg.isFolder? Qt.ArrowCursor : Qt.PointingHandCursor;
                onClicked: {
                    if (dlg.isFolder) {
                        media_library.toggle_expanded(item_id);
                    } else {
                        root.loadItem(item_id);
                    }
                }
            }
            ContextMenuMouseArea {
                onContextMenu: (isHold, mx, my) => itemMenu.popup(dlg, mx, my);
            }
            Menu {
                id: itemMenu;
                font.pixelSize: 11.5 * dpiScale;
                Action {
                    iconName: "plus";
                    text: qsTr("Add section");
                    enabled: !dlg.isFolder;
                    onTriggered: root.addSection(dlg.isSection? parent_id : item_id, item_id);
                }
                Action {
                    iconName: "play";
                    text: qsTr("Stabilize");
                    enabled: !dlg.isFolder && !dlg.isBusy;
                    onTriggered: {
                        media_library.select_only(item_id);
                        root.stabilizeSelected();
                    }
                }
                Action {
                    iconName: "play";
                    text: qsTr("Render now");
                    enabled: job_id > 0 && !dlg.isBusy && !dlg.isJobDone;
                    onTriggered: render_queue.render_job(job_id);
                }
                Action {
                    iconName: "pencil";
                    text: qsTr("Edit render settings");
                    enabled: job_id > 0 && !dlg.isBusy;
                    onTriggered: {
                        const data = render_queue.get_gyroflow_data(job_id);
                        if (data) window.videoArea.loadGyroflowData(JSON.parse(data), job_id);
                    }
                }
                Action {
                    iconName: "arrow-up";
                    text: qsTr("Move up in the queue");
                    enabled: job_id > 0;
                    onTriggered: render_queue.move_item(job_id, -1);
                }
                Action {
                    iconName: "arrow-down";
                    text: qsTr("Move down in the queue");
                    enabled: job_id > 0;
                    onTriggered: render_queue.move_item(job_id, 1);
                }
                Action {
                    iconName: dlg.isBusy? "close" : "spinner";
                    text: dlg.isBusy? qsTr("Stop") : qsTr("Reset status");
                    enabled: job_id > 0 && (dlg.isBusy || dlg.isJobError || dlg.isQuestion || dlg.isJobDone);
                    onTriggered: root.resetItem(item_id);
                }
                Action {
                    iconName: "play";
                    text: qsTr("Open rendered file");
                    enabled: !dlg.isFolder && stabilized_state > 0 && Qt.platform.os != "ios";
                    onTriggered: filesystem.open_file_externally(filesystem.get_file_url(media_library.get_output_folder(item_id), media_library.get_output_filename(item_id), false));
                }
                Action {
                    iconName: "folder";
                    text: qsTr("Open file location");
                    onTriggered: filesystem.open_file_externally(dlg.isFolder? url : filesystem.get_folder(url));
                }
                Action {
                    iconName: "close";
                    text: qsTr("Remove from the queue");
                    enabled: job_id > 0 && !dlg.isBusy;
                    onTriggered: root.cancelItem(item_id);
                }
                Action {
                    iconName: "bin";
                    text: dlg.isFolder? qsTr("Remove folder") : dlg.isSection? qsTr("Delete section") : qsTr("Remove video");
                    enabled: !dlg.isBusy;
                    onTriggered: root.removeItem(item_id);
                }
            }

            Column {
                id: itemCol;
                y: 5 * dpiScale;
                x: 3 * dpiScale + depth * 12 * dpiScale;
                width: parent.width - x - 5 * dpiScale;
                spacing: 2 * dpiScale;

                Item {
                    width: parent.width;
                    height: 22 * dpiScale;

                    LinkButton {
                        id: chevron;
                        width: 18 * dpiScale;
                        height: 18 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        leftPadding: 0; rightPadding: 0;
                        icon.width: 10 * dpiScale;
                        icon.height: 10 * dpiScale;
                        textColor: styleTextColor;
                        visible: has_children;
                        iconName: expanded? "chevron-down" : "chevron-right";
                        onClicked: media_library.toggle_expanded(item_id);
                    }
                    Rectangle {
                        id: selCb;
                        visible: !dlg.isFolder || has_children;
                        anchors.left: parent.left;
                        anchors.leftMargin: 20 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        width: 14 * dpiScale;
                        height: width;
                        radius: 4 * dpiScale;
                        color: selected? styleAccentColor : "transparent";
                        border.width: 1 * dpiScale;
                        border.color: selected? styleAccentColor : "#999999";
                        QQCI.IconImage {
                            visible: selected;
                            anchors.fill: parent;
                            anchors.margins: 2 * dpiScale;
                            name: "checkmark";
                            source: "qrc:/resources/icons/svg/checkmark.svg";
                            color: styleTextColorOnAccent;
                        }
                        MouseArea {
                            anchors.fill: parent;
                            anchors.margins: -3 * dpiScale;
                            cursorShape: Qt.PointingHandCursor;
                            onClicked: media_library.set_selected(item_id, !selected);
                        }
                    }
                    QQCI.IconImage {
                        id: itemIcon;
                        anchors.left: selCb.right;
                        anchors.leftMargin: 4 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        name: dlg.isFolder? "folder" : dlg.isSection? "file-empty" : "video";
                        source: "qrc:/resources/icons/svg/" + (dlg.isFolder? "folder" : dlg.isSection? "file-empty" : "video") + ".svg";
                        color: styleTextColor;
                        height: 14 * dpiScale;
                        width: height;
                        layer.enabled: true;
                        layer.textureSize: Qt.size(height*2, height*2);
                        layer.smooth: true;
                    }
                    BasicText {
                        id: nameText;
                        anchors.left: itemIcon.right;
                        anchors.right: statusRow.left;
                        anchors.rightMargin: 3 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        leftPadding: 4 * dpiScale;
                        text: name;
                        elide: Text.ElideMiddle;
                        font.bold: dlg.isFolder || is_current;
                        font.pixelSize: (dlg.isFolder? 13 : 12) * dpiScale;
                        ToolTip { visible: !isMobile && nameMa.containsMouse && display_output_path.length > 0; text: dlg.isFolder? display_output_path : qsTr("Output: %1").arg(display_output_path); }
                        MouseArea { id: nameMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton; }
                    }
                    Row {
                        id: statusRow;
                        anchors.right: parent.right;
                        anchors.verticalCenter: parent.verticalCenter;
                        spacing: 3 * dpiScale;
                        LinkButton {
                            visible: !dlg.isFolder;
                            width: 20 * dpiScale;
                            height: 20 * dpiScale;
                            anchors.verticalCenter: parent.verticalCenter;
                            leftPadding: 0; rightPadding: 0;
                            icon.width: 10 * dpiScale;
                            icon.height: 10 * dpiScale;
                            iconName: "plus";
                            tooltip: qsTr("Add a section of this video");
                            onClicked: root.addSection(dlg.isSection? parent_id : item_id, item_id);
                        }
                        QQC.BusyIndicator {
                            visible: scanning;
                            height: 16 * dpiScale;
                            width: height;
                            anchors.verticalCenter: parent.verticalCenter;
                            scale: 0.4;
                            running: visible;
                        }
                        QQCI.IconImage {
                            visible: lens_warning && !scanning && !dlg.isFolder;
                            name: "warning";
                            source: "qrc:/resources/icons/svg/warning.svg";
                            color: "#f6a00b";
                            height: 14 * dpiScale;
                            width: height;
                            anchors.verticalCenter: parent.verticalCenter;
                            layer.enabled: true;
                            layer.textureSize: Qt.size(height*2, height*2);
                            layer.smooth: true;
                            ToolTip { visible: !isMobile && ma2.containsMouse; text: qsTr("No lens profile detected for this video."); }
                            MouseArea { id: ma2; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton; }
                        }
                        BasicText {
                            visible: text.length > 0;
                            anchors.verticalCenter: parent.verticalCenter;
                            leftPadding: 0;
                            font.pixelSize: 11 * dpiScale;
                            color: dlg.isJobError? "#ed7676" : dlg.isQuestion? styleAccentColor : stabilized_state == 2? "#f6a00b" : styleTextColor;
                            text: dlg.isJobError?    qsTr("Error")
                                : dlg.isQuestion?    qsTr("Action needed")
                                : dlg.isProcessing?  qsTr("Synchronizing")
                                : dlg.isRendering?   (job_progress * 100).toFixed(0) + "%"
                                : dlg.isQueued?      qsTr("Queued")
                                : dlg.isJobDone?     qsTr("Done")
                                : stabilized_state == 2? qsTr("Changed")
                                : stabilized_state == 1? qsTr("Stabilized") : "";
                        }
                    }
                }
                QQC.ProgressBar {
                    visible: dlg.isBusy;
                    width: parent.width;
                    height: 4 * dpiScale;
                    value: job_progress;
                }
                BasicText {
                    visible: text.length > 0;
                    width: parent.width;
                    leftPadding: 24 * dpiScale;
                    font.pixelSize: 10 * dpiScale;
                    opacity: 0.7;
                    wrapMode: Text.WordWrap;
                    text: job_message? window.getReadableError(job_message) : "";
                }
                BasicText {
                    visible: !dlg.isFolder && (dlg.isSection || duration_ms > 0);
                    width: parent.width;
                    leftPadding: 24 * dpiScale;
                    font.pixelSize: 10 * dpiScale;
                    opacity: 0.7;
                    elide: Text.ElideMiddle;
                    text: {
                        let parts = [];
                        if (duration_ms > 0) parts.push(Math.floor(duration_ms / 60000) + ":" + ("0" + Math.floor((duration_ms % 60000) / 1000)).slice(-2));
                        if (!dlg.isSection && created_at > 0) parts.push(new Date(created_at * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat));
                        if (dlg.isSection) parts.push((trim_start * 100).toFixed(0) + "% - " + (trim_end * 100).toFixed(0) + "%");
                        return parts.join("  |  ");
                    }
                }

                // Errors of the render queue and the questions it asks (pixel format conversion, existing output file)
                Loader {
                    width: parent.width;
                    active: dlg.isJobError || dlg.isQuestion;
                    sourceComponent: Component {
                        Column {
                            topPadding: 3 * dpiScale;
                            spacing: 4 * dpiScale;
                            BasicText {
                                id: messageText;
                                width: parent.width;
                                leftPadding: 24 * dpiScale;
                                font.pixelSize: 10 * dpiScale;
                                wrapMode: Text.WordWrap;
                                textFormat: Text.RichText;
                            }
                            Flow {
                                width: parent.width - 24 * dpiScale;
                                x: 24 * dpiScale;
                                spacing: 4 * dpiScale;
                                visible: btns.model.length > 0;
                                property string errorString: error_string;
                                onErrorStringChanged: {
                                    const readable = window.getReadableError(errorString).replace(/\n/g, "<br>");
                                    messageText.text = readable? readable : qsTr("Missing required components.");

                                    if (errorString.startsWith("convert_format:")) {
                                        const params = errorString.split(":")[1].split(";");
                                        const candidate = params[2];
                                        const supported = params[1].split(",");
                                        let buttons = supported.map(f => ({
                                            text: f,
                                            accent: f.toLowerCase() == candidate,
                                            clicked: () => { render_queue.set_pixel_format(job_id, f); }
                                        }));
                                        buttons.push({
                                            text: qsTr("Render using CPU"),
                                            accent: candidate == '',
                                            clicked: () => { render_queue.set_pixel_format(job_id, "cpu"); }
                                        });
                                        btns.model = buttons;
                                    } else if (errorString.startsWith("file_exists:")) {
                                        // The output of the items queued from here is always overwritten, it's already handled in onError
                                        if (root.ownJobs[job_id]) { btns.model = []; return; }
                                        const data = JSON.parse(errorString.substring(12));
                                        switch (render_queue.overwrite_mode) {
                                            case 1: Qt.callLater(() => render_queue.reset_job(job_id)); btns.model = []; break; // Overwrite
                                            case 2: Qt.callLater(() => root.renameJobOutput(item_id, job_id, data.filename, data.folder, false)); btns.model = []; break; // Rename
                                            case 3: Qt.callLater(() => render_queue.set_error_string(job_id, qsTr("Output file already exists."))); btns.model = []; break; // Skip
                                            default:
                                                btns.model = [
                                                    { text: qsTr("Yes"),    clicked: () => { render_queue.reset_job(job_id); }, accent: true },
                                                    { text: qsTr("Rename"), clicked: () => { root.renameJobOutput(item_id, job_id, data.filename, data.folder, true); } },
                                                    { text: qsTr("No"),     clicked: () => { render_queue.set_error_string(job_id, qsTr("Output file already exists.")); btns.model = []; } },
                                                ];
                                            break;
                                        }
                                    } else {
                                        btns.model = [];
                                    }
                                }
                                Repeater {
                                    id: btns;
                                    model: [];
                                    Button {
                                        text: modelData.text;
                                        height: 22 * dpiScale;
                                        accent: modelData.accent || false;
                                        leftPadding: 8 * dpiScale;
                                        rightPadding: 8 * dpiScale;
                                        font.pixelSize: 11 * dpiScale;
                                        onClicked: modelData.clicked();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // ---------------------------------------- Footer -----------------------------------------
    // -----------------------------------------------------------------------------------------

    Column {
        id: footer;
        width: parent.width - 12 * dpiScale;
        x: 5 * dpiScale;
        anchors.bottom: parent.bottom;
        anchors.bottomMargin: 5 * dpiScale;
        spacing: 4 * dpiScale;

        Hr { width: parent.width; }

        Label {
            width: parent.width;
            text: qsTr("Export folder:");
            position: Label.TopPosition;
            spacing: 2 * dpiScale;
            t.font.pixelSize: 12 * dpiScale;
            OutputPathField {
                id: exportFolderField;
                folderOnly: true;
                onFolderUrlChanged: {
                    media_library.export_folder = folderUrl.toString();
                    settings.setValue("mediaExportFolder", folderUrl.toString());
                }
                Component.onCompleted: {
                    const saved = settings.value("mediaExportFolder", "");
                    if (saved) setFolder(saved);
                }
            }
        }
        BasicText {
            width: parent.width;
            visible: !exportFolderField.folderUrl.toString();
            font.pixelSize: 10 * dpiScale;
            leftPadding: 2 * dpiScale;
            opacity: 0.7;
            wrapMode: Text.WordWrap;
            text: qsTr("Empty: the stabilized files are written next to the original files.");
        }

        Label {
            width: parent.width;
            visible: root.currentItemId > 0;
            text: qsTr("Output path:");
            position: Label.TopPosition;
            spacing: 2 * dpiScale;
            t.font.pixelSize: 12 * dpiScale;
            TextField {
                id: outputPathField;
                width: parent.width;
                height: 28 * dpiScale;
                font.pixelSize: 12 * dpiScale;
                property bool preventChange: false;
                tooltip: qsTr("Relative to the export folder, or an absolute path.");
                onTextChanged: {
                    if (!preventChange && root.currentItemId > 0) {
                        media_library.set_output_path(root.currentItemId, text);
                        root.updateOutputFile();
                    }
                }
            }
        }

        Item { width: 1; height: 2 * dpiScale; }

        Button {
            width: parent.width;
            height: 30 * dpiScale;
            font.pixelSize: 12 * dpiScale;
            text: qsTr("Apply stabilization settings to all");
            tooltip: qsTr("Applies the stabilization settings of the current video to all videos and sections. Lens profile and trim range are not changed.");
            enabled: window.videoArea.vid.loaded;
            onClicked: root.applyStabilizationToAll();
        }
        Button {
            width: parent.width;
            height: 34 * dpiScale;
            accent: true;
            iconName: "play";
            icon.width: 15 * dpiScale;
            icon.height: 15 * dpiScale;
            font.pixelSize: 13 * dpiScale;
            text: root.selectedCount > 0? qsTr("Stabilize %1 selected").arg(root.selectedCount) : qsTr("Stabilize selected");
            enabled: root.selectedCount > 0;
            onClicked: root.stabilizeSelected();
        }

        // -------------------------------------- Render queue --------------------------------------

        Hr { width: parent.width; visible: queueCol.visible; }

        Column {
            id: queueCol;
            width: parent.width;
            spacing: 3 * dpiScale;
            visible: render_queue.total_frames > 0 || render_queue.status != "stopped";

            property real progress: Math.max(0, Math.min(1, render_queue.current_frame / Math.max(1, render_queue.total_frames)));
            onProgressChanged: {
                const times = Util.calculateTimesAndFps(progress, render_queue.current_frame, render_queue.start_timestamp, render_queue.end_timestamp);
                if (times !== false && progress < 1.0) {
                    queueTime.elapsed = times[0];
                    queueTime.remaining = times[1];
                    if (times.length > 2) queueTime.fps = times[2];
                    window.reportProgress(progress, "queue");
                } else {
                    window.reportProgress(-1, "queue");
                    queueTime.remaining = "---";
                }
            }

            BasicText {
                width: parent.width;
                leftPadding: 2 * dpiScale;
                font.pixelSize: 11 * dpiScale;
                textFormat: Text.RichText;
                text: qsTr("Queue: %1").arg(`<b>${(queueCol.progress*100).toFixed(1)}%</b> <small>(${render_queue.current_frame}/${render_queue.total_frames}${queueTime.fpsText})</small>`);
            }
            QQC.ProgressBar {
                width: parent.width;
                height: 4 * dpiScale;
                value: queueCol.progress;
            }
            BasicText {
                id: queueTime;
                width: parent.width;
                leftPadding: 2 * dpiScale;
                font.pixelSize: 10 * dpiScale;
                opacity: 0.7;
                property string elapsed: "---";
                property string remaining: "---";
                property real fps: 0;
                property string fpsText: queueCol.progress > 0? qsTr(" @ %1fps").arg(fps.toFixed(1)) : "";
                text: qsTr("Elapsed: %1. Remaining: %2").arg(elapsed).arg(render_queue.status == "active"? remaining : "---");
            }

            Item { width: 1; height: 2 * dpiScale; }

            Button {
                width: parent.width;
                height: 30 * dpiScale;
                accent: true;
                property var statuses: ({
                    "stopped": [qsTr("Start exporting"), "play",  styleAccentColor, "start"],
                    "paused":  [qsTr("Resume"),          "play",  "#70e574",        "start"],
                    "active":  [qsTr("Pause"),           "pause", "#f6a00b",        "pause"],
                })
                text:        statuses[render_queue.status][0];
                iconName:    statuses[render_queue.status][1];
                accentColor: statuses[render_queue.status][2];
                icon.width: 13 * dpiScale;
                icon.height: 13 * dpiScale;
                font.pixelSize: 12 * dpiScale;
                Behavior on accentColor { ColorAnimation { duration: 700; easing.type: Easing.OutExpo; } }
                onClicked: render_queue[statuses[render_queue.status][3]]();
            }
        }

        Item {
            width: parent.width;
            height: 24 * dpiScale;
            LinkButton {
                id: whenDoneBtn;
                visible: !isMobile;
                anchors.left: parent.left;
                anchors.verticalCenter: parent.verticalCenter;
                leftPadding: 2 * dpiScale; rightPadding: 2 * dpiScale;
                font.pixelSize: 10 * dpiScale;
                property int currentOption: 0;
                property var options: [
                    QT_TRANSLATE_NOOP("Popup", "Do nothing"),
                    QT_TRANSLATE_NOOP("Popup", "Shut down the computer"),
                    QT_TRANSLATE_NOOP("Popup", "Restart the computer"),
                    QT_TRANSLATE_NOOP("Popup", "Sleep"),
                    QT_TRANSLATE_NOOP("Popup", "Hibernate"),
                    QT_TRANSLATE_NOOP("Popup", "Logout"),
                    QT_TRANSLATE_NOOP("Popup", "Close Gyroflow")
                ];
                text: qsTr("When done: %1").arg(qsTranslate("Popup", options[currentOption])).trim();
                onClicked: if (whenDonePopup.visible) { whenDonePopup.close(); } else { whenDonePopup.open(); }
                onCurrentOptionChanged: render_queue.when_done = currentOption;
                Popup {
                    id: whenDonePopup;
                    model: whenDoneBtn.options;
                    currentIndex: whenDoneBtn.currentOption;
                    width: maxItemWidth + 10 * dpiScale;
                    y: -height;
                    itemHeight: 25 * dpiScale;
                    font.pixelSize: 11 * dpiScale;
                    onClicked: i => whenDoneBtn.currentOption = i;
                }
            }
            LinkButton {
                id: queueSettings;
                anchors.right: parent.right;
                anchors.verticalCenter: parent.verticalCenter;
                leftPadding: 2 * dpiScale; rightPadding: 2 * dpiScale;
                font.pixelSize: 10 * dpiScale;
                text: qsTr("Queue settings");
                onClicked: if (queueSettingsMenu.visible) { queueSettingsMenu.dismiss(); } else { queueSettingsMenu.popup(queueSettings, 0, -queueSettingsMenu.height); }

                function setParallelRenders(v: int, menuItem: Menu): void {
                    v = Math.min(6, Math.max(v, 1));

                    render_queue.parallel_renders = v;

                    for (let i = 0; i < menuItem.count; ++i) {
                        if (menuItem.itemAt(i) instanceof QQC.MenuItem) { menuItem.actionAt(i).checked = i == v - 1; }
                    }
                    settings.setValue("parallelRenders", v);
                }
                function setOverwriteAction(v: int, menuItem: Menu): void {
                    v = Math.min(3, Math.max(v, 0));

                    render_queue.overwrite_mode = v;

                    for (let i = 0, j = 0; i < menuItem.count; ++i) {
                        if (menuItem.itemAt(i) instanceof QQC.MenuItem) { menuItem.actionAt(i).checked = j == v; j++;  }
                    }
                    settings.setValue("defaultOverwriteAction", v);
                }
                function setExportMode(v: int, menuItem: Menu): void {
                    v = Math.min(4, Math.max(v, 0));

                    render_queue.export_project = v;

                    for (let i = 0; i < menuItem.count; ++i) {
                        if (menuItem.itemAt(i) instanceof QQC.MenuItem) { menuItem.actionAt(i).checked = i == v; }
                    }
                    settings.setValue("exportMode", v);
                }

                Menu {
                    id: queueSettingsMenu;
                    Menu {
                        id: parallelRendersMenu;
                        title: qsTr("Number of parallel renders");
                        Action { text: "1"; onTriggered: queueSettings.setParallelRenders(1, parallelRendersMenu);  }
                        Action { text: "2"; onTriggered: queueSettings.setParallelRenders(2, parallelRendersMenu);  }
                        Action { text: "3"; onTriggered: queueSettings.setParallelRenders(3, parallelRendersMenu);  }
                        Action { text: "4"; onTriggered: queueSettings.setParallelRenders(4, parallelRendersMenu);  }
                        Action { text: "5"; onTriggered: queueSettings.setParallelRenders(5, parallelRendersMenu);  }
                        Action { text: "6"; onTriggered: queueSettings.setParallelRenders(6, parallelRendersMenu);  }
                        Component.onCompleted: queueSettings.setParallelRenders(+settings.value("parallelRenders", 1), parallelRendersMenu);
                    }
                    Menu {
                        id: overwriteActionMenu;
                        title: qsTr("Default overwrite action");
                        Action { text: qsTr("Ask");            onTriggered: queueSettings.setOverwriteAction(0, overwriteActionMenu); }
                        QQC.MenuSeparator { verticalPadding: 5 * dpiScale; }
                        Action { text: qsTr("Overwrite file"); onTriggered: queueSettings.setOverwriteAction(1, overwriteActionMenu); }
                        Action { text: qsTr("Rename file");    onTriggered: queueSettings.setOverwriteAction(2, overwriteActionMenu); }
                        Action { text: qsTr("Skip file");      onTriggered: queueSettings.setOverwriteAction(3, overwriteActionMenu); }
                        Component.onCompleted: queueSettings.setOverwriteAction(+settings.value("defaultOverwriteAction", 0), overwriteActionMenu);
                    }
                    Menu {
                        id: exportModeMenu;
                        title: qsTr("Export mode");
                        Action { text: qsTr("Stabilized video");                               onTriggered: queueSettings.setExportMode(0, exportModeMenu); }
                        Action { text: qsTr("Project file");                                   onTriggered: queueSettings.setExportMode(1, exportModeMenu); }
                        Action { text: qsTr("Project file (including gyro data)");             onTriggered: queueSettings.setExportMode(2, exportModeMenu); }
                        Action { text: qsTr("Project file (including processed gyro data)");   onTriggered: queueSettings.setExportMode(3, exportModeMenu); }
                        Action { text: qsTr("Stabilized video + Project file with gyro data"); onTriggered: queueSettings.setExportMode(4, exportModeMenu); }
                        Component.onCompleted: queueSettings.setExportMode(+settings.value("exportMode", 0), exportModeMenu);
                    }
                    QQC.MenuSeparator { verticalPadding: 5 * dpiScale; }
                    Action { checked: settings.value("showQueueWhenAdding", true); text: qsTr("Show the media list when adding an item"); onTriggered: { checked = !checked; settings.setValue("showQueueWhenAdding", checked); } }
                    Action { text: qsTr("Clear render queue"); onTriggered: {
                        messageBox(Modal.Warning, qsTr("Are you sure you want to remove all items from the render queue?"), [
                            { text: qsTr("Yes"), clicked: () => { render_queue.clear(); media_library.clear_job_statuses(); } },
                            { text: qsTr("No"), accent: true },
                        ]);
                    } }
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // --------------------------------------- Dialogs -----------------------------------------
    // -----------------------------------------------------------------------------------------

    QQD.FolderDialog {
        id: folderDialog;
        title: qsTr("Select input folder");
        onAccepted: {
            filesystem.folder_access_granted(selectedFolder);
            Qt.callLater(filesystem.save_allowed_folders);
            media_library.add_folder(selectedFolder.toString());
        }
    }
    FileDialog {
        id: filesDialog;
        title: qsTr("Choose a video file");
        nameFilters: Qt.platform.os == "android"? undefined : [qsTr("Video files") + " (*." + fileDialog.extensions.concat(fileDialog.extensions.map(x => x.toUpperCase())).join(" *.") + ")"];
        type: "video";
        fileMode: FileDialog.OpenFiles;
        onAccepted: media_library.add_files(selectedFiles.map(x => x.toString()));
    }

    Rectangle {
        id: dropRect;
        anchors.fill: parent;
        anchors.margins: 5 * dpiScale;
        color: styleBackground;
        radius: 5 * dpiScale;
        opacity: da.containsDrag? 0.85 : 0.0;
        visible: opacity > 0;
        Ease on opacity { duration: 300; }
        BasicText {
            anchors.centerIn: parent;
            width: parent.width - 20 * dpiScale;
            horizontalAlignment: Text.AlignHCenter;
            wrapMode: Text.WordWrap;
            font.pixelSize: 16 * dpiScale;
            text: qsTr("Drop files or folders here");
        }
        Loader {
            anchors.fill: parent;
            anchors.margins: 5 * dpiScale;
            asynchronous: true;
            sourceComponent: Component { DropTargetRect { } }
        }
    }
    DropArea {
        id: da;
        anchors.fill: parent;
        onEntered: (drag) => { drag.accepted = drag.urls.length > 0; }
        onDropped: (drop) => media_library.add_dropped(drop.urls.map(x => x.toString()));
    }

    Component.onCompleted: {
        if (window.advanced) media_library.default_suffix = window.advanced.defaultSuffix.text;
        root.selectedCount = media_library.selected_count();
    }
}
