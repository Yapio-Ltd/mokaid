// Shared, bounded procedural display content for Metal and Direct3D.
// These are local ambient displays; they never represent API/task activity.
#ifdef __METAL_VERSION__
#define SCREEN_MIX mix
#define SCREEN_FRACT fract
#else
#define SCREEN_MIX lerp
#define SCREEN_FRACT frac
#endif

float screenHash(float value) {
  return SCREEN_FRACT(sin(value * 12.9898 + 78.233) * 4375.8545);
}
float screenRect(float2 coordinate, float2 low, float2 high, float2 aa) {
  const float2 mask = smoothstep(low - aa, low + aa, coordinate) *
                     (1.0 - smoothstep(high - aa, high + aa, coordinate));
  return mask.x * mask.y;
}
float screenStroke(float value, float center, float halfWidth, float aa) {
  return 1.0 - smoothstep(halfWidth, halfWidth + aa, abs(value - center));
}
float3 ambientScreen(float2 uv, float seconds, float seed) {
  const float2 aa = max(fwidth(uv), float2(.0015, .0015));
  const float t = seconds + seed * 7.31;
  const float variant = floor(SCREEN_FRACT(seed * .6180339) * 3.0);
  const float3 cyan = float3(.24, .72, 1.08);
  const float3 mint = float3(.20, .89, .64);
  const float3 violet = float3(.67, .43, .99);
  const float3 textColor = float3(.72, .84, 1.04);
  float3 color = SCREEN_MIX(float3(.025, .043, .070), float3(.014, .023, .041), uv.y);
  // A consistent window frame helps tiny displays read as actual computers.
  color = SCREEN_MIX(color, float3(.054, .081, .119), screenRect(uv, float2(.025, .025), float2(.975, .135), aa));
  const float dotX = SCREEN_FRACT((uv.x - .06) / .038);
  const float dots = screenRect(uv, float2(.06, .061), float2(.164, .091), aa) *
                     screenStroke(dotX, .5, .24, aa.x / .038);
  color = SCREEN_MIX(color, float3(.49, .62, .73), dots);
  color = SCREEN_MIX(color, float3(.27, .38, .51), screenRect(uv, float2(.24, .065), float2(.63, .086), aa));
  color = SCREEN_MIX(color, float3(.027, .046, .071), screenRect(uv, float2(.025, .153), float2(.205, .955), aa));
  const float sideRow = SCREEN_FRACT((uv.y - .20) * 8.0);
  const float sidebar = screenRect(uv, float2(.059, .205), float2(.157, .81), aa) *
                        screenStroke(sideRow, .4, .045, aa.y * 8.0);
  color = SCREEN_MIX(color, float3(.26, .36, .48), sidebar);

  if (variant < .5) {
    // Syntax-colored tokens, a slowly advancing active row, and a soft cursor.
    const float scroll = t * .022;
    const float rowPosition = (uv.y - .19) * 10.8 + scroll;
    const float row = floor(rowPosition);
    const float rowY = SCREEN_FRACT(rowPosition);
    const float inset = .027 * floor(screenHash(row + seed) * 4.0);
    const float start = .255 + inset;
    const float token = floor((uv.x - start) / .097);
    const float tokenX = SCREEN_FRACT((uv.x - start) / .097);
    const float lengthMask = 1.0 - smoothstep(.46 + .40 * screenHash(row * 2.3 + seed),
                                             .48 + .40 * screenHash(row * 2.3 + seed), uv.x);
    const float lines = screenRect(uv, float2(start, .18), float2(.94, .88), aa) * lengthMask *
                        screenStroke(rowY, .46, .040, aa.y * 10.8) *
                        (1.0 - smoothstep(.74, .83, tokenX));
    const float tokenColor = screenHash(row * 3.17 + token * 1.73 + seed);
    const float3 syntax = tokenColor < .32 ? cyan : tokenColor < .63 ? mint : tokenColor < .85 ? textColor : violet;
    color = SCREEN_MIX(color, syntax, lines);
    const float caret = screenRect(uv, float2(.29, .906), float2(.305, .942), aa) *
                        (.32 + .68 * smoothstep(-.25, .25, sin(t * 2.6)));
    color = SCREEN_MIX(color, mint, caret);
    color = SCREEN_MIX(color, float3(.14, .38, .33), screenRect(uv, float2(.33, .919), float2(.57, .935), aa));
  } else if (variant < 1.5) {
    // Compact analytics: three metric cards, chart grid and independent traces.
    const float cardX = SCREEN_FRACT((uv.x - .24) / .238);
    const float card = screenRect(uv, float2(.24, .18), float2(.93, .405), aa) *
                       screenRect(float2(cardX, uv.y), float2(.02, .18), float2(.90, .405), aa);
    color = SCREEN_MIX(color, float3(.047, .075, .119), card);
    const float heading = card * screenStroke(uv.y, .225, .008, aa.y) * (1.0 - smoothstep(.59, .68, cardX));
    color = SCREEN_MIX(color, float3(.33, .46, .62), heading);
    const float value = card * screenRect(float2(cardX, uv.y), float2(.15, .28), float2(.64, .337), aa);
    color = SCREEN_MIX(color, textColor, value);
    const float plot = screenRect(uv, float2(.25, .46), float2(.94, .86), aa);
    const float grid = plot * screenStroke(SCREEN_FRACT((uv.y - .46) * 10.0), .0, .012, aa.y * 10.0);
    color = SCREEN_MIX(color, float3(.083, .136, .193), grid);
    const float chartX = (uv.x - .27) / .65;
    const float wave = .745 - chartX * .16 - .045 * sin(chartX * 12.0 + t * .18) - .025 * sin(chartX * 29.0 + seed);
    const float wave2 = .795 - chartX * .08 - .027 * sin(chartX * 15.0 + t * .13 + 2.0);
    color = SCREEN_MIX(color, mint, plot * screenStroke(uv.y, wave, .006, aa.y));
    color = SCREEN_MIX(color, cyan * .76, plot * screenStroke(uv.y, wave2, .004, aa.y));
    color = SCREEN_MIX(color, float3(.19, .31, .44), screenRect(uv, float2(.27, .912), float2(.60, .931), aa));
  } else {
    // A browser-like workspace with a feature card and a gently scrolling list.
    color = SCREEN_MIX(color, float3(.092, .145, .212), screenRect(uv, float2(.24, .18), float2(.94, .405), aa));
    color = SCREEN_MIX(color, float3(.33, .53, .76), screenRect(uv, float2(.28, .216), float2(.46, .345), aa));
    color = SCREEN_MIX(color, textColor, screenRect(uv, float2(.50, .23), float2(.85, .254), aa));
    color = SCREEN_MIX(color, float3(.39, .54, .71), screenRect(uv, float2(.50, .29), float2(.89, .305), aa));
    color = SCREEN_MIX(color, float3(.29, .43, .61), screenRect(uv, float2(.50, .327), float2(.77, .341), aa));
    const float listPosition = (uv.y - .46) * 6.7 + t * .018;
    const float item = floor(listPosition);
    const float listY = SCREEN_FRACT(listPosition);
    const float listMask = screenRect(uv, float2(.25, .44), float2(.94, .92), aa);
    const float thumbnail = listMask * screenRect(float2(uv.x, listY), float2(.27, .10), float2(.385, .75), float2(aa.x, aa.y * 6.7));
    color = SCREEN_MIX(color, SCREEN_MIX(violet * .45, cyan * .45, screenHash(item + seed)), thumbnail);
    const float listTitle = listMask * screenRect(float2(uv.x, listY), float2(.43, .20), float2(.79, .30), float2(aa.x, aa.y * 6.7));
    const float listSubtitle = listMask * screenRect(float2(uv.x, listY), float2(.43, .48), float2(.89, .54), float2(aa.x, aa.y * 6.7));
    color = SCREEN_MIX(color, textColor * .78, listTitle);
    color = SCREEN_MIX(color, float3(.29, .43, .60), listSubtitle);
  }
  // Soft glass edge, with no scanline flicker or synchronized pulsing.
  const float edge = screenRect(uv, float2(.014, .014), float2(.986, .986), aa);
  return SCREEN_MIX(float3(.010, .016, .024), color * 1.12, edge);
}
#undef SCREEN_MIX
#undef SCREEN_FRACT
