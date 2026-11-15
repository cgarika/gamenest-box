/* Fetches the room servers' models from Hugging Face (public repos, no token) at pinned revisions and checks each file's size and
   sha256; any mismatch stops the image build. Usage: node fetch_models.js <models.json> <dest dir> */
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const [list, destDir] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  for (const m of JSON.parse(fs.readFileSync(list, "utf8"))) {
    const url = `https://huggingface.co/${m.repo}/resolve/${m.rev}/${m.path}`;
    const dest = path.join(destDir, m.dest);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    for (let attempt = 1; ; attempt++) {
      try {
        const r = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(600000) });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const buf = Buffer.from(await r.arrayBuffer());
        const sha = crypto.createHash("sha256").update(buf).digest("hex");
        if (buf.length !== m.size || sha !== m.sha256) {
          console.error(`MISMATCH ${m.repo}/${m.path}@${m.rev}: ${buf.length} bytes sha256 ${sha}; want ${m.size} bytes ${m.sha256}`);
          process.exit(1);
        }
        fs.writeFileSync(dest, buf);
        console.log(`ok ${m.dest} (${m.size} bytes, sha256 ${sha.slice(0, 12)})`);
        break;
      } catch (e) {
        if (attempt >= 5) { console.error(`could not fetch ${url}: ${e.message}`); process.exit(1); }
        console.log(`retry ${attempt} for ${m.path}: ${e.message}`);
        await sleep(5000 * attempt);
      }
    }
  }
})();
