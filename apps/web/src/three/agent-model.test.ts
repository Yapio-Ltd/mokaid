import { afterEach, describe, expect, it } from "vitest";
import { Animation, AnimationGroup, NullEngine, Scene, TransformNode } from "@babylonjs/core";
import { advanceAgentAnimation, completeAgentAnimationTracks, disposeAgentAnims, normalizeAnimName, playAgentAnimation, setAgentWalkSpeed, type AgentAnimPlayer } from "./agent-model";

const engines: NullEngine[] = [];
function player() {
  const engine = new NullEngine(); engines.push(engine);
  const scene = new Scene(engine);
  const node = new TransformNode("hips", scene);
  function clip(name: string, value: number) {
    const group = new AnimationGroup(name, scene);
    const animation = new Animation(name, "position.y", 30, Animation.ANIMATIONTYPE_FLOAT);
    animation.setKeys([{ frame: 0, value }, { frame: 30, value }]);
    group.addTargetedAnimation(animation, node);
    return group;
  }
  const idle = clip("idle", 1), walking = clip("walking", 2), sitting = clip("sitting", 0.5);
  const avatar: AgentAnimPlayer = { anims: { idle, walking, sitting }, idleAnim: idle, walkAnim: walking, currentAnim: null };
  return { avatar, idle, walking, sitting, scene, node };
}
afterEach(() => { engines.splice(0).forEach(engine => engine.dispose()); });

describe("avatar animation transitions", () => {
  it("retains both poses during a transition, then retires the old clip", () => {
    const { avatar, idle, walking } = player();
    playAgentAnimation(avatar, "idle"); playAgentAnimation(avatar, "walking");
    for (let i = 0; i < 4; i++) advanceAgentAnimation(avatar, 1 / 30);
    expect(idle.isPlaying).toBe(true); expect(walking.isPlaying).toBe(true);
    expect(idle.weight + walking.weight).toBeCloseTo(1);
    expect(walking.weight).toBeGreaterThan(0); expect(walking.weight).toBeLessThan(1);
    for (let i = 0; i < 5; i++) advanceAgentAnimation(avatar, 1 / 30);
    expect(idle.isPlaying).toBe(false); expect(walking.weight).toBe(1);
  });
  it("preserves normalized weights when a transition is interrupted", () => {
    const { avatar, idle, walking, sitting } = player();
    playAgentAnimation(avatar, "idle"); playAgentAnimation(avatar, "walking");
    advanceAgentAnimation(avatar, 0.05);
    const before = idle.weight;
    playAgentAnimation(avatar, "sitting");
    expect(idle.weight).toBe(before);
    advanceAgentAnimation(avatar, 0.05);
    expect(idle.weight + walking.weight + sitting.weight).toBeCloseTo(1);
    disposeAgentAnims(avatar);
    advanceAgentAnimation(avatar, 0.05);
  });
  it("has the same blend after equal elapsed time at 30 and 60 fps", () => {
    const a = player(), b = player();
    for (const p of [a, b]) { playAgentAnimation(p.avatar, "idle"); playAgentAnimation(p.avatar, "walking"); }
    for (let i = 0; i < 6; i++) advanceAgentAnimation(a.avatar, 1 / 30);
    for (let i = 0; i < 12; i++) advanceAgentAnimation(b.avatar, 1 / 60);
    expect(a.walking.weight).toBeCloseTo(b.walking.weight);
  });
  it("applies the destination pose to the rig after a crossfade", () => {
    const { avatar, scene, node } = player();
    scene.useConstantAnimationDeltaTime = true;
    playAgentAnimation(avatar, "idle");
    scene._animate();
    playAgentAnimation(avatar, "sitting");
    for (let i = 0; i < 30; i++) { advanceAgentAnimation(avatar, 1 / 60); scene._animate(); }
    expect(node.position.y).toBeCloseTo(0.5);
  });
  it("restores translations omitted by a sparse activity after a retargeted walk", () => {
    const { avatar, walking, sitting, scene, node } = player();
    const translation = new Animation("retarget", "position", 30, Animation.ANIMATIONTYPE_VECTOR3);
    translation.setKeys([{ frame: 0, value: node.position.clone().set(2, 3, 4) }, { frame: 30, value: node.position.clone().set(2, 3, 4) }]);
    walking.addTargetedAnimation(translation, node);
    completeAgentAnimationTracks([walking, sitting]);
    const restored = sitting.targetedAnimations.find(track => track.animation.targetProperty === "position");
    expect(restored?.animation.getKeys()[0].value.asArray()).toEqual([0, 0, 0]);
    scene.useConstantAnimationDeltaTime = true;
    playAgentAnimation(avatar, "walking"); scene._animate();
    playAgentAnimation(avatar, "sitting");
    for (let i = 0; i < 30; i++) { advanceAgentAnimation(avatar, 1 / 60); scene._animate(); }
    expect(node.position.x).toBeCloseTo(0); expect(node.position.z).toBeCloseTo(0);
  });
  it("slows the stride when navigation brakes", () => {
    const { avatar, walking } = player();
    playAgentAnimation(avatar, "walking"); setAgentWalkSpeed(avatar, 0.75);
    expect(walking.speedRatio).toBeCloseTo(0.5);
    playAgentAnimation(avatar, "walking");
    expect(walking.speedRatio).toBeCloseTo(0.5);
  });
  it("recognizes compound clip aliases after Babylon instance prefixes", () => {
    expect(normalizeAnimName("agent-id-sitting_sofa")).toBe("sitting");
    expect(normalizeAnimName("agent-id-preparing_coffee")).toBe("preparing_coffee");
    expect(normalizeAnimName("agent-id-requesting_approval")).toBe("requesting_approval");
  });
});
