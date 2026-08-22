import flujo/domain/model.{type SizePolicy}

pub opaque type ImageSize {
  ImageSize(width: Int, height: Int)
}

pub type ImageSizeError {
  SideTooSmall
  SideTooLarge
  InvalidMultiple
  AreaTooLarge
}

pub fn new(
  width: Int,
  height: Int,
  policy: SizePolicy,
) -> Result(ImageSize, ImageSizeError) {
  case policy {
    model.SizePolicy(min_side, max_side, multiple, max_area) ->
      case
        width < min_side || height < min_side,
        width > max_side || height > max_side,
        width % multiple != 0 || height % multiple != 0,
        width * height > max_area
      {
        True, _, _, _ -> Error(SideTooSmall)
        _, True, _, _ -> Error(SideTooLarge)
        _, _, True, _ -> Error(InvalidMultiple)
        _, _, _, True -> Error(AreaTooLarge)
        False, False, False, False -> Ok(ImageSize(width, height))
      }
  }
}

pub fn width(size: ImageSize) -> Int {
  size.width
}

pub fn height(size: ImageSize) -> Int {
  size.height
}
