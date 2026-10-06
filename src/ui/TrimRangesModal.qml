// SPDX-License-Identifier: GPL-3.0-or-later

import QtQml
import QtQuick
import QtQuick.Controls as QQC

import "components/"

// Changes the trim ranges of several videos at once: their starts earlier, their ends later, or all of them moved.
// The mini timelines show the result while the times are entered, the videos are changed on "Apply"
Item {
    id: root;

    property bool shown: false;
    // [{ id, name, duration_ms, ranges: [[start_ms, end_ms]] }]
    property var clips: [];
    readonly property int rangeCount: root.clips.reduce((n, x) => n + x.ranges.length, 0);

    readonly property real extendLeftMs:  extendLeftRow.value * 1000;
    readonly property real extendRightMs: extendRightRow.value * 1000;
    readonly property real shiftMs: (moveRightRow.value - moveLeftRow.value) * 1000;
    readonly property bool hasChanges: root.extendLeftMs > 0 || root.extendRightMs > 0 || root.shiftMs != 0;

    // A time in seconds, the label on the left
    component TimeRow: Label {
        property alias value: field.value;
        function focusField(): void { field.forceActiveFocus(); field.selectAll(); }
        position: Label.LeftPosition;
        NumberField {
            id: field;
            width: parent.width;
            height: 25 * dpiScale;
            precision: 2;
            unit: "s";
            from: 0;
            to: 86400;
            live: true;
            defaultValue: 0;
        }
    }

    opacity: shown? 1 : 0;
    visible: opacity > 0;
    Ease on opacity { duration: 200; }

    signal accepted(var itemIds, real extendLeftMs, real extendRightMs, real shiftMs);

    function open(itemIds: var): void {
        root.clips = itemIds.map(id => Object.assign({ id: id }, JSON.parse(media_library.get_trim_ranges(id) || "{}")))
                            .filter(x => x.ranges && x.ranges.length > 0 && x.duration_ms > 0);
        for (const row of [extendLeftRow, extendRightRow, moveLeftRow, moveRightRow]) row.value = 0;
        if (!root.shown) root.focusBefore = root.Window.activeFocusItem;
        root.shown = true;
        extendLeftRow.focusField();
    }
    function close(): void {
        root.shown = false;
        if (root.focusBefore) root.focusBefore.forceActiveFocus();
        root.focusBefore = null;
    }
    function confirm(): void {
        root.accepted(root.clips.map(x => x.id), root.extendLeftMs, root.extendRightMs, root.shiftMs);
        root.close();
    }
    // The same as `MediaLibrary::modified_trim_range`
    function modifiedRange(range: var, duration: real): var {
        const start = Math.min(duration, Math.max(0, range[0] - root.extendLeftMs + root.shiftMs));
        const end   = Math.min(duration, Math.max(0, range[1] + root.extendRightMs + root.shiftMs));
        return end - start < 1? range : [start, end];
    }
    function formatTime(ms: real): string {
        const s = Math.max(0, ms) / 1000;
        const m = Math.floor(s / 60);
        const sec = s - m * 60;
        return m + ":" + (sec < 10? "0" : "") + sec.toFixed(2);
    }

    // While it's shown it has the keyboard: the keys typed in it aren't shortcuts of the main view (accepting the override
    // event stops a shortcut), and it closes with Esc. The focus goes back where it was when it closes
    readonly property bool blocksShortcuts: root.shown;
    property Item focusBefore: null;
    Keys.onShortcutOverride: (event) => { if (root.shown) event.accepted = true; }
    Keys.onEscapePressed: root.close();

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
                    text: qsTr("Modify trim ranges");
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
                    text: qsTr("All %1 trim ranges of the %2 selected videos are changed by the times below, within their videos.").arg(root.rangeCount).arg(root.clips.length);
                }

                TimeRow { id: extendLeftRow;  text: qsTr("Extend all to the left");  tooltip: qsTr("Every range starts this much earlier"); }
                TimeRow { id: extendRightRow; text: qsTr("Extend all to the right"); tooltip: qsTr("Every range ends this much later"); }
                TimeRow { id: moveLeftRow;    text: qsTr("Move all to the left");    tooltip: qsTr("Every range starts and ends this much earlier"); }
                TimeRow { id: moveRightRow;   text: qsTr("Move all to the right");   tooltip: qsTr("Every range starts and ends this much later"); }

                Hr { width: parent.width; }

                Repeater {
                    model: root.clips;
                    Column {
                        id: clipCol;
                        width: col.width;
                        spacing: 3 * dpiScale;
                        required property var modelData;
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            elide: Text.ElideMiddle;
                            text: clipCol.modelData.name;
                            font.pixelSize: 12 * dpiScale;
                        }
                        // The same mini timeline as in the media list: the ranges as they are now behind the new ones
                        RangeTrack {
                            id: track;
                            width: parent.width;
                            height: 14 * dpiScale;
                            readonly property real duration: clipCol.modelData.duration_ms;
                            ranges: {
                                const ranges = clipCol.modelData.ranges;
                                const before = root.hasChanges? ranges.map(r => ({
                                    start: r[0] / track.duration, end: r[1] / track.duration,
                                    color: Qt.rgba(track.rangeColor.r, track.rangeColor.g, track.rangeColor.b, 0.3),
                                })) : [];
                                return before.concat(ranges.map((r, i) => {
                                    const m = root.modifiedRange(r, track.duration);
                                    return {
                                        start: m[0] / track.duration, end: m[1] / track.duration,
                                        color: root.hasChanges? styleAccentColor : track.rangeColor,
                                        tooltip: qsTr("Range %1").arg(i + 1) + ": " + root.formatTime(m[0]) + " – " + root.formatTime(m[1])
                                    };
                                }));
                            }
                        }
                    }
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
                    text: qsTr("Apply");
                    accent: true;
                    height: 32 * dpiScale;
                    enabled: root.hasChanges && root.clips.length > 0;
                    onClicked: root.confirm();
                }
            }
        }
    }

}
