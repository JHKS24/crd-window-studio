# Project artwork

`AppIcon.png` is the public project icon: two overlapping neutral window frames with a blue status dot in a small capsule. It does not reuse a Google/Chrome logo or vendor icon file.

- Source format: PNG with alpha, 1254 × 1254 pixels.
- Source SHA-256: `1447a5c3a2db0356facd1b7c8d7c9e7c4e967b22b7d111047c804ccf43dac8ac`.
- License: the repository [MIT license](../LICENSE), to the extent of contributors' rights. This does not assert exclusive copyright or trademark clearance for AI-generated artwork.
- Build: `scripts/package.py` resizes the source using macOS `sips` and packages the required ICNS sizes with `iconutil`. No image-generation service or account is needed to build the app.

The source PNG contains provenance metadata. Only the documented PNG is a source asset; ICNS files are generated during packaging.
