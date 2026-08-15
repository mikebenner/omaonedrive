import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize * 1.3
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.width * 0.14
      startY: root.height * 0.79
      PathCubic {
        x: root.width * 0.34; y: root.height * 0.43
        control1X: root.width * 0.12; control1Y: root.height * 0.60
        control2X: root.width * 0.20; control2Y: root.height * 0.43
      }
      PathCubic {
        x: root.width * 0.69; y: root.height * 0.38
        control1X: root.width * 0.40; control1Y: root.height * 0.08
        control2X: root.width * 0.65; control2Y: root.height * 0.17
      }
      PathCubic {
        x: root.width * 0.87; y: root.height * 0.56
        control1X: root.width * 0.78; control1Y: root.height * 0.37
        control2X: root.width * 0.86; control2Y: root.height * 0.45
      }
      PathCubic {
        x: root.width * 0.86; y: root.height * 0.84
        control1X: root.width * 1.02; control1Y: root.height * 0.59
        control2X: root.width * 1.02; control2Y: root.height * 0.82
      }
      PathLine { x: root.width * 0.14; y: root.height * 0.84 }
      PathCubic {
        x: root.width * 0.14; y: root.height * 0.79
        control1X: root.width * 0.06; control1Y: root.height * 0.84
        control2X: root.width * 0.06; control2Y: root.height * 0.78
      }
    }
  }
}
