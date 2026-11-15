# GameNest's shared base image for the 16 room servers (prod_v2, 2026-11-15). Built once per deploy by box_deploy.sh as gamenest-v2/base;
# every room server's own Dockerfile starts FROM it (build arg BASE), so its layers are stored once on the box.
#   Node 26.5.0 (the version every server runs on the dev Mac), pinned by digest.
#   onnxruntime-node 1.30.0 (MIT) at /opt/ort, found through NODE_PATH: the chat filter (moderation.js, every server), Word Spies' bots,
#   Chess's Maia bots. Its CPU build is bundled in the npm package; the install script (an optional CUDA download) is never run, and the
#   other platforms' binaries are removed.
#   The models, from public Hugging Face repos at pinned revisions, each checked by size and sha256 (fetch_models.js, models.json):
#   the chat filter's toxic-bert (110 MB) and Word Spies' MiniLM (23 MB). Chess's Maia model is made in the chess image's own build.
FROM node:26.5.0-bookworm-slim@sha256:2d49d876e96237d76de412761cf05dbfe5aee325cc4406a4d41d5824c5bb8beb
ENV NODE_ENV=production

WORKDIR /opt/ort
COPY ort/package.json ort/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force \
 && node -e "const fs=require('fs'),p=require('path');const b='node_modules/onnxruntime-node/bin/napi-v6';for(const os of fs.readdirSync(b))for(const a of fs.readdirSync(p.join(b,os)))if(os!==process.platform||a!==process.arch)fs.rmSync(p.join(b,os,a),{recursive:true,force:true});"
ENV NODE_PATH=/opt/ort/node_modules

COPY fetch_models.js models.json /tmp/models/
RUN node /tmp/models/fetch_models.js /tmp/models/models.json /models && rm -rf /tmp/models && chmod -R a+rX /models
ENV MODERATION_MODEL_DIR=/models/toxic-bert SPIES_MODEL_DIR=/models/spies

# The build stops here unless onnxruntime loads both models on this machine.
RUN node -e "const ort=require('onnxruntime-node');Promise.all(['/models/toxic-bert/model_quantized.onnx','/models/spies/model_qint8_arm64.onnx'].map(f=>ort.InferenceSession.create(f))).then(s=>{console.log('onnxruntime-node '+require('onnxruntime-node/package.json').version+' loads both models: '+s.map(x=>x.inputNames.join('+')).join(', '))}).catch(e=>{console.error(e);process.exit(1)})"

WORKDIR /app
