# Mokaid Desktop — third-party notices

Mokaid is published by Yapio Ltd. This file accompanies native distributions.

The complete dependency inventory and individual license texts must be included
in every signed release's SBOM and `licenses` directory. These notices do not
replace the license texts or grant rights to proprietary assets.

## Runtime components

- Qt 6.11.2: dynamically linked Qt modules. Qt licensing varies by module and
  deployment agreement; the release owner must document a commercial license or
  all applicable open-source license obligations before distributing a build.
  https://www.qt.io/licensing/
- Qt WebEngine: Chromium and its third-party components. Ship the license files
  and notices from the exact Qt WebEngine runtime being packaged.
  https://doc.qt.io/qt-6/qtwebengine-licensing.html
- Sparkle 2.9.6 (macOS): MIT license, Copyright Sparkle Project.
  https://github.com/sparkle-project/Sparkle/blob/2.9.6/LICENSE
- WinSparkle 0.9.4 (Windows): MIT license, Copyright Vaclav Slavik.
  https://github.com/vslavik/winsparkle/blob/v0.9.4/COPYING
- Recast/Detour, asset codecs and other renderer dependencies: include the exact
  pinned dependency license files and generated software bill of materials.
- Local voice: Whisper.cpp 1.9.4 and multilingual Whisper base q5_1 (MIT),
  Kokoro 82M v1.0 quantized weights (Apache-2.0), sherpa-onnx 1.13.8
  (Apache-2.0), and ONNX Runtime (MIT). Pinned downloads and license texts
  accompany the `voice` runtime; see `apps/desktop/voice/README.md` in the source.
  https://huggingface.co/ggerganov/whisper.cpp
  https://huggingface.co/hexgrad/Kokoro-82M
  https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8
- The separate sherpa speech helper includes eSpeak NG phonemization
  (GPL-3.0). Preserve its bundled license and corresponding-source availability
  with every distribution of that helper.
  https://github.com/espeak-ng/espeak-ng/tree/1.52.0

## Brand and 3D content

The Mokaid logo is reused from the existing application's source assets. Office,
avatar, animation, texture and font redistribution rights must be recorded by
the release owner; inclusion in the repository alone is not proof of a license.
