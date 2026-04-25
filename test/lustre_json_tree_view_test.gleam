import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

import lustre_json_tree_view.{
  Node, TBool, TDict, TFloat, TInt, TList, TNull, TString,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// parse_string
// ---------------------------------------------------------------------------

pub fn parse_string_scalars_test() {
  let assert Ok(node) = lustre_json_tree_view.parse_string("\"hello\"")
  node |> should.equal(Node(value: TString("hello"), key_path: ""))

  let assert Ok(node) = lustre_json_tree_view.parse_string("42")
  node |> should.equal(Node(value: TInt(42), key_path: ""))

  let assert Ok(node) = lustre_json_tree_view.parse_string("3.14")
  node |> should.equal(Node(value: TFloat(3.14), key_path: ""))

  let assert Ok(node) = lustre_json_tree_view.parse_string("true")
  node |> should.equal(Node(value: TBool(True), key_path: ""))

  let assert Ok(node) = lustre_json_tree_view.parse_string("null")
  node |> should.equal(Node(value: TNull, key_path: ""))
}

pub fn parse_string_array_indexes_keypaths_test() {
  let assert Ok(node) = lustre_json_tree_view.parse_string("[1, 2, 3]")
  node.key_path |> should.equal("")
  case node.value {
    TList([a, b, c]) -> {
      a.key_path |> should.equal("[0]")
      b.key_path |> should.equal("[1]")
      c.key_path |> should.equal("[2]")
      a.value |> should.equal(TInt(1))
      b.value |> should.equal(TInt(2))
      c.value |> should.equal(TInt(3))
    }
    _ -> panic as "expected a 3-element list"
  }
}

pub fn parse_string_dict_keypaths_test() {
  let assert Ok(node) =
    lustre_json_tree_view.parse_string("{\"a\": 1, \"b\": [true, null]}")

  case node.value {
    TDict([#("a", a_node), #("b", b_node)]) -> {
      a_node.key_path |> should.equal(".a")
      a_node.value |> should.equal(TInt(1))
      b_node.key_path |> should.equal(".b")
      case b_node.value {
        TList([first, second]) -> {
          first.key_path |> should.equal(".b[0]")
          first.value |> should.equal(TBool(True))
          second.key_path |> should.equal(".b[1]")
          second.value |> should.equal(TNull)
        }
        _ -> panic as "expected nested list"
      }
    }
    _ -> panic as "expected dict with keys a and b in alphabetical order"
  }
}

pub fn parse_string_invalid_test() {
  lustre_json_tree_view.parse_string("not json")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

pub fn collapse_to_depth_round_trip_test() {
  // Simply ensure the function returns a State for any depth without
  // crashing — the internal Set is opaque.
  let assert Ok(tree) =
    lustre_json_tree_view.parse_string("{\"a\":{\"b\":{\"c\":1}}}")
  let _ =
    lustre_json_tree_view.collapse_to_depth(
      max_depth: 1,
      tree: tree,
      state: lustre_json_tree_view.default_state(),
    )
  Nil
}

// ---------------------------------------------------------------------------
// MVU layer
// ---------------------------------------------------------------------------

pub fn init_with_valid_json_test() {
  let model = lustre_json_tree_view.init("{\"x\": 1}")
  model.raw |> should.equal("{\"x\": 1}")
  model.tree |> should.be_ok
  model.selected |> should.equal(None)
}

pub fn init_with_invalid_json_test() {
  let model = lustre_json_tree_view.init("nope")
  model.tree |> should.be_error
}

pub fn update_input_changed_reparses_test() {
  let model = lustre_json_tree_view.init("nope")
  let updated =
    lustre_json_tree_view.update(
      model,
      lustre_json_tree_view.InputChanged("[1]"),
    )
  updated.tree |> should.be_ok
  updated.raw |> should.equal("[1]")
}

pub fn update_selected_records_path_test() {
  let model = lustre_json_tree_view.init("{\"a\": 1}")
  let updated =
    lustre_json_tree_view.update(model, lustre_json_tree_view.Selected(".a"))
  updated.selected |> should.equal(Some(".a"))
}
