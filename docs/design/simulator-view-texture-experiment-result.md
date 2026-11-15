# Fixture-only `snapshotImage` experiment

2026-11-09. One guarded portrait Simulator session returned image data for the
fixture. The blue parent image contained no pixels from its orange or red
children. This is evidence for that fixture and request only, not a general
contract for independent view textures. Ordinary capture, LCD overlays and 3D
presentation remain unavailable; `verified` and `overlayEnabled` stay false.

## Implementation delta

The existing request schema accepts an optional Boolean
`validationTextureProbe` only with `validationOnly: true`. The existing target
policy still requires the `HierarchyFixture` executable and fixture bundle ID.
The fixture session forwards its opt-in `--texture-probe` through the existing
parent/worker and capture path. No caller-selected property, expression,
selector, command or additional output path is accepted. With the option absent
or false, the hierarchy request is unchanged. With it true, only `snapshotImage`
is appended to `propertyNames`: discovery remains 1, transport compression
false, visibility 1 and property-name exclusivity false. The test fixes the
UUID and compares the entire default serialized request, then verifies the
one-property delta.

The enabled path retains the exact outgoing JSON bytes and target response bytes
in the private capture directory, applies the existing 16 MiB cap, and requires
the parsed response to match the capture envelope. It does not add a product
image decoder. Swift, product UI, manifests and installation were not changed.

## Session and response

The selected already-booted device was
`64A62D96-12FE-4D9C-81AE-ED9C3A2174F0`. The fixed end was
`2026-11-09T03:04:33Z`; capture ran from `02:59:07.746704Z` to
`02:59:08.679912Z`, and the capture supervisor reported 10.22 seconds. The
single capture ID was `c6ed08d5-28d3-4b0b-94cb-3348de92c8fb`.
Selected Xcode supplied the iOS 27.2 Simulator SDK and LLDB. Parent/worker
deadline transmission and supervisor/LLDB-worker clock transmission agreed.

The 679-byte wire request (`/tmp/mac-pilot-texture-live-20261109-01/capture/hierarchy-request.json`)
has SHA-256 `ca55bf22d7d8c5717d6345dd6a20cdebd2b00b064f29bed2ac7d99ae3eee2c50`.
The exact 405,764-byte response (`/tmp/mac-pilot-texture-live-20261109-01/capture/hierarchy-response.json`)
has SHA-256 `fd430bd867c2463a0ae758a58f6972b40861ea84752bc0cbdf9bc5432d3ad382`.
Its echoed request contains the same UUID and property list, plus serializer
defaults such as `objectIdentifiers: null`; these defaults were not added to the
outgoing request. The response describes `propertyName: snapshotImage`,
`propertyFormat: image`, `propertyRuntimeType: UIImage`, `fetchStatus: 4`, and
`propertyValue` with `imageData` and `metadata`. In this response `imageData` is
base64 encoding of PNG bytes. Metadata reports point width and height; the
observed PNG dimensions are three times those values. The numeric fetch status
is reported as observed, without assigning it an undocumented meaning.

All 14 captured hierarchy nodes had this property. The seven named fixture
views joined by exact object ID to the same capture's converted snapshot and
geometry; no cross-session address join was used. The original hierarchy,
properties, corners, and screenshot remain in the evidence directory. The
independent oracle had zero corner error for all seven views. Screenshot and
hierarchy are separate, non-atomic observations.

| Fixture view | Same-capture node ID | PNG pixels | PNG bytes | Observation |
| --- | --- | --- | ---: | --- |
| root | `0x1043841c0` | 1206 × 2622 | 61,453 | Exceeds 1024 × 1024; unavailable and not decoded. |
| container | `0x104384540` | 780 × 540 | 9,624 | Entire image is opaque blue; no orange or red child pixels. |
| transform | `0x104384700` | 360 × 195 | 2,195 | Entire image is opaque orange in local, unrotated image bounds. |
| clipped | `0x1043848c0` | 270 × 240 | 2,202 | Entire image is opaque red, including the portion clipped by its parent on screen. |
| hidden | `0x104384a80` | 120 × 120 | 571 | Entire image is transparent; fixture has no background color. |
| scroll | `0x104150000` | 780 × 450 | 7,772 | Gray and transparent regions; no green child pixels. |
| scrolled | `0x104384fc0` | 300 × 210 | 2,023 | Entire image is opaque green. |

