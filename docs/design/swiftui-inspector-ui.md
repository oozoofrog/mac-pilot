# SwiftUI inspector consumer

The native inspector consumes `snapshot.swiftUI` from the frozen product integration contract. `SimulatorInspectorSnapshot.nodes` remains the UIKit registry and geometry map. `swiftUI.nodes` is a separate immutable, capture-local graph. Only outline traversal and search combine them. Serialized parent and ordinal fields define all declarative edges.

The consumer checks schema, capture, outer/inner inspection scope, process-lifetime presence, device/display context, hosting token and scene joins, preorder topology, namespace, property IDs, attribute structure, and asset representation. Backend attestation remains responsible for current process/boot custody. The UI cannot establish live authority from an archived envelope.

Budgets apply before typed metadata decoding: 200,000 JSON values including keys, depth 128, container width 8,192, each string 256 KiB, aggregate strings 8 MiB, 4,096 declarative nodes, graph depth 64, 64 hosts, 64 properties per node, 32,768 reflected attributes, and attribute depth 64. Integer metadata keeps its exact decimal representation. Detail rendering has separate per-property limits. Missing source and fixed-space geometry remain unavailable; reflected layout properties do not create geometry.

SwiftUI selection clears the draft, disables apply and restore, and sends no capture, edit, cancel, release, or HID callback. An already-pending UIKit receipt can still finish against its original UIKit node. Invalidating, replacing, or closing the capture removes SwiftUI selection authority. Reusing a consumed SwiftUI capture ID is rejected; one model admits at most 4,096 such captures.

A `hostingSubtreeComposite` is painted on its UIKit hosting plane. All descendant UIKit textures, including nested hosts and representables, are suppressed before decode/upload. Their outline entries, geometry, picking and selection outlines remain available. SwiftUI graph nodes never enter renderer planes or hit testing.

`tests/simulator-inspector-3d/run.py` freezes and typechecks the three owned sources, then runs model/math checks under the headless entry guard and parent watchdog. Sanitized fixtures preserve the observed 102/106-node serialized topology; all properties are test-authored. The canonical wire parser normalizes these fixtures before the real product parser consumes them. `run-metal.py` tests the production encoder against offscreen textures without ordering a window. `run-window.py` is a separate foreground lane and must not be run as part of headless qualification.

Runtime integration must still verify current boot-generation joins, normal prepared-app graph/composite collection, read-only selection callback counts, recapture stale-selection rejection, UIKit hidden/alpha and restore, minimum-size layout, close/reopen, and cleanup. Do not infer per-node SwiftUI textures or general Text/Shape-loss reproduction from these checks.
