/// Pure point/background geometry used by the dot-only appearance controls.
/// Existing geometry is read as-is; resizing happens only after an explicit edit.
struct DotAppearanceGeometry: Equatable {
    let width: Double
    let height: Double
    let x: Double
    let y: Double

    /// The background margin around a dot of `pointDiameter` in the current frame.
    func padding(pointDiameter: Double) -> Double {
        max(0, (min(width, height) - pointDiameter) / 2)
    }
    /// A square frame that fits the dot plus `padding`, keeping the same center.
    func resized(pointDiameter: Double, padding: Double) -> Self {
        let side = pointDiameter + 2 * padding
        return Self(width: side, height: side,
                    x: x + (width - side) / 2,
                    y: y + (height - side) / 2)
    }
}
