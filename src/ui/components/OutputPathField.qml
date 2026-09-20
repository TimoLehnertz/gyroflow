// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2023 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Dialogs as QQD

import "."

TextField {
    id: root;
    text: "";
    width: parent.width;
    rightPadding: linkBtn.width;

    property var cbAfterSelect: null;
    property bool folderOnly: false;

    signal folderSelectionCanceled();

    property url fullFileUrl;
    property url folderUrl;
    property string filename;

    property alias outputFileDialog: outputFileDialog;
    property alias outputFolderDialog: outputFolderDialog;

    property bool preventChange: false;

    // In path mode the field shows and edits a path that is managed elsewhere (the media library).
    // That path is relative to the export folder by default and absolute when a folder is picked.
    property bool pathMode: false;
    signal pathEdited(path: string);

    onTextChanged: {
        // When typing manually
        if (!preventChange) {
            if (root.pathMode) {
                root.pathEdited(text);
            } else if (isSandboxed) {
                setFilename(text.replace(/^.+\//, ""));
            } else {
                setUrl(filesystem.path_to_url(text));
            }
        }
    }

    // Shows `path` while the actual output is `folder` + `fname`. An empty path keeps the current text.
    function setResolvedPath(folder: url, fname: string, path: string): void {
        preventChange = true;
        folderUrl = folder;
        filename = fname;
        fullFileUrl = "";
        if (path) text = path;
        preventChange = false;
    }
    // A path picked in one of the dialogs, shown as it is and reported to the owner of the path
    function setPathFromDialog(path: string): void {
        preventChange = true;
        text = path;
        preventChange = false;
        root.pathEdited(path);
    }

    function prompt(): void {
        linkBtn.clicked();
    }

    function updateText(): void {
        preventChange = true;
        if (!filename && root.folderOnly && root.folderUrl.toString()) {
            text = filesystem.display_folder_filename(root.folderUrl, filename);
            if (!text && root.folderUrl.toString()) text = qsTr('[Selected folder]');
        } else {
            text = fullFileUrl.toString()? filesystem.display_url(fullFileUrl) : filesystem.display_folder_filename(folderUrl, filename);
        }
        preventChange = false;
    }

    function setUrl(url: url): void {
        fullFileUrl = url;
        filename = filesystem.get_filename(url);
        folderUrl = filesystem.get_folder(url);
        updateText();
    }
    function setFilename(fname: string): void {
        if (fname != filename) {
            filename = fname;
            fullFileUrl = "";
            updateText();
        }
    }
    function setFolder(folder: url): void {
        folderUrl = folder;
        if (folder.toString())
            fullFileUrl = "";
        updateText();
    }

    function getFolderForDialog(folder: url): url {
        if (folder.toString()) {
            return folder;
        } else if (window.videoArea.loadedFileUrl.toString()) {
            let parts = window.videoArea.loadedFileUrl.toString().split('/');
            parts.pop();
            return parts.join('/') + '/';
        }
        return "";
    }

    function selectFolder(folder: url, cb: var): void {
        root.cbAfterSelect = cb;
        outputFolderDialog.currentFolder = root.getFolderForDialog(folder);
        outputFolderDialog.open();
    }

    LinkButton {
        id: linkBtn;
        anchors.right: parent.right;
        height: parent.height - 1 * dpiScale;
        text: "...";
        font.underline: false;
        font.pixelSize: 15 * dpiScale;
        onClicked: {
            if (isSandboxed || root.folderOnly) {
                outputFolderDialog.currentFolder = root.getFolderForDialog(root.folderUrl);
                outputFolderDialog.open();
                return;
            }
            outputFileDialog.defaultSuffix = root.filename.substring(root.filename.length - 3);
            outputFileDialog.currentFolder = root.getFolderForDialog(root.folderUrl);
            outputFileDialog.selectedFile = filesystem.get_file_url(root.folderUrl, root.filename, false);
            outputFileDialog.open();
        }
    }
    FileDialog {
        id: outputFileDialog;
        fileMode: FileDialog.SaveFile;
        title: qsTr("Select file destination");
        nameFilters: Qt.platform.os == "android"? undefined : [qsTr("Video files") + " (*.mp4 *.mov *.png *.exr)"];
        type: "output-video";
        onAccepted: {
            if (root.pathMode) {
                root.setPathFromDialog(filesystem.url_to_path(outputFileDialog.selectedFile));
            } else {
                root.setUrl(outputFileDialog.selectedFile);
            }
            window.exportSettings.updateCodecParams();
        }
    }
    QQD.FolderDialog {
        id: outputFolderDialog;
        title: qsTr("Select file destination");
        onAccepted: {
            root.folderUrl = selectedFolder;
            filesystem.folder_access_granted(selectedFolder);
            Qt.callLater(filesystem.save_allowed_folders);
            if (root.pathMode) {
                root.setPathFromDialog(filesystem.url_to_path(filesystem.get_file_url(selectedFolder, root.filename, false)));
            } else {
                updateText();
            }

            if (window.videoArea.loadedFileUrl.toString() && !window.vidInfo.hasAccessToInputDirectory && Qt.resolvedUrl(filesystem.get_folder(window.videoArea.loadedFileUrl)) == Qt.resolvedUrl(selectedFolder)) {
                window.vidInfo.hasAccessToInputDirectory = true;
                settings.setValue("folder-video", filesystem.get_folder(window.videoArea.loadedFileUrl).toString());
            }

            if (root.cbAfterSelect) {
                root.cbAfterSelect(root.folderUrl);
                root.cbAfterSelect = null;
            }
        }
        onRejected: {
            root.cbAfterSelect = null;
            root.folderSelectionCanceled();
        }
    }
}
