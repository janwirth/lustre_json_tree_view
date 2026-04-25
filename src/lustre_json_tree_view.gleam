//// Interactive expandable JSON tree view for Lustre.
////
//// A Gleam port of [klazuka/elm-json-tree-view](https://github.com/klazuka/elm-json-tree-view).
////
//// Two layers of API are exposed:
////
//// - **Stateless layer** — mirrors the original Elm package. Use
////   [`parse_string`](#parse_string) / [`parse_value`](#parse_value) to turn
////   JSON into a [`Node`](#Node), and [`view`](#view) to render that node
////   given a [`Config`](#Config) and [`State`](#State). The parent owns the
////   state and the message type.
//// - **MVU layer** — convenience [`Model`](#Model), [`Msg`](#Msg),
////   [`init`](#init), [`update`](#update), and [`component_view`](#component_view)
////   for embedding the tree as a sub-component without writing the wiring
////   yourself.
////
//// The package itself is also a runnable Lustre application:
////
//// ```sh
//// gleam run -m lustre_json_tree_view
//// ```
////
//// will mount a small demo on `#app` (see `index.html`).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// --------------------------------------------------------------------------
// TYPES
// --------------------------------------------------------------------------

/// A node in the tree.
pub type Node {
  Node(value: TaggedValue, key_path: KeyPath)
}

