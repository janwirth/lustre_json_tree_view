# lustre_json_tree_view

[![Package Version](https://img.shields.io/hexpm/v/lustre_json_tree_view)](https://hex.pm/packages/lustre_json_tree_view)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lustre_json_tree_view/)

Interactive expandable JSON tree view for [Lustre](https://lustre.build).
A Gleam port of [klazuka/elm-json-tree-view](https://github.com/klazuka/elm-json-tree-view).

Features:

- Show JSON as a tree of HTML
- Expand / collapse individual nodes
- Expand / collapse the entire tree
- Make scalar leaves selectable

Two layers of API are exposed:

- A **stateless** layer that mirrors the original Elm package — the parent
  owns the tree, the runtime state, and the message type.
- An **MVU** layer (`init` / `update` / `component_view` + `Model` + `Msg`)
  for embedding the tree as a sub-component without writing the wiring
  yourself.

The package is also a runnable Lustre application with a small built-in
demo (textarea + live tree).

## Install

Not yet published to Hex — install from the GitHub repo. Add to your `gleam.toml`:

```toml
[dependencies]
lustre_json_tree_view = { git = "https://github.com/janwirth/lustre_json_tree_view", ref = "main" }
```

Then run `gleam deps download`. Bump the `ref` to pin to a newer commit when one ships.

## Quick start (stateless)

```gleam
import gleam/option.{None}
import lustre_json_tree_view as tree

pub type Msg {
  TreeStateChanged(tree.State)
}

pub type Model {
  Model(tree: tree.Node, state: tree.State)
}

pub fn init() -> Model {
  let assert Ok(node) =
    tree.parse_string("{\"name\": \"Lustre\", \"stars\": 9001}")
  Model(tree: node, state: tree.default_state())
}

pub fn view(model: Model) {
  let config =
    tree.Config(
      colors: tree.default_colors(),
      on_select: None,
      to_msg: TreeStateChanged,
    )
  tree.view(tree: model.tree, config: config, state: model.state)
}
```

In your `update`, store the new state when you receive `TreeStateChanged`:

```gleam
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    TreeStateChanged(new_state) -> Model(..model, state: new_state)
  }
}
```

## Quick start (MVU layer — drop-in sub-component)

If you don't need a custom config and just want a working tree view in
your app, use the bundled `init` / `update` / `component_view`:

```gleam
import lustre/element
import lustre_json_tree_view as tree

pub type Msg {
  TreeMsg(tree.Msg)
  // …other parent messages…
}

pub fn init() {
  Model(tree: tree.init("{\"hello\": \"world\"}"))
}

pub fn update(model, msg) {
  case msg {
    TreeMsg(t) -> Model(..model, tree: tree.update(model.tree, t))
  }
}

pub fn view(model) {
  element.map(tree.component_view(model.tree), TreeMsg)
}
```

`tree.Msg` covers `StateChanged`, `Selected`, and `InputChanged`. `tree.Model`
holds the parsed tree, the runtime state, the raw input, and the most recently
selected key path.

## Quick start (standalone app)

```gleam
import lustre_json_tree_view

pub fn main() -> Nil {
  lustre_json_tree_view.main()
}
```

That mounts the bundled demo (textarea + tree view) onto `#app`.

## Types in brief

| Symbol | What it is |
|---|---|
| `Node` | Recursive value: a `TaggedValue` plus its `KeyPath`. |
| `TaggedValue` | `TString` / `TInt` / `TFloat` / `TBool` / `TList` / `TDict` / `TNull`. |
| `KeyPath` | Path string like `".users[0].name"`. |
| `Config(msg)` | `colors`, `on_select`, `to_msg`. Build inside `view`, never store. |
| `State` | Opaque set of collapsed paths. Keep this in your model. |
| `Colors` | Per-type CSS colour overrides. |

`parse_string : String -> Result(Node, json.DecodeError)` and
`parse_value : Dynamic -> Result(Node, …)` build a `Node`. State helpers:
`default_state`, `expand_all`, `collapse_to_depth`. Persistence helpers:
`state_to_json`, `state_decoder`.

## Note on integer vs float

Unlike the Elm original (which only had `TFloat`), Gleam distinguishes ints
from floats. JSON numbers without a decimal point decode to `TInt`; numbers
with one decode to `TFloat`. Both are rendered with the `colors.number`
colour.

## Development

```sh
gleam test                              # run the test suite
gleam format src test                   # format Gleam source
gleam run -m lustre/dev build           # build the demo bundle to dist/
gleam run -m lustre/dev start           # run the demo dev server
```

## Credit

Original Elm implementation © Microsoft Corporation, MIT licensed,
by [klazuka](https://github.com/klazuka).
