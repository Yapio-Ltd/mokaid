/** Mirror the office's authored atlas corrections offline, before GPU upload. */
import sharp from 'sharp';

export function filterOfficePixels(rgba, mode) {
  const out = Buffer.from(rgba);
  for (let i = 0; i < out.length; i += 4) {
    const [r, g, b] = out.subarray(i, i + 3);
    const hi = Math.max(r, g, b), lo = Math.min(r, g, b);
    if (mode === 'emission') {
      const purple = r > 40 && b > 80 && g < Math.max(r, b) * .55;
      const warm = r > 80 && g > 40 && b < Math.max(r, g) * .45;
      const cyan = g > 90 && b > 90 && g > r * .85;
      if (!(hi >= 24 && !cyan && (purple || warm))) out.fill(0, i, i + 3);
    } else if (mode === 'screen') {
      const white = hi > 170 && lo > 130 && hi - lo < 45;
      const screen = !white && b >= 70 && b >= r * .95 && b >= g * .85 && hi - lo > 18;
      out[i] = screen ? Math.min(255, Math.round(r * .85)) : 0;
      out[i + 1] = screen ? Math.min(255, Math.round(g * .9)) : 0;
      out[i + 2] = screen ? Math.min(255, Math.round(b * 1.05)) : 0;
    } else if (hi > 180 && lo > 140 && hi - lo < 50) {
      const factor = mode === 'portrait' ? .28 : .35;
      for (let c = 0; c < 3; c++) out[i + c] = Math.round(out[i + c] * factor);
    }
  }
  return out;
}

export async function prepareOfficeMaterials(document) {
  async function filtered(texture, mode) {
    if (!texture?.getImage()) return null;
    const {data, info} = await sharp(texture.getImage()).ensureAlpha().raw().toBuffer({resolveWithObject: true});
    const image = await sharp(filterOfficePixels(data, mode), {raw: {width: info.width, height: info.height, channels: 4}}).png().toBuffer();
    return document.createTexture(`${texture.getName()}-${mode}`).setImage(image).setMimeType('image/png');
  }
  for (const material of document.getRoot().listMaterials()) {
    const name = material.getName().trim().replace(/\.\d+$/, '');
    if (!['additional', 'Solo items'].includes(name)) continue;
    const original = material.getBaseColorTexture();
    const albedo = await filtered(original, name === 'additional' ? 'portrait' : 'paper');
    if (albedo) material.setBaseColorTexture(albedo);
    material.setMetallicFactor(0).setRoughnessFactor(1);
    if (name === 'additional') {
      const emission = await filtered(material.getEmissiveTexture(), 'emission');
      if (emission) material.setEmissiveTexture(emission);
    } else {
      const emission = await filtered(original, 'screen');
      if (emission) material.setEmissiveTexture(emission).setEmissiveFactor([2.4, 2.4, 2.4]);
    }
  }
}
