import gleam/list

pub opaque type NonEmpty(a) {
  NonEmpty(head: a, tail: List(a))
}

pub fn one(value: a) -> NonEmpty(a) {
  NonEmpty(value, [])
}

pub fn from_parts(head: a, tail: List(a)) -> NonEmpty(a) {
  NonEmpty(head, tail)
}

pub fn from_list(values: List(a)) -> Result(NonEmpty(a), Nil) {
  case values {
    [] -> Error(Nil)
    [head, ..tail] -> Ok(NonEmpty(head, tail))
  }
}

pub fn to_list(values: NonEmpty(a)) -> List(a) {
  [values.head, ..values.tail]
}

pub fn map(values: NonEmpty(a), fun: fn(a) -> b) -> NonEmpty(b) {
  NonEmpty(fun(values.head), list.map(values.tail, fun))
}

pub fn fold(values: NonEmpty(a), initial: b, fun: fn(b, a) -> b) -> b {
  list.fold(to_list(values), initial, fun)
}

pub fn length(values: NonEmpty(a)) -> Int {
  1 + list.length(values.tail)
}

pub fn append(values: NonEmpty(a), value: a) -> NonEmpty(a) {
  NonEmpty(values.head, list.append(values.tail, [value]))
}

pub fn contains(values: NonEmpty(a), value: a) -> Bool {
  list.contains(to_list(values), value)
}
