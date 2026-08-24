import gleam/string

pub opaque type GenerationId {
  GenerationId(String)
}

pub opaque type GenerationItemId {
  GenerationItemId(String)
}


pub opaque type ModelId {
  ModelId(String)
}

pub opaque type AssetId {
  AssetId(String)
}

pub opaque type LoraId {
  LoraId(String)
}

pub opaque type Prompt {
  Prompt(String)
}

pub opaque type Seed {
  Seed(Int)
}

pub opaque type Instant {
  Instant(Int)
}

pub opaque type Duration {
  Duration(Int)
}

pub opaque type PositiveInt {
  PositiveInt(Int)
}

pub opaque type Progress {
  Progress(Float)
}

pub opaque type LoraWeight {
  LoraWeight(Float)
}

pub type ValueError {
  EmptyValue
  PromptTooLong(actual: Int)
  NotPositive
  OutOfRange
}

pub fn generation_id(raw: String) -> Result(GenerationId, ValueError) {
  case string.trim(raw) {
    "" -> Error(EmptyValue)
    value -> Ok(GenerationId(value))
  }
}

pub fn generation_item_id(raw: String) -> Result(GenerationItemId, ValueError) {
  case string.trim(raw) {
    "" -> Error(EmptyValue)
    value -> Ok(GenerationItemId(value))
  }
}


pub fn model_id(raw: String) -> Result(ModelId, ValueError) {
  case string.trim(raw) {
    "" -> Error(EmptyValue)
    value -> Ok(ModelId(value))
  }
}

pub fn asset_id(raw: String) -> Result(AssetId, ValueError) {
  case string.trim(raw) {
    "" -> Error(EmptyValue)
    value -> Ok(AssetId(value))
  }
}

pub fn lora_id(raw: String) -> Result(LoraId, ValueError) {
  case string.trim(raw) {
    "" -> Error(EmptyValue)
    value -> Ok(LoraId(value))
  }
}

pub fn prompt(raw: String) -> Result(Prompt, ValueError) {
  let clean = string.trim(raw)
  let length = string.length(clean)
  case clean {
    "" -> Error(EmptyValue)
    _ if length > 2000 -> Error(PromptTooLong(length))
    _ -> Ok(Prompt(clean))
  }
}

pub fn prompt_value(value: Prompt) -> String {
  let Prompt(raw) = value
  raw
}

pub fn seed(value: Int) -> Seed {
  Seed(value)
}

pub fn seed_value(value: Seed) -> Int {
  let Seed(raw) = value
  raw
}

pub fn instant(milliseconds: Int) -> Instant {
  Instant(milliseconds)
}

pub fn instant_value(value: Instant) -> Int {
  let Instant(raw) = value
  raw
}

pub fn add_duration(at: Instant, duration: Duration) -> Instant {
  let Instant(at_value) = at
  let Duration(duration_value) = duration
  Instant(at_value + duration_value)
}

pub fn duration(milliseconds: Int) -> Result(Duration, ValueError) {
  case milliseconds > 0 {
    True -> Ok(Duration(milliseconds))
    False -> Error(NotPositive)
  }
}

pub fn positive_int(value: Int) -> Result(PositiveInt, ValueError) {
  case value > 0 {
    True -> Ok(PositiveInt(value))
    False -> Error(NotPositive)
  }
}

pub fn positive_int_value(value: PositiveInt) -> Int {
  let PositiveInt(raw) = value
  raw
}

pub fn progress(value: Float) -> Result(Progress, ValueError) {
  case value >=. 0.0 && value <=. 1.0 {
    True -> Ok(Progress(value))
    False -> Error(OutOfRange)
  }
}

pub fn progress_value(value: Progress) -> Float {
  let Progress(raw) = value
  raw
}

pub fn lora_weight(value: Float) -> Result(LoraWeight, ValueError) {
  case value >=. -2.0 && value <=. 2.0 {
    True -> Ok(LoraWeight(value))
    False -> Error(OutOfRange)
  }
}

pub fn lora_weight_value(value: LoraWeight) -> Float {
  let LoraWeight(raw) = value
  raw
}
