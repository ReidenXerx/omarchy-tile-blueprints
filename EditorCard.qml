import Quickshell
import QtQuick
import qs.Commons
import qs.Ui
import "BlueprintModel.js" as Model

// The blueprint editor's card: workspace tabs, the canvas, the app picker, the footer, and the
// question asked before closing with unsaved changes. The TileBlueprints item (`tb`) holds every
// piece of state; this file draws it and hands it the input.

BorderSurface {
  id: editorCard

  // The TileBlueprints item that owns the state, and the screen the card is centred on.
  property var tb: null
  property real screenWidth: 1920
  property real screenHeight: 1080
  readonly property Item canvasItem: canvas
  readonly property real canvasWidth: canvas.width
  readonly property real canvasHeight: canvas.height

  // Tiles and dividers keep their delegates while their ids stay the same, so a drag under way
  // survives the geometry changing beneath it (dragging a divider changes it on every move).
  property var tileIds: []
  property var tileById: ({})
  property var dividerKeys: []
  property var dividerByKey: ({})

  function syncModels() {
    var g = editorCard.tb ? editorCard.tb.geometry : null
    var tiles = g ? g.tiles : []
    var byId = ({})
    var ids = []
    for (var i = 0; i < tiles.length; i++) {
      byId[tiles[i].id] = tiles[i]
      ids.push(tiles[i].id)
    }
    // The lookups first, so delegates made for new ids find their data.
    editorCard.tileById = byId
    if (ids.join(" ") !== editorCard.tileIds.join(" ")) editorCard.tileIds = ids
    var dividers = g ? g.dividers : []
    var byKey = ({})
    var names = []
    for (var d = 0; d < dividers.length; d++) {
      var name = dividers[d].path.join(".") + ":" + dividers[d].index + ":" + dividers[d].dir
      byKey[name] = dividers[d]
      names.push(name)
    }
    editorCard.dividerByKey = byKey
    if (names.join(" ") !== editorCard.dividerKeys.join(" ")) editorCard.dividerKeys = names
  }

  function focusKeys() {
    keys.forceActiveFocus()
  }

  function focusPickerSearch() {
    pickerSearch.text = ""
    pickerSearch.forceActiveFocus()
  }

  // What a drag is over, from a point in canvas coordinates: { tile, onClass } or null.
  function hitTile(px, py) {
    for (var i = 0; i < tilesRepeater.count; i++) {
      var t = tilesRepeater.itemAt(i)
      if (!t) continue
      var p = t.mapFromItem(canvas, px, py)
      if (p.x >= 0 && p.y >= 0 && p.x < t.width && p.y < t.height) return { tile: t.tileId, onClass: t.classAt(px, py) }
    }
    return null
  }

  Connections {
    target: editorCard.tb
    function onGeometryChanged() { editorCard.syncModels() }
  }

  Component.onCompleted: {
    if (editorCard.tb) editorCard.tb.view = editorCard
    editorCard.syncModels()
  }
  Component.onDestruction: {
    if (editorCard.tb && editorCard.tb.view === editorCard) editorCard.tb.view = null
  }

  width: Math.min(Style.space(1080), editorCard.screenWidth - Style.gapsOut * 4)
  height: Math.min(Style.space(760), editorCard.screenHeight - Style.gapsOut * 4)
  radius: tb.cornerRadius
  color: tb.background
  borderSpec: tb.borderSpec
  padding: Style.spacing.panelPadding

  MouseArea { anchors.fill: parent; onClicked: keys.forceActiveFocus() }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { tb.handleKey(event) }
    Keys.onReleased: function(event) { if (event.key === Qt.Key_Shift) tb.setDragShift(false) }
  }

  Column {
    id: content
    anchors.fill: parent
    anchors.topMargin: editorCard.contentTopInset
    anchors.rightMargin: editorCard.contentRightInset
    anchors.bottomMargin: editorCard.contentBottomInset
    anchors.leftMargin: editorCard.contentLeftInset
    spacing: Style.spacing.lg

    // ------------------------------------------------ header
    Item {
      width: parent.width
      height: Style.space(34)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Tile blueprints"
        color: tb.foreground
        font.family: tb.fontFamily
        font.pixelSize: Style.font.heading
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Repeater {
          model: 10
          delegate: Rectangle {
            id: wsTab
            required property int index
            readonly property int number: index + 1
            readonly property bool active: tb.workspace === number
            width: Style.space(34)
            height: Style.space(30)
            radius: tb.cornerRadius
            color: active ? tb.selectedBackground : "transparent"
            border.width: active ? Math.max(1, Style.space(1)) : 0
            border.color: tb.accent

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: wsTab.number === 10 ? "10" : String(wsTab.number)
              color: wsTab.active ? tb.accent : tb.foreground
              opacity: wsTab.active || tb.workspaceHasBlueprint(wsTab.number) ? 1 : 0.45
              font.family: tb.fontFamily
              font.pixelSize: Style.font.title
            }

            Rectangle {
              visible: tb.workspaceHasBlueprint(wsTab.number)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(3)
              width: Style.space(4); height: width; radius: width / 2
              color: tb.accent
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { tb.showWorkspace(wsTab.number); keys.forceActiveFocus() }
            }
          }
        }
      }
    }

    // ------------------------------------------------ canvas + picker
    Item {
      id: stage
      width: parent.width
      height: content.height - Style.space(34) - footer.height - content.spacing * 2

      readonly property real pickerWidth: tb.pickerOpen ? Style.space(300) : 0
      readonly property real aspect: editorCard.screenWidth > 0 && editorCard.screenHeight > 0 ? editorCard.screenWidth / editorCard.screenHeight : 16 / 10

      Item {
        id: canvasFrame
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width - stage.pickerWidth - (tb.pickerOpen ? Style.spacing.lg : 0)

        Rectangle {
          id: canvas
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height * stage.aspect)
          height: width / stage.aspect
          radius: tb.cornerRadius
          color: Util.alpha(tb.foreground, 0.04)
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(tb.foreground, 0.12)

          Repeater {
            id: tilesRepeater
            model: editorCard.tileIds

            delegate: Rectangle {
              id: tile
              required property var modelData
              readonly property string tileId: String(modelData)
              readonly property var info: editorCard.tileById[tileId] || ({ id: tileId, apps: [], x: 0, y: 0, w: 0, h: 0 })
              readonly property bool isSelected: tileId === tb.selected
              readonly property bool isDropTarget: !!tb.dropTarget && tb.dropKind !== "" && tb.dropTarget.tile === tileId

              // The tile's apps by class. The list is replaced only when its classes change, so dragging a
              // divider does not rebuild the cards.
              property var appKeys: []
              property var appByClass: ({})

              function syncApps() {
                var list = info.apps || []
                var byClass = ({})
                var names = []
                for (var i = 0; i < list.length; i++) {
                  byClass[String(list[i]["class"]).toLowerCase()] = list[i]
                  names.push(String(list[i]["class"]))
                }
                appByClass = byClass
                if (names.join("\n") !== appKeys.join("\n")) appKeys = names
              }

              // The class of the app card under a point in canvas coordinates, or "".
              function classAt(px, py) {
                for (var j = 0; j < cardsRepeater.count; j++) {
                  var c = cardsRepeater.itemAt(j)
                  if (!c) continue
                  var q = c.mapFromItem(canvas, px, py)
                  if (q.x >= 0 && q.y >= 0 && q.x < c.width && q.y < c.height) return c.appClass
                }
                return ""
              }

              onInfoChanged: syncApps()
              Component.onCompleted: syncApps()
              readonly property real gap: Style.space(4)

              x: info.x + gap
              y: info.y + gap
              width: Math.max(0, info.w - gap * 2)
              height: Math.max(0, info.h - gap * 2)
              radius: tb.cornerRadius
              color: isDropTarget ? Util.alpha(tb.accent, 0.14) : (isSelected ? tb.selectedBackground : Util.alpha(tb.foreground, 0.06))
              border.width: isSelected || isDropTarget ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
              border.color: isSelected || isDropTarget ? tb.accent : Util.alpha(tb.foreground, 0.18)

              MouseArea {
                anchors.fill: parent
                onClicked: { tb.selected = tile.tileId; keys.forceActiveFocus() }
                onDoubleClicked: { tb.selected = tile.tileId; tb.openPicker() }
              }

              // A preview of what Hyprland will do with this tile: one window per app,
              // sharing the tile evenly along its longer side.
              Item {
                id: cards
                anchors.fill: parent
                anchors.margins: Style.spacing.lg
                anchors.bottomMargin: Style.spacing.sm + tileFoot.height + Style.spacing.sm
                visible: tile.appKeys.length > 0

                Repeater {
                  id: cardsRepeater
                  model: tile.appKeys

                  delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property string appClass: String(modelData)
                    readonly property var app: tile.appByClass[appClass.toLowerCase()] || ({ "class": appClass, name: appClass, desktop: "" })
                    readonly property bool isDragged: !!tb.dragApp && tb.dragFrom === tile.tileId
                      && String(tb.dragApp["class"]).toLowerCase() === appClass.toLowerCase()
                    readonly property bool isSwapTarget: !!tb.dropTarget && tb.dropKind === "swap" && tb.dropTarget.tile === tile.tileId
                      && String(tb.dropTarget.onClass).toLowerCase() === appClass.toLowerCase()
                    readonly property var box: tb.cardBoxes(cards.width, cards.height, tile.appKeys.length)[index]
                    readonly property int iconSide: Math.max(Style.space(20), Math.min(Style.space(64), Math.min(width, height) * 0.34))

                    x: box ? box.x : 0
                    y: box ? box.y : 0
                    width: box ? box.w : 0
                    height: box ? box.h : 0
                    radius: tb.cornerRadius
                    opacity: card.isDragged ? 0.35 : 1
                    color: card.isSwapTarget ? Util.alpha(tb.accent, 0.2) : Util.alpha(tb.foreground, tile.isSelected ? 0.10 : 0.06)
                    border.width: card.isSwapTarget ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
                    border.color: card.isSwapTarget ? tb.accent : Util.alpha(tb.foreground, cardHover.hovered ? 0.35 : 0.14)

                    HoverHandler { id: cardHover }

                    // Press to select the tile; drag to take the app somewhere else: onto another app to swap
                    // the two, onto a tile (or with Shift onto an app) to put it there. The drop is applied
                    // after the release, so no delegate is rebuilt inside its own handler.
                    MouseArea {
                      id: cardPointer
                      anchors.fill: parent
                      preventStealing: true
                      cursorShape: tb.dragApp ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                      property real pressX: 0
                      property real pressY: 0
                      property bool dragging: false

                      onPressed: function(mouse) {
                        pressX = mouse.x
                        pressY = mouse.y
                        dragging = false
                        tb.selected = tile.tileId
                        keys.forceActiveFocus()
                      }
                      onPositionChanged: function(mouse) {
                        if (!pressed) return
                        if (!dragging) {
                          if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(8)) return
                          dragging = tb.beginDrag(card.app, tile.tileId)
                          if (!dragging) return
                        }
                        var p = mapToItem(canvas, mouse.x, mouse.y)
                        tb.moveDrag(editorCard.hitTile(p.x, p.y), p.x, p.y, (mouse.modifiers & Qt.ShiftModifier) !== 0)
                      }
                      onReleased: {
                        if (!dragging) return
                        dragging = false
                        var controller = tb
                        var drop = controller.takeDrop()
                        Qt.callLater(function() { controller.applyDrop(drop) })
                      }
                      onCanceled: {
                        if (!dragging) return
                        dragging = false
                        tb.cancelDrag()
                      }
                      onDoubleClicked: { tb.selected = tile.tileId; tb.openPicker() }
                    }

                    Column {
                      anchors.centerIn: parent
                      width: parent.width - Style.spacing.lg * 2
                      spacing: Style.spacing.sm

                      Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: card.iconSide
                        height: card.iconSide
                        sourceSize.width: card.iconSide * 2
                        sourceSize.height: card.iconSide * 2
                        source: tb.iconFor(card.app)
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                      }

                      Text {
                        width: parent.width
                        visible: card.height >= Style.space(76)
                        horizontalAlignment: Text.AlignHCenter
                        textFormat: Text.PlainText
                        text: card.app.name || card.app["class"]
                        elide: Text.ElideRight
                        color: tb.foreground
                        font.family: tb.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        width: parent.width
                        visible: card.height >= Style.space(110) && card.width >= Style.space(110)
                        horizontalAlignment: Text.AlignHCenter
                        textFormat: Text.PlainText
                        text: card.app["class"]
                        elide: Text.ElideMiddle
                        color: tb.foreground
                        opacity: 0.4
                        font.family: tb.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Rectangle {
                      visible: tb.isRunning(card.app)
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.md
                      width: Style.space(6); height: width; radius: width / 2
                      color: tb.accent
                    }

                    Rectangle {
                      id: removeButton
                      visible: cardHover.hovered || tile.isSelected
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.sm
                      width: Style.space(22); height: width; radius: width / 2
                      color: removeArea.containsMouse ? Util.alpha(tb.accent, 0.3) : "transparent"

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "×"
                        color: tb.foreground
                        opacity: removeArea.containsMouse ? 1 : 0.6
                        font.family: tb.fontFamily
                        font.pixelSize: Style.font.title
                      }

                      MouseArea {
                        id: removeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: tb.removeApp(tile.tileId, card.app["class"])
                      }
                    }
                  }
                }
              }

              // Empty tile: a target to click.
              Column {
                anchors.centerIn: parent
                visible: tile.appKeys.length === 0
                spacing: Style.spacing.md

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(44); height: width; radius: width / 2
                  color: plusArea.containsMouse ? Util.alpha(tb.accent, 0.22) : Util.alpha(tb.foreground, 0.07)
                  border.width: Math.max(1, Style.space(1))
                  border.color: tile.isSelected || plusArea.containsMouse ? tb.accent : Util.alpha(tb.foreground, 0.2)

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "+"
                    color: tile.isSelected ? tb.accent : tb.foreground
                    font.family: tb.fontFamily
                    font.pixelSize: Style.font.display
                  }

                  MouseArea {
                    id: plusArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { tb.selected = tile.tileId; tb.openPicker() }
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: tile.height >= Style.space(110)
                  textFormat: Text.PlainText
                  text: "Add app"
                  color: tb.foreground
                  opacity: 0.55
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                id: tileFoot
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Style.spacing.lg
                anchors.rightMargin: Style.spacing.lg
                anchors.bottomMargin: Style.spacing.sm
                height: Style.space(16)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  visible: tile.isSelected && tile.appKeys.length > 0 && tile.width >= Style.space(220)
                  textFormat: Text.PlainText
                  text: "A  add another app"
                  color: tb.accent
                  opacity: 0.75
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: tile.width >= Style.space(90)
                  textFormat: Text.PlainText
                  text: tb.percent(tile.info.w, canvas.width) + " × " + tb.percent(tile.info.h, canvas.height)
                  color: tb.foreground
                  opacity: 0.45
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Dividers: drag to set the split between two neighbouring tiles.
          Repeater {
            id: dividersRepeater
            model: editorCard.dividerKeys

            delegate: Item {
              id: divider
              required property var modelData
              readonly property var info: editorCard.dividerByKey[modelData] || ({ dir: "h", at: 0, index: 0, path: [], split: { x: 0, y: 0, w: 0, h: 0 } })
              readonly property bool across: info.dir === "h"
              readonly property real grip: Style.space(10)

              x: across ? info.at - grip / 2 : info.split.x
              y: across ? info.split.y : info.at - grip / 2
              width: across ? grip : info.split.w
              height: across ? info.split.h : grip

              Rectangle {
                anchors.centerIn: parent
                width: divider.across ? Math.max(2, Style.space(2)) : parent.width * 0.3
                height: divider.across ? parent.height * 0.3 : Math.max(2, Style.space(2))
                radius: Math.max(1, Style.space(1))
                color: tb.accent
                opacity: dragArea.containsMouse || dragArea.pressed ? 0.9 : 0
              }

              MouseArea {
                id: dragArea
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: divider.across ? Qt.SplitHCursor : Qt.SplitVCursor
                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  var s = divider.info.split
                  var fraction = divider.across ? (p.x - s.x) / s.w : (p.y - s.y) / s.h
                  tb.editRoot(Model.moveDivider(tb.current.root, divider.info.path, divider.info.index, fraction), tb.selected)
                }
                onReleased: keys.forceActiveFocus()
              }
            }
          }
        }
      }

      // The app being dragged, under the pointer.
      Rectangle {
        id: dragGhost
        z: 10
        visible: !!tb.dragApp
        x: canvasFrame.x + canvas.x + tb.dragX - width / 2
        y: canvasFrame.y + canvas.y + tb.dragY - height / 2
        width: ghostRow.implicitWidth + Style.spacing.lg * 2
        height: Style.space(44)
        radius: height / 2
        color: Qt.rgba(tb.background.r, tb.background.g, tb.background.b, 1)
        border.width: Math.max(2, Style.space(2))
        border.color: tb.accent

        Row {
          id: ghostRow
          anchors.centerIn: parent
          spacing: Style.spacing.md

          Image {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(24)
            height: width
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            source: tb.dragApp ? tb.iconFor(tb.dragApp) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: tb.dragApp ? (tb.dragApp.name || tb.dragApp["class"]) : ""
            color: tb.foreground
            font.family: tb.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      // ------------------------------------------------ app picker
      Rectangle {
        id: picker
        visible: tb.pickerOpen
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: stage.pickerWidth
        radius: tb.cornerRadius
        color: Util.alpha(tb.foreground, 0.05)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(tb.foreground, 0.12)

        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.lg
          spacing: Style.spacing.md

          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: tb.cornerRadius
            color: Util.alpha(tb.foreground, 0.07)

            TextInput {
              id: pickerSearch
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.lg
              anchors.rightMargin: Style.spacing.lg
              verticalAlignment: TextInput.AlignVCenter
              color: tb.foreground
              font.family: tb.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              onTextChanged: { tb.pickerQuery = text; tb.pickerIndex = 0 }
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                var count = tb.pickerApps.length
                if (event.key === Qt.Key_Escape) { tb.pickerOpen = false; keys.forceActiveFocus() }
                else if (event.key === Qt.Key_Down) { tb.pickerIndex = Math.min(count - 1, tb.pickerIndex + 1); appList.positionViewAtIndex(tb.pickerIndex, ListView.Contain) }
                else if (event.key === Qt.Key_Up) { tb.pickerIndex = Math.max(0, tb.pickerIndex - 1); appList.positionViewAtIndex(tb.pickerIndex, ListView.Contain) }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) tb.assignApp(tb.pickerApps[tb.pickerIndex])
                else return
                event.accepted = true
              }

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: pickerSearch.text === ""
                textFormat: Text.PlainText
                text: "App for this tile…"
                color: tb.foreground
                opacity: 0.45
                font: pickerSearch.font
              }
            }
          }

          ListView {
            id: appList
            width: parent.width
            height: parent.height - Style.space(32) - parent.spacing
            clip: true
            model: tb.pickerApps
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: appRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: Style.space(40)
              radius: tb.cornerRadius
              color: index === tb.pickerIndex ? tb.selectedBackground : "transparent"

              Image {
                id: appIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(24)
                height: width
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                source: tb.iconFor(appRow.modelData)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
              }

              Column {
                anchors.left: appIcon.right
                anchors.right: runningDot.left
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: appRow.modelData.name
                  elide: Text.ElideRight
                  color: appRow.index === tb.pickerIndex ? tb.accent : tb.foreground
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: appRow.modelData["class"]
                  elide: Text.ElideRight
                  color: tb.foreground
                  opacity: 0.45
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                id: runningDot
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6); height: width; radius: width / 2
                color: tb.accent
                opacity: appRow.modelData.running ? 0.9 : 0
              }

              // Click adds the app to the selected tile; drag it onto any tile to put it there.
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.PointingHandCursor
                property real pressX: 0
                property real pressY: 0
                property bool dragging: false
                property bool dragged: false

                onEntered: tb.pickerIndex = appRow.index
                onPressed: function(mouse) {
                  pressX = mouse.x
                  pressY = mouse.y
                  dragging = false
                  dragged = false
                }
                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  if (!dragging) {
                    if (dragged || Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(8)) return
                    dragged = tb.beginDrag(appRow.modelData, "")
                    dragging = dragged
                    if (!dragging) return
                  }
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  tb.moveDrag(editorCard.hitTile(p.x, p.y), p.x, p.y, false)
                }
                onReleased: {
                  if (!dragging) return
                  dragging = false
                  var controller = tb
                  var drop = controller.takeDrop()
                  Qt.callLater(function() { controller.applyDrop(drop) })
                }
                onCanceled: {
                  if (!dragging) return
                  dragging = false
                  tb.cancelDrag()
                }
                onClicked: if (!dragged) tb.assignApp(appRow.modelData)
              }
            }
          }
        }
      }
    }

    // ------------------------------------------------ footer
    Item {
      id: footer
      width: parent.width
      height: Style.space(48)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.normalBorderWidth
        color: Util.alpha(tb.border, 0.28)
      }

      Column {
        anchors.left: parent.left
        anchors.right: flags.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Style.spacing.xs
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: tb.status !== "" ? tb.status
            : (tb.hasChanges ? "Unsaved changes · Ctrl+S saves and applies" : "Workspace " + tb.workspace)
          color: tb.status !== "" || tb.hasChanges ? tb.accent : tb.foreground
          font.family: tb.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: "Drag apps between tiles · | split beside · - split below · X remove · Shift+arrows resize · A add · C capture"
          color: tb.foreground
          opacity: 0.5
          font.family: tb.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: flags
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Style.spacing.xs
        spacing: Style.spacing.md

        Repeater {
          model: [
            { flag: "pin", label: "P  pin to workspace" },
            { flag: "launch", label: "O  open at login" },
            { flag: "save", label: "Ctrl+S  save" }
          ]

          delegate: Rectangle {
            id: flagChip
            required property var modelData
            readonly property bool on: modelData.flag === "save" ? tb.hasChanges : tb.current[modelData.flag] !== false
            width: flagText.implicitWidth + Style.spacing.lg * 2
            height: Style.space(28)
            radius: height / 2
            color: on ? Util.alpha(tb.accent, 0.18) : "transparent"
            border.width: Math.max(1, Style.space(1))
            border.color: on ? tb.accent : Util.alpha(tb.foreground, 0.2)

            Text {
              id: flagText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: flagChip.modelData.label
              color: flagChip.on ? tb.foreground : Util.alpha(tb.foreground, 0.5)
              font.family: tb.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { if (flagChip.modelData.flag === "save") tb.save(); else tb.toggleFlag(flagChip.modelData.flag); keys.forceActiveFocus() }
            }
          }
        }
      }
    }
  }

  // Asked when the editor is closed with unsaved changes: Esc, a click outside the card, or the
  // shell closing it (its key pressed again). Nothing behind it takes input meanwhile.
  Item {
    id: savePrompt
    anchors.fill: parent
    visible: tb.promptOpen
    z: 20

    Rectangle {
      anchors.fill: parent
      radius: tb.cornerRadius
      color: Qt.rgba(tb.background.r, tb.background.g, tb.background.b, 0.8)
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      hoverEnabled: true
      onWheel: function(wheel) { wheel.accepted = true }
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.spacing.lg * 4, Style.space(520))
      height: promptColumn.implicitHeight + Style.spacing.lg * 4
      radius: tb.cornerRadius
      color: Qt.rgba(tb.background.r, tb.background.g, tb.background.b, 1)
      border.width: Math.max(1, Style.space(2))
      border.color: tb.accent

      Column {
        id: promptColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.lg * 2
        anchors.rightMargin: Style.spacing.lg * 2
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Save your changes?"
          color: tb.foreground
          wrapMode: Text.WordWrap
          font.family: tb.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: tb.promptText
          color: tb.foreground
          opacity: 0.75
          wrapMode: Text.WordWrap
          font.family: tb.fontFamily
          font.pixelSize: Style.font.body
        }

        Flow {
          width: parent.width
          spacing: Style.spacing.md

          Repeater {
            model: [
              { action: "save", label: "Save", key: "Enter" },
              { action: "discard", label: "Don't save", key: "D" },
              { action: "cancel", label: "Keep editing", key: "Esc" }
            ]

            delegate: Rectangle {
              id: promptButton
              required property var modelData
              readonly property bool primary: modelData.action === "save"
              readonly property color ink: primary ? Qt.rgba(tb.background.r, tb.background.g, tb.background.b, 1) : tb.foreground
              width: promptButtonRow.implicitWidth + Style.spacing.lg * 2
              height: Style.space(34)
              radius: height / 2
              color: primary ? tb.accent : (promptButtonArea.containsMouse ? Util.alpha(tb.foreground, 0.1) : "transparent")
              border.width: Math.max(1, Style.space(1))
              border.color: primary ? tb.accent : Util.alpha(tb.foreground, 0.25)

              Row {
                id: promptButtonRow
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: promptButton.modelData.label
                  color: promptButton.ink
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: promptButton.modelData.key
                  color: promptButton.ink
                  opacity: 0.6
                  font.family: tb.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: promptButtonArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tb.answerPrompt(promptButton.modelData.action)
              }
            }
          }
        }
      }
    }
  }
}
