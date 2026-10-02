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
    }

    // -----------------------------------------------------------------------------------------
    // --------------------------------------- Actions -----------------------------------------
    // -----------------------------------------------------------------------------------------

    function saveCurrentSettings(): void {
        const id = media_library.current_item;
        if (id > 0 && window.videoArea.vid.loaded && !window.videoArea.videoLoader.active) {
            media_library.save_settings(id, controller.export_gyroflow_data("Simple", window.getAdditionalProjectData()));
            root.updateQueuedJob(id);
        }
    }

    function loadItem(itemId: int): void {
        if (itemId <= 0 || itemId == media_library.current_item) return;
        root.saveCurrentSettings();
        media_library.set_current_item(itemId);
        // Show the path of the item before loading, so the video area leaves the output path to the library
        root.updateOutputFile();

        // Every clip starts with one video per range, unless its own settings say otherwise
        if (window.exportSettings) window.exportSettings.exportTrimsSeparately.checked = true;
        const data = media_library.get_project_data(itemId);
        if (data) {
            window.videoArea.loadGyroflowData(JSON.parse(data), 0);
        } else {
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
        if (id <= 0 || !window.videoArea.vid.loaded || window.videoArea.videoLoader.active) return;
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
            root.showOutputPath(id, path, false);
            root.saveCurrentSettings();
        } else {
            media_library.set_output_path(id, path);
            root.showOutputPath(id, path, false);
            root.updateQueuedJob(id);
        }
        root.updatingOutput = false;
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

    property string pendingMarkerFile: "";

    function openImportMarkers(url): void {
        root.saveCurrentSettings();
        root.pendingMarkerFile = url || "";
        importModalLoader.active = true;
        if (importModalLoader.item) root.finishOpenImportMarkers();
    }
    function finishOpenImportMarkers(): void {
        const modal = importModalLoader.item;
        if (root.pendingMarkerFile) {
            modal.loadFile(root.pendingMarkerFile);
            root.pendingMarkerFile = "";
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
        for (const u of rest) media_library.add_url(u);
        if (rest.length) root.rememberMediaFolder(rest[0].toString());
        if (jsons.length) root.openImportMarkers(jsons[0]);
    }
    function applyImportedMarkers(offsetHours: real, queue: bool): void {
        const result = JSON.parse(media_library.import_markers(offsetHours * 3600));
        if (result.error) {
            messageBox(Modal.Error, result.error, [ { text: qsTr("Ok") } ]);
            return;
        }
        result.queued = queue;
        root.lastImport = result;
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
    // All jobs of a video (one per output file), keeping their order
    function prioritizeItem(itemId: int): void {
        const jobs = media_library.get_item_jobs(itemId);
        for (let i = jobs.length - 1; i >= 0; --i) render_queue.move_item(jobs[i], -1000000);
        render_queue.start();
    }
    function moveItem(itemId: int, step: int): void {
        let jobs = media_library.get_item_jobs(itemId);
        if (step > 0) jobs = jobs.reverse();
        for (const jobId of jobs) render_queue.move_item(jobId, step);
    }
    // The video is loaded by one job, which is split into one job per output file once it's ready (see onProcessing_done)
    function queueItem(itemId: int): void {
        const jobId = render_queue.add_file(media_library.get_item_url(itemId), "", JSON.stringify(root.jobData(itemId)));
        root.pendingJobs[jobId] = true;
        media_library.set_item_job(itemId, jobId);
        root.ownJobs[jobId] = true;
    }
    // Every output file of the video (one per trim range, unless they are joined) gets its own job.
    // They share the loaded video, so it's synchronized and its smoothing computed only once.
    function splitItemJobs(itemId: int, jobId: int): void {
        const outputs = JSON.parse(media_library.get_item_outputs(itemId, ""));
        if (!outputs.length) return;
        const ids = render_queue.split_job_by_ranges(jobId, JSON.stringify(outputs));
        for (const id of ids) root.ownJobs[id] = true;
        media_library.set_item_jobs(itemId, ids, outputs.map(x => x.range_index));
        root.applyRangeSettings(itemId, ids, outputs);
        root.splitLayouts[itemId] = root.splitLayout(outputs);
    }
    // Which ranges the jobs of an item were split into, and which of them got their own copy of the video
    property var splitLayouts: ({ });
    function splitLayout(outputs: var): string {
        return JSON.stringify(outputs.map(x => [x.range_index, !!x.own_settings]));
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
    // An item can be edited while it's waiting in the queue, keep its jobs up to date until they start rendering
    function updateQueuedJob(itemId: int): void {
        const jobIds = media_library.get_item_jobs(itemId);
        if (!jobIds.length) return;
        // A trim range with its own stabilization settings gets those
        const settingsOf = (jobId) => { const x = media_library.get_settings_for_job(jobId); return x? JSON.parse(x) : ({ title: "Gyroflow data file", version: 4 }); };
        let data = settingsOf(jobIds[0]);
        const output = root.jobData(itemId).output;
        const additionalData = window.getAdditionalProjectDataJson();
        const outputs = JSON.parse(media_library.get_item_outputs(itemId, ""));
        const ranges = jobIds.map(id => render_queue.get_job_range_index(id));
        const allQueued = jobIds.every(id => media_library.get_job_status(id) == "queued");
        const sameFiles = outputs.length == jobIds.length && outputs.every((x, i) => x.range_index == ranges[i])
                       && (root.splitLayouts[itemId] || root.splitLayout(outputs)) == root.splitLayout(outputs);
        if (!sameFiles && allQueued) {
            // The trim ranges (or whether they have their own settings) changed: keep the first job, which has the video loaded, and split it again
            for (const id of jobIds.slice(1)) render_queue.remove(id);
            data.output = output;
            render_queue.apply_to_all(JSON.stringify(data), additionalData, jobIds[0]);
            root.splitItemJobs(itemId, jobIds[0]);
            return;
        }
        // Each job keeps its own output file. Jobs that already started or finished are left as they are
        for (let i = 0; i < jobIds.length; ++i) {
            if (media_library.get_job_status(jobIds[i]) != "queued") continue;
            const file = outputs.find(x => x.range_index == ranges[i]);
            data = settingsOf(jobIds[i]);
            // A range with its own settings keeps its own export settings, all of them render to their own file
            const rangeOutput = file && file.own_settings? (data.output || { }) : { };
            data.output = Object.assign({ }, output, rangeOutput, file? { output_folder: file.output_folder, output_filename: file.output_filename } : { });
            // The metadata has the stabilization hash, which tells whether the rendered file is up to date
            data.output.metadata = output.metadata;
            render_queue.apply_to_all(JSON.stringify(data), additionalData, jobIds[i]);
            render_queue.set_job_output(jobIds[i], ranges[i], "", "");
        }
    }
    function updateQueuedJobs(): void {
        for (const id of media_library.get_render_items(false)) root.updateQueuedJob(id);
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
            root.updateQueuedJob(id);
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
    function queueLoadedFile(): int {
        const itemId = root.loadedItem();
        if (itemId <= 0) return 0;
        // The settings of the main view are the ones of this item
        root.saveCurrentSettings();
        if (!media_library.is_item_queued(itemId)) root.queueItem(itemId);
        const index = media_library.get_item_index(itemId);
        if (index >= 0) lv.positionViewAtIndex(index, ListView.Contain);
        return itemId;
    }
    // The output files of the video loaded in the main view, with its current settings: one per trim range
    // if they are exported as separate videos. Empty if it's not a video of the library
    function loadedOutputs(): var {
        const itemId = root.loadedItem();
        if (itemId <= 0) return [];
        root.saveCurrentSettings();
        return JSON.parse(media_library.get_item_outputs(itemId, root.outputExtension(itemId)));
    }
    // "Stabilize now" renders the main view in one job, split it into one job per output file like the queue does.
    // Returns the ids of the jobs, in the order of the trim ranges
    function splitDirectJob(jobId: int): var {
        const outputs = root.loadedOutputs();
        if (outputs.length <= 1 && (!outputs.length || outputs[0].range_index < 0)) return [jobId];
        const ids = render_queue.split_job_by_ranges(jobId, JSON.stringify(outputs));
        root.applyRangeSettings(root.loadedItem(), ids, outputs);
        return ids;
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
    function cancelItem(itemId: int): void {
        const jobIds = media_library.get_item_jobs(itemId);
        if (!jobIds.length) return;
        for (const jobId of jobIds) render_queue.remove(jobId);
        media_library.set_item_job(itemId, 0);
    }
    function resetItem(itemId: int): void {
        const jobIds = media_library.get_item_jobs(itemId);
        if (!jobIds.length) return;
        const status = media_library.get_item_job_status(itemId);
        const ranges = jobIds.map(id => render_queue.get_job_range_index(id));
        for (const jobId of jobIds) render_queue.reset_job(jobId);
        media_library.set_item_jobs(itemId, jobIds, ranges);
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
        media_library.add_item_job(itemId, jobId, rangeIndex);
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
        function onProcessing_done(job_id: real, by_preset: bool): void {
            if (by_preset) return;
            // Either the job made it into the queue by now, or it never will
            delete root.pendingJobs[job_id];
            if (!media_library.is_library_job(job_id)) return;
            // The video is loaded in the queue now, apply the settings of this item on top of it
            const data = media_library.get_settings_for_job(job_id);
            if (data) {
                render_queue.apply_to_all(data, window.getAdditionalProjectDataJson(), job_id);
            }
            // One job per output file, they share the loaded video
            const itemId = media_library.get_item_for_job(job_id);
            if (media_library.get_item_jobs(itemId).length == 1) root.splitItemJobs(itemId, job_id);
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

    // Unfinished jobs of the previous session are added back to the queue and show up in the list above
    Timer {
        interval: 100;
        running: window.exportSettings != null && window.sync != null;
        onTriggered: {
            Qt.callLater(() => {
                if (render_queue.restore_render_queue(window.getAdditionalProjectDataJson())) {
                    messageBox(Modal.Info, qsTr("You have unfinished tasks in the render queue."), [
                        { text: qsTr("Open render queue"), accent: true, clicked: function() { root.showQueue(); } },
                        { text: qsTr("Ok") }
                    ]);
                }
            });
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
                sourceSize.width: Math.min(220 * dpiScale, parent.width * 0.8);
                anchors.centerIn: parent;
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
            property bool isRendering:  job_status == "rendering";
            property bool isProcessing: job_status == "processing";
            property bool isQueued:     job_status == "queued";
            property bool isJobError:   job_status == "error";
            property bool isQuestion:   job_status == "question";
            property bool isJobDone:    job_status == "done";
            property bool isBusy: dlg.isRendering || dlg.isProcessing;
            // Being in the render queue is shown independently of the selection, an item can be both
            property bool isInQueue: job_id > 0;

            color: selected?     "#33ffffff"
                 : isJobError?   "#30ed7676"
                 : isQuestion?   "#30" + styleAccentColor.toString().substring(1)
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
                color: dlg.isJobError? "#ed7676" : dlg.isJobDone? "#70e574" : styleAccentColor;
            }

            MouseArea {
                anchors.fill: parent;
                acceptedButtons: Qt.LeftButton;
                cursorShape: dlg.isFolder? Qt.ArrowCursor : Qt.PointingHandCursor;
                onClicked: (mouse) => {
                    lv.forceActiveFocus();
                    if (dlg.isFolder) {
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
                    lv.forceActiveFocus();
                    if (!selected) root.clickItem(item_id, Qt.NoModifier);
                    itemMenu.popup(dlg, mx, my);
                }
            }
            Menu {
                id: itemMenu;
                font.pixelSize: 11.5 * dpiScale;
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
                    iconName: "play";
                    text: qsTr("Render now");
                    enabled: job_id > 0 && !dlg.isBusy && !dlg.isJobDone;
                    onTriggered: root.prioritizeItem(item_id);
                }
                Action {
                    iconName: "pencil";
                    text: qsTr("Edit render settings");
                    // The jobs of the trim ranges of a video are edited through the video itself
                    enabled: job_id > 0 && job_count == 1 && !dlg.isBusy;
                    onTriggered: {
                        const data = render_queue.get_gyroflow_data(job_id);
                        if (data) window.videoArea.loadGyroflowData(JSON.parse(data), job_id);
                    }
                }
                Action {
                    iconName: "arrow-up";
                    text: qsTr("Move up in the queue");
                    enabled: job_id > 0;
                    onTriggered: root.moveItem(item_id, -1);
                }
                Action {
                    iconName: "arrow-down";
                    text: qsTr("Move down in the queue");
                    enabled: job_id > 0;
                    onTriggered: root.moveItem(item_id, 1);
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
                            visible: !dlg.isFolder;
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
            for (let i = 0; i < selectedFiles.length; i++) media_library.add_url(selectedFiles[i].toString());
            if (selectedFiles.length) root.rememberMediaFolder(selectedFiles[0].toString());
        }
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
        property var pendingUrls: [];
        onEntered: (drag) => {
            da.pendingUrls = Util.collectDropUrls(drag);
            drag.accepted = da.pendingUrls.length > 0;
        }
        onDropped: (drop) => {
            let urls = Util.collectDropUrls(drop);
            if (!urls.length) urls = da.pendingUrls;
            da.pendingUrls = [];
            root.handleDroppedUrls(urls);
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
        if (window.advanced) media_library.default_suffix = window.advanced.defaultSuffix.text;
        root.refreshState();
    }
}