The separately inspected screenshot (`/tmp/mac-pilot-texture-live-20261109-01/device.png`)
shows the transformed orange child and partially clipped red child over the blue
container, and green over the scroll view. The gray/transparent scroll image
does not by itself establish a complete standalone scroll-view texture. The
fixture has no colored hidden view, overlapping translucent siblings, masks,
effects or perspective case, so those semantics remain untested. In particular,
the transparent hidden image cannot establish how a hidden colored view behaves.
No hide/unhide or run-loop action was used. No same-lifetime baseline comparison
is claimed.

The analysis selected the seven named nodes and rejected duplicate or unknown
IDs and duplicate image hashes. It checked base64 and per-image encoded size,
PNG signature and IHDR dimensions, and aggregate budgets before Pillow loaded
pixels. Limits were 64 images, 1024 × 1024 pixels each, 4 MiB encoded per
image, 16 MiB aggregate encoded, and 32 MiB aggregate decoded RGBA. Six admitted
images total 24,387 encoded bytes and 3,938,400 decoded RGBA bytes. The root was
not resized or decoded. Decoded images and per-image metadata, hashes and pixel
counts are in inspection.json (`/tmp/mac-pilot-texture-decoded-20261109-01/inspection.json`);
the bounded inspection script is `/tmp/mac-pilot-texture-inspect-20261109.py`.
These host limits do not constrain allocations performed inside the target.

## Safety and verification receipt

The session used the existing instance budget: parent 1, worker 1, fixture 1,
capture supervisor 1, LLDB worker 1, debugserver 1, probe 1 and serialized
simctl 1. The selected device passed inventory, claim, portrait, foreground,
desktop-lock, input and fixture/data-absence gates. The prepared probe was
reused only after source and binary hash verification; preparation retained a
new manifest and dispatch receipt. No historical prepared08/live06 files were
modified.

The runtime confirmed unique main-thread selection and `NSThread.isMainThread`,
successful detach, the same target lifetime running and untraced after detach,
and worker/debugserver reaping. The fixture was observed gone before its new
bundle and data were removed. Original foreground, display and host layout were
restored; the owned claim was released; the new session group was empty. The
existing cleanup used `simctl terminate` for the identified owned fixture; it
sent no direct signal to the target, user, historical PID, or process group, and
used no `SIGCONT`. Receipts are session.json (`/tmp/mac-pilot-texture-live-20261109-01/session.json`),
parent.json (`/tmp/mac-pilot-texture-live-20261109-01/parent.json`), and
capture-result.json (`/tmp/mac-pilot-texture-live-20261109-01/capture-result.json`).

Headless checks before the live session:

- Capture tests: 22 passed, including option policy, exact request delta,
  LLDB-engine forwarding, cancellation, cleanup and direct-child ownership.
- Fixture session tests: 26 passed, including worker option dispatch and deadline,
  input, ownership and restoration guards.
- Native safety regression: 6 passed. Preparation independently proved
  helper, unknown and inherited entry routes and exact instance budgets.
- `check-view-capture.py`: passed both expression syntax variants, canonical
  isolated build/signature, packaged resources, Swift conversion and dispatch.
- Xcode Python `session.py --guard --texture-probe`: passed with zero mutations,
  unchanged parent/worker deadline, and empty owned group.
- `python3 scripts/validate_distribution.py`: passed. `git diff --check`: passed.

Full logs: `/tmp/mac-pilot-texture-headless-20261109.log`,
`/tmp/mac-pilot-texture-session-tests-20261109.log`,
`/tmp/mac-pilot-texture-native-safety-20261109.log`,
`/tmp/mac-pilot-texture-prepare-20261109.log`,
`/tmp/mac-pilot-texture-guard-20261109.log`,
`/tmp/mac-pilot-texture-distribution-20261109.log`, and
`/tmp/mac-pilot-texture-live-20261109.log`. The new prepared manifest is
`/tmp/mac-pilot-texture-prepared-20261109-01/prepared.json`. This was one live
session, with no speculative retry, global installation or publication.
