{CompositeDisposable, Emitter} = require 'event-kit'
{Point} = require 'text-buffer'
_ = require 'underscore-plus'

module.exports =
class TextEditorPresenter
  toggleCursorBlinkHandle: null
  startBlinkingCursorsAfterDelay: null
  stoppedScrollingTimeoutId: null
  mouseWheelScreenRow: null

  constructor: (params) ->
    {@model, @autoHeight, @height, @contentFrameWidth, @scrollTop, @scrollLeft} = params
    {@horizontalScrollbarHeight, @verticalScrollbarWidth} = params
    {@lineHeight, @baseCharacterWidth, @lineOverdrawMargin, @backgroundColor, @gutterBackgroundColor} = params
    {@cursorBlinkPeriod, @cursorBlinkResumeDelay, @stoppedScrollingDelay} = params

    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @charWidthsByScope = {}
    @observeModel()
    @observeConfig()
    @buildState()
    @startBlinkingCursors()

  destroy: ->
    @disposables.dispose()

  onDidUpdateState: (callback) ->
    @emitter.on 'did-update-state', callback

  observeModel: ->
    @disposables.add @model.onDidChange =>
      @updateHeightState()
      @updateVerticalScrollState()
      @updateHorizontalScrollState()
      @updateContentState()
      @updateLinesState()
      @updateGutterState()
      @updateLineNumbersState()
    @disposables.add @model.onDidChangeGrammar(@updateContentState.bind(this))
    @disposables.add @model.onDidChangePlaceholderText(@updateContentState.bind(this))
    @disposables.add @model.onDidChangeMini =>
      @updateContentState()
      @updateLinesState()
      @updateLineNumbersState()
    @disposables.add @model.onDidAddDecoration(@didAddDecoration.bind(this))
    @disposables.add @model.onDidAddCursor(@didAddCursor.bind(this))
    @observeLineDecoration(decoration) for decoration in @model.getLineDecorations()
    @observeLineNumberDecoration(decoration) for decoration in @model.getLineNumberDecorations()
    @observeHighlightDecoration(decoration) for decoration in @model.getHighlightDecorations()
    @observeOverlayDecoration(decoration) for decoration in @model.getOverlayDecorations()
    @observeCursor(cursor) for cursor in @model.getCursors()

  observeConfig: ->
    @disposables.add atom.config.onDidChange 'editor.showIndentGuide', scope: @model.getRootScopeDescriptor(), @updateContentState.bind(this)

  buildState: ->
    @state =
      horizontalScrollbar: {}
      verticalScrollbar: {}
      content:
        scrollingVertically: false
        blinkCursorsOff: false
        lines: {}
        highlights: {}
        overlays: {}
      gutter:
        lineNumbers: {}
    @updateState()

  updateState: ->
    @updateHeightState()
    @updateVerticalScrollState()
    @updateHorizontalScrollState()
    @updateScrollbarsState()
    @updateContentState()
    @updateLinesState()
    @updateCursorsState()
    @updateHighlightsState()
    @updateOverlaysState()
    @updateGutterState()
    @updateLineNumbersState()

  updateHeightState: ->
    if @hasAutoHeight()
      @state.height = @computeContentHeight()
    else
      @state.height = null

    @emitter.emit 'did-update-state'

  updateVerticalScrollState: ->
    scrollHeight = @computeScrollHeight()
    @state.content.scrollHeight = scrollHeight
    @state.gutter.scrollHeight = scrollHeight
    @state.verticalScrollbar.scrollHeight = scrollHeight

    scrollTop = @getScrollTop()
    @state.content.scrollTop = scrollTop
    @state.gutter.scrollTop = scrollTop
    @state.verticalScrollbar.scrollTop = scrollTop

    @emitter.emit 'did-update-state'

  updateHorizontalScrollState: ->
    scrollWidth = @computeScrollWidth()
    @state.content.scrollWidth = scrollWidth
    @state.horizontalScrollbar.scrollWidth = scrollWidth

    scrollLeft = @getScrollLeft()
    @state.content.scrollLeft = @getScrollLeft()
    @state.horizontalScrollbar.scrollLeft = @getScrollLeft()

    @emitter.emit 'did-update-state'

  updateScrollbarsState: ->
    contentWidth = @computeContentWidth()
    contentHeight = @computeContentHeight()
    clientWidthWithoutVerticalScrollbar = @getContentFrameWidth()
    clientWidthWithVerticalScrollbar = clientWidthWithoutVerticalScrollbar - @getVerticalScrollbarWidth()
    clientHeightWithoutHorizontalScrollbar = @getHeight()
    clientHeightWithHorizontalScrollbar = clientHeightWithoutHorizontalScrollbar - @getHorizontalScrollbarHeight()
    horizontalScrollbarVisible =
      contentWidth > clientWidthWithoutVerticalScrollbar or
        contentWidth > clientWidthWithVerticalScrollbar and contentHeight > clientHeightWithoutHorizontalScrollbar
    verticalScrollbarVisible =
      contentHeight > clientHeightWithoutHorizontalScrollbar or
        contentHeight > clientHeightWithHorizontalScrollbar and contentWidth > clientWidthWithoutVerticalScrollbar

    @state.horizontalScrollbar.visible = horizontalScrollbarVisible
    @state.horizontalScrollbar.height = @getHorizontalScrollbarHeight()
    @state.horizontalScrollbar.right = if verticalScrollbarVisible then @getVerticalScrollbarWidth() else 0

    @state.verticalScrollbar.visible = verticalScrollbarVisible
    @state.verticalScrollbar.width = @getVerticalScrollbarWidth()
    @state.verticalScrollbar.bottom = if horizontalScrollbarVisible then @getHorizontalScrollbarHeight() else 0

    @emitter.emit 'did-update-state'

  updateContentState: ->
    @state.content.scrollWidth = @computeScrollWidth()
    @state.content.scrollLeft = @getScrollLeft()
    @state.content.indentGuidesVisible = not @model.isMini() and atom.config.get('editor.showIndentGuide', scope: @model.getRootScopeDescriptor())
    @state.content.backgroundColor = if @model.isMini() then null else @getBackgroundColor()
    @state.content.placeholderText = if @model.isEmpty() then @model.getPlaceholderText() else null
    @emitter.emit 'did-update-state'

  updateLinesState: ->
    visibleLineIds = {}
    startRow = @computeStartRow()
    endRow = @computeEndRow()

    row = startRow
    while row < endRow
      line = @model.tokenizedLineForScreenRow(row)
      visibleLineIds[line.id] = true
      if @state.content.lines.hasOwnProperty(line.id)
        @updateLineState(row, line)
      else
        @buildLineState(row, line)
      row++

    if @getMouseWheelScreenRow()? and not startRow <= @getMouseWheelScreenRow() < endRow
      preservedLine = @model.tokenizedLineForScreenRow(@getMouseWheelScreenRow())
      visibleLineIds[preservedLine.id] = true
      @updateLineState(@getMouseWheelScreenRow(), preservedLine)

    for id, line of @state.content.lines
      unless visibleLineIds.hasOwnProperty(id)
        delete @state.content.lines[id]

    @emitter.emit 'did-update-state'

  updateLineState: (row, line) ->
    lineState = @state.content.lines[line.id]
    lineState.screenRow = row
    lineState.top = row * @getLineHeight()
    lineState.decorationClasses = @lineDecorationClassesForRow(row)

  buildLineState: (row, line) ->
    @state.content.lines[line.id] =
      screenRow: row
      text: line.text
      tokens: line.tokens
      endOfLineInvisibles: line.endOfLineInvisibles
      indentLevel: line.indentLevel
      tabLength: line.tabLength
      fold: line.fold
      top: row * @getLineHeight()
      decorationClasses: @lineDecorationClassesForRow(row)

  updateCursorsState: ->
    @state.content.cursors = {}
    return unless @hasRequiredMeasurements()

    startRow = @computeStartRow()
    endRow = @computeEndRow()

    for cursor in @model.getCursors()
      if cursor.isVisible() and startRow <= cursor.getScreenRow() < endRow
        pixelRect = @pixelRectForScreenRange(cursor.getScreenRange())
        pixelRect.width = @getBaseCharacterWidth() if pixelRect.width is 0
        @state.content.cursors[cursor.id] = pixelRect

    @emitter.emit 'did-update-state'

  updateHighlightsState: ->
    return unless @hasRequiredMeasurements()

    startRow = @computeStartRow()
    endRow = @computeEndRow()
    visibleHighlights = {}

    for decoration in @model.getHighlightDecorations()
      continue unless decoration.getMarker().isValid()
      screenRange = decoration.getMarker().getScreenRange()
      if screenRange.intersectsRowRange(startRow, endRow - 1)
        if screenRange.start.row < startRow
          screenRange.start.row = startRow
          screenRange.start.column = 0
        if screenRange.end.row >= endRow
          screenRange.end.row = endRow
          screenRange.end.column = 0
        continue if screenRange.isEmpty()

        visibleHighlights[decoration.id] = true

        @state.content.highlights[decoration.id] ?= {
          flashCount: 0
          flashDuration: null
          flashClass: null
        }
        highlightState = @state.content.highlights[decoration.id]
        highlightState.class = decoration.getProperties().class
        highlightState.deprecatedRegionClass = decoration.getProperties().deprecatedRegionClass
        highlightState.regions = @buildHighlightRegions(screenRange)

    for id of @state.content.highlights
      unless visibleHighlights.hasOwnProperty(id)
        delete @state.content.highlights[id]

    @emitter.emit 'did-update-state'

  updateOverlaysState: ->
    return unless @hasRequiredMeasurements()

    visibleDecorationIds = {}

    for decoration in @model.getOverlayDecorations()
      continue unless decoration.getMarker().isValid()

      {item, position} = decoration.getProperties()
      if position is 'tail'
        screenPosition = decoration.getMarker().getTailScreenPosition()
      else
        screenPosition = decoration.getMarker().getHeadScreenPosition()

      @state.content.overlays[decoration.id] ?= {item}
      @state.content.overlays[decoration.id].pixelPosition = @pixelPositionForScreenPosition(screenPosition)
      visibleDecorationIds[decoration.id] = true

    for id of @state.content.overlays
      delete @state.content.overlays[id] unless visibleDecorationIds[id]

    @emitter.emit "did-update-state"

  updateGutterState: ->
    @state.gutter.maxLineNumberDigits = @model.getLineCount().toString().length
    @state.gutter.backgroundColor = if @getGutterBackgroundColor() isnt "rgba(0, 0, 0, 0)"
      @getGutterBackgroundColor()
    else
      @getBackgroundColor()
    @emitter.emit "did-update-state"

  updateLineNumbersState: ->
    startRow = @computeStartRow()
    endRow = @computeEndRow()
    lastBufferRow = null
    wrapCount = 0
    visibleLineNumberIds = {}

    for bufferRow, i in @model.bufferRowsForScreenRows(startRow, endRow - 1)
      screenRow = startRow + i
      top = screenRow * @getLineHeight()
      if bufferRow is lastBufferRow
        wrapCount++
        softWrapped = true
        id = bufferRow + '-' + wrapCount
      else
        wrapCount = 0
        softWrapped = false
        lastBufferRow = bufferRow
        id = bufferRow
      decorationClasses = @lineNumberDecorationClassesForRow(screenRow)
      foldable = @model.isFoldableAtScreenRow(screenRow)

      @state.gutter.lineNumbers[id] = {screenRow, bufferRow, softWrapped, top, decorationClasses, foldable}
      visibleLineNumberIds[id] = true

    if @getMouseWheelScreenRow()? and not startRow <= @getMouseWheelScreenRow() < endRow
      screenRow = @getMouseWheelScreenRow()
      top = screenRow * @getLineHeight()
      bufferRow = @model.bufferRowForScreenRow(screenRow)
      @state.gutter.lineNumbers[id] = {screenRow, bufferRow, top}
      visibleLineNumberIds[bufferRow] = true

    for id of @state.gutter.lineNumbers
      delete @state.gutter.lineNumbers[id] unless visibleLineNumberIds[id]

    @emitter.emit 'did-update-state'

  buildHighlightRegions: (screenRange) ->
    lineHeightInPixels = @getLineHeight()
    startPixelPosition = @pixelPositionForScreenPosition(screenRange.start, true)
    endPixelPosition = @pixelPositionForScreenPosition(screenRange.end, true)
    spannedRows = screenRange.end.row - screenRange.start.row + 1

    if spannedRows is 1
      [
        top: startPixelPosition.top
        height: lineHeightInPixels
        left: startPixelPosition.left
        width: endPixelPosition.left - startPixelPosition.left
      ]
    else
      regions = []

      # First row, extending from selection start to the right side of screen
      regions.push(
        top: startPixelPosition.top
        left: startPixelPosition.left
        height: lineHeightInPixels
        right: 0
      )

      # Middle rows, extending from left side to right side of screen
      if spannedRows > 2
        regions.push(
          top: startPixelPosition.top + lineHeightInPixels
          height: endPixelPosition.top - startPixelPosition.top - lineHeightInPixels
          left: 0
          right: 0
        )

      # Last row, extending from left side of screen to selection end
      if screenRange.end.column > 0
        regions.push(
          top: endPixelPosition.top
          height: lineHeightInPixels
          left: 0
          width: endPixelPosition.left
        )

      regions

  computeStartRow: ->
    startRow = Math.floor(@getScrollTop() / @getLineHeight()) - @lineOverdrawMargin
    Math.max(0, startRow)

  computeEndRow: ->
    startRow = Math.floor(@getScrollTop() / @getLineHeight())
    visibleLinesCount = Math.ceil(@getHeight() / @getLineHeight()) + 1
    endRow = startRow + visibleLinesCount + @lineOverdrawMargin
    Math.min(@model.getScreenLineCount(), endRow)

  computeScrollWidth: ->
    Math.max(@computeContentWidth(), @getContentFrameWidth())

  computeScrollHeight: ->
    Math.max(@computeContentHeight(), @getHeight())

  computeContentWidth: ->
    contentWidth = @pixelPositionForScreenPosition([@model.getLongestScreenRow(), Infinity]).left
    contentWidth += 1 unless @model.isSoftWrapped() # account for cursor width
    contentWidth

  computeContentHeight: ->
    @getLineHeight() * @model.getScreenLineCount()

  lineDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for markerId, decorations of @model.decorationsForScreenRowRange(row, row) when @model.getMarker(markerId).isValid()
      for decoration in decorations when decoration.isType('line')
        properties = decoration.getProperties()
        range = decoration.getMarker().getScreenRange()

        continue if properties.onlyHead and decoration.getMarker().getHeadScreenPosition().row isnt row
        continue unless range.intersectsRow(row)
        if range.isEmpty()
          continue if properties.onlyNonEmpty
        else
          continue if properties.onlyEmpty
          continue if row is range.end.row and range.end.column is 0

        decorationClasses ?= []
        decorationClasses.push(properties.class)

    decorationClasses

  lineNumberDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for markerId, decorations of @model.decorationsForScreenRowRange(row, row) when @model.getMarker(markerId).isValid()
      for decoration in decorations when decoration.isType('line-number')
        properties = decoration.getProperties()
        range = decoration.getMarker().getScreenRange()

        continue if properties.onlyHead and decoration.getMarker().getHeadScreenPosition().row isnt row
        continue unless range.intersectsRow(row)
        if range.isEmpty()
          continue if properties.onlyNonEmpty
        else
          continue if properties.onlyEmpty
          continue if row is range.end.row and range.end.column is 0

        decorationClasses ?= []
        decorationClasses.push(properties.class)

    decorationClasses

  getCursorBlinkPeriod: -> @cursorBlinkPeriod

  getCursorBlinkResumeDelay: -> @cursorBlinkResumeDelay

  hasRequiredMeasurements: ->
    @getLineHeight()? and @getBaseCharacterWidth()? and @getHeight()? and @getScrollTop()?

  setScrollTop: (@scrollTop) ->
    @didStartScrolling()
    @updateVerticalScrollState()
    @updateLinesState()
    @updateCursorsState()
    @updateHighlightsState()
    @updateLineNumbersState()

  didStartScrolling: ->
    if @stoppedScrollingTimeoutId?
      clearTimeout(@stoppedScrollingTimeoutId)
      @stoppedScrollingTimeoutId = null
    @stoppedScrollingTimeoutId = setTimeout(@didStopScrolling.bind(this), @stoppedScrollingDelay)
    @state.content.scrollingVertically = true
    @emitter.emit 'did-update-state'

  didStopScrolling: ->
    @state.content.scrollingVertically = false
    if @getMouseWheelScreenRow()?
      @mouseWheelScreenRow = null
      @updateLinesState()
      @updateLineNumbersState()
    else
      @emitter.emit 'did-update-state'

  getScrollTop: -> @scrollTop

  setScrollLeft: (@scrollLeft) ->
    @updateHorizontalScrollState()

  getScrollLeft: -> @scrollLeft

  setHorizontalScrollbarHeight: (@horizontalScrollbarHeight) ->
    @updateScrollbarsState()

  getHorizontalScrollbarHeight: -> @horizontalScrollbarHeight

  setVerticalScrollbarWidth: (@verticalScrollbarWidth) ->
    @updateScrollbarsState()

  getVerticalScrollbarWidth: -> @verticalScrollbarWidth

  setAutoHeight: (@autoHeight) ->
    @updateHeightState()

  hasAutoHeight: -> @autoHeight

  setHeight: (@height) ->
    @updateVerticalScrollState()
    @updateScrollbarsState()
    @updateLinesState()
    @updateCursorsState()
    @updateHighlightsState()
    @updateLineNumbersState()

  getHeight: ->
    @height ? @computeContentHeight()

  setContentFrameWidth: (@contentFrameWidth) ->
    @updateHorizontalScrollState()
    @updateScrollbarsState()
    @updateContentState()
    @updateLinesState()

  getContentFrameWidth: -> @contentFrameWidth

  setBackgroundColor: (backgroundColor) ->
    if backgroundColor isnt @backgroundColor
      @backgroundColor = backgroundColor
      @updateContentState()

  getBackgroundColor: -> @backgroundColor

  setGutterBackgroundColor: (gutterBackgroundColor) ->
    if gutterBackgroundColor isnt @gutterBackgroundColor
      @gutterBackgroundColor = gutterBackgroundColor
      @updateGutterState()

  getGutterBackgroundColor: -> @gutterBackgroundColor

  setLineHeight: (@lineHeight) ->
    @updateHeightState()
    @updateVerticalScrollState()
    @updateLinesState()
    @updateCursorsState()
    @updateHighlightsState()
    @updateLineNumbersState()
    @updateOverlaysState()

  getLineHeight: -> @lineHeight

  setMouseWheelScreenRow: (@mouseWheelScreenRow) ->
    @didStartScrolling()

  getMouseWheelScreenRow: -> @mouseWheelScreenRow

  setBaseCharacterWidth: (@baseCharacterWidth) ->
    @characterWidthsChanged()

  getBaseCharacterWidth: -> @baseCharacterWidth

  getScopedCharWidth: (scopeNames, char) ->
    @getScopedCharWidths(scopeNames)[char]

  getScopedCharWidths: (scopeNames) ->
    scope = @charWidthsByScope
    for scopeName in scopeNames
      scope[scopeName] ?= {}
      scope = scope[scopeName]
    scope.charWidths ?= {}
    scope.charWidths

  batchCharacterMeasurement: (fn) ->
    oldChangeCount = @scopedCharacterWidthsChangeCount
    @batchingCharacterMeasurement = true
    fn()
    @batchingCharacterMeasurement = false
    @characterWidthsChanged() if oldChangeCount isnt @scopedCharacterWidthsChangeCount

  setScopedCharWidth: (scopeNames, char, width) ->
    @getScopedCharWidths(scopeNames)[char] = width
    @scopedCharacterWidthsChangeCount++
    @characterWidthsChanged() unless @batchingCharacterMeasurement

  characterWidthsChanged: ->
    @updateHorizontalScrollState()
    @updateContentState()
    @updateLinesState()
    @updateCursorsState()
    @updateHighlightsState()
    @updateOverlaysState()

  clearScopedCharWidths: ->
    @charWidthsByScope = {}

  pixelPositionForScreenPosition: (screenPosition, clip=true) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = @model.clipScreenPosition(screenPosition) if clip

    targetRow = screenPosition.row
    targetColumn = screenPosition.column
    baseCharacterWidth = @getBaseCharacterWidth()

    top = targetRow * @getLineHeight()
    left = 0
    column = 0
    for token in @model.tokenizedLineForScreenRow(targetRow).tokens
      charWidths = @getScopedCharWidths(token.scopes)

      valueIndex = 0
      while valueIndex < token.value.length
        if token.hasPairedCharacter
          char = token.value.substr(valueIndex, 2)
          charLength = 2
          valueIndex += 2
        else
          char = token.value[valueIndex]
          charLength = 1
          valueIndex++

        return {top, left} if column is targetColumn

        left += charWidths[char] ? baseCharacterWidth unless char is '\0'
        column += charLength
    {top, left}

  pixelRectForScreenRange: (screenRange) ->
    if screenRange.end.row > screenRange.start.row
      top = @pixelPositionForScreenPosition(screenRange.start).top
      left = 0
      height = (screenRange.end.row - screenRange.start.row + 1) * @getLineHeight()
      width = @getScrollWidth()
    else
      {top, left} = @pixelPositionForScreenPosition(screenRange.start, false)
      height = @getLineHeight()
      width = @pixelPositionForScreenPosition(screenRange.end, false).left - left

    {top, left, width, height}

  observeLineDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@updateLinesState.bind(this))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      @updateLinesState()
    @disposables.add(decorationDisposables)

  observeLineNumberDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@updateLineNumbersState.bind(this))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      @updateLineNumbersState()
    @disposables.add(decorationDisposables)

  observeHighlightDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@updateHighlightsState.bind(this))
    decorationDisposables.add decoration.onDidChangeProperties(@updateHighlightsState.bind(this))
    decorationDisposables.add decoration.onDidFlash(@highlightDidFlash.bind(this, decoration))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      @updateHighlightsState()
    @disposables.add(decorationDisposables)

  highlightDidFlash: (decoration) ->
    flash = decoration.consumeNextFlash()
    if decorationState = @state.content.highlights[decoration.id]
      decorationState.flashCount++
      decorationState.flashClass = flash.class
      decorationState.flashDuration = flash.duration
      @emitter.emit "did-update-state"

  observeOverlayDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@updateOverlaysState.bind(this))
    decorationDisposables.add decoration.onDidChangeProperties(@updateOverlaysState.bind(this))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      @updateOverlaysState()
    @disposables.add(decorationDisposables)

  didAddDecoration: (decoration) ->
    if decoration.isType('line')
      @observeLineDecoration(decoration)
      @updateLinesState()
    if decoration.isType('line-number')
      @observeLineNumberDecoration(decoration)
      @updateLineNumbersState()
    else if decoration.isType('highlight')
      @observeHighlightDecoration(decoration)
      @updateHighlightsState()
    else if decoration.isType('overlay')
      @observeOverlayDecoration(decoration)
      @updateOverlaysState()

  observeCursor: (cursor) ->
    didChangePositionDisposable = cursor.onDidChangePosition =>
      @pauseCursorBlinking()
      @updateCursorsState()

    didChangeVisibilityDisposable = cursor.onDidChangeVisibility(@updateCursorsState.bind(this))

    didDestroyDisposable = cursor.onDidDestroy =>
      @disposables.remove(didChangePositionDisposable)
      @disposables.remove(didChangeVisibilityDisposable)
      @disposables.remove(didDestroyDisposable)
      @updateCursorsState()

    @disposables.add(didChangePositionDisposable)
    @disposables.add(didChangeVisibilityDisposable)
    @disposables.add(didDestroyDisposable)

  didAddCursor: (cursor) ->
    @observeCursor(cursor)
    @pauseCursorBlinking()
    @updateCursorsState()

  startBlinkingCursors: ->
    @toggleCursorBlinkHandle = setInterval(@toggleCursorBlink.bind(this), @getCursorBlinkPeriod() / 2)

  stopBlinkingCursors: ->
    clearInterval(@toggleCursorBlinkHandle)

  toggleCursorBlink: ->
    @state.content.blinkCursorsOff = not @state.content.blinkCursorsOff
    @emitter.emit 'did-update-state'

  pauseCursorBlinking: ->
    @state.content.blinkCursorsOff = false
    @stopBlinkingCursors()
    @startBlinkingCursorsAfterDelay ?= _.debounce(@startBlinkingCursors, @getCursorBlinkResumeDelay())
    @startBlinkingCursorsAfterDelay()
    @emitter.emit 'did-update-state'
