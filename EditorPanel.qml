import Quickshell
import Quickshell.Wayland
import QtQuick

// The editor's full-screen layer-shell window. TileBlueprints.qml loads it with setSource, because
// a PanelWindow cannot even be declared in the offscreen probe that tests EditorCard.qml.
PanelWindow {
  id: panel
  property var controller: null

  visible: !!controller && controller.opened
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-tile-blueprints"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  Rectangle { anchors.fill: parent; color: panel.controller ? panel.controller.scrim : "transparent" }
  MouseArea { anchors.fill: parent; onClicked: if (panel.controller) panel.controller.requestClose() }

  EditorCard {
    anchors.centerIn: parent
    tb: panel.controller
    screenWidth: panel.width
    screenHeight: panel.height
  }
}
