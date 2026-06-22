# Third-party notices

HandsOff bundles the following third-party components. Attribution is retained per
each component's license.

## MediaPipe Tasks Vision (`@mediapipe/tasks-vision`)

- **Version:** 0.10.35
- **License:** Apache License 2.0
- **Copyright:** © Google LLC
- **Source / license text:** https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE
- **What we bundle:** the WebAssembly runtime (`public/wasm/*`, copied from the npm
  package) and the Hand Landmarker model (`public/models/hand_landmarker.task`,
  downloaded from Google's `mediapipe-models` storage).

Apache-2.0 permits commercial use, modification, and redistribution provided the
copyright, license, and this notice are retained. The software is provided "AS IS"
without warranty (Apache-2.0 §7–8). The npm package does not ship a LICENSE file, so
this notice supplies the required attribution.

### ⚠️ Open item — model-weights license (flag to team / counsel before release)

The `hand_landmarker.task` weights carry **no embedded or accompanying license
statement** (verified: the `.task` is a zip of two `.tflite` files with no LICENSE,
NOTICE, or copyright string). The reasonable reading is that the weights ship under the
MediaPipe project's Apache-2.0 grant, but Google publishes **no explicit "the weights
are licensed under X" sentence** on any fetched page. Treat the model-weights license
as **UNVERIFIED** and confirm with the team/counsel before a public release.

Fallback if the weights license can't be cleared: TensorFlow.js `hand-pose-detection`
(Apache-2.0, same 21-keypoint output). See `docs/research/models/alternatives.md`.
