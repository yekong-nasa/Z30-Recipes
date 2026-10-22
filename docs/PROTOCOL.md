# PTP/IP implementation notes

These are observations used by this implementation, not a Nikon specification. Camera firmware may differ.

## Operations

- `0x1002` / `0x1003`: open / close session.
- `0x1014`, `0x1015`, `0x1016`: descriptor, get and set property; `0xD200` selects Picture Control.
- `0x90CC`: read Picture Control data, parameters `[profile, mode]`.
- `0x90CD`: send Picture Control data, parameters `[customProfile, 0]`.
- Custom slots C1–C9 use profile IDs 201–209. Writes target custom slots.
- A command/event connection pair is kept open. A FIFO gate serializes complete transactions and heartbeat traffic across actor suspension points.

## Traditional wire dataset

The observed header is 36 bytes. A custom curve appends 578 bytes for a total of 614.

| Offset | Meaning used by the implementation |
| --- | --- |
| 0 | Base ID: Standard 1, Neutral 2, Vivid 3, Monochrome 4, Portrait 5, Landscape 6 |
| 1 | Camera-native base flag; read from the matching built-in style when available |
| 2–21 | NUL-padded name, 20 bytes |
| 23 | Camera state byte: 0 and 1 have been observed |
| 25–31 | Sharpening, mid-range sharpening, clarity, contrast, brightness, saturation, hue; numeric manual values use signed quarter steps |
| 32–34 | Monochrome filter, toning, density fields in the trial encoder |
| 35 | Custom curve flag |
| 36 onward | Optional complete curve block |

On the development Z30, built-in monochrome had prefix `04 00`. Unused monochrome fields are taken from the camera's built-in style rather than inferred from a different camera generation. Only plain B&W without filter/colored toning has completed hardware verification so far. Auto/sentinel encoding and colored toning remain experimental.

## Curves

The 578-byte curve block stores the curve header, control points, and padding in bytes 0–63, followed by **257 big-endian 16-bit LUT entries** at offset 64. Values run from 0 to 32767. Keep the complete source block; do not rebuild the LUT from a reduced set of points when lossless preservation is intended.

## Readback

Mode 0 is used to verify stored data. On the development Z30, a successfully stored 614-byte recipe could still return a different 36-byte mode-1 state. Independent SD export confirmed the stored curve. A mode-1 mismatch alone therefore does not trigger another edit write or invalidate the stored recipe.

The current implementation checks the complete stored dataset and permits only the observed state-byte normalization. Readback disagreement is reported rather than labeled as a successful full verification.

## Flexible Color

NP3 version `0310` does not by itself identify full compatibility. Flexible Color base `0020` includes eight-color and tonal-region adjustments that cannot generally be represented by a single traditional tone curve and global hue/saturation. This repository does not implement a complete Flexible Color renderer or lossless Z30 downgrade.
