# Actual Meshy characters in the native office

`meshy-generated-office-overview.png` shows both real outputs from the text and image Meshy API validation, rendered through the production Qt/Metal viewport and Office engine. The test injects the exact cooked files from `/tmp/mokaid-meshy-live/text.mokaidasset` and `image.mokaidasset` through `CustomAvatarLoader::ready`; it does not replace the catalog assets. Both models are normalized by the engine to the same 1.75 m reference height as existing agents (separately verified by the native `custom_avatar_tests`).

This is an isolated local visual fixture. Its two agent records are synthetic; the geometry and textures are real Meshy output. It verifies rendering, not production authentication or delivery from the deployed asset URL. Generated models currently have walking and a held idle pose; the catalog's authored seated/activity animations are not supplied by Meshy.

Reproduce with `MOKAID_GENERATED_CHARACTER_FIXTURES=/tmp/mokaid-meshy-live MOKAID_OFFICE_CAPTURE_DIR=<capture-directory>` and the `generatedMeshyCharactersRenderAtOfficeScale` test in `mokaid_office_tour_qml_tests`.
