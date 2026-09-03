import QtQuick

Item {
  id: root

  property real badgeSize: 0
  property string glyph: ""
  property color glyphColor: "transparent"
  property color ringColor: "transparent"
  property color background: "transparent"
  property string fontFamily: ""
  property bool pulsing: false

  width: badgeSize
  height: badgeSize

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.background
    border.width: 1
    border.color: root.ringColor
  }

  Text {

    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.glyph
    color: root.glyphColor
    font.family: root.fontFamily
    font.pixelSize: root.badgeSize * 0.62
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  SequentialAnimation on opacity {
    running: root.pulsing
    loops: Animation.Infinite
    NumberAnimation { to: 0.25; duration: 500 }
    NumberAnimation { to: 1.0; duration: 500 }
  }
}
