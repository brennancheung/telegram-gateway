# Documentation diagrams

These diagrams explain the gateway's components, event flow, access model, and approval
sequence. The PNGs use a shared visual style: a light background, dark labels, outline
icons, blue connections, and teal approved access. Each image is 1536 × 1024 pixels.

| Image | Used in | Purpose |
|---|---|---|
| [overview.png](overview.png) | [README](../../README.md) | Telegram, the gateway, administration, and consuming apps |
| [architecture.png](architecture.png) | [Architecture](../architecture.md) | Process ownership and storage before delivery |
| [grants.png](grants.png) | [Grants](../grants.md) | The intersection of monitored and granted chats |
| [access-request.png](access-request.png) | [API](../api.md#access-requests) | Request, polling, approval, and token collection |

## Maintenance

The surrounding prose and alt text describe the diagrams without requiring image access.
When changing an image, check its labels, arrows, process boundaries, and set relationships
against the API and architecture documents. Update the corresponding alt text if its meaning
changes. Keep illustrative identities and credentials fictional.

These files were produced with the built-in imagegen tool. That interface exposes no
separate quality or resolution setting; the requested 3072 × 2048 output was returned at
1536 × 1024. The repository stores the generated PNGs without upscaling or lossy compression.
The diagrams keep a light background in either viewer theme; application screenshots in
`docs/screenshots/` have separate light and dark variants.

## Style reference for contributors

Use the current image as the reference when revising a diagram. The following prompt records
the shared style direction. Only the grants diagram uses overlapping sets; the overview's
three feature icons are independent.

```text
Use case: style-transfer. Edit the provided Telegram Gateway diagram into a thoroughly contemporary, professionally art-directed technical publication graphic.

CONTENT AND LAYOUT ARE LOCKED: preserve the same words verbatim, exact component inventory, relative positions, boundaries, connector endpoints, arrow directions, sequence order and technical meaning. Restyle the entire image from scratch; none of the current surface treatment should survive.

DESIGN SYSTEM:
Pure flat white #FFFFFF background, perfectly uniform, no paper texture or noise.
Precise Swiss information design and contemporary developer documentation aesthetic. Typography similar to Inter / Helvetica Neue: charcoal #20242B, medium-weight headers, regular-weight body, understated and beautifully spaced. Reduce the oversized heavy headline to a confident medium-weight title while preserving its place and leaving breathing room. Code strings in a crisp modern monospaced font. No serif fonts.
Hairline neutral-gray borders #DDE1E6, pale cool-gray #F7F8FA panels, tightly controlled small corner radii. Uniform thin 2D connectors, small sharp arrowheads. Clean geometric shapes and pixel-precise alignments.
Use one restrained muted cobalt blue #3765B0 for principal connections and minimal accents. Approved access uses muted deep teal #237565. Pending uses very pale warm-gray panel with subdued amber border. Keep most of the canvas white or neutral. No rainbow accents.
Replace every current bulky 3D icon with a much smaller, elegant flat monoline pictogram in a consistent stroke weight. Paper-plane is a simple outline, service is a minimal outlined square/node, database is a simple line glyph, Mac window/terminal are clean outlined rectangles, app tiles are thin border squares with understated line symbols. Human becomes a simple outline person glyph, NOT an illustrated person or avatar. Preserve labels. Treat icons as secondary to information, not giant visual attractions.
For overlapping sets use uniform pale transparent flat fills with a clear muted-teal intersection and perfect smooth circular contours; tiny chat symbols are flat monoline outlines. Text inside the intersection must have strong contrast.
No 3D, no extrusion, no isometric view, no shadows, no bevels, no glossy surfaces, no plastic or clay, no lighting effects, no gradients, no glowing colors, no emoji, no cartoon people, no clip art, no textures, no wobbly AI ornament. No new decorative details, no branding watermarks.

QUALITY: use the highest available rendering quality and maximum fidelity. Request 3072 x 2048 output, same 3:2 landscape aspect ratio. Meticulous clean antialiasing, mathematically smooth curves, straight consistent line weights, perfectly formed sharp readable glyphs, no duplicated characters, no compression fuzz, no ghost edges or texture artifacts. This should look like a designer's finished export from a professional diagram design tool.
```
