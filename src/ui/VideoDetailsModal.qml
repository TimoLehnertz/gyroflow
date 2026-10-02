// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Controls as QQC

import "components/"

// Video information, lens profile and motion data of the video loaded in the main view. They are set up
// once per video, so they are opened from the video (in the media list) instead of taking space all the time.
Item {
    id: root;

    property bool shown: false;
    property alias col: col;
    // The panels declared inside go into the scrollable column
    default property alias data: col.data;
    opacity: shown? 1 : 0;
    visible: opacity > 0;
    Ease on opacity { duration: 300; }

    // Nothing behind the modal can be clicked while it's open
    MouseArea {
        anchors.fill: parent;
        preventStealing: true;
        hoverEnabled: true;
        onClicked: root.shown = false;
    }
    Rectangle {
        anchors.fill: parent;
        color: "#000000";
        opacity: 0.5;
    }

    Rectangle {
        id: dialog;
        anchors.centerIn: parent;
        width: Math.min(parent.width - 60 * dpiScale, 600 * dpiScale);
        height: Math.min(parent.height - 60 * dpiScale, 900 * dpiScale);
        color: styleBackground2;
        radius: 6 * dpiScale;
        border.width: 1 * dpiScale;
        border.color: styleVideoBorderColor;
        scale: root.shown? 1 : 0.97;
        Ease on scale { duration: 300; }

        MouseArea { anchors.fill: parent; preventStealing: true; }

        Item {
            id: dlgHeader;
            width: parent.width;
            height: 44 * dpiScale;
            BasicText {
                anchors.verticalCenter: parent.verticalCenter;
                width: parent.width - 60 * dpiScale;
                leftPadding: 15 * dpiScale;
                text: window.vidInfo && window.vidInfo.filename? qsTr("Video details: %1").arg(window.vidInfo.filename) : qsTr("Video details");
                font.pixelSize: 16 * dpiScale;
                font.bold: true;
                elide: Text.ElideMiddle;
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
                onClicked: root.shown = false;
            }
        }
        Hr { width: parent.width; y: dlgHeader.height; }

        Flickable {
            x: 10 * dpiScale;
            y: dlgHeader.height + 6 * dpiScale;
            width: parent.width - 2*x;
            height: parent.height - y - 10 * dpiScale;
            clip: true;
            contentHeight: col.height;
            contentWidth: width;
            QQC.ScrollIndicator.vertical: QQC.ScrollIndicator { padding: 0; }
            // The video information, lens profile and motion data panels are put in here, see App.qml
            Column {
                id: col;
                width: parent.width;
                spacing: 5 * dpiScale;
            }
        }
    }
}
