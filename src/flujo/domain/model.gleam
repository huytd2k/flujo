import flujo/domain/value.{type LoraId, type ModelId, type PositiveInt}

pub type ModelKind {
  Flux
  QwenImage
}

pub type ModelRef {
  ModelRef(id: ModelId, revision: String)
}

pub type InputPolicy {
  TextOnly
  TextAndImages(max_images: PositiveInt)
}

pub type SizePolicy {
  SizePolicy(min_side: Int, max_side: Int, multiple_of: Int, max_area: Int)
}

pub type BatchPolicy {
  BatchPolicy(max_count: PositiveInt)
}

pub type WeightRange {
  WeightRange(min: Float, max: Float)
}

pub type LoraPolicy {
  LoraUnsupported
  LoraSupported(max_count: PositiveInt, weight_range: WeightRange)
}

pub type ModelProfile {
  ModelProfile(
    ref: ModelRef,
    name: String,
    kind: ModelKind,
    input_policy: InputPolicy,
    size_policy: SizePolicy,
    batch_policy: BatchPolicy,
    lora_policy: LoraPolicy,
  )
}

pub type LoraProfile {
  LoraProfile(id: LoraId, compatible_models: List(ModelId))
}

pub type FluxParameters {
  FluxParameters(steps: PositiveInt, guidance: Float)
}

pub type QwenParameters {
  QwenParameters(steps: PositiveInt, guidance: Float)
}

pub type InferenceParams {
  FluxParams(FluxParameters)
  QwenImageParams(QwenParameters)
}

pub fn params_match(kind: ModelKind, params: InferenceParams) -> Bool {
  case kind, params {
    Flux, FluxParams(_) -> True
    QwenImage, QwenImageParams(_) -> True
    Flux, QwenImageParams(_) -> False
    QwenImage, FluxParams(_) -> False
  }
}
