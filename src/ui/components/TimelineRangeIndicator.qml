// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick

Rectangle {
    id: root;
    property real trimStart: 0;
    property real trimEnd: 1.0;

    property real trimStartAdjustment: 0;
    property real trimEndAdjustment: 0;
    // The range the playhead is in, or the last one it was in (whose settings and output path are shown)
    property bool isActive: true;

    property bool active: rightTrimDrag.active || leftTrimDrag.active || moveDrag.active;
    // The whole range is dragged (the playhead stays where it is, unlike when one of its ends is dragged)
    readonly property bool moving: moveDrag.active;

    x: parent.width * mapToVisibleArea(Math.max(0.0, trimStart + trimStartAdjustment));
    width: Math.max(10, parent.width * mapToVisibleArea(Math.min(1.0, trimEnd + trimEndAdjustment)) - x);
    // The active range has its own color, the accent color (blue) is too close to the color of what's queued.
    // The theme colors are strings, as a `color` their channels can be used
    readonly property color activeColor: styleActiveRangeColor;
    color: isActive? Qt.rgba(activeColor.r, activeColor.g, activeColor.b, 0.22) : "#12ffffff";
    border.width: 2 * dpiScale;
    border.color: isActive? activeColor : Qt.rgba(activeColor.r, activeColor.g, activeColor.b, 0.4);
    radius: 3 * dpiScale;
    clip: true;
    function mapToVisibleArea(v: real): real { return parent.parent.parent.mapToVisibleArea(v); }
    function mapFromVisibleArea(v: real): real { return parent.parent.parent.mapFromVisibleArea(v); }
    property real visibleRange: (parent.parent.parent.visibleAreaRight - parent.parent.parent.visibleAreaLeft);

    signal changeTrimStart(real val);
    signal changeTrimEnd(real val);
    // The whole range was dragged to `start` (its length stays)
    signal moveRange(real start, real end);
    signal reset();


    Rectangle {
        color: parent.border.color;
        radius: parent.radius;
        height: parent.height;
        width: 5 * dpiScale;
        Item {
            anchors.fill: parent;
            anchors.margins: (isMobile? -15 : -7) * dpiScale;
            MouseArea {
                anchors.fill: parent;
                acceptedButtons: Qt.NoButton;
                cursorShape: Qt.SizeHorCursor;
            }
            DragHandler {
                id: leftTrimDrag;
                target: null;
                onActiveChanged: if (!active) { root.changeTrimStart(Math.max(0.0, root.trimStart + root.trimStartAdjustment)); root.trimStartAdjustment = 0; }
                onActiveTranslationChanged: root.trimStartAdjustment = (leftTrimDrag.activeTranslation.x / root.parent.width) * root.visibleRange;
            }
            TapHandler { onDoubleTapped: root.reset(); }
        }

        Rectangle {
            color: parent.color;
            width: 10 * dpiScale;
            height: 25 * dpiScale;
            rotation: 45;
            x: -2 * dpiScale;
            y: -width/2;
        }
    }
    Rectangle {
        anchors.right: parent.right;
        color: parent.border.color;
        radius: parent.radius;
        height: parent.height;
        width: 5 * dpiScale;
        Item {
            anchors.fill: parent;
            anchors.margins: (isMobile? -15 : -7) * dpiScale;
            MouseArea {
                anchors.fill: parent;
                acceptedButtons: Qt.NoButton;
                cursorShape: Qt.SizeHorCursor;
            }
            DragHandler {
                id: rightTrimDrag;
                target: null;
                onActiveChanged: if (!active) { root.changeTrimEnd(Math.min(1.0, root.trimEnd + root.trimEndAdjustment)); root.trimEndAdjustment = 0; }
                onActiveTranslationChanged: root.trimEndAdjustment = (rightTrimDrag.activeTranslation.x / root.parent.width) * root.visibleRange;
            }
            TapHandler { onDoubleTapped: root.reset(); }
        }
        Rectangle {
            color: parent.color;
            width: 10 * dpiScale;
            height: 25 * dpiScale;
            rotation: 45;
            x: -2 * dpiScale;
            y: parent.height - height + width/2;
        }
    }

    // Grabbing the top middle moves the whole range, its length stays and it stays within the video
    Rectangle {
        id: moveGrip;
        visible: root.width > width + 24 * dpiScale;
        anchors.horizontalCenter: parent.horizontalCenter;
        y: 4 * dpiScale;
        width: 33 * dpiScale;
        height: 9 * dpiScale;
        radius: height / 2;
        color: root.border.color;
        opacity: moveMa.containsMouse || moveDrag.active? 1 : 0.7;
        Item {
            anchors.fill: parent;
            anchors.margins: (isMobile? -12 : -6) * dpiScale;
            MouseArea {
                id: moveMa;
                anchors.fill: parent;
                hoverEnabled: true;
                acceptedButtons: Qt.NoButton;
                cursorShape: Qt.SizeAllCursor;
            }
            DragHandler {
                id: moveDrag;
                target: null;
                xAxis.enabled: true;
                yAxis.enabled: false;
                property real offset: 0;
                onActiveChanged: {
                    if (!active) {
                        root.moveRange(root.trimStart + offset, root.trimEnd + offset);
                        root.trimStartAdjustment = 0;
                        root.trimEndAdjustment = 0;
                        offset = 0;
                    }
                }
                onActiveTranslationChanged: {
                    const delta = (moveDrag.activeTranslation.x / root.parent.width) * root.visibleRange;
                    offset = Math.max(-root.trimStart, Math.min(1.0 - root.trimEnd, delta));
                    root.trimEndAdjustment = offset;
                    root.trimStartAdjustment = offset;
                }
            }
        }
    }

}
