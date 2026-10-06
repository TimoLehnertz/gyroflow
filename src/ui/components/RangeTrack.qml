// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Gyroflow contributors

import QtQuick

// A mini timeline: the trim ranges of a video where they are in it, as segments on a thin track that stands for the whole
// video. The same look wherever ranges are previewed (the media list, the marker import)
Item {
    id: root;
    // [{ start, end, color, tooltip }], start and end as a fraction of the duration. Without a color it's the accent color
    property var ranges: [];
    // The theme colors are strings, these are the ones of the track and of a range without its own color
    readonly property color trackColor: style === "light"? "#b4b4b4" : "#6b6b6b";
    readonly property color rangeColor: style === "light"? "#4a4a4a" : "#d8d8d8";
    implicitHeight: 12 * dpiScale;

    Rectangle {
        width: parent.width;
        height: Math.max(2 * dpiScale, Math.round(parent.height * 0.3));
        anchors.verticalCenter: parent.verticalCenter;
        radius: height / 2;
        color: root.trackColor;
    }
    Repeater {
        model: root.ranges;
        Rectangle {
            x: root.width * modelData.start;
            width: Math.max(3 * dpiScale, root.width * Math.max(0, modelData.end - modelData.start));
            height: root.height;
            radius: Math.min(3 * dpiScale, height / 3);
            color: modelData.color || styleAccentColor;
            ToolTip { visible: !isMobile && !!modelData.tooltip && ma.containsMouse; text: modelData.tooltip || ""; }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: !!modelData.tooltip; acceptedButtons: Qt.NoButton; }
        }
    }
}
