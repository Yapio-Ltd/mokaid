import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mediaRange, createMediaThrottleProxy } from "./cinematic-media-throttle.mjs";

test("byte ranges clamp ends, support suffixes, and reject malformed/unsatisfiable input", () => {
  assert.deepEqual(mediaRange(undefined, 100), { status: 200, start: 0, end: 99 });
  assert.deepEqual(mediaRange("bytes=20-200", 100), { status: 206, start: 20, end: 99 });
  assert.deepEqual(mediaRange("bytes=20-", 100), { status: 206, start: 20, end: 99 });
  assert.deepEqual(mediaRange("bytes=-10", 100), { status: 206, start: 90, end: 99 });
  for (const header of ["bytes=-0", "bytes=100-", "bytes=40-20", "bytes=0-1,4-5", "bytes=-", "foo"])
    assert.equal(mediaRange(header, 100), null);
});

test("proxy streams real byte ranges under one aggregate scheduler", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cinema-throttle-unit-"));
  const file = join(directory, "tiny-test-bytes.bin");
  const bytes = Buffer.alloc(8192, 67);
  await writeFile(file, bytes);
  const proxy = await createMediaThrottleProxy({
    upstreamOrigin: "http://127.0.0.1:1",
    mediaPath: "/test.mp4",
    mediaFile: file,
    bytesPerSecond: 32 * 1024,
  });
  try {
    const started = Date.now();
    const responses = await Promise.all(
      [0, 4096].map((start) =>
        fetch(`${proxy.origin}/test.mp4`, { headers: { Range: `bytes=${start}-${start + 4095}` } }),
      ),
    );
    const bodies = await Promise.all(responses.map((response) => response.arrayBuffer()));
    assert.equal(responses[0].status, 206);
    assert.equal(responses[0].headers.get("content-range"), "bytes 0-4095/8192");
    assert.equal(responses[1].headers.get("content-range"), "bytes 4096-8191/8192");
    bodies.forEach((body) => assert.deepEqual(Buffer.from(body), bytes.subarray(0, 4096)));
    assert.ok(Date.now() - started >= 190, "Concurrent connections must share the 32 KiB/s cap");
    assert.equal(proxy.snapshot().transferredBytes, 8192);
    const invalid = await fetch(`${proxy.origin}/test.mp4`, { headers: { Range: "bytes=9000-" } });
    assert.equal(invalid.status, 416);
    assert.equal(invalid.headers.get("content-range"), "bytes */8192");
  } finally {
    await proxy.close();
    await rm(directory, { recursive: true, force: true });
  }
});