/// A tagged JSON value.
///
/// Note: unlike the Elm original (which only had `TFloat`), Gleam distinguishes
/// integers from floats. JSON numbers without a decimal point decode to
/// `TInt`; numbers with one decode to `TFloat`.
pub type TaggedValue {
  TString(String)
  TInt(Int)
  TFloat(Float)
  TBool(Bool)
  TList(List(Node))
  TDict(List(#(String, Node)))
  TNull
}

/// The path to a piece of data in the tree, e.g. `".users[0].name"`.
pub type KeyPath =
  String

/// CSS colours used by the tree view. All strings must be valid CSS colours
/// (e.g. `"red"`, `"#ff0000"`).
pub type Colors {
  Colors(
    string: String,
    number: String,
    bool: String,
    null: String,
    selectable: String,
  )
}

/// The default colours, suitable for a light background.
pub fn default_colors() -> Colors {
  Colors(
    string: "green",
    number: "blue",
    bool: "firebrick",
    null: "gray",
    selectable: "#fafad2",
  )
}

/// Configuration of the JSON tree view. Describes how events in the tree map
/// onto messages in the parent application.
///
/// Because `Config` contains functions, it should never be held in your
/// model — build it inside `view`.
///
/// - `colors` — pass [`default_colors`](#default_colors) or a custom set.
/// - `on_select` — set to `None` for read-only display. To make scalar leaves
///   selectable, pass `Some(handler)` where `handler` receives the selected
///   `KeyPath`.
/// - `to_msg` — receives an updated [`State`](#State); store it in your model.
pub type Config(msg) {
  Config(
    colors: Colors,
    on_select: Option(fn(KeyPath) -> msg),
    to_msg: fn(State) -> msg,
  )
}

/// The runtime state of the tree view (which nodes are collapsed). This is
/// **not** the tree data itself — keep it in your model alongside the tree.
pub opaque type State {
  State(hidden: Set(KeyPath))
}

/// Initial state — the entire tree is fully expanded.
pub fn default_state() -> State {
  state_fully_expanded()
}

fn state_fully_expanded() -> State {
  State(hidden: set.new())
}

/// Expand every node.
pub fn expand_all(_state: State) -> State {
  state_fully_expanded()
}

/// Collapse any nodes deeper than `max_depth`.
pub fn collapse_to_depth(
  max_depth max_depth: Int,
  tree tree: Node,
  state _state: State,
) -> State {
  collapse_to_depth_help(max_depth, 0, tree, state_fully_expanded())
}

fn collapse_to_depth_help(
  max_depth: Int,
  current_depth: Int,
  node: Node,
  state: State,
) -> State {
  let descend = fn(children: List(Node)) -> State {
    let seed = case current_depth >= max_depth {
      True -> collapse(node.key_path, state)
      False -> state
    }
    list.fold(children, seed, fn(acc, child) {
      collapse_to_depth_help(max_depth, current_depth + 1, child, acc)
    })
  }

  case node.value {
    TString(_) -> state
    TInt(_) -> state
    TFloat(_) -> state
    TBool(_) -> state
    TNull -> state
    TList(nodes) -> descend(nodes)
    TDict(pairs) -> descend(list.map(pairs, fn(p) { p.1 }))
  }
}

fn expand(key_path: KeyPath, state: State) -> State {
  let State(hidden) = state
  State(hidden: set.delete(hidden, key_path))
}

fn collapse(key_path: KeyPath, state: State) -> State {
  let State(hidden) = state
  State(hidden: set.insert(hidden, key_path))
}

fn is_collapsed(key_path: KeyPath, state: State) -> Bool {
  let State(hidden) = state
  set.contains(hidden, key_path)
}

/// Encode the runtime state as JSON. Use this if you want to persist
/// expanded/collapsed state across sessions.
pub fn state_to_json(state: State) -> json.Json {
  let State(hidden) = state
  json.array(set.to_list(hidden), of: json.string)
}

/// Decoder for state previously serialised with [`state_to_json`](#state_to_json).
pub fn state_decoder() -> Decoder(State) {
  decode.list(decode.string)
  |> decode.map(fn(paths) { State(hidden: set.from_list(paths)) })
}

// --------------------------------------------------------------------------
// PARSING
// --------------------------------------------------------------------------

/// Parse a JSON string into a [`Node`](#Node) tree. Key paths are computed
/// during parsing.
pub fn parse_string(input: String) -> Result(Node, json.DecodeError) {
  json.parse(from: input, using: core_decoder())
  |> result.map(annotate(_, ""))
}

/// Parse an already-decoded `Dynamic` JSON value into a [`Node`](#Node) tree.
/// Use this when JSON arrives via FFI rather than as a string.
pub fn parse_value(input: Dynamic) -> Result(Node, List(decode.DecodeError)) {
  decode.run(input, core_decoder())
  |> result.map(annotate(_, ""))
}

fn core_decoder() -> Decoder(Node) {
  decode.recursive(fn() {
    let make = fn(v) { Node(value: v, key_path: "") }
    decode.one_of(decode.string |> decode.map(fn(s) { make(TString(s)) }), [
      decode.bool |> decode.map(fn(b) { make(TBool(b)) }),
      decode.int |> decode.map(fn(i) { make(TInt(i)) }),
      decode.float |> decode.map(fn(f) { make(TFloat(f)) }),
      decode.list(core_decoder()) |> decode.map(fn(xs) { make(TList(xs)) }),
      decode.dict(decode.string, core_decoder())
        |> decode.map(fn(d) { make(TDict(dict_to_sorted_list(d))) }),
      // Anything that fails every decoder above (in practice: `null`) maps
      // to `TNull`. JSON has no other value types so this fallback is safe.
      decode.success(make(TNull)),
    ])
  })
}

fn dict_to_sorted_list(d: Dict(String, Node)) -> List(#(String, Node)) {
  d
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn annotate(node: Node, path_so_far: KeyPath) -> Node {
  case node.value {
    TString(_) | TInt(_) | TFloat(_) | TBool(_) | TNull ->
      Node(..node, key_path: path_so_far)

    TList(children) ->
      Node(
        key_path: path_so_far,
        value: TList(
          list.index_map(children, fn(child, index) {
            annotate(child, path_so_far <> "[" <> int.to_string(index) <> "]")
          }),
        ),
      )

    TDict(pairs) ->
      Node(
        key_path: path_so_far,
        value: TDict(
          list.map(pairs, fn(pair) {
            let #(field_name, child) = pair
            #(field_name, annotate(child, path_so_far <> "." <> field_name))
          }),
        ),
      )
  }
}

// --------------------------------------------------------------------------
// VIEW (stateless, mirrors the Elm API)
// --------------------------------------------------------------------------

/// Render a JSON tree.
///
/// This is the stateless renderer that matches the Elm API: the parent owns
/// the [`State`](#State) and the message type, and is responsible for
/// updating state in response to `to_msg`.
pub fn view(
  tree tree: Node,
  config config: Config(msg),
  state state: State,
) -> Element(msg) {
  html.div(style_list(css_root()), [
    hover_styles(config),
    ..view_node_internal(0, config, tree, state)
  ])
}

fn view_node_internal(
  depth: Int,
  config: Config(msg),
  node: Node,
  state: State,
) -> List(Element(msg)) {
  let colors = config.colors
  case node.value {
    TString(s) ->
      view_scalar(css_string(colors), "\"" <> s <> "\"", node, config)
    TInt(i) -> view_scalar(css_number(colors), int.to_string(i), node, config)
    TFloat(f) ->
      view_scalar(css_number(colors), float.to_string(f), node, config)
    TBool(True) -> view_scalar(css_bool(colors), "true", node, config)
    TBool(False) -> view_scalar(css_bool(colors), "false", node, config)
    TNull -> view_scalar(css_null(colors), "null", node, config)
    TList(nodes) -> view_array(depth, nodes, node.key_path, config, state)
    TDict(pairs) -> view_dict(depth, pairs, node.key_path, config, state)
  }
}

fn view_scalar(
  some_css: List(#(String, String)),
  str: String,
  node: Node,
  config: Config(msg),
) -> List(Element(msg)) {
  let base_attrs = [attribute.id(node.key_path), ..style_list(some_css)]
  let attrs = case config.on_select {
    Some(on_select) -> [
      event.on_click(on_select(node.key_path)),
      attribute.class(selectable_node_class),
      ..base_attrs
    ]
    None -> base_attrs
  }
  [html.span(attrs, [element.text(str)])]
}

fn view_collapser(
  depth: Int,
  config: Config(msg),
  new_state: State,
  display_text: String,
) -> Element(msg) {
  case depth {
    0 -> element.text("")
    _ ->
      html.span(
        [
          event.on_click(config.to_msg(new_state)),
          ..style_list(css_collapser())
        ],
        [element.text(display_text)],
      )
  }
}

fn view_expand_button(
  depth: Int,
  key_path: KeyPath,
  config: Config(msg),
  state: State,
) -> Element(msg) {
  view_collapser(depth, config, expand(key_path, state), "+")
}

fn view_collapse_button(
  depth: Int,
  key_path: KeyPath,
  config: Config(msg),
  state: State,
) -> Element(msg) {
  view_collapser(depth, config, collapse(key_path, state), "-")
}

fn view_array(
  depth: Int,
  nodes: List(Node),
  key_path: KeyPath,
  config: Config(msg),
  state: State,
) -> List(Element(msg)) {
  let inner = case nodes {
    [] -> []
    _ ->
      case is_collapsed(key_path, state) {
        True -> [
          view_expand_button(depth, key_path, config, state),
          element.text("…"),
        ]
        False -> [
          view_collapse_button(depth, key_path, config, state),
          html.ul(
            style_list(css_ul()),
            list.map(nodes, fn(child) {
              html.li(
                style_list(css_li()),
                list.append(
                  view_node_internal(depth + 1, config, child, state),
                  [
                    element.text(","),
                  ],
                ),
              )
            }),
          ),
        ]
      }
  }
  list.flatten([[element.text("[")], inner, [element.text("]")]])
}

fn view_dict(
  depth: Int,
  pairs: List(#(String, Node)),
  key_path: KeyPath,
  config: Config(msg),
  state: State,
) -> List(Element(msg)) {
  let inner = case pairs {
    [] -> []
    _ ->
      case is_collapsed(key_path, state) {
        True -> [
          view_expand_button(depth, key_path, config, state),
          element.text("…"),
        ]
        False -> [
          view_collapse_button(depth, key_path, config, state),
          html.ul(
            style_list(css_ul()),
            list.map(pairs, fn(pair) {
              let #(field_name, child) = pair
              html.li(
                style_list(css_li()),
                list.flatten([
                  [
                    html.span(style_list(css_field_name()), [
                      element.text(field_name),
                    ]),
                    element.text(": "),
                  ],
                  view_node_internal(depth + 1, config, child, state),
                  [element.text(",")],
                ]),
              )
            }),
          ),
        ]
      }
  }
  list.flatten([[element.text("{")], inner, [element.text("}")]])
}

// --------------------------------------------------------------------------
// STYLES
// --------------------------------------------------------------------------

fn css_root() -> List(#(String, String)) {
  [#("font-family", "monospace"), #("white-space", "pre")]
}

fn css_ul() -> List(#(String, String)) {
  [
    #("list-style-type", "none"),
    #("margin-left", "26px"),
    #("padding-left", "0px"),
  ]
}

fn css_li() -> List(#(String, String)) {
  [#("position", "relative")]
}

fn css_collapser() -> List(#(String, String)) {
  [
    #("position", "absolute"),
    #("cursor", "pointer"),
    #("top", "1px"),
    #("left", "-15px"),
  ]
}

fn css_field_name() -> List(#(String, String)) {
  [#("font-weight", "bold")]
}

fn css_string(c: Colors) -> List(#(String, String)) {
  [#("color", c.string)]
}

fn css_number(c: Colors) -> List(#(String, String)) {
  [#("color", c.number)]
}

fn css_bool(c: Colors) -> List(#(String, String)) {
  [#("color", c.bool)]
}

fn css_null(c: Colors) -> List(#(String, String)) {
  [#("color", c.null)]
}

fn css_selectable(c: Colors) -> List(#(String, String)) {
  [#("background-color", c.selectable), #("cursor", "pointer")]
}

fn style_list(styles: List(#(String, String))) -> List(attribute.Attribute(msg)) {
  [attribute.styles(styles)]
}

const selectable_node_class: String = "selectableJsonTreeNode"

/// Inserts a `<style>` element into the DOM in order to style CSS
/// pseudo-elements such as `:hover`. Mirrors the technique used by elm-css.
fn hover_styles(config: Config(msg)) -> Element(msg) {
  let body =
    list.fold(css_selectable(config.colors), "", fn(acc, pair) {
      let #(name, value) = pair
      acc <> name <> ": " <> value <> ";\n"
    })
  let css_text = "." <> selectable_node_class <> ":hover {\n" <> body <> "}\n"
  html.style([], css_text)
}

// --------------------------------------------------------------------------
// MVU LAYER (init / update / view) for easy embedding
// --------------------------------------------------------------------------

/// Bundled model for the MVU helpers. Stores the parsed tree (or a parse
/// error) and the runtime state.
pub type Model {
  Model(
    tree: Result(Node, String),
    state: State,
    raw: String,
    selected: Option(KeyPath),
  )
}

/// Messages emitted by the MVU view. Map these into your parent message
/// type with `element.map` if you embed the component.
pub type Msg {
  StateChanged(State)
  Selected(KeyPath)
  InputChanged(String)
}

/// Build an initial [`Model`](#Model) from a JSON string. If the string
/// fails to parse, `tree` will be `Error(reason)` and the rendered view
/// will show the reason — `raw` and `state` are still populated so the
/// user can edit and retry.
pub fn init(json_input: String) -> Model {
  Model(
    tree: parse_string(json_input)
      |> result.map_error(decode_error_to_string),
    state: default_state(),
    raw: json_input,
    selected: None,
  )
}

/// Update the [`Model`](#Model) in response to a [`Msg`](#Msg).
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    StateChanged(new_state) -> Model(..model, state: new_state)
    Selected(path) -> Model(..model, selected: Some(path))
    InputChanged(raw) ->
      Model(
        ..model,
        raw: raw,
        tree: parse_string(raw) |> result.map_error(decode_error_to_string),
      )
  }
}

/// Render the [`Model`](#Model) as the bundled MVU view.
///
/// This builds a default [`Config`](#Config) (default colours, scalars are
/// selectable) under the hood. If you need a custom config, drop down to the
/// stateless [`view`](#view) and own the `State` yourself.
pub fn component_view(model: Model) -> Element(Msg) {
  let config =
    Config(
      colors: default_colors(),
      on_select: Some(Selected),
      to_msg: StateChanged,
    )
  case model.tree {
    Ok(tree) -> view(tree: tree, config: config, state: model.state)
    Error(reason) ->
      html.div(
        style_list([#("color", "firebrick"), #("font-family", "monospace")]),
        [
          element.text("Could not parse JSON: " <> reason),
        ],
      )
  }
}

fn decode_error_to_string(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(b) -> "unexpected byte: " <> b
    json.UnexpectedSequence(s) -> "unexpected sequence: " <> s
    json.UnableToDecode(_) -> "value did not match expected JSON shape"
  }
}

// --------------------------------------------------------------------------
// STANDALONE LUSTRE APPLICATION
// --------------------------------------------------------------------------

/// Bundled standalone Lustre application. Useful as a quick demo or for
/// dropping the tree view into a page that has nothing else going on.
///
/// The app exposes a textarea for editing the source JSON and renders the
/// tree below it. Mount it onto any element with [`lustre.start`](https://hexdocs.pm/lustre/lustre.html#start):
///
/// ```gleam
/// import lustre
/// import lustre_json_tree_view
///
/// pub fn main() -> Nil {
///   let app = lustre_json_tree_view.app()
///   let assert Ok(_) = lustre.start(app, "#app", Nil)
///   Nil
/// }
/// ```
pub fn app() -> lustre.App(Nil, Model, Msg) {
  lustre.simple(init: app_init, update: update, view: app_view)
}

fn app_init(_flags: Nil) -> Model {
  init(default_demo_json)
}

fn app_view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui, sans-serif"),
        #("max-width", "960px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [element.text("lustre_json_tree_view")]),
      html.p([], [
        element.text(
          "Edit the JSON below — the tree view re-parses on every keystroke.",
        ),
      ]),
      html.textarea(
        [
          attribute.styles([
            #("width", "100%"),
            #("min-height", "10rem"),
            #("font-family", "monospace"),
            #("padding", "0.5rem"),
          ]),
          event.on_input(InputChanged),
        ],
        model.raw,
      ),
      case model.selected {
        Some(path) ->
          html.p(
            [
              attribute.styles([
                #("color", "#555"),
                #("font-family", "monospace"),
              ]),
            ],
            [element.text("selected: " <> path)],
          )
        None -> element.none()
      },
      html.hr([]),
      component_view(model),
    ],
  )
}

const default_demo_json: String = "{
  \"name\": \"lustre_json_tree_view\",
  \"description\": \"Interactive JSON tree view for Lustre.\",
  \"counts\": {\"stars\": 0, \"forks\": 0, \"issues\": 0},
  \"tags\": [\"gleam\", \"lustre\", \"json\"],
  \"published\": false,
  \"latest\": null
}"

/// Convenience entry point: starts the bundled [`app`](#app) on `#app`.
pub fn main() -> Nil {
  let assert Ok(_) = lustre.start(app(), "#app", Nil)
  Nil
}
