// SPDX-License-Identifier: GPL-3.0-or-later

import QtQml
import QtQuick
import QtQuick.Controls as QQC

import "components/"

Item {
    id: root;

    property bool shown: false;
    property string fileName: "";
    property int markerCount: 0;
    property var preview: ({ videos: [], unmatched: [], untouched: [], sections: 0, matched: 0 });
    property bool hasFile: root.fileName.length > 0;
    property real offsetHours: 0;
    // An offset up to 12 whole hours more / less matches trim ranges, which the + / - buttons show
    property bool matchesLater: false;
    property bool matchesEarlier: false;

    opacity: shown? 1 : 0;
    visible: opacity > 0;
    Ease on opacity { duration: 200; }

    signal accepted(real offsetHours, bool queue);

    function open(): void {
        const saved = +settings.value("markerOffsetHours", 0);
        root.setOffsetSeconds(Math.round(saved * 3600));
        queueImported.checked = +settings.value("markerQueueImported", 1) > 0;
        root.shown = true;
        if (root.hasFile) root.refresh();
    }
    // The offset is entered as [-]H[:MM[:SS]], eg. "2", "-3:30" or "5:45:30"
    function parseOffset(text: string): real {
        const m = text.trim().match(/^([+-]?)(\d{1,2})(?::(\d{1,2}))?(?::(\d{1,2}))?$/);
        if (!m) return NaN;
        const minutes = +(m[3] || 0), seconds = +(m[4] || 0);
        if (minutes >= 60 || seconds >= 60) return NaN;
        const total = +m[2] * 3600 + minutes * 60 + seconds;
        if (total > 24 * 3600) return NaN;
        return m[1] === "-"? -total : total;
    }
    function formatOffset(totalSeconds: real): string {
        const abs = Math.round(Math.abs(totalSeconds));
        const h = Math.floor(abs / 3600), m = Math.floor(abs % 3600 / 60), s = abs % 60;
        const pad = (x) => (x < 10? "0" : "") + x;
        let text = (totalSeconds < 0 && abs > 0? "-" : "") + h;
        if (m || s) text += ":" + pad(m);
        if (s) text += ":" + pad(s);
        return text;
    }
    // Sets the offset from the slider, the buttons or the saved value, the field shows it formatted
    function setOffsetSeconds(totalSeconds: real): void {
        totalSeconds = Math.max(-24 * 3600, Math.min(24 * 3600, Math.round(totalSeconds)));
        offsetField.text = root.formatOffset(totalSeconds);
        root.applyOffsetSeconds(totalSeconds);
    }
    function applyOffsetSeconds(totalSeconds: real): void {
        offsetSlider.preventChange = true;
        offsetSlider.value = totalSeconds / 3600;
        offsetSlider.preventChange = false;
        if (root.offsetHours === totalSeconds / 3600) return;
        root.offsetHours = totalSeconds / 3600;
        root.refresh();
    }
    function close(): void {
        root.shown = false;
    }
    function loadFile(url: string): void {
        const result = JSON.parse(media_library.load_markers(url));
        if (result.error) {
            messageBox(Modal.Error, result.error, [ { text: qsTr("Ok") } ]);
            return;
        }
        root.fileName = result.name || qsTr("markers.json");
        root.markerCount = result.count || 0;
        root.refresh();
    }
    function refresh(): void {
        const nearby = root.hasFile? JSON.parse(media_library.nearby_marker_matches(root.offsetHours * 3600)) : {};
        root.matchesLater = !!nearby.later;
        root.matchesEarlier = !!nearby.earlier;
        if (!root.hasFile) {
            root.preview = { videos: [], unmatched: [], untouched: [], sections: 0, matched: 0 };
            videoModel.clear();
            return;
        }
        const result = JSON.parse(media_library.preview_markers(root.offsetHours * 3600));
        if (result.error) {
            root.preview = { videos: [], unmatched: [], untouched: [], sections: 0, matched: 0 };
            videoModel.clear();
            return;
        }
        root.preview = result;
        root.syncVideos(result.videos || []);
    }
    function syncVideos(videos: var): void {
        let same = videoModel.count === videos.length;
        if (same) {
            for (let i = 0; i < videos.length; i++) {
                if (videoModel.get(i).vid !== videos[i].id) { same = false; break; }
            }
        }
        if (!same) {
            videoModel.clear();
            for (const v of videos) {
                videoModel.append({ vid: v.id, name: v.name, sectionsJson: JSON.stringify(v.sections) });
            }
            return;
        }
        for (let i = 0; i < videos.length; i++) {
            const json = JSON.stringify(videos[i].sections);
            if (videoModel.get(i).sectionsJson !== json) {
                videoModel.setProperty(i, "sectionsJson", json);
            }
        }
    }
    function confirm(): void {
        settings.setValue("markerOffsetHours", root.offsetHours);
        settings.setValue("markerQueueImported", queueImported.checked? 1 : 0);
        root.accepted(root.offsetHours, queueImported.checked);
        root.close();
    }

    MouseArea {
        anchors.fill: parent;
        preventStealing: true;
        hoverEnabled: true;
        onClicked: root.close();
    }
    Rectangle {
        anchors.fill: parent;
        color: "#000000";
        opacity: 0.5;
    }

    Rectangle {
        id: dialog;
        anchors.centerIn: parent;
        width: Math.min(parent.width - 40 * dpiScale, 560 * dpiScale);
        height: Math.min(parent.height - 40 * dpiScale, header.height + body.implicitHeight + footer.height + 20 * dpiScale);
        color: styleBackground2;
        radius: 6 * dpiScale;
        border.width: 1 * dpiScale;
        border.color: styleVideoBorderColor;
        scale: root.shown? 1 : 0.97;
        Ease on scale { duration: 200; }
        MouseArea { anchors.fill: parent; preventStealing: true; }

        Column {
            id: header;
            width: parent.width;
            Item {
                width: parent.width;
                height: 44 * dpiScale;
                BasicText {
                    anchors.verticalCenter: parent.verticalCenter;
                    leftPadding: 15 * dpiScale;
                    text: qsTr("Import markers");
                    font.pixelSize: 16 * dpiScale;
                    font.bold: true;
                }
                LinkButton {
                    anchors.right: parent.right;
                    anchors.rightMargin: 5 * dpiScale;
                    anchors.verticalCenter: parent.verticalCenter;
                    width: 32 * dpiScale;
                    height: 32 * dpiScale;
                    leftPadding: 0; rightPadding: 0;
                    textColor: styleTextColor;
                    iconName: "close";
                    tooltip: qsTr("Close");
                    onClicked: root.close();
                }
            }
            Hr { width: parent.width; }
        }

        Flickable {
            id: body;
            x: 15 * dpiScale;
            y: header.height + 12 * dpiScale;
            width: parent.width - 30 * dpiScale;
            height: parent.height - header.height - footer.height - 20 * dpiScale;
            clip: true;
            boundsBehavior: Flickable.StopAtBounds;
            contentWidth: width;
            contentHeight: col.height;
            // Only when it scrolls, and next to the content: over it, it took the clicks on the right edge (the + button)
            QQC.ScrollBar.vertical: QQC.ScrollBar { id: bodyScroll; visible: body.contentHeight > body.height; }
            property real implicitHeight: col.height;

            Column {
                id: col;
                width: parent.width - (bodyScroll.visible? bodyScroll.width : 0);
                spacing: 10 * dpiScale;

                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    wrapMode: Text.WordWrap;
                    text: qsTr("In and out markers from a JSON file are matched to videos by creation time and duration. If nothing lines up, enter the camera timezone offset — many cameras store local time as UTC.");
                }

                Row {
                    spacing: 8 * dpiScale;
                    width: parent.width;
                    Button {
                        id: chooseBtn;
                        text: qsTr("Choose file");
                        height: 32 * dpiScale;
                        onClicked: markersDialog.open2();
                    }
                    BasicText {
                        anchors.verticalCenter: parent.verticalCenter;
                        leftPadding: 0;
                        width: parent.width - chooseBtn.width - parent.spacing;
                        elide: Text.ElideMiddle;
                        text: root.hasFile
                            ? qsTr("%1 (%2 markers)").arg(root.fileName).arg(root.markerCount)
                            : qsTr("No file selected");
                        opacity: root.hasFile? 1 : 0.6;
                    }
                }

                Label {
                    text: qsTr("Time offset");
                    tooltip: qsTr("Subtracted from each video's creation time, as hours[:minutes[:seconds]], eg. 2 for CEST if the camera stored local time as UTC, -3:30 or 1:00:15.");
                    Row {
                        spacing: 8 * dpiScale;
                        width: parent.width;
                        height: 25 * dpiScale;
                        Slider {
                            id: offsetSlider;
                            width: parent.width - offsetField.width - 2 * offsetMinus.width - 3 * parent.spacing;
                            anchors.verticalCenter: parent.verticalCenter;
                            from: -12;
                            to: 12;
                            live: true;
                            property bool preventChange: false;
                            stepSize: 0.25;
                            snapMode: QQC.Slider.SnapAlways;
                            onValueChanged: if (!preventChange) root.setOffsetSeconds(value * 3600);
                        }
                        Button {
                            id: offsetMinus;
                            width: 25 * dpiScale;
                            height: 25 * dpiScale;
                            anchors.verticalCenter: parent.verticalCenter;
                            leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0;
                            accent: root.matchesEarlier;
                            iconName: "minus";
                            icon.width: 12 * dpiScale;
                            icon.height: 12 * dpiScale;
                            tooltip: root.matchesEarlier? qsTr("One hour less — an offset up to 12 hours less matches trim ranges") : qsTr("One hour less");
                            onClicked: root.setOffsetSeconds(root.offsetHours * 3600 - 3600);
                        }
                        TextField {
                            id: offsetField;
                            width: 78 * dpiScale;
                            height: 25 * dpiScale;
                            horizontalAlignment: Text.AlignHCenter;
                            placeholderText: "h:mm:ss";
                            // Partial input is allowed while typing, the offset follows once it's complete
                            validator: RegularExpressionValidator { regularExpression: /[+-]?\d{0,2}(:\d{0,2}(:\d{0,2})?)?/ }
                            readonly property real seconds: root.parseOffset(text);
                            color: isNaN(seconds)? "#f67575" : styleTextColor;
                            tooltip: qsTr("hours[:minutes[:seconds]], eg. 2, -3:30 or 1:00:15");
                            onTextEdited: if (!isNaN(seconds)) root.applyOffsetSeconds(seconds);
                            onEditingFinished: root.setOffsetSeconds(isNaN(seconds)? root.offsetHours * 3600 : seconds);
                        }
                        Button {
                            id: offsetPlus;
                            width: 25 * dpiScale;
                            height: 25 * dpiScale;
                            anchors.verticalCenter: parent.verticalCenter;
                            leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0;
                            accent: root.matchesLater;
                            iconName: "plus";
                            icon.width: 12 * dpiScale;
                            icon.height: 12 * dpiScale;
                            tooltip: root.matchesLater? qsTr("One hour more — an offset up to 12 hours more matches trim ranges") : qsTr("One hour more");
                            onClicked: root.setOffsetSeconds(root.offsetHours * 3600 + 3600);
                        }
                    }
                }

                CheckBox {
                    id: queueImported;
                    text: qsTr("Add the videos with imported trim ranges to the render queue");
                    font.pixelSize: 12 * dpiScale;
                    checked: true;
                }

                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    wrapMode: Text.WordWrap;
                    visible: root.hasFile;
                    text: qsTr("%1 trim ranges in %2 videos.").arg(root.preview.sections || 0).arg(root.preview.matched || 0)
                        + " "
                        + qsTr("Unmatched markers: %1.").arg((root.preview.unmatched || []).length);
                    font.bold: true;
                }
                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    wrapMode: Text.WordWrap;
                    visible: root.hasFile && !(root.preview.sections > 0);
                    color: "#f6a00b";
                    text: qsTr("No trim ranges matched. Try a different offset.");
                }

                Repeater {
                    model: videoModel;
                    Column {
                        id: videoCol;
                        width: col.width;
                        spacing: 3 * dpiScale;
                        required property string sectionsJson;
                        required property string name;
                        property var sections: JSON.parse(sectionsJson || "[]");
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            elide: Text.ElideMiddle;
                            text: videoCol.name;
                            font.pixelSize: 12 * dpiScale;
                        }
                        // The same mini timeline as in the media list
                        RangeTrack {
                            width: parent.width;
                            height: 14 * dpiScale;
                            ranges: videoCol.sections.map(x => ({
                                start: x.start, end: x.end,
                                tooltip: x.label || x.path || x.name || qsTr("Trim range")
                            }));
                        }
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            font.pixelSize: 11 * dpiScale;
                            opacity: 0.75;
                            elide: Text.ElideMiddle;
                            text: parent.sections.map(s => s.label || s.name || s.path).filter(x => x && x.length).join("  ·  ");
                            visible: text.length > 0;
                        }
                    }
                }

                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    wrapMode: Text.WordWrap;
                    visible: root.hasFile && (root.preview.untouched || []).length > 0;
                    opacity: 0.75;
                    text: qsTr("Videos without a match (%1): %2")
                        .arg((root.preview.untouched || []).length)
                        .arg((root.preview.untouched || []).join(", "));
                }
                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    wrapMode: Text.WordWrap;
                    visible: root.hasFile && (root.preview.unmatched || []).length > 0;
                    opacity: 0.75;
                    text: qsTr("Unmatched: %1").arg((root.preview.unmatched || []).join(", "));
                }
            }
        }

        Rectangle {
            id: footer;
            anchors.bottom: parent.bottom;
            width: parent.width;
            height: 54 * dpiScale;
            color: "#B0" + stylePopupBorder.substring(1);
            radius: 6 * dpiScale;
            Rectangle {
                width: parent.width;
                height: parent.radius;
                color: parent.color;
            }
            Row {
                anchors.centerIn: parent;
                spacing: 10 * dpiScale;
                Button {
                    text: qsTr("Cancel");
                    height: 32 * dpiScale;
                    onClicked: root.close();
                }
                Button {
                    text: qsTr("Import");
                    accent: true;
                    height: 32 * dpiScale;
                    enabled: root.hasFile && !media_library.scanning;
                    onClicked: root.confirm();
                }
            }
        }
    }

    ListModel { id: videoModel; }

    FileDialog {
        id: markersDialog;
        title: qsTr("Choose markers.json");
        type: "markers";
        nameFilters: [qsTr("JSON files") + " (*.json)"];
        fileMode: FileDialog.OpenFile;
        onAccepted: root.loadFile(selectedFile.toString());
    }
}
