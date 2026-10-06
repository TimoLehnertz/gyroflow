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
    // The selection is only the working set of the bulk actions, being in the render queue is a separate state
    property int selectedCount: 0;
    property int queueableCount: 0;
    property int queuedSelectedCount: 0;
    property int removableCount: 0;
    property string removableKind: "";
    // Anchor of the shift+click range selection
    property int lastClickedId: 0;
    // Job of the item loaded in the main view, so the bottom bar can show whether it's in the queue
    property int currentJobId: 0;
    property alias queueModal: queueModalLoader;
    readonly property bool listHasFocus: lv.activeFocus;
    // Jobs queued from here, the user already decided to (re-)stabilize these items, so their output is always overwritten
    property var ownJobs: ({ });
    property var lastImport: null;

    Connections {
        target: media_library;
        function onItems_changed(): void { root.refreshState(); }
        function onCurrent_item_changed(): void { root.refreshState(); }
        // The same question wherever the videos were added from (the main view adds them here too), unless the answer
        // was remembered, which the queue settings show and change
        function onSplit_recordings_found(names: string): void {
            root.joinPending = true;
            const remembered = +settings.value("dontShowAgain-join-split-recordings", 0);
            if (remembered) {
                root.joinSplitRecordings(remembered == 1);
                return;
            }
            messageBox(Modal.Question, qsTr("These videos are one recording that the camera split into several files. Do you want to join them into one clip?") + "<br><br><b>" + names.split("\n").join("<br>") + "</b>", [
                { text: qsTr("Yes"), accent: true, clicked: () => root.joinSplitRecordings(true) },
                { text: qsTr("No"),  clicked: () => root.joinSplitRecordings(false) },
            ], null, Text.StyledText, "join-split-recordings");
        }
        function onSplit_recordings_joined(result: string): void {
            const r = JSON.parse(result);
            if (r.errors.length) {
                messageBox(Modal.Error, qsTr("Failed to join the files: %1").arg(r.errors.join("\n")), [ { text: qsTr("Ok") } ]);
            }
            root.joinPending = false;
            // The video in the main view (or a dropped one waiting to be opened) was one of the files, it continues as the joined one
            const joined = r.joined.find(x => x.replaced.includes(root.itemBeforeJoin) || x.replaced.includes(root.openAfterJoin));
            root.itemBeforeJoin = 0;
            if (joined) {
                root.openAfterJoin = 0;
                media_library.select_only(joined.id);
                root.lastClickedId = joined.id;
                media_library.set_current_item(joined.id);
                root.loadItemSettings(joined.id);
            } else {
                root.openDroppedAfterJoin();
            }
        }
    }
    // The trim ranges are edited in the main view: the list shows them (the mini timeline of the video) and the render
    // queue follows them (eg. the key of a deleted range leaves it), so the settings of the item are saved as they change
    Connections {
        target: window.videoArea? window.videoArea.timeline : null;
        function onTrimRangesChanged(): void { rangesSaveTimer.restart(); }
    }
    Timer {
        id: rangesSaveTimer;
        interval: 300;
        // Not while the settings of an item are still being applied to the main view
        onTriggered: if (!window.videoArea.pendingGyroflowData) root.saveCurrentSettings();
    }
    property int itemBeforeJoin: 0;
    // Between finding a split recording and joining it: a dropped video is opened after that, as the joined one if it's one of its files
    property bool joinPending: false;
    property int openAfterJoin: 0;
    function joinSplitRecordings(join: bool): void {
        // The current item, which can still be loading (eg. a video opened when it was dropped)
        const loaded = window.videoArea.loadedFileUrl.toString();
        root.itemBeforeJoin = media_library.current_item > 0? media_library.current_item : (loaded? media_library.find_by_url(loaded) : 0);
        media_library.join_split_recordings(join);
        if (!join) {
            root.joinPending = false;
            root.openDroppedAfterJoin();
        }
    }
    function openDroppedAfterJoin(): void {
        const id = root.openAfterJoin;
        root.openAfterJoin = 0;
        if (id > 0 && media_library.get_item_kind(id)) root.openItem(id);
    }
    function openItem(itemId: int): void {
        media_library.select_only(itemId);
        root.lastClickedId = itemId;
        root.loadItem(itemId);
    }
    function refreshState(): void {
        root.selectedCount      = media_library.selected_count();
        root.queueableCount     = media_library.get_queueable_selection().length;
        root.queuedSelectedCount = media_library.get_queued_selection().length;
        const removable = media_library.get_removable_selection();
        root.removableCount     = removable.length;
        root.removableKind      = removable.length == 1? media_library.get_item_kind(removable[0]) : "";
        root.currentJobId       = media_library.current_item > 0? media_library.get_item_job(media_library.current_item) : 0;
        root.updateOutputFile();
        window.videoArea.timeline.importedMarkers = JSON.parse(media_library.get_timeline_markers(media_library.current_item));
        root.updateKeyStates();
    }

    // -----------------------------------------------------------------------------------------
    // --------------------------------------- Actions -----------------------------------------
    // -----------------------------------------------------------------------------------------

    function saveCurrentSettings(): void {
        const id = media_library.current_item;
        // The main view can show another video than the current item (eg. while a new one is loading), its settings don't belong to this item
        if (id > 0 && window.videoArea.vid.loaded && !window.videoArea.videoLoader.active && !controller.loading_gyro_in_progress && media_library.is_item_url(id, window.videoArea.loadedFileUrl.toString())) {
            media_library.save_settings(id, controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
            root.markQueuedJobOutdated(id);
        }
    }

    function loadItem(itemId: int): void {
        if (itemId <= 0 || itemId == media_library.current_item) return;
        // A path that's still being typed belongs to the item that's shown now
        if (window.outputFile) window.outputFile.commit();
        root.saveCurrentSettings();
        media_library.set_current_item(itemId);
        root.loadItemSettings(itemId);
    }
    // Loads the item into the main view with the settings the library has for it
    function loadItemSettings(itemId: int): void {
        // Show the path of the item before loading, so the video area leaves the output path to the library
        root.updateOutputFile();

        // Every clip starts with one video per range, unless its own settings say otherwise
        if (window.exportSettings) window.exportSettings.exportTrimsSeparately.checked = true;
        const data = media_library.get_project_data(itemId);
        if (data) {
            window.videoArea.loadGyroflowData(JSON.parse(data), 0);
        } else {
            // An item clicked before, still waiting for the previous video to finish loading, would be loaded after this one
            window.videoArea.pendingGyroflowData = null;
            window.videoArea.loadFile(media_library.get_item_url(itemId), true);
        }
    }

    // The output path of the item loaded in the main view is edited in the bottom bar. It's stored as
    // written there: relative to the export folder by default, or absolute if the user picks a folder.
    // When the trim ranges are exported as separate videos, every range has its own output path, and the
    // bottom bar shows and edits the one of the active range (the one the playhead is in, or was in last).
    property bool updatingOutput: false;
    // The item in the main view is resolved with the extension of the codec selected there, which isn't saved with the item yet
    function outputFilename(itemId: int): string {
        return media_library.get_output_filename(itemId, root.outputExtension(itemId));
    }
    function outputExtension(itemId: int): string {
        return itemId == media_library.current_item && window.exportSettings? window.exportSettings.currentExtension() : "";
    }
    // The trim range whose output path is edited in the bottom bar, -1 if it's the output path of the video
    function activeRange(): int {
        const timeline = window.videoArea.timeline;
        const separate = window.exportSettings && window.exportSettings.exportTrimsSeparately.checked;
        return separate && timeline.trimRanges.length > 0? timeline.activeTrimRange : -1;
    }
    function currentOutputPath(itemId: int): string {
        const range = root.activeRange();
        if (range >= 0) return (window.videoArea.timeline.trimRanges[range][2] || { }).output_path || "";
        return media_library.get_output_path(itemId);
    }
    // Shows the output path, the folder and filename it resolves to are what's rendered
    function showOutputPath(itemId: int, path: string, updateText: bool): void {
        const resolved = media_library.resolve_output_path(itemId, path, root.outputExtension(itemId));
        window.outputFile.setResolvedPath(resolved[0], resolved[1], updateText? path : "");
    }
    // Every trim range of the loaded video has its own output path: the ones that don't have one yet
    // get the path of the video with the next free number (clip_stabilized-001, -002, ...)
    function assignRangePaths(): void {
        const id = media_library.current_item;
        const timeline = window.videoArea.timeline;
        if (id <= 0 || !window.videoArea.vid.loaded || window.videoArea.videoLoader.active || controller.loading_gyro_in_progress) return;
        if (!media_library.is_item_url(id, window.videoArea.loadedFileUrl.toString())) return;
        const base = media_library.get_output_path(id);
        const used = timeline.trimRanges.map(x => (x[2] || { }).output_path).filter(x => x);
        let number = 1;
        let changed = false;
        for (let i = 0; i < timeline.trimRanges.length; ++i) {
            const info = timeline.trimRangeInfo(i);
            if (info.output_path) continue;
            let path = "";
            do { path = base + "-" + ("00" + number++).slice(-3); } while (used.includes(path));
            used.push(path);
            info.output_path = path;
            changed = true;
        }
        if (changed) timeline.trimRangesChanged();
    }
    function updateOutputFile(): void {
        const id = media_library.current_item;
        // Don't type over the field while the user is editing it
        if (!window.outputFile || root.updatingOutput) return;
        root.updatingOutput = true;
        if (id > 0) root.showOutputPath(id, root.currentOutputPath(id), true);
        window.outputFile.pathMode = id > 0;
        root.updatingOutput = false;
    }
    // The output path can also be changed in the bottom bar, store it in the library then
    function pushOutputToItem(path: string): void {
        const id = media_library.current_item;
        if (root.updatingOutput || id <= 0) return;
        root.updatingOutput = true;
        const range = root.activeRange();
        if (range >= 0) {
            // It's part of the settings of the video, like the trim range itself
            window.videoArea.timeline.setTrimRangeOutputPath(range, path);
            // An emptied path gets the default one of the range again
            root.assignRangePaths();
            root.saveCurrentSettings();
        } else {
            media_library.set_output_path(id, path);
            root.updateQueuedJob(id);
        }
        root.updatingOutput = false;
        // Show the path as it's stored now
        root.updateOutputFile();
    }
    Connections {
        target: window.outputFile;
        function onPathEdited(path: string): void { root.pushOutputToItem(path); }
        function onResolveRequested(): void {
            const id = media_library.current_item;
            if (id > 0) root.showOutputPath(id, root.currentOutputPath(id), false);
        }
    }
    Connections {
        target: window.videoArea.timeline;
        function onTrimRangesChanged(): void { root.assignRangePaths(); root.updateOutputFile(); }
        function onActiveTrimRangeChanged(): void { root.updateOutputFile(); }
    }
    Connections {
        target: window.exportSettings? window.exportSettings.exportTrimsSeparately : null;
        function onCheckedChanged(): void { root.updateOutputFile(); }
    }

    // The dropped markers.json files, their markers are merged
    property var pendingMarkerFiles: [];

    function openImportMarkers(urls): void {
        root.saveCurrentSettings();
        root.pendingMarkerFiles = urls || [];
        importModalLoader.active = true;
        if (importModalLoader.item) root.finishOpenImportMarkers();
    }
    function finishOpenImportMarkers(): void {
        const modal = importModalLoader.item;
        if (root.pendingMarkerFiles.length) {
            modal.loadFiles(root.pendingMarkerFiles);
            root.pendingMarkerFiles = [];
        }
        modal.open();
    }
    function handleDroppedUrls(urls) {
        const jsons = [];
        const rest = [];
        for (const u of urls) {
            if (!u) continue;
            if (u.split("?")[0].toLowerCase().endsWith(".json")) jsons.push(u);
            else rest.push(u);
        }
        if (rest.length) media_library.add_dropped(rest.join("\n"));
        if (rest.length) root.rememberMediaFolder(rest[0].toString());
        // A dropped video is opened right away (a dropped folder is only added to the list)
        const openId = rest.map(u => media_library.find_by_url(u)).find(x => x > 0);
        if (openId) {
            // Files of a split recording are opened once it's clear whether they are joined
            if (root.joinPending) root.openAfterJoin = openId;
            else root.openItem(openId);
        }
        if (jsons.length) root.openImportMarkers(jsons);
    }
    function applyImportedMarkers(offsetHours: real, queue: bool): void {
        const result = JSON.parse(media_library.import_markers(offsetHours * 3600));
        if (result.error) {
            messageBox(Modal.Error, result.error, [ { text: qsTr("Ok") } ]);
            return;
        }
        result.queued = queue;
        root.lastImport = result;
        // The video in the main view doesn't have the new trim ranges yet, and saving its settings would drop them again.
        // Its settings were saved when the import was opened, so load it again with the ranges.
        const current = media_library.current_item;
        if ((result.queue_ids || []).includes(current) && window.videoArea.vid.loaded && !window.videoArea.videoLoader.active && !controller.loading_gyro_in_progress) {
            root.loadItemSettings(current);
        }
        if (queue) {
            for (const id of result.queue_ids || []) root.queueItem(id);
        }
        root.refreshState();
        showNotification(Modal.Success, qsTr("Added %1 trim ranges.").arg("<b>" + (result.sections || 0) + "</b>"));
    }

    function applyStabilizationToAll(): void {
        root.saveCurrentSettings();
        if (!window.videoArea.vid.loaded) {
            messageBox(Modal.Error, qsTr("Load a video first to apply its settings to the other videos."), [ { text: qsTr("Ok") } ]);
            return;
        }
        const allData = JSON.parse(controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
        // The current video keeps its settings, including the separate ones of its trim ranges
        const count = media_library.apply_stabilization_to_all(JSON.stringify({ stabilization: allData.stabilization }), media_library.current_item);
        root.updateQueuedJobs();
        showNotification(Modal.Success, qsTr("Stabilization settings applied to %1 items.").arg("<b>" + count + "</b>"));
    }

    // -----------------------------------------------------------------------------------------
    // -------------------------------------- Selection ----------------------------------------
    // -----------------------------------------------------------------------------------------

    // A plain click selects one item and loads it, ctrl+click toggles one and shift+click selects a range
    function clickItem(itemId: int, modifiers: int): void {
        lv.forceActiveFocus();
        if (modifiers & Qt.ShiftModifier) {
            media_library.select_range(root.lastClickedId, itemId);
        } else if (modifiers & Qt.ControlModifier) {
            media_library.toggle_selected(itemId);
            root.lastClickedId = itemId;
        } else {
            media_library.select_only(itemId);
            root.lastClickedId = itemId;
            root.loadItem(itemId);
        }
    }

    // -----------------------------------------------------------------------------------------
    // ------------------------------------ Queueing items -------------------------------------
    // -----------------------------------------------------------------------------------------

    // Queueing is always an explicit action: the selection is just the set of items it's applied to
    function queueSelected(): void {
        const ids = media_library.get_queueable_selection();
        if (!ids.length) return;
        // The main view can have unsaved changes of the item that's being queued
        root.saveCurrentSettings();
        for (const id of ids) root.queueItem(id);
    }
    function unqueueSelected(): void {
        for (const id of media_library.get_queued_selection()) root.unqueueItem(id);
    }
    function unqueueItem(itemId: int): void {
        if (media_library.get_item_job_status(itemId) == "rendering" || media_library.get_item_job_status(itemId) == "processing") return;
        root.cancelItem(itemId);
    }
    // Bring a job to the front of the queue and let `start` pick it up as soon as a render slot
    // is free, instead of rendering it right away regardless of the parallel renders limit.
    function prioritizeJob(job_id: int): void {
        render_queue.move_item(job_id, -1000000);
        render_queue.start();
    }
    // The render queue is an ordered set of keys, a video of the list and what of it is rendered (its `seq`: the id of a
    // trim range, or "" for the whole video). The keys are kept by the media library, which decides what's queued (see
    // "Render queue keys" in media_library.rs). This only does the work it asks for: every key gets its own job, which
    // only renders that key, and jobs of keys that aren't queued anymore are removed. The jobs of a video share the loaded
    // video, its first job loads it and the others are added from that one

    // All keys of the video in its export mode. A video that's queued again (eg. by a marker import) gets new jobs instead
    // of its old ones, which would stay in the queue with the old settings
    function queueItem(itemId: int): void {
        if (media_library.is_item_queued(itemId)) {
            const status = media_library.get_item_job_status(itemId);
            if (status == "rendering" || status == "processing") return;
            media_library.set_item_job(itemId, 0);
        }
        media_library.enqueue_all(itemId);
    }
    function enqueue(itemId: int, seq: string): void { media_library.enqueue(itemId, seq); }
    function dequeue(itemId: int, seq: string): void { media_library.dequeue(itemId, seq); }

    property bool queueWorkScheduled: false;
    function scheduleQueueWork(): void {
        if (root.queueWorkScheduled) return;
        root.queueWorkScheduled = true;
        Qt.callLater(root.doQueueWork);
    }
    function doQueueWork(): void {
        root.queueWorkScheduled = false;
        let added = false;
        for (const work of JSON.parse(media_library.get_queue_work())) {
            for (const seq of work.pending) {
                if (work.base_job > 0) {
                    // From the loaded video of another job of the video
                    const output = JSON.parse(media_library.get_item_outputs(work.item_id, "")).find(x => x.seq == seq);
                    const jobId = output? render_queue.add_range_job(work.base_job, JSON.stringify(output)) : 0;
                    if (!jobId) continue;
                    root.ownJobs[jobId] = true;
                    media_library.set_key_job(work.item_id, seq, jobId, false);
                    root.syncJob(work.item_id, jobId, true);
                    added = true;
                } else if (!work.loading) {
                    // The first job of the video loads it, the other keys wait for it (see onProcessing_done)
                    const jobId = render_queue.add_file(work.url, "", JSON.stringify(root.jobData(work.item_id)));
                    root.pendingJobs[jobId] = true;
                    root.ownJobs[jobId] = true;
                    media_library.set_key_job(work.item_id, seq, jobId, true);
                    break;
                }
            }
            // A job that's loading the video can't be removed yet, it's removed once it's loaded
            for (const retired of work.retired) {
                if (retired.loading) continue;
                render_queue.remove(retired.job_id);
                media_library.forget_retired(work.item_id, retired.job_id);
            }
        }
        // Queued jobs wait for the user to start the queue, but a running queue picks up the new ones
        if (added && render_queue.status == "active") render_queue.start();
    }
    Connections {
        target: media_library;
        function onQueue_keys_changed(): void { root.scheduleQueueWork(); }
        function onKey_states_changed(item_id: int): void { if (item_id == media_library.current_item) root.updateKeyStates(); }
        function onCurrent_item_changed(): void { root.updateKeyStates(); }
    }
    // Queue state of the keys of the video in the main view (`seq` → status, see `get_key_states`), shown on the timeline
    // and used by the queue button of the bottom bar. They look up their trim ranges by the ids the timeline has
    property var keyStates: ({ });
    function updateKeyStates(): void {
        const states = media_library.current_item > 0? JSON.parse(media_library.get_key_states(media_library.current_item)) : ({ });
        if (JSON.stringify(states) != JSON.stringify(root.keyStates)) root.keyStates = states;
    }
    // The job renders its key with the settings the video has now: the ones of its trim range, if it has its own, and the
    // output file of the key. Jobs that started rendering are left as they are, unless `loaded` (it just loaded the video)
    function syncJob(itemId: int, jobId: int, loaded: bool): void {
        if (!loaded && media_library.get_job_status(jobId) != "queued") return;
        const seq = media_library.get_job_seq(jobId);
        const file = JSON.parse(media_library.get_item_outputs(itemId, "")).find(x => x.seq == seq);
        if (!file) return;
        const settings = media_library.get_settings_for_job(jobId);
        let data = settings? JSON.parse(settings) : ({ title: "Gyroflow data file", version: 4 });
        const output = root.jobData(itemId).output;
        // A range with its own settings keeps its own export settings, every key renders to its own file
        const rangeOutput = file.own_settings? (data.output || { }) : { };
        data.output = Object.assign({ }, output, rangeOutput, { output_folder: file.output_folder, output_filename: file.output_filename });
        // The metadata has the stabilization hash, which tells whether the rendered file is up to date
        data.output.metadata = output.metadata;
        render_queue.apply_to_all(JSON.stringify(data), window.getAdditionalProjectDataJson(), jobId);
        render_queue.set_job_output(jobId, file.range_index, "", "");
    }
    // Trim ranges with their own stabilization settings got their own copy of the loaded video, apply their settings to it
    function applyRangeSettings(itemId: int, jobIds: var, outputs: var): void {
        const additionalData = window.getAdditionalProjectDataJson();
        for (let i = 0; i < jobIds.length && i < outputs.length; ++i) {
            if (!outputs[i].own_settings) continue;
            const data = media_library.get_range_settings(itemId, outputs[i].range_index);
            if (data) render_queue.apply_to_all(data, additionalData, jobIds[i]);
        }
    }
    // Render settings of the job, with the export settings, the output path and the settings hash of this item
    function jobData(itemId: int): var {
        let ad = JSON.parse(JSON.stringify(window.getAdditionalProjectData()));
        ad.output = ad.output || ({ });
        const isLoaded = media_library.current_item == itemId && window.videoArea.vid.loaded && !window.videoArea.videoLoader.active;
        const saved = isLoaded? "" : media_library.get_output_settings(itemId);
        if (saved) {
            ad.output = JSON.parse(saved);
        } else if (!isLoaded) {
            // Not configured yet, use the current export settings, but every video is rendered in its own resolution
            delete ad.output.output_width;
            delete ad.output.output_height;
        }
        ad.output.output_folder   = media_library.get_output_folder(itemId);
        ad.output.output_filename = isLoaded? root.outputFilename(itemId) : media_library.get_output_filename(itemId, "");
        ad.output.metadata = Object.assign({ }, ad.output.metadata || { }, { stabilization_hash: media_library.settings_hash(itemId) });
        return ad;
    }
    // An item can be edited while it's waiting in the queue, keep its jobs up to date until they start rendering. Which of
    // its keys are queued follows its settings in the media library (see `reconcile_keys`)
    function updateQueuedJob(itemId: int): void {
        delete root.outdatedJobItems[itemId];
        for (const jobId of media_library.get_item_jobs(itemId)) root.syncJob(itemId, jobId, false);
    }
    function updateQueuedJobs(): void {
        for (const id of media_library.get_render_items(false)) root.markQueuedJobOutdated(id);
    }
    // Changing settings only updates the config of the items, which is instant. Their queued jobs are synced from it
    // afterwards, one item per event loop iteration so the UI doesn't stall, and all at once before the queue starts a job
    property var outdatedJobItems: ({ });
    function markQueuedJobOutdated(itemId: int): void {
        if (!media_library.get_item_jobs(itemId).length) return;
        root.outdatedJobItems[itemId] = true;
        outdatedJobsTimer.start();
    }
    function syncOutdatedJob(itemId: int): void {
        if (root.outdatedJobItems[itemId]) root.updateQueuedJob(itemId);
    }
    function syncOutdatedJobs(): void {
        for (const id of Object.keys(root.outdatedJobItems)) root.syncOutdatedJob(+id);
    }
    Timer {
        id: outdatedJobsTimer;
        interval: 1;
        onTriggered: {
            const ids = Object.keys(root.outdatedJobItems);
            if (!ids.length) return;
            root.syncOutdatedJob(+ids[0]);
            if (ids.length > 1) outdatedJobsTimer.start();
        }
    }
    // "Apply settings to render queue": the jobs of the library items are synced from the item settings,
    // so those are updated instead of the jobs directly, otherwise the next sync would revert them
    function applySettingsToQueue(data: var): void {
        const json = JSON.stringify(data);
        const folder = data.output && data.output.output_folder;
        let libraryJobs = ({ });
        for (const id of media_library.apply_settings_to_queued(json)) {
            if (folder) media_library.set_output_url(id, folder, media_library.get_output_filename(id, ""));
            for (const jobId of media_library.get_item_jobs(id)) libraryJobs[jobId] = true;
            root.markQueuedJobOutdated(id);
        }
        // Jobs that were added outside of the library
        const additionalData = window.getAdditionalProjectDataJson();
        for (const jobId of render_queue.get_job_ids()) {
            if (!libraryJobs[jobId] && !media_library.is_library_job(jobId)) render_queue.apply_to_all(json, additionalData, jobId);
        }
    }

    // The item of the video currently loaded in the main view, adding it to the list
    // as a standalone entry if it isn't tracked in a watched folder yet. 0 if there's nothing loaded.
    function loadedItem(): int {
        const url = window.videoArea.loadedFileUrl.toString();
        if (!url) return 0;
        let itemId = media_library.is_item_url(media_library.current_item, url)? media_library.current_item : media_library.find_by_url(url);
        if (itemId <= 0) {
            media_library.add_url(url);
            itemId = media_library.find_by_url(url);
            if (itemId <= 0) return 0;
        }
        if (media_library.current_item != itemId) media_library.set_current_item(itemId);
        return itemId;
    }
    // The "Add to render queue" button of the bottom bar queues the loaded item through the same path
    // the sidebar uses, so there's only one way a job is created. Returns the queued item id, or 0.
    // `range` >= 0 queues only that trim range (with the trim ranges exported as separate videos), -1 all of them
    function queueLoadedFile(range: int): int {
        const itemId = root.loadedItem();
        if (itemId <= 0) return 0;
        // The settings of the main view are the ones of this item
        root.saveCurrentSettings();
        if (range >= 0) {
            root.enqueue(itemId, media_library.get_seq_of_range(itemId, range));
        } else {
            // The keys that aren't queued yet
            media_library.enqueue_all(itemId);
        }
        const index = media_library.get_item_index(itemId);
        if (index >= 0) lv.positionViewAtIndex(index, ListView.Contain);
        return itemId;
    }
    // The output files of the video loaded in the main view, with its current settings: one per trim range
    // if they are exported as separate videos, only the one of `onlyRange` if it's >= 0. Empty if it's not a video of the library
    function loadedOutputs(onlyRange: int): var {
        const itemId = root.loadedItem();
        if (itemId <= 0) return [];
        root.saveCurrentSettings();
        const outputs = JSON.parse(media_library.get_item_outputs(itemId, root.outputExtension(itemId)));
        if (onlyRange < 0) return outputs;
        const own = outputs.filter(x => x.range_index == onlyRange);
        return own.length? own : outputs;
    }
    // "Stabilize now" renders the main view in one job, split it into one job per output file like the queue does,
    // or into the job of `onlyRange` if it's >= 0. Returns the ids of the jobs, in the order of the trim ranges
    function splitDirectJob(jobId: int, onlyRange: int): var {
        const outputs = root.loadedOutputs(onlyRange);
        if (outputs.length <= 1 && (!outputs.length || outputs[0].range_index < 0)) return [jobId];
        const ids = render_queue.split_job_by_ranges(jobId, JSON.stringify(outputs));
        root.applyRangeSettings(root.loadedItem(), ids, outputs);
        return ids;
    }
    // "Stabilize now" of the bottom bar for a video of the list: it's opened first if it isn't the one in the main view,
    // and its active range (or the whole video) is rendered once it's ready
    property int pendingStabilizeItem: 0;
    function stabilizeItem(itemId: int): void {
        if (itemId != media_library.current_item) {
            media_library.select_only(itemId);
            root.lastClickedId = itemId;
            root.loadItem(itemId);
        }
        root.pendingStabilizeItem = itemId;
        stabilizeWhenReady.elapsed = 0;
        stabilizeWhenReady.restart();
    }
    Timer {
        id: stabilizeWhenReady;
        interval: 200;
        repeat: true;
        property int elapsed: 0;
        onTriggered: {
            const id = root.pendingStabilizeItem;
            elapsed += interval;
            // Another video was opened meanwhile, or it doesn't load
            if (id != media_library.current_item || elapsed > 120000) { stop(); root.pendingStabilizeItem = 0; return; }
            const ready = window.renderBtn.canExport && !controller.loading_gyro_in_progress && !window.videoArea.pendingGyroflowData
                       && media_library.is_item_url(id, window.videoArea.loadedFileUrl.toString());
            if (!ready) return;
            stop();
            root.pendingStabilizeItem = 0;
            window.renderBtn.stabilizeNow();
        }
    }
    // Video information, lens profile and motion data are set up for the video in the main view, load it first
    function showDetails(itemId: int): void {
        if (itemId != media_library.current_item) {
            media_library.select_only(itemId);
            root.loadItem(itemId);
        }
        window.videoDetails.shown = true;
    }
    function unqueueLoadedFile(): void {
        const itemId = root.loadedItem();
        if (itemId > 0) root.unqueueItem(itemId);
    }
    function unqueueLoadedRange(range: int): void {
        const itemId = root.loadedItem();
        if (itemId > 0) root.dequeue(itemId, media_library.get_seq_of_range(itemId, range));
    }

    // The render queue itself is managed in its own modal, opened from here or from the bottom bar
    function showQueue(): void {
        queueModalLoader.active = true;
        if (queueModalLoader.item) queueModalLoader.item.shown = true;
    }

    function removeItem(itemId: int): void {
        const jobs = media_library.remove_item(itemId);
        for (const jobId of jobs) render_queue.remove(jobId);
    }
    function removeSelected(): void {
        const jobs = media_library.remove_selected();
        for (const jobId of jobs) render_queue.remove(jobId);
    }
    // Out of the queue: its jobs are removed by the queue (see `doQueueWork`)
    function cancelItem(itemId: int): void {
        media_library.set_item_job(itemId, 0);
    }
    function resetItem(itemId: int): void {
        const jobIds = media_library.get_item_jobs(itemId);
        if (!jobIds.length) return;
        const status = media_library.get_item_job_status(itemId);
        for (const jobId of jobIds) render_queue.reset_job(jobId);
        media_library.reset_item_job_states(itemId);
        // Finished or failed jobs render again with the settings the item has now, running ones are only stopped
        if (status != "rendering" && status != "processing") root.updateQueuedJob(itemId);
    }

    // -----------------------------------------------------------------------------------------
    // ------------------------------------- Render queue --------------------------------------
    // -----------------------------------------------------------------------------------------

    // Every job of the render queue belongs to an item in this list, no matter if it was queued from here,
    // exported directly from the bottom bar or restored from the previous session. This mirrors the state
    // of the jobs onto their items, the queue itself stays the only source of truth for what is queued.
    Instantiator {
        model: render_queue.queue;
        delegate: QtObject {
            property string errorString: error_string;
            onErrorStringChanged: root.updateJobState(job_id, errorString);
            // The job is not fully set up yet when the row is added, so register it in the next event loop iteration
            Component.onCompleted: root.scheduleJobRegistration(job_id, input_file, output_folder, output_filename);
        }
    }
    // Jobs removed from the queue elsewhere (the queue modal, clearing the queue) lose their item as well.
    // A job that was just added doesn't have its row yet, so it's kept until it shows up in the queue.
    property var pendingJobs: ({ });
    function syncJobsWithQueue(): void {
        const ids = render_queue.get_job_ids().concat(Object.keys(root.pendingJobs).map(x => +x));
        media_library.retain_jobs(ids);
        let own = ({ });
        for (const id of ids) { if (root.ownJobs[id]) own[id] = true; }
        root.ownJobs = own;
    }
    property var jobsToRegister: [];
    function scheduleJobRegistration(jobId: int, inputFile: string, outputFolder: string, outputFilename: string): void {
        delete root.pendingJobs[jobId]; // It's in the queue now
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
            media_library.add_url(inputFile);
            itemId = media_library.find_by_url(inputFile);
        }
        if (itemId <= 0) return;
        // The job was configured elsewhere, take its settings and output path as the ones of the item.
        // A job of a single trim range has the output file of that range, not the one of the video
        const rangeIndex = render_queue.get_job_range_index(jobId);
        const data = render_queue.get_gyroflow_data(jobId);
        if (data && data.includes("\"stabilization\"")) media_library.save_settings(itemId, data);
        if (rangeIndex < 0) media_library.set_output_url(itemId, outputFolder, outputFilename);
        // Its key is the trim range it renders (the settings above gave the ranges their ids)
        media_library.add_item_job(itemId, jobId, rangeIndex < 0? "" : media_library.get_seq_of_range(itemId, rangeIndex));
    }
    function renameJobOutput(itemId: int, jobId: int, filename: string, folder: string, start: bool): void {
        const newName = window.renameOutput(filename, folder);
        render_queue.set_job_output_filename(jobId, newName, start);
        if (itemId > 0 && render_queue.get_job_range_index(jobId) < 0) media_library.set_output_url(itemId, folder, newName);
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
        function onAbout_to_start(): void { root.syncOutdatedJobs(); }
        function onProcessing_done(job_id: real, by_preset: bool): void {
            if (by_preset) return;
            // Either the job made it into the queue by now, or it never will
            delete root.pendingJobs[job_id];
            if (!media_library.is_library_job(job_id)) return;
            // The video is loaded in the queue now: the job gets the settings of its key (unless it was taken out of the
            // queue meanwhile), the keys that wait for it get their jobs, or it's removed (see `doQueueWork`)
            const itemId = media_library.get_item_for_job(job_id);
            if (media_library.get_item_job_for_seq(itemId, media_library.get_job_seq(job_id)) == job_id) root.syncJob(itemId, job_id, true);
            media_library.job_loaded(job_id);
            // Queued jobs wait for the user to start the queue, but a running queue picks up the new ones
            if (render_queue.status == "active") render_queue.start();
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
            if (media_library.active_job_count() == 0) media_library.refresh_outputs();
        }
        function onQueue_changed():  void { render_queue.save_render_queue(); root.syncJobsWithQueue(); root.refreshState(); }
        function onStatus_changed(): void { render_queue.save_render_queue(); }
        function onRequest_close(): void {
            main_window.closeConfirmed = true;
            Qt.callLater(Qt.quit);
        }
    }

    // Adds the unfinished jobs of previous sessions back to the queue, they show up in the list above.
    // When there are none and `reportNone` is set, it says so.
    function restorePreviousQueue(reportNone: bool): void {
        if (render_queue.restore_render_queue(window.getAdditionalProjectDataJson())) {
            messageBox(Modal.Info, qsTr("You have unfinished tasks in the render queue."), [
                { text: qsTr("Open render queue"), accent: true, clicked: function() { root.showQueue(); } },
                { text: qsTr("Ok") }
            ]);
        } else if (reportNone) {
            messageBox(Modal.Info, qsTr("There are no unfinished tasks from previous sessions."), [ { text: qsTr("Ok") } ]);
        }
    }

    // Unfinished jobs of previous sessions are restored on start, unless disabled in the settings dialog.
    // Otherwise they are kept and can be restored later from there.
    Timer {
        interval: 100;
        running: window.exportSettings != null && window.sync != null;
        onTriggered: {
            if (settings.value("restorePreviousQueue", true) === false) return;
            Qt.callLater(() => root.restorePreviousQueue(false));
        }
    }

    // The main view can also be loaded from outside of the sidebar, in that case follow the loaded file.
    // It's added to the list if needed, so its output path is managed (and kept) by the library like any other.
    // This happens before the video area sets up the output path for the new file, so it leaves it to the library.
    Connections {
        target: window.videoArea;
        function onLoadedFileUrlChanged(): void {
            const url = window.videoArea.loadedFileUrl.toString();
            if (!media_library.is_item_url(media_library.current_item, url)) {
                root.saveCurrentSettings();
                if (root.loadedItem() <= 0) media_library.set_current_item(0);
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
            height: logo.height + 12 * dpiScale;
            Image {
                id: logo;
                source: "qrc:/resources/logo" + (style === "dark"? "_white" : "_black") + ".svg"
                sourceSize.width: Math.min(220 * dpiScale, parent.width * 0.8 - 2 * settingsBtn.width);
                anchors.centerIn: parent;
            }
            LinkButton {
                id: settingsBtn;
                width: 32 * dpiScale;
                height: 32 * dpiScale;
                leftPadding: 0; rightPadding: 0;
                iconName: "settings";
                textColor: styleTextColor;
                transparent: true;
                anchors.right: parent.right;
                anchors.verticalCenter: parent.verticalCenter;
                tooltip: qsTr("Settings");
                onClicked: window.globalSettings.show();
            }
        }
        Hr { width: parent.width; }

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
                    onClicked: folderDialog.openInLastFolder();
                }
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "plus";
                    tooltip: qsTr("Add video files");
                    onClicked: filesDialog.openInLastFolder();
                }
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "file-empty";
                    tooltip: qsTr("Import markers.json");
                    enabled: !media_library.scanning && media_library.items.rowCount() > 0;
                    onClicked: root.openImportMarkers();
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
                                root.lastImport = null;
                            } },
                            { text: qsTr("No") }
                        ]);
                    }
                }
                // Shown again with the button at the left of the bottom bar
                LinkButton {
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    iconName: "chevron-left";
                    tooltip: qsTr("Hide the media list");
                    onClicked: window.mediaPanelShown = false;
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
        focus: true;
        Shortcut {
            sequences: ["Delete", "Backspace"];
            context: Qt.WidgetWithChildrenShortcut;
            // Only while the list has the focus, otherwise Delete removes the active trim range of the timeline
            enabled: root.removableCount > 0 && lv.activeFocus;
            onActivated: root.removeSelected();
        }
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                if (root.removableCount > 0) root.removeSelected();
                event.accepted = true;
            }
        }
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
            // A file of a joined video, listed below it
            property bool isPart:    kind == "part";
            property bool isRendering:  job_status == "rendering";
            property bool isProcessing: job_status == "processing";
            property bool isQueued:     job_status == "queued";
            property bool isJobError:   job_status == "error";
            property bool isQuestion:   job_status == "question";
            property bool isJobDone:    job_status == "done";
            property bool isBusy: dlg.isRendering || dlg.isProcessing;
            // Being in the render queue is shown independently of the selection, an item can be both
            property bool isInQueue: queue_state.length > 0;

            color: selected?     "#33ffffff"
                 : isJobError?   "#30ed7676"
                 : isQuestion?   "#30" + styleAccentColor.toString().substring(1)
                 // All of it is in the render queue (all of its trim ranges, or the whole video)
                 : queue_state == "all"? Qt.rgba(styleQueuedColor.r, styleQueuedColor.g, styleQueuedColor.b, 0.2)
                 : stabilized_state == 1? "#3070e574"
                 : stabilized_state == 2? "#30f6a00b"
                 : "transparent";
            border.width: selected || is_current? 1 * dpiScale : 0;
            border.color: selected? "#99ffffff" : styleAccentColor;

            // Queued items get an accent stripe on the left, which stays visible while they are selected
            Rectangle {
                visible: dlg.isInQueue;
                width: 3 * dpiScale;
                height: parent.height - 8 * dpiScale;
                radius: width;
                x: 1 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
                color: dlg.isJobError? "#ed7676" : dlg.isJobDone? "#70e574" : styleQueuedColor;
            }

            MouseArea {
                anchors.fill: parent;
                acceptedButtons: Qt.LeftButton;
                cursorShape: dlg.isFolder? Qt.ArrowCursor : Qt.PointingHandCursor;
                onClicked: (mouse) => {
                    lv.forceActiveFocus();
                    if (dlg.isPart) {
                        root.clickItem(parent_id, mouse.modifiers);
                    } else if (dlg.isFolder) {
                        if (mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) {
                            root.clickItem(item_id, mouse.modifiers);
                        } else {
                            media_library.toggle_expanded(item_id);
                        }
                    } else {
                        root.clickItem(item_id, mouse.modifiers);
                    }
                }
            }
            ContextMenuMouseArea {
                // Right clicking an item that isn't part of the selection makes it the selection first
                onContextMenu: (isHold, mx, my) => {
                    if (dlg.isPart) return;
                    lv.forceActiveFocus();
                    if (!selected) root.clickItem(item_id, Qt.NoModifier);
                    itemMenu.popup(dlg, mx, my);
                }
            }
            // Created on the first right click: a menu in every row made adding videos slow, all rows are created at once
            ContextMenuLoader {
                id: itemMenu;
                sourceComponent: Component {
                    Menu {
                        font.pixelSize: 11.5 * dpiScale;
                        hideDisabled: true;
                        Action {
                            iconName: "queue";
                            text: qsTr("Add %1 selected to the render queue").arg(root.queueableCount);
                            enabled: root.queueableCount > 0;
                            onTriggered: root.queueSelected();
                        }
                        Action {
                            iconName: "close";
                            text: qsTr("Remove %1 selected from the render queue").arg(root.queuedSelectedCount);
                            enabled: root.queuedSelectedCount > 0;
                            onTriggered: root.unqueueSelected();
                        }
                        Action {
                            iconName: "video";
                            text: qsTr("Stabilize now…");
                            enabled: !dlg.isFolder && !dlg.isPart;
                            onTriggered: root.stabilizeItem(item_id);
                        }
                        Action {
                            iconName: "pencil";
                            text: qsTr("Edit render settings");
                            // The jobs of the trim ranges of a video are edited through the video itself
                            enabled: job_id > 0 && job_count == 1 && !dlg.isBusy;
                            onTriggered: {
                                root.syncOutdatedJob(item_id);
                                const data = render_queue.get_gyroflow_data(job_id);
                                if (data) window.videoArea.loadGyroflowData(JSON.parse(data), job_id);
                            }
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
                            onTriggered: filesystem.open_file_externally(filesystem.get_file_url(media_library.get_output_folder(item_id), media_library.get_output_filename(item_id, ""), false));
                        }
                        Action {
                            iconName: "info";
                            text: qsTr("Video details");
                            enabled: !dlg.isFolder;
                            onTriggered: root.showDetails(item_id);
                        }
                        Action {
                            iconName: "folder";
                            text: qsTr("Open file location");
                            onTriggered: filesystem.open_file_externally(dlg.isFolder? url : filesystem.get_folder(url));
                        }
                        Action {
                            iconName: "bin";
                            text: root.removableCount > 1? qsTr("Remove %1 selected").arg(root.removableCount)
                                : root.removableKind == "folder"? qsTr("Remove folder")
                                : qsTr("Remove video");
                            enabled: root.removableCount > 0;
                            onTriggered: root.removeSelected();
                        }
                    }
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
                    QQCI.IconImage {
                        id: itemIcon;
                        anchors.left: parent.left;
                        anchors.leftMargin: 20 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        name: dlg.isFolder? "folder" : "video";
                        source: "qrc:/resources/icons/svg/" + (dlg.isFolder? "folder" : "video") + ".svg";
                        color: styleTextColor;
                        opacity: dlg.isPart? 0.5 : 1;
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
                        QQC.BusyIndicator {
                            visible: scanning;
                            height: 16 * dpiScale;
                            width: height;
                            padding: 0;
                            anchors.verticalCenter: parent.verticalCenter;
                            running: visible;
                        }
                        // Video information, lens profile and motion data of the video
                        LinkButton {
                            visible: !dlg.isFolder && !dlg.isPart;
                            width: 20 * dpiScale;
                            height: 20 * dpiScale;
                            anchors.verticalCenter: parent.verticalCenter;
                            leftPadding: 0; rightPadding: 0;
                            icon.width: 12 * dpiScale;
                            icon.height: 12 * dpiScale;
                            iconName: "info";
                            tooltip: qsTr("Video information, lens profile and motion data");
                            onClicked: root.showDetails(item_id);
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
                            ToolTip { visible: !isMobile && ma2.containsMouse; text: qsTr("No lens profile detected for this video. Click to choose one."); }
                            MouseArea { id: ma2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.showDetails(item_id); }
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
                                : dlg.isQueued?      (queue_state == "some"? qsTr("%1/%2 queued").arg(queued_count).arg(key_count) : qsTr("Queued"))
                                : dlg.isJobDone?     qsTr("Done")
                                : stabilized_state == 2? qsTr("Changed")
                                : stabilized_state == 1? qsTr("Stabilized") : "";
                        }
                    }
                }
                // Where the trim ranges are in the video (for every video with ranges), and which of them are in the render queue:
                // queued or rendering ones in the queue color, done ones green, failed ones red, the others dim
                Item {
                    id: rangeBar;
                    readonly property var ranges: range_bar? JSON.parse(range_bar) : [];
                    visible: !dlg.isFolder && !dlg.isPart && ranges.length > 0;
                    width: parent.width;
                    height: 16 * dpiScale;
                    RangeTrack {
                        x: 24 * dpiScale;
                        width: parent.width - x;
                        height: 12 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        ranges: rangeBar.ranges.map((x, i) => ({
                            start: x[0], end: x[1],
                            color: x[2] == "done"? "#70e574"
                                 : x[2] == "error" || x[2] == "question"? "#ed7676"
                                 : x[2]? styleQueuedColor
                                 : Qt.rgba(styleTextColor.r, styleTextColor.g, styleTextColor.b, 0.35),
                            tooltip: qsTr("Range %1").arg(i + 1) + ": " + (x[2] == "done"? qsTr("Done") : x[2] == "error"? qsTr("Error")
                                   : x[2] == "rendering" || x[2] == "processing"? qsTr("Rendering") : x[2]? qsTr("Queued") : qsTr("Not queued"))
                        }));
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
                    visible: !dlg.isFolder && duration_ms > 0;
                    width: parent.width;
                    leftPadding: 24 * dpiScale;
                    font.pixelSize: 10 * dpiScale;
                    opacity: 0.7;
                    elide: Text.ElideMiddle;
                    text: {
                        let parts = [];
                        if (duration_ms > 0) parts.push(Math.floor(duration_ms / 60000) + ":" + ("0" + Math.floor((duration_ms % 60000) / 1000)).slice(-2));
                        if (created_at > 0) parts.push(new Date(created_at * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat));
                        if (part_count > 1) parts.push(qsTr("%1 files joined").arg(part_count));
                        if (range_count > 1) parts.push(output_count > 1? qsTr("%1 trim ranges, %2 files").arg(range_count).arg(output_count) : qsTr("%1 trim ranges").arg(range_count));
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
                    root.updateQueuedJobs();
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

        Item { width: 1; height: 2 * dpiScale; }

        // -------------------------------------- Render queue --------------------------------------

        Hr { width: parent.width; }

        // Queueing the selection is an explicit action, the button follows what the current selection allows
        Button {
            width: parent.width;
            height: 32 * dpiScale;
            accent: true;
            iconName: root.queueableCount > 0? "queue" : "close";
            icon.width: 14 * dpiScale;
            icon.height: 14 * dpiScale;
            font.pixelSize: 12 * dpiScale;
            enabled: root.queueableCount > 0 || root.queuedSelectedCount > 0;
            tooltip: qsTr("Select the videos in the list above, then add them to the render queue.");
            text: root.queueableCount > 0? qsTr("Add %1 selected to the queue").arg(root.queueableCount)
                : root.queuedSelectedCount > 0? qsTr("Remove %1 selected from the queue").arg(root.queuedSelectedCount)
                : qsTr("Add selected to the queue");
            onClicked: if (root.queueableCount > 0) { root.queueSelected(); } else { root.unqueueSelected(); }
        }

        // Opening the queue and starting or pausing it, without having to open the queue first
        Row {
            width: parent.width;
            spacing: 4 * dpiScale;
            Button {
                id: openQueueBtn;
                width: parent.width - playPauseBtn.width - parent.spacing;
                height: 30 * dpiScale;
                iconName: "queue";
                icon.width: 14 * dpiScale;
                icon.height: 14 * dpiScale;
                font.pixelSize: 12 * dpiScale;
                text: render_queue.queue.rowCount() > 0? qsTr("Render queue (%1)").arg(render_queue.queue.rowCount()) : qsTr("Render queue");
                onClicked: root.showQueue();
            }
            Button {
                id: playPauseBtn;
                width: 36 * dpiScale;
                height: 30 * dpiScale;
                accent: true;
                leftPadding: 0; rightPadding: 0;
                icon.width: 14 * dpiScale;
                icon.height: 14 * dpiScale;
                property var statuses: ({
                    "stopped": ["play",  styleAccentColor, "start", qsTr("Start exporting")],
                    "paused":  ["play",  "#70e574",        "start", qsTr("Resume")],
                    "active":  ["pause", "#f6a00b",        "pause", qsTr("Pause")],
                })
                iconName:    statuses[render_queue.status][0];
                accentColor: statuses[render_queue.status][1];
                tooltip:     statuses[render_queue.status][3];
                enabled: render_queue.total_frames > 0;
                Behavior on accentColor { ColorAnimation { duration: 700; easing.type: Easing.OutExpo; } }
                onClicked: {
                    const action = statuses[render_queue.status][2];
                    render_queue[action]();
                    // Show what's being rendered when starting, not when pausing
                    if (action == "start") root.showQueue();
                }
            }
        }

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
                    queueTime.fps = render_queue.fps > 0? render_queue.fps : (times[2] || 0);
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
        }
    }

    // -----------------------------------------------------------------------------------------
    // --------------------------------------- Dialogs -----------------------------------------
    // -----------------------------------------------------------------------------------------

    // Both dialogs start in the folder something was last added from (also through drag and drop), across restarts
    function rememberMediaFolder(url: string): void {
        if (!url) return;
        // A folder (eg. dropped) is remembered itself, a file by its folder
        const folder = url.endsWith("/") || media_library.has_folder(url)? url : filesystem.get_folder(url).toString();
        if (folder) settings.setValue("mediaLastFolder", folder);
    }
    QQD.FolderDialog {
        id: folderDialog;
        title: qsTr("Select input folder");
        function openInLastFolder(): void {
            const last = settings.value("mediaLastFolder", "");
            if (last) currentFolder = last;
            open();
        }
        onAccepted: {
            filesystem.folder_access_granted(selectedFolder);
            Qt.callLater(filesystem.save_allowed_folders);
            media_library.add_folder(selectedFolder.toString());
            // The folder itself, so the next folder can be picked next to it or inside of it
            settings.setValue("mediaLastFolder", selectedFolder.toString());
        }
    }
    FileDialog {
        id: filesDialog;
        title: qsTr("Choose a video file");
        nameFilters: Qt.platform.os == "android"? undefined : [qsTr("Video files") + " (*." + fileDialog.extensions.concat(fileDialog.extensions.map(x => x.toUpperCase())).join(" *.") + ")"];
        type: "video";
        fileMode: FileDialog.OpenFiles;
        function openInLastFolder(): void {
            const last = settings.value("mediaLastFolder", "");
            if (last) currentFolder = last;
            open();
        }
        onAccepted: {
            if (selectedFiles.length) media_library.add_dropped(Array.from(selectedFiles, x => x.toString()).join("\n"));
            if (selectedFiles.length) root.rememberMediaFolder(selectedFiles[0].toString());
        }
    }

    // The queue modal covers the whole window, so it lives next to the main layout and not inside the panel
    Loader {
        id: queueModalLoader;
        active: false;
        parent: window;
        anchors.fill: parent;
        z: 100;
        asynchronous: true;
        sourceComponent: Component {
            RenderQueueModal {
                onShownChanged: if (!shown) hideTimer.start();
                Timer { id: hideTimer; interval: 500; onTriggered: queueModalLoader.active = false; }
            }
        }
        onLoaded: item.shown = true;
    }

    Loader {
        id: importModalLoader;
        active: false;
        parent: window;
        anchors.fill: parent;
        z: 101;
        sourceComponent: Component {
            ImportMarkersModal {
                onAccepted: (offsetHours, queue) => root.applyImportedMarkers(offsetHours, queue);
            }
        }
        onLoaded: root.finishOpenImportMarkers();
    }

    Component.onCompleted: {
        if (window.globalSettings) media_library.default_suffix = window.globalSettings.defaultSuffix.text;
        root.refreshState();
    }
}
