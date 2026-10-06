// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick

import "../components/"

MenuItem {
    text: qsTr("Background");
    iconName: "fov-overview";
    opened: false;
    objectName: "advanced";

    Item {
        id: sett;
        property alias renderBackground: renderBackground.text;
        property alias backgroundMode: backgroundMode.currentIndex;
        property alias marginPixels: marginPixels.value;
        property alias featherPixels: featherPixels.value;

        Component.onCompleted: settings.init(sett);
        function propChanged() { settings.propChanged(sett); }
    }

    function loadGyroflow(obj: var): void {
        if (obj.hasOwnProperty("background_mode")) backgroundMode.currentIndex = +obj.background_mode;
        if (obj.hasOwnProperty("background_margin")) marginPixels.value = +obj.background_margin;
        if (obj.hasOwnProperty("background_margin_feather")) featherPixels.value = +obj.background_margin_feather;
        if (obj.hasOwnProperty("background_color")) renderBackground.text = Qt.rgba(obj.background_color[0], obj.background_color[1], obj.background_color[2], obj.background_color[3]).toString();
    }
    Label {
        position: Label.LeftPosition;
        text: qsTr("Background mode");
        ComboBox {
            id: backgroundMode;
            model: [QT_TRANSLATE_NOOP("Popup", "Solid color"), QT_TRANSLATE_NOOP("Popup", "Repeat edge pixels"), QT_TRANSLATE_NOOP("Popup", "Mirror edge pixels"), QT_TRANSLATE_NOOP("Popup", "Margin with feather")];
            font.pixelSize: 12 * dpiScale;
            width: parent.width;
            currentIndex: 0;
            onCurrentIndexChanged: controller.background_mode = currentIndex;
        }
    }
    Column {
        width: parent.width;
        visible: backgroundMode.currentIndex == 3;
        Label {
            text: qsTr("Margin");
            SliderWithField {
                id: marginPixels;
                value: 0.20;
                defaultValue: 20;
                from: 0;
                to: 50;
                unit: "%";
                precision: 0;
                width: parent.width;
                keyframe: "BackgroundMargin";
                scaler: 100.0;
                onValueChanged: controller.background_margin = value;
            }
        }
        Label {
            text: qsTr("Feather");
            SliderWithField {
                id: featherPixels;
                value: 0.05;
                defaultValue: 5;
                from: 0;
                to: 50;
                unit: "%";
                precision: 0;
                width: parent.width;
                keyframe: "BackgroundFeather";
                scaler: 100.0;
                onValueChanged: controller.background_margin_feather = value;
            }
        }
    }
    Label {
        position: Label.LeftPosition;
        visible: backgroundMode.currentIndex == 0;
        text: qsTr("Render background");

        TextField {
            id: renderBackground;
            text: "#111111";
            width: parent.width;
            onTextChanged: controller.set_background_color(text, window.videoArea.vid);
        }
    }
}
