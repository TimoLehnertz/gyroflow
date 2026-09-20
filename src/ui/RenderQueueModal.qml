// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Controls.impl as QQCI

import "components/"
import "Util.js" as Util;

// The render queue itself. The media list is where items are picked, this is where the queue they
// ended up in is managed: reordering, removing and starting or pausing the rendering.
Item {
    id: root;

    property bool shown: false;
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
        width: Math.min(parent.width - 60 * dpiScale, 900 * dpiScale);
        height: Math.min(parent.height - 60 * dpiScale, 700 * dpiScale);
        color: styleBackground2;
        radius: 6 * dpiScale;
        border.width: 1 * dpiScale;
        border.color: styleVideoBorderColor;
        scale: root.shown? 1 : 0.97;
        Ease on scale { duration: 300; }

        MouseArea { anchors.fill: parent; preventStealing: true; }

        // ------------------------------------- Header -------------------------------------

        Item {
            id: dlgHeader;
            width: parent.width;
            height: 44 * dpiScale;
            BasicText {
                anchors.verticalCenter: parent.verticalCenter;
                leftPadding: 15 * dpiScale;
                text: qsTr("Render queue");
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
                onClicked: root.shown = false;
            }
        }
        Hr { width: parent.width; y: dlgHeader.height; }

        // ------------------------------------ Progress ------------------------------------

        Item {
            id: progressRow;
            y: dlgHeader.height + 10 * dpiScale;
            x: 15 * dpiScale;
            width: parent.width - 2*x;
            height: 46 * dpiScale;

            property real progress: Math.max(0, Math.min(1, render_queue.current_frame / Math.max(1, render_queue.total_frames)));
            onProgressChanged: {
                const times = Util.calculateTimesAndFps(progress, render_queue.current_frame, render_queue.start_timestamp, render_queue.end_timestamp);
                if (times !== false && progress < 1.0) {
                    totalTime.elapsed = times[0];
                    totalTime.remaining = times[1];
                    if (times.length > 2) totalTime.fps = times[2];
                } else {
                    totalTime.remaining = "---";
                }
            }

            Column {
                id: progressCol;
                width: parent.width - mainBtn.width - 15 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
                spacing: 4 * dpiScale;
                BasicText {
                    width: parent.width;
                    leftPadding: 0;
                    font.pixelSize: 12 * dpiScale;
                    textFormat: Text.RichText;
                    text: qsTr("Queue: %1").arg(`<b>${(progressRow.progress*100).toFixed(1)}%</b> <small>(${render_queue.current_frame}/${render_queue.total_frames}${totalTime.fpsText})</small>`);
                }
                QQC.ProgressBar {
                    width: parent.width;
                    height: 4 * dpiScale;
                    value: progressRow.progress;
                }
                BasicText {
                    id: totalTime;
                    width: parent.width;
                    leftPadding: 0;
                    font.pixelSize: 10 * dpiScale;
                    opacity: 0.7;
                    property string elapsed: "---";
                    property string remaining: "---";
                    property real fps: 0;
                    property string fpsText: progressRow.progress > 0? qsTr(" @ %1fps").arg(fps.toFixed(1)) : "";
                    text: qsTr("Elapsed: %1. Remaining: %2").arg(elapsed).arg(render_queue.status == "active"? remaining : "---");
                }
            }
            Button {
                id: mainBtn;
                anchors.right: parent.right;
                anchors.verticalCenter: parent.verticalCenter;
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
                enabled: render_queue.total_frames > 0;
                Behavior on accentColor { ColorAnimation { duration: 700; easing.type: Easing.OutExpo; } }
                onClicked: render_queue[statuses[render_queue.status][3]]();
            }
        }

        // -------------------------------------- Queue --------------------------------------

        ListView {
            id: lv;
            x: 15 * dpiScale;
            width: parent.width - 2*x;
            anchors.top: progressRow.bottom;
            anchors.topMargin: 10 * dpiScale;
            anchors.bottom: dlgFooter.top;
            anchors.bottomMargin: 10 * dpiScale;
            clip: true;
            spacing: 5 * dpiScale;
            model: render_queue.queue;
            QQC.ScrollIndicator.vertical: QQC.ScrollIndicator { }

            BasicText {
                anchors.centerIn: parent;
                width: parent.width - 40 * dpiScale;
                visible: lv.count == 0;
                horizontalAlignment: Text.AlignHCenter;
                wrapMode: Text.WordWrap;
                font.pixelSize: 13 * dpiScale;
                opacity: 0.7;
                text: qsTr("The render queue is empty. Select videos in the media list and add them to the queue.");
            }

            // Drag and drop reordering, see the dynamic view tutorial in the Qt documentation
            property bool isDragging: false;
            property int dragTargetIndex: -1;
            Rectangle {
                id: dragIndicator;
                width: parent.width;
                height: 3 * dpiScale;
                radius: 2 * dpiScale;
                color: styleAccentColor;
                visible: opacity > 0;
                opacity: lv.isDragging? 0.9 : 0;
                Ease on opacity { duration: 300; }
            }

            delegate: Rectangle {
                id: dlg;
                width: lv.width;
                height: 60 * dpiScale;
                radius: 5 * dpiScale;
                property real progress: total_frames > 0? current_frame / total_frames : 0;
                property bool isFinished: current_frame >= total_frames && total_frames > 0;
                property bool isQuestion: error_string.startsWith("convert_format:") || error_string.startsWith("file_exists:");
                property bool isInfo: error_string == "uses_cpu";
                property bool isError: error_string.length > 0 && !isQuestion && !isInfo;
                property bool isProcessing: processing_progress > 0.0 && processing_progress < 1.0;
                property bool isRendering: !isFinished && !isError && !isQuestion && total_frames > 0 && (current_frame > 0 || isProcessing);
                property bool dragging: false;

                color: isError?    "#30ed7676"
                     : isQuestion? "#30" + styleAccentColor.toString().substring(1)
                     : isFinished? "#3070e574"
                     : "#15ffffff";
                opacity: dragging? 0.5 : 1;
                Ease on opacity { duration: 200; }

                Drag.active: dragging;
                DropArea {
                    anchors.fill: parent;
                    enabled: lv.isDragging;
                    onEntered: (drag) => {
                        if (drag.y > dlg.height / 2) {
                            lv.dragTargetIndex = index + 1;
                            dragIndicator.y = lv.mapFromItem(dlg, 0, dlg.height + lv.spacing).y;
                        } else {
                            lv.dragTargetIndex = index;
                            dragIndicator.y = lv.mapFromItem(dlg, 0, 0).y;
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
                        iconName: "play";
                        text: qsTr("Render now");
                        enabled: !dlg.isFinished && !dlg.isRendering;
                        onTriggered: render_queue.render_job(job_id);
                    }
                    Action {
                        iconName: "arrow-up";
                        text: qsTr("Move up");
                        enabled: index > 0;
                        onTriggered: render_queue.move_item(job_id, -1);
                    }
                    Action {
                        iconName: "arrow-down";
                        text: qsTr("Move down");
                        enabled: index < lv.count - 1;
                        onTriggered: render_queue.move_item(job_id, 1);
                    }
                    Action {
                        iconName: dlg.isRendering? "close" : "spinner";
                        text: dlg.isRendering? qsTr("Stop") : qsTr("Reset status");
                        enabled: dlg.isRendering || dlg.isError || dlg.isQuestion || dlg.isFinished;
                        onTriggered: render_queue.reset_job(job_id);
                    }
                    Action {
                        iconName: "bin";
                        text: qsTr("Remove from the queue");
                        enabled: !dlg.isRendering;
                        onTriggered: render_queue.remove(job_id);
                    }
                }

                Row {
                    anchors.fill: parent;
                    anchors.leftMargin: 5 * dpiScale;
                    anchors.rightMargin: 8 * dpiScale;
                    spacing: 8 * dpiScale;

                    // Grabbing this handle reorders the item in the queue
                    Item {
                        width: 20 * dpiScale;
                        height: parent.height;
                        QQCI.IconImage {
                            anchors.centerIn: parent;
                            name: "menu";
                            source: "qrc:/resources/icons/svg/menu.svg";
                            color: styleTextColor;
                            opacity: 0.6;
                            height: 14 * dpiScale;
                            width: height;
                            layer.enabled: true;
                            layer.textureSize: Qt.size(height*2, height*2);
                            layer.smooth: true;
                        }
                        MouseArea {
                            id: dragMa;
                            anchors.fill: parent;
                            hoverEnabled: true;
                            cursorShape: Qt.SizeVerCursor;
                            drag.target: dlg.dragging? dlg : undefined;
                            drag.axis: Drag.YAxis;
                            onPressed: {
                                dragIndicator.y = lv.mapFromItem(dlg, 0, 0).y;
                                lv.isDragging = dlg.dragging = true;
                                lv.dragTargetIndex = index;
                            }
                            onReleased: {
                                if (dlg.dragging) {
                                    let diff = lv.dragTargetIndex - index;
                                    if (lv.dragTargetIndex > index) diff--;
                                    if (diff != 0) render_queue.move_item(job_id, diff);
                                }
                                lv.isDragging = dlg.dragging = false;
                                lv.dragTargetIndex = -1;
                            }
                            ToolTip { visible: !isMobile && dragMa.containsMouse && !lv.isDragging; text: qsTr("Drag to reorder"); }
                        }
                    }

                    Image {
                        source: thumbnail_url;
                        fillMode: Image.PreserveAspectCrop;
                        width: 44 * dpiScale;
                        height: 44 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                        QQC.BusyIndicator { anchors.centerIn: parent; visible: !thumbnail_url; height: 20 * dpiScale; width: height; running: visible; }
                    }

                    Column {
                        width: parent.width - 20 * dpiScale - 44 * dpiScale - btnsRow.width - 4 * parent.spacing;
                        anchors.verticalCenter: parent.verticalCenter;
                        spacing: 2 * dpiScale;
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            text: input_filename;
                            font.bold: true;
                            font.pixelSize: 12 * dpiScale;
                            elide: Text.ElideMiddle;
                        }
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            font.pixelSize: 10 * dpiScale;
                            opacity: 0.7;
                            elide: Text.ElideMiddle;
                            text: qsTr("To: %1").arg(display_output_path);
                        }
                        QQC.ProgressBar {
                            width: parent.width;
                            height: 3 * dpiScale;
                            visible: dlg.isRendering;
                            value: dlg.isProcessing? processing_progress : dlg.progress;
                        }
                        BasicText {
                            width: parent.width;
                            leftPadding: 0;
                            font.pixelSize: 10 * dpiScale;
                            visible: !dlg.isRendering;
                            color: dlg.isError? "#ed7676" : dlg.isQuestion? styleAccentColor : styleTextColor;
                            opacity: 0.8;
                            elide: Text.ElideRight;
                            text: dlg.isError?    qsTr("Error")
                                : dlg.isQuestion? qsTr("Action needed")
                                : dlg.isFinished? qsTr("Done")
                                : export_settings;
                        }
                    }

                    Row {
                        id: btnsRow;
                        anchors.verticalCenter: parent.verticalCenter;
                        spacing: 2 * dpiScale;
                        LinkButton {
                            width: 28 * dpiScale;
                            height: 28 * dpiScale;
                            leftPadding: 0; rightPadding: 0;
                            icon.width: 13 * dpiScale;
                            icon.height: 13 * dpiScale;
                            textColor: styleAccentColor;
                            visible: !dlg.isFinished && !dlg.isRendering;
                            iconName: "play";
                            tooltip: qsTr("Render now");
                            onClicked: render_queue.render_job(job_id);
                        }
                        LinkButton {
                            width: 28 * dpiScale;
                            height: 28 * dpiScale;
                            leftPadding: 0; rightPadding: 0;
                            icon.width: 13 * dpiScale;
                            icon.height: 13 * dpiScale;
                            textColor: "#f67575";
                            enabled: !dlg.isRendering;
                            iconName: "bin";
                            tooltip: dlg.isRendering? qsTr("This item is already rendering.") : qsTr("Remove from the queue");
                            onClicked: render_queue.remove(job_id);
                        }
                    }
                }
            }

            displaced: Transition {
                NumberAnimation { properties: "y"; duration: 400; easing.type: Easing.OutExpo; }
            }
        }

        // ------------------------------------- Footer -------------------------------------

        Hr { width: parent.width; anchors.bottom: dlgFooter.top; }
        Item {
            id: dlgFooter;
            width: parent.width;
            height: 44 * dpiScale;
            anchors.bottom: parent.bottom;
            BasicText {
                anchors.verticalCenter: parent.verticalCenter;
                leftPadding: 15 * dpiScale;
                font.pixelSize: 11 * dpiScale;
                opacity: 0.7;
                text: qsTr("%1 items in the queue").arg(lv.count);
            }
            Button {
                anchors.right: parent.right;
                anchors.rightMargin: 15 * dpiScale;
                anchors.verticalCenter: parent.verticalCenter;
                height: 28 * dpiScale;
                font.pixelSize: 11 * dpiScale;
                enabled: lv.count > 0;
                text: qsTr("Clear the queue");
                onClicked: {
                    messageBox(Modal.Warning, qsTr("Are you sure you want to remove all items from the render queue?"), [
                        { text: qsTr("Yes"), clicked: () => { render_queue.clear(); media_library.clear_job_statuses(); } },
                        { text: qsTr("No"), accent: true },
                    ]);
                }
            }
        }
    }
}
